# Theft4-MetalFX

An unofficial performance fork of [Theft4 0.3.2](https://github.com/KoreanSeats1/Theft4) by KoreanSeats1 (GPL-3.0).

## What Theft4 is
Theft4 is a native iOS port of the Xbox 360 version of GTA IV. It is a **static recompilation**: the game's
PowerPC code from the 360 executable was translated ahead of time into C++ (`LibertyRecompLib` /
`gta4-recomp`) and compiled for Apple's ARM chips, so it runs as a real iPhone app instead of through a
live emulator. Graphics run on a direct Metal renderer, with a MoltenVK (Vulkan-on-Metal) fallback. The
launcher has settings for resolution, shadows, draw distance, model detail, motion blur and a Frame Speed
preset.

**No game content is included.** The app needs your own legally dumped Xbox 360 disc
(`default.xex`, `common.rpf`, `xbox360.rpf`, `audio.rpf` and the rest of the game folder).

## What this fork adds
### 1. MetalFX upscaling (GPU)
On the 0.3.2 direct-Metal path, the final Present pass simply stretches the scene to the screen, so lower
render resolutions look soft and blocky. This fork renders lower, runs **Apple MetalFX Spatial** on the
frame, then presents it 1:1.

Launcher → Graphics → **METALFX UPSCALER**

| Preset | Internal resolution (of output) |
|---|---|
| Off | uses the normal resolution settings |
| UQ (Ultra Quality) | 1 / 1.3 |
| Qual (Quality) | 1 / 1.5 |
| Bal (Balanced) | 1 / 1.7 |
| Perf (Performance, default) | 1 / 2.0 |
| UP (Ultra Performance) | 1 / 3.0 |

### 2. Traffic and pedestrian density (CPU)
Upstream ships GTA IV's population at 125% of stock. Fewer cars and people means less AI, physics and
streaming work for the CPU, which is usually the bottleneck on phones.

Launcher → Graphics → **TRAFFIC** and **PEDESTRIANS**

| Setting | Share of the game's stock density |
|---|---|
| Low | 35% |
| Med (default) | 60% |
| High | 80% |
| Stock | 100% |

Traffic covers driving and parked cars; Pedestrians covers street and scenario peds. Missions that turn
population off still work, since zero values are left alone.

All new settings apply on the next game launch.

## Tips for best performance
- Frame Speed preset + MetalFX Performance + Traffic/Pedestrians on Low or Med.
- Lock to 30 FPS for steady frame pacing.
- MetalFX helps GPU-bound scenes; density helps CPU-bound scenes (busy streets, driving fast).

## Install
1. Download the latest `.ipa` from [Releases](../../releases).
2. Sideload with AltStore or Sideloadly (the IPA is unsigned).
3. Add your own game files as the upstream Theft4 instructions describe.

## Build
GitHub Actions (`.github/workflows/build-ipa.yml`) clones upstream v0.3.2, copies `overlay/` on top,
builds the iPhoneOS MoltenVK/SPIR-V libraries and offline Metal shaders, and publishes an unsigned IPA to
Releases. It can run on `macos-26` or `macos-26-intel` (Actions → Run workflow → runner). `metalfx.patch`
is the MetalFX change as a diff.

Changed files: `ios/bridge/theft4_metal_frame.mm`, `theft4_metal_presenter.mm`, `theft4_native_metal.{h,mm}`,
`theft4_upscale_preset.h` (MetalFX); `ios/bridge/theft4_motion_blur.cpp` (density, applied each frame);
`ios/Theft4/Theft4LauncherView.{h,m}` (settings); `ios/CMakeLists.txt` (MetalFX framework).

## Status
Experimental and untested on device. Report issues here, not to upstream.

## License
GPL-3.0, same as upstream (see `COPYING`). All credit for Theft4 goes to KoreanSeats1 and its contributors.
