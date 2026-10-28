# Version 0.2

Bloodshot - Battle Frenzy : Headache Edition is a Godot reconstruction of the
Mega CD version of the original game, with the full sixteen-level campaign,
original menus and audio, widescreen support and online multiplayer for
up to four players.

It's not 1:1, but it's pretty close! Some liberties had to be taken due to the
very very low frame rate of the original game and the technical workarounds
that came with that, as well as enabling layering in the new input features and
game modes.

This is the initial public release. There are likely bugs, please report them!

## Bring your own game image

You need your own supported European Mega CD CHD or CUE/BIN image. Original game
images, artwork, music, sound and console firmware are not included. A Mega CD BIOS
is not needed.

On first launch, select your CHD or CUE in the file picker. The game validates it
and stores a verified copy in its user folder for future launches. Your source
image stays unchanged. For CUE/BIN, select the CUE; single-BIN and split-track
BINARY layouts are supported. WAVE/MP3 CUE audio and standalone ISO/BIN images
are not supported.

You can also put the ROM for the cartridge version of the game in your game folder
or select it in-game to enable some extra features, like the original game audio
and ambient background effects instead of CD audio.

## Campaign and presentation

- The full sixteen-level campaign with save/load, using the European CD edition
  as the gameplay baseline.
- 3D accelerated, an uncapped framerate, mouse aiming, configurable controls,
  fullscreen and widescreen support (including ultrawide).
- Original sprites, textures, HUD artwork, bitmap fonts and menus read from the
  game image at runtime and displayed at their correct aspect ratio.
- Sharp bilinear UI/HUD scaling.
- Original CD music and effects, positional audio and independent Music/Effects
  volume sliders.
- Optional Mega Drive ambient soundtrack and effects as independent source choices.
  Use the supported original European ROM using Locate ROM in Audio settings,
  or put it beside the executable or AppImage with any filename or extension.
  The game validates and copies it into the user folder. Finding it preserves
  your existing audio choices; the CD image remains required.

## Controls and preferences

- Keyboard, mouse and gamepad bindings.
- Next/previous weapon selection on the mousewheel and gamepad RB/LB; Q selects.
  Keyboard number-row 1–9 selects occupied HUD slots.
- Video settings with fullscreen/widescreen switches and an FOV slider.

## Four-player multiplayer

- Host a lobby, select a map and add host-controlled bots. Human players take
  priority over bots when joining.
- VS bots have easy/normal/hard difficulty settings. They're currently quite dumb
  as they were mainly developed for testing.
- Set your player name, network port and password through Network Setup.
- Online connections use encrypted transport and persistent player identities.
  Same-session score recovery allows players to leave and rejoin a running host;
  rejoining creates a fresh avatar, with carried inventory dropped on exit.
- Hold Tab to see names, player colours/numbers, scores and ping.
- The host can add/remove VS bots during play and kick or ban human participants.
  Bans persist by player key, with a separate unban list.
- Dedicated servers have a command-line console for players, moderation, maps,
  modes, bot settings and co-op save slots. Type help to see its commands.
- Standalone Linux and Windows server downloads are included, these need testing.
- Remote administration uses individually granted player keys and an explicitly
  verified server profile, without occupying a player seat.
- Multiplayer has seen fairly light testing, mostly simulated. I'd love to hear
  any real world reports.

### VS Battle rules

Some changes accommodate four players while retaining the original game's flavour:

- First to 15 kills by default, with a configurable kill limit.
- Random starts/respawns biased towards points farther from active opponents,
  while allowing close spawns.
- Players respawn with the default gun. Death drops carry weapons with their
  remaining ammunition and a +32 health pickup.
- Weapons respawn and other items and mine hazards reset after 60 seconds.
- Kill streaks refill the selected weapon's ammunition. Taking damage resets
  the streak.

## Downloads and first launch

### Windows x86_64

Extract the complete Windows ZIP and run bloodshot.exe. Keep its companion files
in the same folder, then select your supported CHD or CUE when prompted.

### Linux x86_64

Make the AppImage executable and run it, then select your supported CHD or CUE.
The Linux build targets Ubuntu 20.04 and newer. A working Vulkan graphics driver
is required; the AppImage does not supply the system's graphics driver. On systems
without FUSE, use APPIMAGE_EXTRACT_AND_RUN=1.

The README contains build instructions, controls, dedicated-server commands and
media-storage details.

### Dedicated servers

Extract `Bloodshot-Server-Linux-x86_64.tar.gz` or
`Bloodshot-Server-Windows-x86_64.zip` completely. Keep the executable, matching
PCK and native library together. Open the included `README.txt` for terminal
commands and media-path setup. The Windows server is untested. Good luck!

The Linux server needs no graphical desktop, GPU or AppImage/FUSE mount.

## Current limitations and release checks

- Local split-screen is not included.
- Host certificate trust is established on first connection. Player-key bans
  identify the saved key; generating a new identity can bypass an old key's ban.
- Windows packages are unsigned.

## Source and licensing

Project-authored source is available under BSD-3-Clause. Third-party components
retain their own licences and notices. The source release includes the Original
CD editor dock, which reads assets from the developer's own game image.
