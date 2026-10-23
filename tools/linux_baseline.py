"""Pinned Ubuntu 20.04 native builds and fail-closed Linux release ABI checks."""
from __future__ import annotations
import hashlib
import csv
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

MAX_GLIBC = '2.31'
BASE_IMAGE = 'ubuntu@sha256:c664f8f86ed5a386b0a340d981b8f81714e21a8b9c73f658c4bea56aa179d54a'
SYSTEM_LIBRARIES = {'libc.so.6', 'libm.so.6', 'libdl.so.2', 'libpthread.so.0',
                    'librt.so.1', 'libutil.so.1', 'libresolv.so.2', 'ld-linux-x86-64.so.2'}


def version(value: str) -> tuple[int, ...]:
    return tuple(map(int,value.split('.')))


def validate_elf_report(versions: str, header: str, dynamic: str) -> dict:
    if 'ELF64' not in header or 'Advanced Micro Devices X86-64' not in header:
        raise ValueError('Linux release requires ELF64 x86_64')
    if 'GLIBC_PRIVATE' in versions or 'GLIBC_ABI_' in versions:
        raise ValueError('Unsupported private/new glibc ABI requirement')
    required=set(re.findall(r'\bGLIBC_([0-9]+(?:\.[0-9]+)+)', versions))
    if not required:
        raise ValueError('Cannot determine ELF glibc requirement')
    highest=max(required,key=version)
    if version(highest)>version(MAX_GLIBC):
        raise ValueError(f'ELF requires glibc {highest}; Ubuntu 20.04 release maximum is {MAX_GLIBC}')
    needed=re.findall(r'\(NEEDED\).*?\[([^]]+)\]|NEEDED Shared library: \[([^]]+)\]',dynamic)
    dependencies={left or right for left,right in needed}
    missing=dependencies-SYSTEM_LIBRARIES
    if missing:
        raise ValueError('Unexpected/unbundled Linux libraries: '+', '.join(sorted(missing)))
    return {'maximum_glibc':highest,'needed':sorted(dependencies)}


def inspect_elf(path: Path) -> dict:
    def read(option):
        return subprocess.check_output(['readelf',option,str(path)],text=True,
                                       env={**os.environ,'LC_ALL':'C'})
    return validate_elf_report(read('--version-info'),read('--file-header'),read('--dynamic'))


def audit_tree(root: Path) -> dict:
    reports={}
    for path in sorted(root.rglob('*')):
        if not path.is_file():continue
        with path.open('rb') as stream:
            if stream.read(4)!=b'\x7fELF':continue
        reports[path.relative_to(root).as_posix()]=inspect_elf(path)
    if not reports:raise ValueError('No release ELF files found')
    return {'target':'Ubuntu 20.04 x86_64','glibc_ceiling':MAX_GLIBC,
            'maximum_glibc':max((r['maximum_glibc'] for r in reports.values()),key=version),
            'files':reports}


