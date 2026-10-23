# Original media

Supply your own supported European Mega CD Bloodshot / Battle Frenzy CHD or CUE/BIN image.
The cartridge edition is not a replacement for this disc image. The native game
does not require a console BIOS.

Windows and Linux clients ask for the CHD or CUE with an OS file picker when needed.
Select a CUE rather than a BIN so the complete track layout is available.
Single-BIN and split-track BINARY images are supported, including Mode 1 data
with 2048- or 2352-byte sectors. All referenced binaries must exist beside the CUE
or in its subfolders. Compressed/WAVE audio and standalone ISO/BIN are unsupported.

A verified image copy goes into `user://original-media/` and is used on later
launches. CHD uses `bloodshot-europe.chd`; CUE/BIN uses an owned image-set folder
with rewritten references. An atomic `active-image.json` selects the installed
image. CHDMAN is not required by the game. No particular source filename or location is required.
The source is read only. Cancelling exits without starting the game.

For development, servers or automation, set `BLOODSHOT_DISC` to the image's absolute path, pass `-- --disc /path/game.chd`,
or use the project's `bloodshot/source/disc_path` setting. Original media is never included in packages. Decoded runtime caches belong to the local user profile.
Do not commit disc images, ripped assets, screenshots, saves or profile keys.
