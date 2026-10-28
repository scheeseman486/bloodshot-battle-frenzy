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


def server_readme(windows: bool) -> str:
    executable = 'bloodshot-server.console.exe' if windows else './bloodshot-server'
    media = 'C:\\Games\\Bloodshot\\game.chd' if windows else '/path/to/game.chd'
    return (
        "Bloodshot - Battle Frenzy: Headache Edition - Dedicated Server\n\n"
        "Extract the complete archive and keep all companion files together.\n"
        "Requires your supported European Mega CD CHD or CUE/BIN image.\n"
        "No original game media or console firmware is included.\n"
        "For CUE/BIN, supply the CUE and retain its referenced BINARY tracks.\n"
        "The server opens the supplied media read-only; it does not show a file picker.\n\n"
        "Open a terminal in this directory and run:\n"
        f'  {executable} --headless -- --port=28760 --bind=0.0.0.0 --disc "{media}"\n\n'
        "Windows: launch the .console.exe wrapper, keeping the server EXE, PCK\n"
        "and native DLL beside it. Linux: the server executable needs no desktop,\n"
        "GPU or AppImage/FUSE mount and targets Ubuntu 20.04 or newer (x86_64).\n"
        "The host occupies no player seat; up to four players can connect.\n"
        "Allow the chosen UDP port through your firewall/router for remote clients.\n"
        "The port must be explicit; an occupied port fails rather than changing it.\n\n"
        "Default: co-op level 1. Add --level=1 through --level=16 to choose a level.\n"
        "VS Battle: add --mode=versus --map=arena-1 --kill-limit=15.\n"
        "Maps: arena-1, arena-2, arena-3. Kill limits: 5, 10, 15, 20, 30, 50.\n"
        "Set BLOODSHOT_NETWORK_PASSWORD in the environment for an optional join password.\n"
        "BLOODSHOT_DISC can supply the media path instead of --disc.\n\n"
        "Console: help, status, players, maps, mode coop|versus, map MAP, lobby,\n"
        "  limit N, rematch, bots N, difficulty easy|normal|hard, remove-bot ID,\n"
        "  revive-bot ID, kick ID, ban ID, bans, unban FULL_FINGERPRINT, slots,\n"
        "  save N, load N, admins, admin grant ID, admin add FULL_FINGERPRINT,\n"
        "  admin revoke FULL_FINGERPRINT, admin reload, profile HOSTNAME, quit.\n"
        "Use IDs from players. Help describes the current session restrictions.\n"
        "Bots require a human; configure co-op companions in the lobby.\n"
        "Waiting for input does not pause play. EOF leaves the server running.\n"
        "Use quit to stop, or add --no-console for unattended service use.\n\n"
        "Remote administration grants individual public player-key fingerprints.\n"
        "Distribute the public server profile and verify its full certificate hash\n"
        "independently. A profile grants no rights; never distribute private keys.\n"
        "The matching hardened client/server builds are required.\n\n"
        "Bans, co-op saves and private network identities belong to the OS user profile,\n"
        "outside this archive. Preserve that profile to retain server identity/bans.\n"
        "No host migration or local split-screen is provided.\n"
        "License/notices: LICENSE, THIRD_PARTY_NOTICES.txt, GODOT_ENGINE_NOTICES.txt\n"
        "and the platform's NATIVE_NOTICES.txt.\n"
    )


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


def verify_console_wrapper(template: Path, metadata: dict) -> Path:
    wrapper = template.with_suffix('.console.exe')
    if not wrapper.is_file() or metadata.get('console_wrapper_sha256') != hashlib.sha256(wrapper.read_bytes()).hexdigest():
        raise RuntimeError('Hardened Windows console wrapper provenance/hash mismatch')
    return wrapper


def resolve_templates(presets: str, templates: Path, platform: str, secure: dict | None = None) -> str:
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
            if mode == 'release' and secure:
                template = secure['windows' if windows else 'linux']
            if not template.is_file():
                raise RuntimeError(f"Missing matching export template: {template}")
            body = body.replace(f'custom_template/{mode}=""', f'custom_template/{mode}="{template}"')
        return match.group(1) + body
    return re.sub(r"(\[preset\.(\d+)\.options\]\n)(.*?)(?=\n\[|\Z)", options, presets, flags=re.S)


