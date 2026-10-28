# Bloodshot - Battle Frenzy : Headache Edition

**Version 0.2**

A Godot reconstruction of the European Mega CD game. Original game assets
are read from your own supported disc image at runtime; no original media, ripped
artwork, sound or console firmware is included. See [original media](roms/README.md).

The game includes the sixteen-level campaign, original menus and audio, native
mouse/gamepad controls, save/load, widescreen HUD, four-player online co-op and
VS Battle, host-owned bots and moderation. VS supports item respawns, a configurable
kill limit and adding/removing bots during play. Online sessions use encrypted transport,
persistent player keys, key-based bans and same-session score recovery. Rejoining
creates a fresh avatar though carried inventory is dropped on exit.

Four-player co-op, VS Battle and dedicated hosting are ready(ish) for the version 0.2
release. Both listen hosts and standalone servers support moderation and bots.

## Settings, controls and multiplayer

WASD + mouse movement aims, left mouse/Space fires, E uses doors
and Q/wheel-down selects the next weapon; wheel-up selects the previous. Gamepad
RB/LB selects next/previous. Number-row 1–9 selects matching occupied HUD weapon
slots. Esc opens the game menu; Tab shows scores. Keyboard, mouse and gamepad
bindings are configurable.

**Options → Preferences → Video settings** contains options for
fullscreen/widescreen switches, a 70–105 degree FOV slider.

Choose **Options → Preferences → Audio settings** for independent Music and
Effects volume sliders and CD/Mega Drive source choices. Mega Drive choices
require the original cartridge ROM.

You can put the European Mega Drive ROM beside `bloodshot.exe`, the Linux
executable or the `.AppImage` itself. Its filename and extension do not matter:
the game identifies the supported raw ROM by its contents and copies it into
`original-media/bloodshot-europe.md` in the game user folder. **Locate ROM** in
Audio settings imports a selected file in the same way. The original stays
unchanged, and future launches use the copy even if you move or remove it.
Finding a ROM keeps both audio sources on their existing choices; select
**Mega Drive** and **Save** to enable it. Compressed archives and interleaved
SMD dumps are not supported. The Mega CD disc image is still required.

Choose **Multiplayer → Network Setup** for player name, port and password.
Host Game opens a lobby; choose Co-op or VS Battle, configure bots and select a
map. While hosting VS, **Bots** changes count/difficulty and **Player Moderation**
removes bots or kicks/bans human participants. **Unban Players** removes a stored
ban. Bans identify a player key; generating another key creates another identity.
Host certificate trust is established on first connection. Score recovery lasts
for the running host session; bans persist in the local hosting profile.

## Server administration

**Multiplayer → Administration** can manage a server without taking a player
seat, including while all four seats are occupied. The owner grants individual
public player-key fingerprints; importing a server profile grants no authority.
The private player key stays on its owner's computer. Passwords and key bans
still apply to administrators.

An administrator copies their full fingerprint from that screen and supplies it
to the owner through a trusted channel. At the server console, use
`admin add FULL_FINGERPRINT`, or `players` followed by `admin grant CONNECTION_ID`.
Use `admins`, `admin revoke FULL_FINGERPRINT` and `admin reload` to manage access.
A listen-server owner has equivalent controls under **Player Moderation**.

The owner runs `profile game.example.net`, using the server's reachable hostname
or IP, and distributes the generated public `server-profile.json`. The client
imports it and independently compares the complete displayed certificate SHA-256
with the owner's value before confirming trust. Administration requires this
explicit pin; ordinary gameplay's first-contact trust is insufficient. The
profile contains only the endpoint and public certificate. Changing the server's
certificate requires explicit trust renewal.

Authorized clients can manage matches, bots, players, bans and the server's five
co-op save slots using the existing game menus. Player Details shows addresses
and public fingerprints only to authorized administrators. Grants/revocation,
server identity and process shutdown stay with the local owner. Live revocation
removes remote controls and closes management-only access.

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

For administration-enabled development, build the pinned hardened editor:

```sh
python3 tools/build_engine.py --target editor --host -j 4
```

This requires SCons 4.4+, GCC 9+ or Clang 11+, `pkg-config` and `wayland-scanner`.
`tools/godot`, `tools/play` and `tools/editor` prefer that local engine once built.
The patch bounds ENet packet/queue allocation before application authentication
and fixes fragment/admission checks. Archive, patch and source hashes are checked
before building; stock engines refuse remote administration. No game-image code
or renderer is patched.

