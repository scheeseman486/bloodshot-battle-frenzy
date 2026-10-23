# Bloodshot / Battle Frenzy

**Version 0.1**

A native Godot reconstruction of the European Mega CD game. Original game assets
are read from your own supported disc image at runtime; no original media, ripped
artwork, sound or console firmware is included. See [original media](roms/README.md).

The game includes the sixteen-level campaign, original menus and audio, native
mouse/gamepad controls, save/load, widescreen HUD, four-player online co-op and
VS Battle, host-owned bots and moderation. VS supports item respawns, a configurable
kill limit and adding/removing bots during play. Online sessions use encrypted transport,
persistent player keys, key-based bans and same-session score recovery. Rejoining
creates a fresh avatar though carried inventory is dropped on exit.

## Settings, controls and multiplayer

W/S moves, A/D strafes, mouse movement aims, left mouse/Space fires, E uses doors
and Q cycles weapons. Esc opens the game menu; Tab shows scores. Keyboard,
mouse and gamepad bindings are configurable. Video options include widescreen
and fullscreen.

Choose **Multiplayer → Network Setup** for player name, port and password.
Host Game opens a lobby; choose Co-op or VS Battle, configure bots and select a
map. While hosting VS, **Bots** changes count/difficulty and **Player Moderation**
removes bots or kicks/bans human participants. **Unban Players** removes a stored
ban. Bans identify a player key; generating another key creates another identity.
Host certificate trust is established on first connection. Score recovery lasts
for the running host session; bans persist in the local hosting profile.

## Build and run

The build host is **Linux x86_64 with Godot 4.7.1 and Forward+**. It produces
Linux AppImage and Windows x86_64 ZIP releases. Install Python 3.12+ (for safe archive
extraction), Docker with an accessible running daemon, and binutils (`readelf`).
Linux native code and its codecs are built inside a pinned Ubuntu 20.04 container;
host compiler or codec packages are not used. Supply the official Godot 4.7.1 Linux
x86_64 executable:

```sh
python3 tools/setup.py --godot /path/to/Godot_v4.7.1-stable_linux.x86_64
export BLOODSHOT_DISC=/path/to/your/game.chd
tools/play
```

Setup verifies the engine checksum, installs a project-local copy and builds the
native disc/audio/value extension. Its SDK and ymfm dependencies are downloaded
from checksum-pinned upstream sources. Generated bindings, binaries, caches and
profiles stay in ignored local directories. No original media is modified.

Open `tools/editor` for the **Original CD** dock. It previews disc files, textures,
sprites, HUD artwork and audio through the same runtime readers. You are required to
supply your own disc. The dock and runtime export helper are included.

Build both release packages from Linux using matching official Godot 4.7.1 Linux
and Windows export templates in Godot's normal per-user template directory. Also
install CMake, the POSIX-thread MinGW-w64 x86_64 C/C++ cross-compiler and binutils,
and `mksquashfs` (SquashFS tools):

```sh
python3 tools/package_builds.py --platform all --output reports/releases/my-build
```

This builds native dependencies, Linux client/server exports and Windows
client/server exports, then creates `Bloodshot-Linux-x86_64.AppImage`,
`Bloodshot-Windows-x86_64.zip`, `artifacts.json` and `SHA256SUMS`. Outputs stay local.
Use `--platform linux` or `--platform windows` to select one distribution.
Windows codecs and compiler runtimes are statically linked. AppImage packaging
fetches checksum-pinned tooling/runtime and can build without FUSE. Native and
engine notices accompany both formats. Use a fresh output directory per build.

On Windows, extract the entire ZIP and run `bloodshot.exe`. On Linux, make the
AppImage executable and run it. On first launch, choose your supported European
Mega CD CHD or CUE in the OS file picker. For CUE/BIN, select the CUE rather than
a BIN: it describes the data and audio tracks, whether stored in one binary or
split across several files. Keep all referenced BIN files beside the CUE or in
its subfolders. Mode 1 data (2048 or 2352 bytes per sector) and BINARY audio are
supported; WAVE/MP3 CUE audio and standalone ISO/BIN files are not supported.

The game validates and copies the complete image into its user folder. A CUE's
referenced binaries are copied and verified together, and its file references
are rewritten for the installed copy. Future launches use this copy; source
files stay unchanged. Cancel the picker to exit. No CHDMAN installation or manual
conversion is required.

Managed media lives below `%APPDATA%/bloodshot-battle-frenzy/original-media/` on
Windows, or `$XDG_DATA_HOME/bloodshot-battle-frenzy/original-media/` on Linux
(default `~/.local/share`). CHDs use `bloodshot-europe.chd`; CUE/BIN sets use an
owned subfolder selected by `active-image.json`. No source filename or adjacent
folder is required.
Advanced/server users can set `BLOODSHOT_DISC` or pass `-- --disc /path/to/game.chd`;
these explicit paths bypass importing. The old executable-adjacent `roms/` layout
is still accepted when no managed copy exists. AppImage's
`APPIMAGE_EXTRACT_AND_RUN=1` fallback works when FUSE is unavailable. Caches, saves
and network identities belong to your normal user profile, outside the package.

For loose exports only:

```sh
python3 tools/build_audio.py --release
python3 tools/build_audio.py --platform windows --release
python3 tools/export_build.py --platform all --output reports/exports
```

The dedicated server supports `--headless -- --port=28760 --bind=0.0.0.0`; supply
its disc path too. Local split-screen and host migration are not implemented.
Linux releases target Ubuntu 20.04 and newer (glibc 2.31 maximum requirement).
Pinned container builds keep native dependencies on that baseline. Export and
AppImage gates reject newer glibc requirements or unexpected shared dependencies,
including when `--skip-native` is used. `build-info.json` records the actual ABI
requirements and toolchain provenance. GPU/Vulkan drivers remain system-provided.
To test the actual AppImage in Ubuntu 20.04 userspace using your read-only disc:

```sh
python3 tools/package_builds.py --platform linux --output reports/releases/checked \
  --test-baseline --disc /path/to/your/game.chd
```

This runs startup, menus and all campaign levels in a container without network
access. Graphical hardware/driver testing remains separate.
Windows packages are unsigned; native Windows hardware testing is still required
in addition to cross-build/Wine checks. Building directly on Windows is not yet a
supported build-host workflow.

## License and dependencies

Project-authored source is distributed under [BSD-3-Clause](LICENSE).
Reused native audio sources retain their original BSD notices in
`native/audio/LICENSE-mightyweenie`. Other components retain their respective
licenses; see `game/addons/bloodshot_audio/THIRD_PARTY_NOTICES.txt`. Builds also
include notices obtained from the exact Godot engine. The license does not grant
rights to the original game media, which is not distributed here.