def stage_runtime(source: Path, stage: Path) -> None:
    """Copy explicit runtime roots; newly added research/test folders stay out."""
    stage.mkdir(parents=True, exist_ok=False)
    for name in ["scenes", "scripts", "shaders", "resources", "addons/bloodshot_audio", "addons/bloodshot_export"]:
        # Presentation capture scenes are private, as in the public snapshot
        # policy; direct developer-tree exports must apply the same boundary.
        ignored = ["__pycache__", "native-build*.json", "libchdr.so.*", "libz.so.*", "libzstd.so.*"]
        if name == "scenes":
            ignored.append("cinematics")
        shutil.copytree(source / name, stage / name,
                        ignore=shutil.ignore_patterns(*ignored))
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
        if not name.startswith("addons/bloodshot_audio/bin/"):
            try:
                text = path.read_text(encoding="utf-8")
                if "\0" in text:
                    raise UnicodeError()
            except UnicodeError:
                raise ValueError("Unreviewed binary in runtime text sources: " + name) from None


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
    secure = {}
    from build_engine import LOCK as ENGINE_LOCK, sha as engine_sha
    lock = json.loads(ENGINE_LOCK.read_text())
    for target_platform in (['linux', 'windows'] if platform == 'all' else [platform]):
        metadata_path = ROOT / 'local/build/engine' / f'{target_platform}-template_release/build.json'
        template = ROOT / 'tools/bin/network-templates' / f'{target_platform}_release_x86_64{ ".exe" if target_platform == "windows" else ""}'
        if not metadata_path.is_file() or not template.is_file():
            raise RuntimeError('Build the hardened release template with tools/build_engine.py for ' + target_platform)
        metadata = json.loads(metadata_path.read_text())
        if metadata.get('patch_sha256') != lock['patch_sha256'] or metadata.get('source_sha256') != lock['source_sha256'] or metadata.get('sha256') != engine_sha(template):
            raise RuntimeError('Hardened template provenance/hash mismatch: ' + target_platform)
        if target_platform == 'windows':
            verify_console_wrapper(template, metadata)
        secure[target_platform] = template
    presets = resolve_templates(presets, templates, platform, secure)
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
            if kind == 'windows-server':
                wrapper = output / 'bloodshot-server.console.exe'
                expected = verify_console_wrapper(secure['windows'], json.loads((
                    ROOT / 'local/build/engine/windows-template_release/build.json'
                ).read_text()))
                if not wrapper.is_file() or engine_sha(wrapper) != engine_sha(expected):
                    raise RuntimeError('Windows server export is missing its matching console wrapper')
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
            readme = (
                "Bloodshot - Battle Frenzy: Headache Edition\n\n"
                "Requires your original European Mega CD CHD or CUE/BIN. No original game media is included.\n"
                "On first launch, select your European Mega CD CHD or CUE in the OS file picker.\n"
                "It is copied into the game user folder; later launches use that copy.\n"
                "Your source image is unchanged. Cancel the picker to exit.\n"
                "Optional Mega Drive audio: put your supported European raw ROM beside the exe or AppImage.\n"
                "Any filename works; a verified copy is stored as original-media/bloodshot-europe.md in the user folder.\n"
                "Or choose Locate ROM in Audio settings, then select your CD/Mega Drive sources and Save.\n"
                "For CUE/BIN, select the CUE; all referenced BINARY tracks are copied together.\n"
                "User media: bloodshot-battle-frenzy/original-media/ (managed image selection).\n"
                "  Windows: beneath %APPDATA%; Linux: beneath $XDG_DATA_HOME (default ~/.local/share).\n"
                "Advanced/server: set BLOODSHOT_DISC or pass -- --disc /absolute/game.chd.\n"
                "Windows: bloodshot.exe (server console: bloodshot-server.console.exe)\n"
                "Linux: ./bloodshot (server: ./bloodshot-server)\n"
                "Legacy media fallback: roms/Bloodshot ~ Battle Frenzy (Europe) (En,Fr,De,Es).chd beside the executable.\n"
                "Server: ./bloodshot-server --headless -- --port=28760 --bind=0.0.0.0\n"
                "Server console: type help for players/IPs/public fingerprints, kick/ban/unban, maps/modes, bots, saves and quit.\n"
                "Add --no-console for unattended service use. Closed stdin leaves the server running.\n"
                "Server ports are explicit; occupied ports fail. Host migration is not supported.\n"
                "Online co-op Save/Load and four-player VS Battle are supported. Local split screen and co-op recordings are deferred.\n"
                "Notices: GODOT_ENGINE_NOTICES.txt and THIRD_PARTY_NOTICES.txt.\n"
            )
            if kind in ["server", "windows-server"]:
                readme = server_readme(kind == "windows-server")
            (output / "README.txt").write_text(readme)
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
