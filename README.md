# Wing Commander Prophecy: widescreen and 60 FPS

Release 0.1 adds a wider flight view and a 60 FPS limit to the Steam Enhanced version of Wing Commander Prophecy: 30th Anniversary Edition.
It preserves the vertical view and HUD scale, expands ship visibility into the added screen area, and keeps the small cockpit displays separate.

The patch uses the normal game launcher.
It needs no background injector, new runtime installation, or replacement game data.
You must own the supported game installation.

## Supported build

The tested target is Steam app `3067120`, build `26463990`, on Windows 11 at 2560×1440.
The installer checks exact executable and OpenGL renderer hashes from [manifest.json](manifest.json).
The original executable and the matching 60 FPS executable are accepted.

GOG, retail editions, Secret Ops, other executable revisions, and other resolutions were not validated for this release.
A matching file hash takes priority over an edition label.
This is an early release with limited gameplay coverage.

## Install

Download and extract the Windows ZIP from this repository's Releases page.
Close Prophecy before you run the installer.
Set `GameDirectory` to the folder that contains the Enhanced `prophecy.exe` and `gl_00007.dll`:

```powershell
& .\Install.ps1 -GameDirectory 'G:\Steam\steamapps\common\Wing Commander - Prophecy\Enhanced'
```

The installer preserves the original files, changes the supported 32 FPS limit to 60, and installs the widescreen renderer proxy.
If 60 FPS is already present, it keeps that state.
Launch Enhanced Prophecy through the normal launcher after installation.

The file `wcpwide.log` in the game folder records whether the widescreen hooks loaded.
Backups and the installation record remain in `wcpwide-backup`.
Keep `gl_00007_original.dll` beside the proxy because the proxy loads that renderer.

## Remove

Close Prophecy and run the same installer with `-Uninstall`:

```powershell
& .\Install.ps1 -GameDirectory 'G:\Steam\steamapps\common\Wing Commander - Prophecy\Enhanced' -Uninstall
```

Removal restores the original renderer and the executable state saved before installation.
An existing 60 FPS patch stays at 60 FPS.
Backups remain available, and the installer refuses to overwrite later unrecognized modifications.

## Validation and limits

The original installation initialized a 32 FPS limit and displayed flight in 4:3.
The temporary widescreen trial showed extra scenery and a carrier beyond the old left boundary, with the displayed counter around 60 FPS.
The installed native proxy then loaded through the normal launcher, and its owner confirmed that it worked in flight.

The native geometry and loader tests passed.
The portable install/remove tests cover stock input, existing 60 FPS, repeat installation, original-file restoration, and changed-file refusal.
The [technical report](docs/REPORT.md) separates those results from untested behavior.

Full campaign completion, every cockpit, all targeting modes, mission transitions, and frame pacing remain unverified.
The target is 60 FPS because earlier community work reported gameplay and animation faults at higher rates.
A Steam update or file verification can restore the original executable or renderer.

## Build

From the source checkout, use the installed Visual Studio C++ x86 build tools and Windows SDK:

```powershell
& .\Build.ps1
```

The build uses the installed toolchain, runs the geometry self-test, and writes the package to `dist`.
The source build can differ in file hash from the published DLL because linker metadata changes.
The published 0.1 package contains the exact DLL used in the confirmed flight test.

## Credits and license

The existing OpenGL renderer by Pedro and PopsiclePete and the enhancement work by HCl provide the underlying game improvements.
gr1mre4per's [FPS utility](https://www.wcnews.com/chatzone/threads/prophecy-frame-rate-boost.27791/) established the existing frame-limit patch.
Matt Wells' [WC3](https://github.com/mattwells77/Wing_Commander_III_Enhancement_Patch) and [WC4](https://github.com/mattwells77/Wing_Commander_IV_Enhancement_Patch) patches provided reference approaches for camera and HUD separation.

This patch is distributed under the [MIT license](LICENSE).
The release contains this patch's own DLL, source, installer, and documentation.
It contains no original executable, original renderer, game assets, or saved games.
