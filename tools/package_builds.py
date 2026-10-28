#!/usr/bin/env python3
"""Build x86_64 clients and standalone server archives with external game media."""
from __future__ import annotations
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import zipfile

from build_support import download
import export_build
from linux_baseline import audit_tree, smoke_appimage

ROOT = Path(__file__).resolve().parents[1]
PACKAGING = ROOT / 'tools/packaging'
APPIMAGE = {
    'tool': ('appimagetool-1.9.1-x86_64.AppImage',
             'https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage',
             'ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0'),
    'runtime': ('appimage-runtime-20251108-x86_64',
                'https://github.com/AppImage/type2-runtime/releases/download/20251108/runtime-x86_64',
                '2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d'),
    'license': ('appimage-runtime-20251108-LICENSE',
                'https://raw.githubusercontent.com/AppImage/type2-runtime/dd6cebedcbddde9c82f89b011e8e1d40b6e43868/LICENSE',
                'aa154fc9070614bbe7921f89db11efd1dba7a1f3a41685958110e2230f9c0ca1'),
}
FORBIDDEN = re.compile(r'(^|/)(?:tests|contracts|asset-cache|\.git|\.godot|local|user-data|addons/(?!bloodshot_audio/)[^/]+)(/|$)|\.(?:chd|iso|cue|gen|smd|key|pem|sav|xcf|gz)$', re.I)
CLIENT_FILES = {
    'bloodshot', 'bloodshot.exe', 'bloodshot.pck', 'README.txt', 'roms/README.txt',
    'LICENSE', 'THIRD_PARTY_NOTICES.txt', 'GODOT_ENGINE_NOTICES.txt',
    'LINUX_NATIVE_NOTICES.txt', 'WINDOWS_NATIVE_NOTICES.txt',
    'libbloodshot_audio.linux.template_release.x86_64.so',
    'bloodshot_audio.windows.template_release.x86_64.dll',
}
SERVER_COMMON = {'bloodshot-server.pck', 'README.txt', 'roms/README.txt', 'LICENSE',
                 'THIRD_PARTY_NOTICES.txt', 'GODOT_ENGINE_NOTICES.txt'}
SERVER_FILES = {
    'linux': SERVER_COMMON | {'bloodshot-server', 'LINUX_NATIVE_NOTICES.txt',
                             'libbloodshot_audio.linux.template_release.x86_64.so'},
    'windows': SERVER_COMMON | {'bloodshot-server.exe', 'bloodshot-server.console.exe',
                               'WINDOWS_NATIVE_NOTICES.txt',
                               'bloodshot_audio.windows.template_release.x86_64.dll'},
}


def validate_payload(source: Path, allowed_files: set[str] | None = None) -> None:
    if source.is_symlink() or not source.is_dir():
        raise ValueError('Release payload must be a real directory')
    allowed_files = CLIENT_FILES if allowed_files is None else allowed_files
    for path in source.rglob('*'):
        name = path.relative_to(source).as_posix()
        if path.is_symlink() or FORBIDDEN.search(name):
            raise ValueError('Forbidden release payload: ' + name)
        if (path.is_file() and name not in allowed_files) or (path.is_dir() and name != 'roms'):
            raise ValueError('Unreviewed release payload: ' + name)


def windows_zip(source: Path, target: Path) -> None:
    if target.exists():
        raise FileExistsError('Artifact already exists: ' + str(target))
    validate_payload(source)
    required = ['bloodshot.exe', 'bloodshot.pck', 'LICENSE', 'THIRD_PARTY_NOTICES.txt',
                'GODOT_ENGINE_NOTICES.txt', 'WINDOWS_NATIVE_NOTICES.txt', 'README.txt',
                'bloodshot_audio.windows.template_release.x86_64.dll']
    for name in required:
        if not (source / name).is_file():
            raise ValueError('Missing Windows release file: ' + name)
    _zip_bundle(source, target, 'Bloodshot-Windows-x86_64')


