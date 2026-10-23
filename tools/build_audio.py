#!/usr/bin/env python3
"""Build native Linux or cross-compiled Windows disc/audio/value support."""

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
DEPENDENCIES = {
    "libchdr": (
        "93d8c239ff0d4e8d7722985992649fce12d2463b",
        "https://codeload.github.com/rtissera/libchdr/tar.gz/93d8c239ff0d4e8d7722985992649fce12d2463b",
        "f38fb1b3e907c8927271a57ad6e3c02347eaa2d5803f910880b4b3c3021b3657",
    ),
    "zstd": (
        "1.5.7",
        "https://codeload.github.com/facebook/zstd/tar.gz/refs/tags/v1.5.7",
        "37d7284556b20954e56e1ca85b80226768902e2edabd3b649e9e72c0c9012ee3",
    ),
    "godot-cpp": (
        "10.0.0-stable",
        "https://codeload.github.com/godotengine/godot-cpp/tar.gz/refs/tags/10.0.0-stable",
        "ebbf64f0f8f8b8b66bc4bc4d3797db97f95b19cf0dfb5b3f8cf56683d9df7db4",
    ),
    "ymfm": (
        "81aec25ccbb98f4873a255f7551ac4dadac59b4a",
        "https://codeload.github.com/aaronsgiles/ymfm/tar.gz/81aec25ccbb98f4873a255f7551ac4dadac59b4a",
        "9bcf001b30f53754c49cf2fb864792a64702b8aeebb105baa908ad5dd33f443f",
    ),
}


def fetch(name):
    revision, url, digest = DEPENDENCIES[name]
    archive = ROOT / "tools/cache" / f"{name}-{revision}.tar.gz"
    download(url, archive, digest)
    target = ROOT / "tools/vendor/audio" / f"{name}-{revision}"
    if not target.exists():
        with tarfile.open(archive) as package:
            package.extractall(target.parent, filter="data")
    return target


def codec_notices(chdr: Path, zstd: Path) -> list[str]:
    notices = ["Static native codecs: libchdr v0.3.0; zstd 1.5.7\n",
               (chdr / "LICENSE.txt").read_text(), (zstd / "LICENSE").read_text(),
               (chdr / "deps/lzma-25.01/LICENSE").read_text()]
    miniz = (chdr / "deps/miniz-3.1.1/miniz.c").read_text()
    notices.append(miniz[miniz.index('/***'):miniz.index('typedef unsigned')])
    flac = (chdr / "include/dr_libs/dr_flac.h").read_text()
    notices.append(flac[flac.rindex('ALTERNATIVE 2 - MIT No Attribution'):].split('*/')[0])
    return notices