def image(root: Path, target: str = 'build') -> str:
    if not shutil.which('docker'):
        raise RuntimeError('Docker is required for the Ubuntu 20.04 Linux baseline build')
    context=root/'tools/packaging/linux'
    digest=hashlib.sha256(b''.join(p.read_bytes() for p in sorted(context.iterdir()) if p.is_file())).hexdigest()[:16]
    tag=f'bloodshot-linux-baseline:{target}-{digest}'
    result=subprocess.run(['docker','image','inspect',tag,'--format','{{.Id}}'],text=True,
                          stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
    if result.returncode:
        subprocess.run(['docker','build','--platform','linux/amd64','--target',target,'--tag',tag,str(context)],check=True)
    return subprocess.check_output(['docker','image','inspect',tag,'--format','{{.Id}}'],text=True).strip()


def container_command(image_id: str, mounts: list, output: Path, arguments: list) -> list[str]:
    command=['docker','run','--rm','--platform','linux/amd64','--network=none',
             '--read-only','--cap-drop=ALL','--security-opt=no-new-privileges',
             '--user',f'{os.getuid()}:{os.getgid()}',
             '--tmpfs','/tmp:rw,exec,nosuid,mode=1777,size=1g']
    for source,destination,readonly in [*mounts,(output,'/output',False)]:
        fields=['type=bind',f'source={source.resolve()}',f'destination={destination}']
        if readonly:fields.append('readonly')
        encoded=io.StringIO()
        csv.writer(encoded,lineterminator='').writerow(fields)
        command+=['--mount',encoded.getvalue()]
    return [*command,image_id,*arguments]


def build_native(root: Path, cpp: Path, ymfm: Path, chdr: Path, zstd: Path,
                 bindings: Path, target: str, jobs: int) -> dict:
    image_id=image(root)
    # Independent paths cannot reuse newer host objects or codec archives.
    output=root/'local/build/audio/ubuntu-20.04'/image_id.removeprefix('sha256:')[:16]
    output.mkdir(parents=True,exist_ok=True)
    mounts=[(root/'native','/source/native',True),(cpp,'/godot-cpp',True),
            (ymfm,'/ymfm',True),(chdr,'/chdr',True),(zstd,'/zstd',True),(bindings,'/bindings',True)]
    subprocess.run(container_command(image_id,mounts,output,[target,str(jobs)]),check=True)
    binary=output/target/'native.so'
    report=inspect_elf(binary)
    destination=root/'game/addons/bloodshot_audio/bin'/f'libbloodshot_audio.linux.{target}.x86_64.so'
    destination.parent.mkdir(parents=True,exist_ok=True)
    temporary=destination.with_name('.'+destination.name+'.tmp')
    shutil.copyfile(binary,temporary)
    os.replace(temporary,destination)
    return {'architecture':'linux.x86_64','baseline':'Ubuntu 20.04','glibc_ceiling':MAX_GLIBC,
            'base_image':BASE_IMAGE,'build_image':image_id,'abi':report,
            'compiler':(output/'compiler.txt').read_text().splitlines()[0],
            'build_glibc':(output/'glibc.txt').read_text().strip(),
            'packages':(output/'packages.txt').read_text().splitlines(),
            'sha256':hashlib.sha256(binary.read_bytes()).hexdigest()}


def smoke_appimage(root: Path, artifact: Path, disc: Path, output: Path) -> dict:
    """Run the real AppImage in Ubuntu 20.04 userspace with read-only external media."""
    if not artifact.is_file() or not disc.is_file():
        raise ValueError('Baseline smoke requires an AppImage and your original CHD')
    output.mkdir(parents=True,exist_ok=True)
    image_id=image(root,'runtime')
    mounts=[(artifact,'/artifact/Bloodshot.AppImage',True),(disc,'/media/game.chd',True)]
    arguments=['/bin/sh','-c','getconf GNU_LIBC_VERSION; exec "$@"','baseline',
               '/usr/bin/env','APPIMAGE_EXTRACT_AND_RUN=1','timeout','120',
               '/artifact/Bloodshot.AppImage','--headless','--audio-driver','Dummy','--',
               '--runtime-audit','--audit-cycles=1','--audit-frames=30','--disc','/media/game.chd']
    log=output/'runtime.log'
    with log.open('w') as stream:
        subprocess.run(container_command(image_id,mounts,output,arguments),check=True,
                       stdout=stream,stderr=subprocess.STDOUT,timeout=150)
    text=log.read_text()
    errors=[line for line in text.splitlines() if 'SCRIPT ERROR:' in line or line.startswith('ERROR:')]
    if errors or 'RUNTIME_AUDIT_COMPLETE ' not in text or 'glibc 2.31' not in text or text.count('RUNTIME_AUDIT_BOUNDARY ') != 20:
        raise RuntimeError('Ubuntu 20.04 runtime audit failed; inspect '+str(log))
    report={'baseline':'Ubuntu 20.04','glibc':'2.31','image':image_id,
            'artifact_sha256':hashlib.sha256(artifact.read_bytes()).hexdigest(),
            'scene_boundaries':text.count('RUNTIME_AUDIT_BOUNDARY '),
            'mode':'headless; AppImage extract-and-run; original media read-only'}
    (output/'result.json').write_text(json.dumps(report,indent=2)+'\n')
    return report
