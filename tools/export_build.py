#!/usr/bin/env python3
"""Export isolated Linux/Windows bundles, never rewriting editor settings."""

from __future__ import annotations
import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
from linux_baseline import inspect_elf

ROOT = Path(__file__).resolve().parents[1]


def check_windows_imports(output: str) -> None:
    # The extension statically links its codecs and MinGW runtimes. Only Windows
    # system imports are allowed; a new third-party DLL must be bundled explicitly.
    system = {"kernel32.dll", "msvcrt.dll", "user32.dll", "advapi32.dll", "bcrypt.dll",
              "crypt32.dll", "ole32.dll", "shell32.dll", "ws2_32.dll", "ntdll.dll"}
    imports = re.findall(r"DLL Name:\s*(\S+)", output)
    if not imports:
        raise ValueError("Could not inspect Windows extension imports")
    missing = [name for name in imports if name.lower() not in system and not name.lower().startswith("api-ms-win-")]
    if missing:
        raise ValueError("Unbundled Windows native dependencies: " + ", ".join(missing))


def resolve_templates(presets: str, templates: Path, platform: str) -> str:
    """Resolve each platform independently; host templates cannot serve Windows."""
    def options(match):
        number, body = match.group(2), match.group(3)
        header = re.search(r"\[preset\." + number + r"\]\n(.*?)(?=\n\[|\Z)", presets, re.S)
        if header is None:
            raise ValueError("Export options have no corresponding preset")
        windows = 'platform="Windows Desktop"' in header.group(1)
        if platform != "all" and (platform == "windows") != windows:
            return match.group(0)
        for mode in ["debug", "release"]:
            template = templates / (f"windows_{mode}_x86_64.exe" if windows else f"linux_{mode}.x86_64")
            if not template.is_file():
                raise RuntimeError(f"Missing matching export template: {template}")
            body = body.replace(f'custom_template/{mode}=""', f'custom_template/{mode}="{template}"')
        return match.group(1) + body
    return re.sub(r"(\[preset\.(\d+)\.options\]\n)(.*?)(?=\n\[|\Z)", options, presets, flags=re.S)


def stage_runtime(source: Path, stage: Path) -> None:
    """Copy explicit runtime roots; newly added research/test folders stay out."""
    stage.mkdir(parents=True, exist_ok=False)
    for name in ["scenes", "scripts", "shaders", "resources", "addons/bloodshot_audio", "addons/bloodshot_export"]:
        shutil.copytree(source / name, stage / name,
                        ignore=shutil.ignore_patterns("__pycache__", "native-build*.json", "libchdr.so.*", "libz.so.*", "libzstd.so.*"))
    for name in ["project.godot", "export_presets.cfg", "default_bus_layout.tres"]:
        shutil.copyfile(source / name, stage / name)
    # Runtime artwork comes from media. Only this exact owner-authored font
    # addition is source artwork; accidental local drops must not enter exports.
    authored = "resources/fonts/small_font_additions.png"
    expected = "6a3cc9fa3a44fd9937993d5d782dd8366f2c0ed4f2f29ed5f9252aba10202b83"
    source_suffixes = {".gd", ".uid", ".tscn", ".tres", ".gdshader", ".gdshaderinc",
                       ".json", ".md", ".txt", ".cfg", ".godot", ".gdextension", ".import"}
    native = re.compile(r"(?:libbloodshot_audio\.linux\.template_(?:debug|release)\.x86_64\.so|"
                        r"bloodshot_audio\.windows\.template_(?:debug|release)\.x86_64\.dll|"
                        r"(?:WINDOWS|LINUX)_NATIVE_NOTICES\.txt)")
    for path in stage.rglob('*'):
        if not path.is_file():
            continue
        name = path.relative_to(stage).as_posix()
        if name == authored and hashlib.sha256(path.read_bytes()).hexdigest() == expected:
            continue
        if name.startswith("addons/bloodshot_audio/bin/"):
            allowed = native.fullmatch(path.name) is not None
        else:
            allowed = path.suffix.lower() in source_suffixes
        if not allowed:
            raise ValueError("Unreviewed media or build file in runtime sources: " + name)


