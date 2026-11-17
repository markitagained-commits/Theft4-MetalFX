# Theft4-MetalFX

A small fork of [Theft4 0.3.2](https://github.com/KoreanSeats1/Theft4) (GPL-3.0) that swaps the final
upscale on iOS for **Apple MetalFX Spatial** and adds upscaler presets.

Why: on the 0.3.2 direct-Metal path the final Present pass upscales by point sampling, so lower
internal resolutions look blocky. This fork runs MetalFX Spatial on the scene first, then presents 1:1.

## Presets (launcher → Graphics → METALFX UPSCALER)
| Preset | Internal res (of output) |
|---|---|
| Off | unchanged launcher settings |
| Ultra Quality | 1 / 1.3 |
| Quality | 1 / 1.5 |
| Balanced | 1 / 1.7 |
| Performance (default) | 1 / 2.0 |
| Ultra Performance | 1 / 3.0 |

Applies on the next game launch. Upscaling only helps GPU-bound frames; CPU-heavy scenes won't speed up.

## Build
GitHub Actions (`.github/workflows/build-ipa.yml`) clones upstream v0.3.2, copies `overlay/` on top,
builds the iPhoneOS MoltenVK/SPIR-V archives and offline Metal shaders, and packages an unsigned IPA
into Releases. `metalfx.patch` is the same change as a diff. No game files are included; bring your
own legally dumped copy.
