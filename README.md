# Theft4-MetalFX

An improved version of [Theft4](https://github.com/KoreanSeats1/Theft4) by KoreanSeats1, the GTA IV port for iPhone. Theft4 is their work, not mine. I built on top of it and added MetalFX upscaling, lighter traffic, and an easier way to get your game files in, to make it run smoother.

You need your own legally dumped Xbox 360 copy of GTA IV. No game files come with this.

## What I improved

### Load your game files without the hassle
On first open the loader appears right away (no setup screen to get past). If you close it, tap **LOAD GAME FILES** to bring it back. Pick how you want to do it:

- **Download ZIP/ISO From Link** – paste a direct download link that starts the file right away (use `https://`; plain `http://` links may be blocked by iOS). Dropbox and Google Drive share links work. It downloads over 16 connections at once, like a download manager, shows MB/s and time left, and picks back up if a piece fails.
- **Select ZIP/ISO From Files** – pick a ZIP or an Xbox 360 ISO and it gets unpacked for you. A ZIP with an ISO inside works too. It checks what the file really is, not just the name.
- **Select Game Folder From Files** – pick an already unpacked game folder and it gets moved into place. No leftover copy eating your storage.
- **Check For Game Files** – finds your game even if it's buried in extra folders, cleans that up, and unpacks any ZIP or ISO you dropped in the game folder.

ZIPs and ISOs unpack into a temp folder first and every file is checked (ZIP CRC, ISO re-read) before anything is moved into place. A picked game folder is moved in without a check. ZIPs and ISOs are deleted after extraction, so you need space for the archive and the extracted game at the same time.

### MetalFX upscaling
Renders the game at a lower resolution and lets Apple's MetalFX sharpen it back up to your screen. More FPS, and it looks a lot cleaner than just dropping the resolution.

Launcher → Graphics → turn on **METALFX UPSCALING**, then pick a **METALFX MODE**. It is off by default. Turning it on turns FSR off and overrides Internal Resolution.

| Mode | Renders at |
|---|---|
| Native | full screen resolution (sharpest, slowest) |
| Quality | 1.5x lower |
| Performance | 2x lower |
| Ultra Performance | 3x lower (fastest, softest) |

### Traffic and pedestrians
Fewer cars and people means less work for the CPU, which is usually what holds phones back.

Launcher → Graphics → **TRAFFIC DENSITY** and **PEDESTRIAN DENSITY**: 5%, 15%, 35%, 60% (default), 80%, 100%.

These scale GTA IV's own population multipliers (random cars, parked cars, ambient and scenario pedestrians), which the game's spawners read, so fewer cars and people are actually created and simulated, not just hidden. Missions that clear the streets still work (zero is left alone). Settings kick in next time you launch the game. Long Performance Capture records the multipliers actually written.

### MetalFX output, frame generation, enhancement
- **METALFX OUTPUT** (in the MetalFX mode row): Match / 720p / 1080p / 1440p. Match follows Internal Resolution; 720p now stays 720p (older builds bumped it to 1080p).
- **METALFX FRAME GENERATION** (Off by default, experimental): Apple MetalFX frame interpolation. Uses scene depth plus camera motion vectors made from the game's camera matrices. Cars and people only carry camera motion, so expect artifacts on them and on the HUD, and about half a frame of extra latency.
- **VISUAL ENHANCEMENT** (Off by default): light contrast-adaptive sharpening plus a mild color and contrast curve in one small pass.

### Performance capture
System → **LONG PERFORMANCE CAPTURE** now also writes `perf-frames-*.csv`, `perf-system-*.csv` and `perf-summary-*.json`: presented FPS and frame-time p50/p95/p99 (from real display times), CPU prepare/encode time, frame-slot and drawable waits, GPU time per command buffer, memory footprint and pressure, thermal state, and frame-generation stats. Download Latest Log Capture includes them.

### Performance overlay and benchmark
- System → **PERFORMANCE OVERLAY** (Off by default): top-left box with **Rendered** (real game frames) and **Generated** (MetalFX frame generation) as per-second rates and totals since you turned it on, plus presented FPS and real frame time. Generated stays 0 when frame generation is off.
- System → **BENCHMARK (60 S)** (off each launch): arms the capture. In game, three-finger tap → **Start 60 s Benchmark** at the same spot or route each time. You get rendered/generated FPS, frame-time p50/p95/p99, GPU and CPU time, waits, thermal and memory, a `benchmark-*.json` in the log capture, and a recommended traffic/pedestrian/MetalFX/resolution profile with **Apply for Next Launch**. Repeat until it says Stable.

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
This is an unofficial improved version, so report problems here, not to the Theft4 devs. Still experimental. The new loader, ISO unpacking, and downloader haven't been fully tested on a real device yet.

## License
GPL-3.0, same as Theft4 (see `COPYING`). All credit for Theft4 goes to KoreanSeats1 and its contributors.
