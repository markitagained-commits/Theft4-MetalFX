#pragma once
// MetalFX upscaler presets (Theft4-MetalFX fork).
// 0 = Off: the launcher's own resolution policy is used unchanged.
// 1..5 = MetalFX Spatial with a fixed render-to-output ratio:
//   1 Ultra Quality 1.3x, 2 Quality 1.5x, 3 Balanced 1.7x,
//   4 Performance 2.0x, 5 Ultra Performance 3.0x.
#include <stdint.h>
#include "theft4_output_policy.h"

#define THEFT4_METALFX_PRESET_KEY "Theft4MetalFXPreset"
#define THEFT4_METALFX_PRESET_DEFAULT 4
#define THEFT4_METALFX_PRESET_COUNT 6

static inline double theft4_metalfx_ratio(int preset) {
    switch (preset) {
        case 1: return 1.3;
        case 2: return 1.5;
        case 3: return 1.7;
        case 4: return 2.0;
        case 5: return 3.0;
        default: return 1.0;
    }
}

static inline uint32_t theft4_metalfx_even(double value, uint32_t minimum) {
    uint32_t v = (uint32_t)(value + 0.5);
    v &= ~1u;
    return v < minimum ? minimum : v;
}

// Rewrites a launcher policy so the scene renders at output / ratio and the
// final present is upscaled by MetalFX. The runtime's native-resolution hook
// divides the logical video mode by 1.5 (FSR "quality"), so video = render*1.5.
static inline theft4_output_policy theft4_apply_metalfx_preset(
    theft4_output_policy policy, int preset) {
    if (preset <= 0 || preset >= THEFT4_METALFX_PRESET_COUNT) return policy;
    // Upscaling needs a real output budget. Keep native-aspect shapes; lift
    // plain 720p/scene-sized outputs to a 1080p 16:9 target.
    if (!policy.native_aspect && policy.output_height < 1080) {
        policy.output_width = 1920;
        policy.output_height = 1080;
    }
    const double ratio = theft4_metalfx_ratio(preset);
    // The runtime hook rejects scenes below 640x360; clamp to that floor.
    uint32_t render_width = theft4_metalfx_even(policy.output_width / ratio, 640);
    uint32_t render_height = theft4_metalfx_even(policy.output_height / ratio, 360);
    if (render_width > policy.output_width) render_width = policy.output_width;
    if (render_height > policy.output_height) render_height = policy.output_height;
    policy.render_width = render_width;
    policy.render_height = render_height;
    policy.fsr1 = true;  // selects the runtime's reduced-resolution scene path
    policy.video_width = render_width * 3 / 2;
    policy.video_height = render_height * 3 / 2;
    return policy;
}
