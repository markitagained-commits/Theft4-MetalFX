#pragma once
// MetalFX upscaler presets (Theft4-MetalFX fork).
// 0 = Off: the launcher's own resolution policy is used unchanged.
// 1..4 = MetalFX Spatial with a fixed render-to-output ratio:
//   1 Native 1.0x (full output resolution, no upscale),
//   2 Quality 1.5x, 3 Performance 2.0x, 4 Ultra Performance 3.0x.
// Stored under a new key so values saved by the earlier six-choice build
// are not misread.
#include <stdint.h>
#include "theft4_output_policy.h"

#define THEFT4_METALFX_PRESET_KEY "Theft4MetalFXMode"
#define THEFT4_METALFX_PRESET_DEFAULT 0
#define THEFT4_METALFX_PRESET_COUNT 5
// MetalFX output target (height), chosen in the same MetalFX settings row.
// 0 = match the Internal Resolution choice's output; 720/1080/1440 = fixed.
#define THEFT4_METALFX_OUTPUT_KEY "Theft4MetalFXOutput"

static inline uint32_t theft4_metalfx_output_height(int value) {
    return value == 720 || value == 1080 || value == 1440 ? (uint32_t)value : 0u;
}

static inline double theft4_metalfx_ratio(int preset) {
    switch (preset) {
        case 1: return 1.0;
        case 2: return 1.5;
        case 3: return 2.0;
        case 4: return 3.0;
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
static inline theft4_output_policy theft4_apply_metalfx_preset_output(
    theft4_output_policy policy, int preset, uint32_t output_target_height) {
    if (preset <= 0 || preset >= THEFT4_METALFX_PRESET_COUNT) return policy;
    output_target_height = theft4_metalfx_output_height((int)output_target_height);
    if (output_target_height) {
        // Explicit MetalFX output target. Keep the presented shape: 16:9 for
        // centered output, the device aspect for Native Aspect.
        uint32_t aw = policy.native_aspect && policy.aspect_width ? policy.aspect_width : 16;
        uint32_t ah = policy.native_aspect && policy.aspect_height ? policy.aspect_height : 9;
        policy.output_height = output_target_height;
        policy.output_width = theft4_metalfx_even((double)output_target_height * aw / ah, 2);
    }
    // Keep the launcher's chosen output size. Earlier builds lifted any
    // output below 1080p (e.g. the 720p choice) to 1920x1080 here, which made
    // "720p + MetalFX Native/Quality" render at 1080p/720p and present at
    // 1080p. MetalFX now upscales into the selected output (720p stays 720p).
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

static inline theft4_output_policy theft4_apply_metalfx_preset(
    theft4_output_policy policy, int preset) {
    return theft4_apply_metalfx_preset_output(policy, preset, 0);
}
