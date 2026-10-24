# Version 0.1 — Initial public release

Bloodshot / Battle Frenzy - Headache Edition is a native Godot reconstruction of the
European Mega CD edition of the original game, with the sixteen-level campaign, original
menus and audio, widescreen support, and online multiplayer for up to four players. It
was built with assistance from AI coding agents.

## Bring your own game image

You need your own supported European Mega CD CHD or CUE/BIN image. Original game images,
artwork, music, sound and console firmware are not included, though a Mega CD BIOS is not
needed.

On first launch, select your CHD or CUE in the file picker. The game validates it and
stores a verified copy in its user folder for future launches. Your source image
is unchanged.

For CUE/BIN, select the CUE file. Single-BIN and split-track BINARY layouts are
supported. WAVE/MP3 CUE audio and standalone ISO/BIN images are not supported.

## Features

- The full campaign with arbitrary save/load, with the European CD edition of the game
  as the gameplay baseline.
- Uncapped framerate.
- True 3D geometry, mouse aiming, configurable keyboard/mouse/gamepad controls,
  and widescreen and fullscreen options.
- Original sprites, textures, HUD artwork, bitmap fonts and menus read from the
  game image at runtime, displayed at their correct aspect ratio.
- Enhanced audio (distance falloff).

## Four-player multiplayer

Play online co-op or respawning free-for-all VS Battle. Local split-screen is not
included in this release.

- Host a lobby, select a map and add host-controlled bots. Human players take
  priority over bots when joining.
- VS bots have difficulty settings. Co-op bots act as companions, collect weapons
  rather than keys or bonuses, and yield when players push against them. They're
  currently quite dumb as they were mainly developed for testing.
- Set your player name, network port and password through Network Setup.
- Online connections use encrypted transport and persistent player identities.
  Same-session score recovery allows players to leave and rejoin a running host.
- The host can kick/ban players, though ideally just avoid inviting arseholes.

### VS Battle rules

Some changes were made to VS Battle to better accomodate 4 players and to polish
some of the original design decisions, while trying to retain it's unique flavour.

- Players respawn at a randomly selected spawn point, with a bias towards points
  farther from active opponents.
- Death drops player weapons with their remaining ammunition and a +32 health pickup.
- Weapons respawn at their original locations after 60 seconds. Other renewable
  items and mine hazards also have 60-second reset timers.
- Kill streaks refill ammunition for the selected weapon. Taking damage resets
  the streak.

## Downloads and first launch

### Windows x86_64

Extract the complete Windows ZIP and run `bloodshot.exe`. Keep its companion files
in the same folder. Select your supported CHD or CUE when prompted.

### Linux x86_64

Make the AppImage executable and run it, then select your supported CHD or CUE. The Linux
build targets Ubuntu 20.04 and newer. A working graphics driver with Vulkan support
is required for the Forward+ renderer; the AppImage does not supply the system's
graphics driver. On systems without FUSE, use `APPIMAGE_EXTRACT_AND_RUN=1`.

The README contains build instructions, controls, dedicated-server options and
additional details about media storage.

## Current limitations

- Local split-screen, host migration and co-op recordings are not included.
- Host certificate trust is established on first connection. Player-key bans
  identify the saved key; generating a new identity can bypass an old key's ban.

## Source and licensing

Project-authored source is available under BSD-3-Clause. Third-party components
retain their own licences and notices. The source release includes the Original
CD editor dock, which reads assets from the developer's own game image.

## Updated 0.1 build

- Restored the original Welcome sound when starting a playable level.
- Restored the level-completion music and kept it playing through co-op results.
  Music playback remains independent on each client.
- Clarified the opening notice to say "This port is not licensed".

## Input and performance fixes

- Capture the mouse when entering gameplay from the menu in a focused window.
- Keep mouse aiming responsive without running simulation, targeting or collision
  work for every mouse report, in offline and online play.
- Avoid unnecessary lock-on visibility work while preserving target selection.
- Reduce explosion/mine knockback collision work and reuse checked camera paths
  for the affected player and multiplayer observers.

## HUD fixes

- Preserve transparent minimap/card pixels and widescreen HUD frame cutouts.
- Restore the original upper-left and upper-right corner tiles in the 4:3 frame.