def _zip_bundle(source: Path, target: Path, folder: str) -> None:
    with zipfile.ZipFile(target, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for path in sorted(source.rglob('*')):
            if path.is_file():
                # Stable metadata; build binary hashes still identify the exact toolchain.
                entry = zipfile.ZipInfo(folder + '/' + path.relative_to(source).as_posix())
                entry.external_attr = 0o100644 << 16
                entry.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(entry, path.read_bytes())


def server_archive(source: Path, target: Path, platform: str) -> None:
    """Keep a complete, reviewed server together in one portable directory."""
    if platform not in SERVER_FILES:
        raise ValueError('Unsupported server platform: ' + platform)
    if target.exists():
        raise FileExistsError('Artifact already exists: ' + str(target))
    required = SERVER_FILES[platform]
    validate_payload(source, required)
    for name in sorted(required):
        if not (source / name).is_file():
            raise ValueError('Missing server release file: ' + name)
    folder = 'Bloodshot-Server-' + ('Linux' if platform == 'linux' else 'Windows') + '-x86_64'
    if platform == 'windows':
        _zip_bundle(source, target, folder)
        return
    # A server tarball needs neither an AppImage mount nor desktop/Vulkan setup.
    # Retain the same older-glibc/dependency gate used by Linux clients.
    audit_tree(source)
    with target.open('xb') as stream, gzip.GzipFile(
        fileobj=stream, mode='wb', filename='', mtime=0, compresslevel=9
    ) as compressed, tarfile.open(fileobj=compressed, mode='w|', format=tarfile.PAX_FORMAT) as archive:
        for path in sorted(source.rglob('*')):
            if not path.is_file():
                continue
            relative = path.relative_to(source).as_posix()
            entry = tarfile.TarInfo(folder + '/' + relative)
            entry.size = path.stat().st_size
            entry.mode = 0o755 if relative == 'bloodshot-server' else 0o644
            # Stable metadata excludes builder names, host paths and mtimes.
            with path.open('rb') as contents:
                archive.addfile(entry, contents)


def appimage(source: Path, target: Path) -> None:
    if target.exists():
        raise FileExistsError('Artifact already exists: ' + str(target))
    validate_payload(source)
    audit_tree(source)
    for name in ['bloodshot', 'bloodshot.pck', 'LICENSE', 'THIRD_PARTY_NOTICES.txt', 'GODOT_ENGINE_NOTICES.txt', 'LINUX_NATIVE_NOTICES.txt']:
        if not (source / name).is_file():
            raise ValueError('Missing Linux release file: ' + name)
    files = {name: download(url, ROOT / 'tools/cache' / filename, digest)
             for name, (filename, url, digest) in APPIMAGE.items()}
    files['tool'].chmod(0o755)
    app = target.parent / 'Bloodshot.AppDir'
    if app.exists():
        raise FileExistsError('AppDir already exists: ' + str(app))
    shutil.copytree(source, app / 'usr/bin')
    shutil.copyfile(PACKAGING / 'AppRun', app / 'AppRun')
    (app / 'AppRun').chmod(0o755)
    for name in ['bloodshot.desktop', 'bloodshot.svg']:
        shutil.copyfile(PACKAGING / name, app / name)
    # A regular icon file keeps package inspection simple, without symlinks.
    shutil.copyfile(PACKAGING / 'bloodshot.svg', app / '.DirIcon')
    docs = app / 'usr/share/doc/bloodshot'
    docs.mkdir(parents=True)
    shutil.copyfile(files['license'], docs / 'APPIMAGE_RUNTIME_LICENSE.txt')
    with (target.parent / 'appimagetool.log').open('w') as log:
        subprocess.run([str(files['tool']), '--no-appstream', '--runtime-file', str(files['runtime']),
                        str(app), str(target)], check=True,
                       env={**os.environ, 'ARCH': 'x86_64', 'APPIMAGE_EXTRACT_AND_RUN': '1',
                            'SOURCE_DATE_EPOCH': os.environ.get('SOURCE_DATE_EPOCH', '0')},
                       stdout=log, stderr=subprocess.STDOUT)
    target.chmod(0o755)


def linux_glibc_requirement(source: Path) -> str:
    """AppImage does not replace libc; report the actual packaged ELF floor."""
    versions = set()
    for path in source.rglob('*'):
        if not path.is_file():
            continue
        with path.open('rb') as stream:
            if stream.read(4) != b'\x7fELF':
                continue
        output = subprocess.check_output(['readelf', '--version-info', str(path)], text=True)
        versions.update(re.findall(r'\bGLIBC_([0-9]+(?:\.[0-9]+)+)', output))
    if not versions:
        raise ValueError('Could not determine packaged Linux libc requirement')
    return max(versions, key=lambda value: tuple(map(int, value.split('.'))))


def build(output: Path, platform: str, skip_native: bool = False) -> None:
    output = output.resolve()
    if not output.is_relative_to(ROOT / 'reports'):
        raise ValueError('Release output must stay under project reports')
    if output.exists() and any(output.iterdir()):
        raise FileExistsError('Use a fresh release directory: ' + str(output))
    output.mkdir(parents=True, exist_ok=True)
    for target_platform in (['linux', 'windows'] if platform == 'all' else [platform]):
        subprocess.run([sys.executable, str(ROOT / 'tools/build_engine.py'),
                        '--platform', target_platform, '--target', 'template_release'], check=True)
    # The Linux editor imports the staging project even for a Windows export.
    if not skip_native:
        for args in [[], ['--release']] + ([['--platform', 'windows', '--release']] if platform in ['all', 'windows'] else []):
            subprocess.run([sys.executable, str(ROOT / 'tools/build_audio.py'), *args], check=True)
    export_build.build(output / 'exports', platform='all' if platform == 'all' else platform)
    artifacts = []
    if platform in ['all', 'linux']:
        target = output / 'Bloodshot-Linux-x86_64.AppImage'
        appimage(output / 'exports/client', target)
        artifacts.append(target)
        target = output / 'Bloodshot-Server-Linux-x86_64.tar.gz'
        server_archive(output / 'exports/server', target, 'linux')
        artifacts.append(target)
    if platform in ['all', 'windows']:
        target = output / 'Bloodshot-Windows-x86_64.zip'
        windows_zip(output / 'exports/windows-client', target)
        artifacts.append(target)
        target = output / 'Bloodshot-Server-Windows-x86_64.zip'
        server_archive(output / 'exports/windows-server', target, 'windows')
        artifacts.append(target)
    info = {'architecture': 'x86_64', 'build_host': 'Linux',
            'godot_sha256': hashlib.sha256((ROOT / 'tools/bin/godot-4.7.1').read_bytes()).hexdigest(),
            'native': {}, 'release_engines': {}}
    # The official editor imports/exports; the patched templates are what ship.
    # Preserve their reviewed source, patch, ABI, probe and exact binary hashes.
    for target_platform in (['linux', 'windows'] if platform == 'all' else [platform]):
        info['release_engines'][target_platform] = json.loads((
            ROOT / 'local/build/engine' / f'{target_platform}-template_release/build.json'
        ).read_text())
    for name in ['native-build.json', 'native-build-windows.json']:
        path = ROOT / 'game/addons/bloodshot_audio' / name
        if path.exists() and (name == 'native-build.json' or platform in ['windows', 'all']):
            info['native'][name] = json.loads(path.read_text())
    if platform in ['linux', 'all']:
        info['linux_abi'] = audit_tree(output / 'exports/client')
        info['linux_minimum_glibc'] = info['linux_abi']['maximum_glibc']
        info['linux_server_abi'] = audit_tree(output / 'exports/server')
    (output / 'build-info.json').write_text(json.dumps(info, indent=2) + '\n')
    record = {path.name: {'bytes':path.stat().st_size, 'sha256':hashlib.sha256(path.read_bytes()).hexdigest()}
              for path in artifacts}
    (output / 'artifacts.json').write_text(json.dumps(record, indent=2) + '\n')
    (output / 'SHA256SUMS').write_text(''.join(f"{row['sha256']}  {name}\n" for name,row in record.items()))
    print(json.dumps(record, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=['all', 'linux', 'windows'], default='all')
    parser.add_argument('--output', type=Path, default=Path('reports/releases'))
    parser.add_argument('--test-baseline', action='store_true', help='Run the packaged AppImage in Ubuntu 20.04 using your original CHD')
    parser.add_argument('--disc', type=Path, default=Path(os.environ['BLOODSHOT_DISC']) if os.environ.get('BLOODSHOT_DISC') else None)
    parser.add_argument('--skip-native', action='store_true', help='Use existing native binaries; export still checks dependencies')
    args = parser.parse_args()
    if args.test_baseline and (args.platform == 'windows' or args.disc is None):
        parser.error('--test-baseline requires a Linux package and --disc or BLOODSHOT_DISC')
    build(ROOT / args.output, args.platform, args.skip_native)
    if args.test_baseline:
        print(json.dumps(smoke_appimage(ROOT, ROOT / args.output / 'Bloodshot-Linux-x86_64.AppImage',
                                        args.disc.resolve(), ROOT / args.output / 'ubuntu-20.04-smoke'),indent=2))