def windows_codecs(jobs: int, prefix: str) -> tuple[Path, Path, list[Path]]:
    """Cross-build CHD and full zstd (network snapshots also need compression)."""
    chdr, zstd = fetch("libchdr"), fetch("zstd")
    base = ROOT / "local/build/audio/windows-codecs"
    install = base / "install"
    common = [
        "-DCMAKE_SYSTEM_NAME=Windows", "-DCMAKE_BUILD_TYPE=Release",
        f"-DCMAKE_C_FLAGS=-ffile-prefix-map={ROOT}=.",
        f"-DCMAKE_C_COMPILER={prefix}gcc", f"-DCMAKE_CXX_COMPILER={prefix}g++",
        f"-DCMAKE_AR={shutil.which(prefix + 'ar')}", "-DCMAKE_POLICY_VERSION_MINIMUM=3.5",
    ]
    zbuild = base / "zstd"
    subprocess.run([
        "cmake", "-S", str(zstd / "build/cmake"), "-B", str(zbuild), *common,
        f"-DCMAKE_INSTALL_PREFIX={install}", "-DZSTD_BUILD_PROGRAMS=OFF",
        "-DZSTD_BUILD_TESTS=OFF", "-DZSTD_BUILD_SHARED=OFF", "-DZSTD_BUILD_STATIC=ON",
        "-DZSTD_MULTITHREAD_SUPPORT=OFF",
    ], check=True)
    subprocess.run(["cmake", "--build", str(zbuild), "--parallel", str(jobs)], check=True)
    subprocess.run(["cmake", "--install", str(zbuild)], check=True)
    cbuild = base / "libchdr"
    subprocess.run([
        "cmake", "-S", str(chdr), "-B", str(cbuild), *common,
        f"-DCMAKE_PREFIX_PATH={install}", "-DBUILD_SHARED_LIBS=OFF",
        "-DWITH_SYSTEM_ZSTD=ON", "-DWITH_SYSTEM_ZLIB=OFF", "-DWITH_LZMA_ASM=OFF",
    ], check=True)
    subprocess.run(["cmake", "--build", str(cbuild), "--target", "chdr-static", "--parallel", str(jobs)], check=True)
    libraries = [cbuild / "libchdr-static.a", cbuild / "deps/lzma-25.01/libchdr-lzma.a",
                 cbuild / "deps/miniz-3.1.1/libminiz.a", install / "lib/libzstd.a"]
    if not all(path.is_file() for path in libraries):
        raise RuntimeError("Windows codec build did not produce all static libraries")
    # Include the exact vendored codec notices, not merely the umbrella license.
    notices = codec_notices(chdr, zstd)
    notices.append((ROOT / "native/audio/LICENSE-MinGW-w64-runtime.txt").read_text())
    out = ROOT / "game/addons/bloodshot_audio/bin"
    out.mkdir(parents=True, exist_ok=True)
    (out / "WINDOWS_NATIVE_NOTICES.txt").write_text("\n\n".join(notices))
    return chdr, install, libraries


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release", action="store_true")
    parser.add_argument("--platform", choices=["linux", "windows"], default="linux")
    parser.add_argument("--cross-prefix", default="x86_64-w64-mingw32-")
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("-j", type=int, default=4)
    args = parser.parse_args()
    cpp, ymfm = fetch("godot-cpp"), fetch("ymfm")
    source = ROOT / "native/audio"
    profile = source / "build_profile.json"
    key = hashlib.sha256(profile.read_bytes()).hexdigest()[:12]
    generated = ROOT / "local/build/audio" / f"bindings-{key}"
    generated.mkdir(parents=True, exist_ok=True)
    if not (generated / ".done").exists():
        subprocess.run(
            [
                "python3",
                "-B",
                str(source / "gen_bindings.py"),
                str(cpp),
                "4.7",
                str(profile),
                str(generated),
            ],
            check=True,
            env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
        )
        (generated / ".done").touch()
    if args.prepare_only:
        print(generated)
        return
    target = "template_release" if args.release else "template_debug"
    addon = ROOT / "game/addons/bloodshot_audio"
    binary = addon / "bin" / (f"libbloodshot_audio.linux.{target}.x86_64.so" if args.platform == "linux"
                              else f"bloodshot_audio.windows.{target}.x86_64.dll")
    if args.platform == "linux":
        from linux_baseline import build_native
        chdr, zstd = fetch("libchdr"), fetch("zstd")
        metadata = build_native(ROOT, cpp, ymfm, chdr, zstd, generated, target, args.j)
        metadata["dependencies"] = {name: {"revision":value[0], "archive_sha256":value[2]}
                                    for name,value in DEPENDENCIES.items()}
        metadata["static_codecs"] = ["libchdr", "miniz", "LZMA", "dr_flac", "zstd"]
        (addon / "bin/LINUX_NATIVE_NOTICES.txt").write_text("\n\n".join(codec_notices(chdr,zstd)))
        config = addon / "native-build.json"
        previous = json.loads(config.read_text()) if config.exists() else {}
        variants = previous.get("variants", {}) if previous.get("build_image") == metadata["build_image"] else {}
        variants[target] = {"sha256":metadata.pop("sha256"), "abi":metadata["abi"]}
        metadata["variants"] = variants
        config.write_text(json.dumps(metadata,indent=2)+"\n")
        extension_list = ROOT / "game/.godot/extension_list.cfg"
        extension_list.parent.mkdir(parents=True,exist_ok=True)
        entry = "res://addons/bloodshot_audio/bloodshot_audio.gdextension"
        lines = extension_list.read_text().splitlines() if extension_list.exists() else []
        if entry not in lines:extension_list.write_text("\n".join([*lines,entry])+"\n")
        print("Built",binary)
        return
    extra = []
    if args.platform == "windows":
        for tool in ["cmake", args.cross_prefix + "g++", args.cross_prefix + "gcc", args.cross_prefix + "ar"]:
            if not shutil.which(tool):
                raise RuntimeError("Missing Windows cross-build prerequisite: " + tool)
        chdr, install, libraries = windows_codecs(args.j, args.cross_prefix)
        extra = [f"PLATFORM=windows", f"CXX={args.cross_prefix}g++", f"AR={args.cross_prefix}ar",
                 f"CODEC_INCLUDES=-I{chdr / 'include'} -I{install / 'include'}",
                 "CODEC_LIBS=" + " ".join(map(str, libraries))]
    subprocess.run(
        [
            "make",
            "-C",
            str(source),
            "--no-print-directory",
            f"-j{args.j}",
            f"TARGET={target}",
            f"GODOT_CPP={cpp}",
            f"YMFM={ymfm}",
            f"GEN={generated}",
            f'BUILD={ROOT / "local/build/audio" / (target if args.platform == "linux" else "windows-" + target)}',
            f"OUT={binary}",
            *extra,
        ],
        check=True,
    )
    if args.platform == "windows":
        (addon / "native-build-windows.json").write_text(json.dumps({
            "architecture": "windows.x86_64", "godot_api": "4.7",
            "dependencies": {name: DEPENDENCIES[name][0] for name in DEPENDENCIES},
            "static_codecs": [path.name for path in libraries],
            "compiler": subprocess.check_output([args.cross_prefix + "g++", "--version"], text=True).splitlines()[0],
            "sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        }, indent=2) + "\n")
        print("Built", binary)
        return


if __name__ == "__main__":
    main()
