#!/usr/bin/env python3
"""Build Godot 4.7.1 with the reviewed, pre-allocation ENet security limits.

Source archives, every edited original/patched file and the patch are hashed.
Each platform/target has its own tree. Linux release templates use glibc 2.31;
Windows uses MinGW. Binaries stay ignored and never replace the stock editor.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
from build_support import download

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / 'tools/patches/godot-network-source.json'
PATCH = ROOT / 'tools/patches/godot-4.7.1-network-limits.patch'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare(platform, target):
    lock = json.loads(LOCK.read_text())
    if sha(PATCH) != lock['patch_sha256']:
        raise ValueError('Engine patch differs from its reviewed hash')
    archive = ROOT / 'tools/cache/godot-4.7.1-stable-source.tar.gz'
    download(lock['source_url'], archive, lock['source_sha256'])
    base = ROOT / 'local/build/engine' / f'{platform}-{target}'
    source = base / 'godot-4.7.1-stable'
    if not source.exists():
        base.mkdir(parents=True, exist_ok=True)
        with tarfile.open(archive) as package:
            package.extractall(base, filter='data')
    values = {name: sha(source / name) for name in lock['files']}
    if all(values[name] == row['original'] for name, row in lock['files'].items()):
        subprocess.run(['patch', '--batch', '-p1', '-i', str(PATCH)], cwd=source, check=True)
    if any(sha(source / name) != row['patched'] for name, row in lock['files'].items()):
        raise ValueError('Unreviewed engine source change or incomplete patch')
    with tarfile.open(archive) as package:
        for member in package.getmembers():
            if not member.isfile():
                continue
            relative = Path(member.name).relative_to('godot-4.7.1-stable').as_posix()
            expected = lock['files'][relative]['patched'] if relative in lock['files'] else hashlib.sha256(package.extractfile(member).read()).hexdigest()
            if sha(source / relative) != expected:
                raise ValueError('Unreviewed engine source file: ' + relative)
    return source, lock


def probe(source):
    output = source.parent / 'native-enet-limits'
    enet = source / 'thirdparty/enet'
    subprocess.run(['cc', '-DUNIX_ENABLED', '-ffunction-sections', '-fdata-sections',
                    '-I' + str(enet), str(ROOT / 'tools/packaging/engine/native_enet_limits.c'),
                    str(enet / 'packet.c'), str(enet / 'list.c'), '-Wl,--gc-sections',
                    '-o', str(output)], check=True)
    return json.loads(subprocess.check_output([str(output)], text=True))


def image():
    context = ROOT / 'tools/packaging/engine'
    key = hashlib.sha256(b''.join(path.read_bytes() for path in sorted(context.iterdir()))).hexdigest()[:16]
    tag = 'bloodshot-engine-baseline:' + key
    result = subprocess.run(['docker', 'image', 'inspect', tag], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if result.returncode:
        subprocess.run(['docker', 'build', '--tag', tag, str(context)], check=True)
    return subprocess.check_output(['docker', 'image', 'inspect', tag, '--format', '{{.Id}}'], text=True).strip()


def build(platform, target, jobs, host=False, prepare_only=False):
    if target == 'editor' and platform != 'linux':
        raise ValueError('The development editor target is Linux only')
    source, lock = prepare(platform, target)
    native = probe(source)
    if prepare_only:
        print(source)
        return
    arguments = ['scons', 'platform=' + ('linuxbsd' if platform == 'linux' else 'windows'),
                 'target=' + target, 'arch=x86_64', 'debug_symbols=no', 'lto=none', '-j' + str(jobs)]
    metadata = {'source_sha256': lock['source_sha256'], 'patch_sha256': lock['patch_sha256'],
                'native_probe': native, 'platform': platform, 'target': target}
    if platform == 'windows':
        arguments += ['d3d12=no']
    if platform == 'linux' and not host:
        build_image = image()
        metadata['build_image'] = build_image
        command = ['docker', 'run', '--rm', '--network=none', '--read-only', '--cap-drop=ALL',
                   '--security-opt=no-new-privileges', '--user', f'{os.getuid()}:{os.getgid()}',
                   '--tmpfs', '/tmp:rw,exec,nosuid,mode=1777,size=2g',
                   '--env', 'HOME=/tmp', '--mount', f'type=bind,source={source},destination=/source',
                   build_image, *arguments]
        subprocess.run(command, check=True)
        from linux_baseline import inspect_elf
        metadata['abi'] = inspect_elf(source / f'bin/godot.linuxbsd.{target}.x86_64')
    else:
        if platform == 'linux' and target != 'editor':
            raise ValueError('Linux templates must use the glibc 2.31 container')
        subprocess.run(arguments, cwd=source, check=True)
    filename = f'godot.{"linuxbsd" if platform == "linux" else "windows"}.{target}.x86_64'
    binary = source / ('bin/' + filename + ('.exe' if platform == 'windows' else ''))
    destination = ROOT / 'tools/bin/godot-4.7.1-network' if target == 'editor' else ROOT / 'tools/bin/network-templates' / f'{platform}_{target.removeprefix("template_")}_x86_64{ ".exe" if platform == "windows" else ""}'
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix('.tmp')
    shutil.copyfile(binary, temporary)
    temporary.chmod(0o755)
    os.replace(temporary, destination)
    metadata['sha256'] = sha(destination)
    if platform == 'windows':
        # The exporter searches beside a custom EXE for its console wrapper.
        # Copying only the hardened engine silently drops the server terminal.
        wrapper = binary.with_suffix('.console.exe')
        if not wrapper.is_file():
            raise RuntimeError('Windows build did not produce its console wrapper')
        wrapper_destination = destination.with_suffix('.console.exe')
        temporary = wrapper_destination.with_suffix('.tmp')
        shutil.copyfile(wrapper, temporary)
        temporary.chmod(0o755)
        os.replace(temporary, wrapper_destination)
        metadata['console_wrapper_sha256'] = sha(wrapper_destination)
    output = ROOT / 'local/build/engine' / f'{platform}-{target}' / 'build.json'
    output.write_text(json.dumps(metadata, indent=2) + '\n')
    print('Built', destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=['linux', 'windows'], default='linux')
    parser.add_argument('--target', choices=['editor', 'template_debug', 'template_release'], default='template_release')
    parser.add_argument('--host', action='store_true', help='Development editor only; release Linux always uses the old baseline')
    parser.add_argument('--prepare-only', action='store_true')
    parser.add_argument('-j', type=int, default=4)
    args = parser.parse_args()
    if not 1 <= args.j <= 32:
        parser.error('Use 1..32 build jobs')
    build(args.platform, args.target, args.j, args.host, args.prepare_only)


if __name__ == '__main__':
    main()