def build(destination: Path, platform: str = "linux") -> None:
    destination = destination.resolve()
    if not destination.is_relative_to(ROOT / "reports"):
        raise ValueError("Export output must stay under project reports")
    if platform not in ["linux", "windows", "all"]:
        raise ValueError("Unsupported export platform")
    addon = ROOT / "game/addons/bloodshot_audio/bin"
    needed = ["libbloodshot_audio.linux.template_debug.x86_64.so"]
    if platform in ["linux", "all"]:
        needed += ["libbloodshot_audio.linux.template_release.x86_64.so", "LINUX_NATIVE_NOTICES.txt"]
    if platform in ["windows", "all"]:
        needed += ["bloodshot_audio.windows.template_release.x86_64.dll", "WINDOWS_NATIVE_NOTICES.txt"]
    for name in needed:
        if not (addon / name).is_file():
            raise RuntimeError("Missing native build prerequisite: " + name)
    inspect_elf(addon / "libbloodshot_audio.linux.template_debug.x86_64.so")
    if platform in ["linux", "all"]:
        inspect_elf(addon / "libbloodshot_audio.linux.template_release.x86_64.so")
    if platform in ["windows", "all"]:
        check_windows_imports(subprocess.check_output([
            "x86_64-w64-mingw32-objdump", "-p",
            str(addon / "bloodshot_audio.windows.template_release.x86_64.dll")], text=True))
    destination.mkdir(parents=True, exist_ok=True)
    stage = destination / "project"
    if stage.exists():
        shutil.rmtree(stage)  # Only this explicitly selected generated checkout.
    stage_runtime(ROOT / "game", stage)
    # Strip editor-only autoload/plugin sections in the disposable project.
    config, skip = [], False
    for line in (stage / "project.godot").read_text().splitlines():
        if line.startswith("["):
            skip = line in ["[autoload]", "[editor_plugins]"]
        if not skip:
            config.append(line)
    config.extend(
        [
            "[editor_plugins]",
            'enabled=PackedStringArray("res://addons/bloodshot_export/plugin.cfg")',
        ]
    )
    (stage / "project.godot").write_text("\n".join(config) + "\n")
    engine = ROOT / "tools/bin/godot-4.7.1"
    private = destination / "user-data"
    env = {
        **os.environ,
        **{f"XDG_{key}_HOME": str(private / key.lower()) for key in ["CONFIG", "DATA", "CACHE"]},
    }
    templates = Path.home() / ".local/share/godot/export_templates/4.7.1.stable"
    preset_path = stage / "export_presets.cfg"
    presets = preset_path.read_text()
    presets = resolve_templates(presets, templates, platform)
    preset_path.write_text(presets)
    engine_notices = destination / "GODOT_ENGINE_NOTICES.txt"
    subprocess.run(
        [
            str(engine),
            "--headless",
            "--path",
            str(stage),
            "--script",
            str(ROOT / "tools/write_engine_notices.gd"),
            "--",
            str(engine_notices),
        ],
        env=env,
        check=True,
        timeout=30,
        stdout=subprocess.DEVNULL,
    )
    targets = []
    if platform in ["linux", "all"]:
        targets += [("client", "Linux Client", "bloodshot"),
                    ("server", "Linux Dedicated Server", "bloodshot-server")]
    if platform in ["windows", "all"]:
        targets += [("windows-client", "Windows Client", "bloodshot.exe"),
                    ("windows-server", "Windows Dedicated Server", "bloodshot-server.exe")]
    with (destination / "export.log").open("w") as log:
        for kind, preset, binary in targets:
            output = destination / kind
            output.mkdir(exist_ok=True)
            subprocess.run(
                [
                    str(engine),
                    "--headless",
                    "--path",
                    str(stage),
                    "--export-release",
                    preset,
                    str(output / binary),
                ],
                env=env,
                stdout=log,
                stderr=subprocess.STDOUT,
                check=True,
                timeout=120,
            )
            shutil.copyfile(
                ROOT / "game/addons/bloodshot_audio/THIRD_PARTY_NOTICES.txt",
                output / "THIRD_PARTY_NOTICES.txt",
            )
            shutil.copyfile(ROOT / "LICENSE", output / "LICENSE")
            if kind.startswith("windows"):
                shutil.copyfile(addon / "WINDOWS_NATIVE_NOTICES.txt", output / "WINDOWS_NATIVE_NOTICES.txt")
            else:
                shutil.copyfile(addon / "LINUX_NATIVE_NOTICES.txt", output / "LINUX_NATIVE_NOTICES.txt")
            media = output / "roms"
            media.mkdir(exist_ok=True)
            (media / "README.txt").write_text(
                "Launch the client and select your European Mega CD CHD or CUE in the file picker.\n"
                "A verified copy is stored in the game user folder for future launches.\n"
                "Legacy option: place your own supported CHD here. No original media is supplied.\n"
                "Default filename: Bloodshot ~ Battle Frenzy (Europe) (En,Fr,De,Es).chd\n"
                "Alternatively set BLOODSHOT_DISC or pass -- --disc /path/to/your/game.chd.\n"
            )
            shutil.copyfile(engine_notices, output / "GODOT_ENGINE_NOTICES.txt")
            (output / "README.txt").write_text(
                "Bloodshot - Battle Frenzy: Headache Edition\n\n"
                "Requires your original European Mega CD CHD or CUE/BIN. No original game media is included.\n"
                "On first launch, select your European Mega CD CHD or CUE in the OS file picker.\n"
                "It is copied into the game user folder; later launches use that copy.\n"
                "Your source image is unchanged. Cancel the picker to exit.\n"
                "For CUE/BIN, select the CUE; all referenced BINARY tracks are copied together.\n"
                "User media: bloodshot-battle-frenzy/original-media/ (managed image selection).\n"
                "  Windows: beneath %APPDATA%; Linux: beneath $XDG_DATA_HOME (default ~/.local/share).\n"
                "Advanced/server: set BLOODSHOT_DISC or pass -- --disc /absolute/game.chd.\n"
                "Windows: bloodshot.exe (server: bloodshot-server.exe)\n"
                "Linux: ./bloodshot (server: ./bloodshot-server)\n"
                "Legacy media fallback: roms/Bloodshot ~ Battle Frenzy (Europe) (En,Fr,De,Es).chd beside the executable.\n"
                "Server: ./bloodshot-server --headless -- --port=28760 --bind=0.0.0.0\n"
                "Server ports are explicit; occupied ports fail. Host migration is not supported.\n"
                "Online co-op Save/Load and four-player VS Battle are supported. Local split screen and co-op recordings are deferred.\n"
                "Notices: GODOT_ENGINE_NOTICES.txt and THIRD_PARTY_NOTICES.txt.\n"
            )
    errors = [
        line
        for line in (destination / "export.log").read_text().splitlines()
        if "SCRIPT ERROR:" in line or line.startswith("ERROR:")
    ]
    if errors:
        raise RuntimeError("Export has engine errors: " + "\n".join(errors[:10]))
    files = {
        str(path.relative_to(destination)): {
            "bytes": path.stat().st_size,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        }
        for kind, _, _ in targets
        for path in (destination / kind).rglob("*")
        if path.is_file()
    }
    (destination / "manifest.json").write_text(json.dumps(files, indent=2) + "\n")
    print(json.dumps({"destination": str(destination), "files": len(files)}, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", default="reports/010i/exports")
    parser.add_argument("--platform", choices=["linux", "windows", "all"], default="linux")
    args = parser.parse_args()
    build(ROOT / args.output, args.platform)