Build both release packages from Linux using matching official Godot 4.7.1 Linux
and Windows export templates in Godot's normal per-user template directory. Also
install CMake, the POSIX-thread MinGW-w64 x86_64 C/C++ cross-compiler and binutils,
and `mksquashfs` (SquashFS tools):

```sh
python3 tools/package_builds.py --platform all --output reports/releases/my-build
```

This builds native dependencies and hardened release engines, Linux client/server exports and Windows
client/server exports, then creates:

- `Bloodshot-Linux-x86_64.AppImage` — Linux client.
- `Bloodshot-Windows-x86_64.zip` — Windows client.
- `Bloodshot-Server-Linux-x86_64.tar.gz` — standalone Linux dedicated server.
- `Bloodshot-Server-Windows-x86_64.zip` — standalone Windows dedicated server.

`artifacts.json` and `SHA256SUMS` cover all selected downloads; `build-info.json`
records native/engine provenance and both Linux client/server ABI checks. Outputs stay local.
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
python3 tools/build_engine.py --target template_release --platform linux -j 4
python3 tools/build_engine.py --target template_release --platform windows -j 4
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

## Dedicated server console

Extract the complete dedicated-server archive. It contains the server, matching
PCK, native library, licenses/notices and server-specific `README.txt`. Linux's
tarball preserves executable permissions and needs no desktop, GPU or FUSE.
Loose exports contain the same server files. Start it in a terminal, supplying
your own supported disc image:

```sh
./bloodshot-server --headless -- --port=28760 --bind=0.0.0.0 --disc /path/to/game.chd
```

On Windows use `bloodshot-server.console.exe` with the same options so the
terminal stays attached. Keep the wrapper, server executable, PCK and native DLL
together. For a VS server add `--mode=versus --map=arena-1 --kill-limit=15`.
Co-op defaults to level 1; use `--level=1` through `--level=16` to choose its start.
`BLOODSHOT_NETWORK_PASSWORD` sets the optional join password for that process.

The server prints its command help at startup. Type `help` to show it again:

| Command | Action |
| --- | --- |
| `status`, `players` | Session details; human/bot IDs, names, seats, connection IPs/ports and public-key fingerprints |
| `kick ID`, `ban ID` | Disconnect a human, or persist their key ban before disconnecting |
| `bans`, `unban FINGERPRINT` | List bans or remove an exact full fingerprint |
| `maps`, `map MAP`, `mode coop`, `mode versus`, `lobby` | List/select maps or change mode and enter its lobby |
| `limit 15`, `rematch` | Set a VS limit (5/10/15/20/30/50) or restart the current arena |
| `bots 3`, `difficulty normal` | Set 0–3 bots or easy/normal/hard VS difficulty |
| `remove-bot B1`, `revive-bot B1` | Remove a listed bot or spend a co-op continue on an exhausted bot |
| `slots`, `save 1`, `load 1` | List or use the five co-op save slots shared with the host menu |
| `admins`, `admin grant ID`, `admin add FINGERPRINT` | List administrators or grant a verified public identity |
| `admin revoke FINGERPRINT`, `admin reload` | Revoke a grant or reload the owner-managed allowlist |
| `profile HOSTNAME` | Export the public connection profile and print its certificate hash |
| `quit` | Disconnect clients and stop the server |

Use the IDs from `players`, not seat numbers. Human connection IDs are never
reused within a running process; bot IDs expire when that incarnation leaves.
These are local owner controls. Joining players receive no administrator rights.
The displayed key is a public fingerprint, never a private key or join password.

The console follows the in-game host rules: mode changes enter the lobby; map,
rematch and active kill-limit changes restart the relevant match. A human must
join before bots can be added. Bot counts/removal can change in the lobby or
VS play; set co-op companions in the lobby before selecting a campaign level.
VS difficulty is independent of co-op companions.

Commands do not block simulation while waiting for input. Redirected input is
accepted too. EOF leaves the server running; use `quit` for an explicit shutdown,
or add `--no-console` when running as an unattended service. Bans, saves and host
identity belong to that server's user profile.

## License and dependencies

Project-authored source is distributed under [BSD-3-Clause](LICENSE).
Reused native audio sources retain their original BSD notices in
`native/audio/LICENSE-mightyweenie`. Other components retain their respective
licenses; see `game/addons/bloodshot_audio/THIRD_PARTY_NOTICES.txt`. Builds also
include notices obtained from the exact Godot engine. The license does not grant
rights to the original game media, which is not distributed here.
