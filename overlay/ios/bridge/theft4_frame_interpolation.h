#pragma once
// Theft4-MetalFX: Apple MetalFX frame interpolation (MTLFXFrameInterpolator,
// iOS 26 SDK). Off by default (launcher: Graphics -> MetalFX FRAME GENERATION).
//
// Inputs, all produced by this renderer every real frame:
//  * color: the frame's final presented image (rendered offscreen instead of
//    straight into the drawable while interpolation is on),
//  * depth: the scene depth of the pass with the most game draws, copied into
//    a Depth32Float texture right after that pass ends,
//  * motion: per-pixel camera-reprojection motion vectors computed in the same
//    full-screen pass from that depth and the game's current/previous
//    view-projection matrices (EnvironmentalDataV1). GTA IV supplies no
//    per-object velocities, so moving cars/peds only carry camera motion.
// Presentation: interpolated frame, then the real frame, each held for at
// least max(1/30 s, half the measured real-frame interval) (presentDrawable:
// afterMinimumDuration:), so presented frames (real + generated) stay at the
// game's 30 FPS cap. No frame duplication or blending is used.
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <cstdint>
#include <string>

#define THEFT4_FRAME_INTERPOLATION_KEY "Theft4MetalFXFrameInterpolation"

namespace theft4::metal {
class Frame;
namespace fi {
// True when the user enabled it, the device supports it and the effect exists.
// Creates the effect lazily on first call for this device/output size.
bool Active(id<MTLDevice> device, uint32_t output_width, uint32_t output_height);
// Backend marks the submission it is about to make as a presented frame that
// interpolation will present (render thread only).
void MarkPresentedFrame(bool presented);
bool PresentedFrameMarked();
// Called by the frame adapter right after the main scene pass. Encodes the
// motion-vector + depth-copy pass into this frame's command buffer.
void EncodeMotion(Frame& frame, id<MTLTexture> scene_depth);
// Called by the backend after the real frame's command buffer was committed.
// Copies color, encodes interpolation and presents interpolated + real frames.
// Returns false (and presents nothing) when the backend must fall back.
bool Present(id<MTLCommandQueue> queue, CAMetalLayer* layer, id<MTLTexture> color,
             uint64_t commit_ns, std::string& error);
}  // namespace fi
}  // namespace theft4::metal

extern "C" {
// From the title frontend, before each presented frame is submitted.
// valid: bit 0 = view-projection valid, bit 1 = projection valid.
void theft4_fi_note_camera(const float* view_projection16, const float* projection16,
                           int valid, float time_step_seconds);
// 0 off, 1 active, -1 device unsupported, -2 creation failed, -3 waiting for inputs.
int theft4_fi_status(void);
}
