# Theft4-MetalFX

GTA IV on iPhone, tuned to run smoother. This is my build of Theft4 with MetalFX upscaling, lighter traffic, and a much easier way to get your game files in.

You need your own legally dumped Xbox 360 copy of GTA IV. No game files come with this.

## What's new in this build

### Load your game files without the hassle
On first open, tap **LOAD GAME FILES** and pick how you want to do it:

- **Download ZIP/ISO From Link** – paste a direct link (Dropbox and Google Drive share links work). It downloads over 16 connections at once, like a download manager, shows MB/s and time left, and picks back up if a piece fails.
- **Select ZIP/ISO From Files** – pick a ZIP or an Xbox 360 ISO and it gets unpacked for you. A ZIP with an ISO inside works too. It checks what the file really is, not just the name.
- **Select Game Folder From Files** – pick an already unpacked game folder and it gets moved into place. No leftover copy eating your storage.
- **Check For Game Files** – finds your game even if it's buried in extra folders, cleans that up, and unpacks any ZIP or ISO you dropped in the game folder.

Everything unpacks into a temp folder first and every file gets checked before it's swapped in, so a failed or cut-off download won't break a working install.

### MetalFX upscaling
Renders the game at a lower resolution and lets Apple's MetalFX sharpen it back up to your screen. More FPS, and it looks a lot cleaner than just dropping the resolution.

Launcher → Graphics → **METALFX UPSCALER**

| Mode | Renders at |
|---|---|
| Native | full screen resolution (sharpest, slowest) |
| Quality | 1.5x lower |
| Performance | 2x lower |
| Ultra Performance | 3x lower (fastest, softest) |

### Traffic and pedestrians
Fewer cars and people means less work for the CPU, which is usually what holds phones back.

Launcher → Graphics → **TRAFFIC** and **PEDESTRIANS**

| Setting | Amount |
|---|---|
| Low | 35% |
| Medium (default) | 60% |
| High | 80% |
| Stock | 100% |

Missions that clear the streets still work. Settings kick in next time you launch the game.

## Best settings for FPS
- Frame Speed preset + MetalFX Performance + Traffic and Pedestrians on Low or Medium
- Lock to 30 FPS for smoother frame pacing
- MetalFX helps when the graphics are the problem, lower density helps on busy streets and fast driving

## Install
1. Grab the latest `.ipa` from [Releases](../../releases).
2. Sideload it with AltStore or Sideloadly (it's unsigned).
3. Already have Theft4 installed? It installs right over it as an update. Export your saves first just in case (System → Export Saves to Files).
4. Open it and tap **LOAD GAME FILES**.

## Building it yourself
GitHub Actions builds the IPA and posts it to Releases. Actions → Run workflow, and pick `macos-26` or `macos-26-intel` for the runner.

## Heads up
Still experimental. The new loader, ISO unpacking, and downloader haven't been fully tested on a real device yet, so report anything weird in Issues here.

## License
GPL-3.0 (see `COPYING`). Built on [Theft4](https://github.com/KoreanSeats1/Theft4).
