#!/usr/bin/env python3
"""Theft4-MetalFX: small, asserted source patches applied after the overlay copy.

Each patch must match exactly once, so a changed base fails the build loudly
instead of silently skipping the change.
"""
import sys
from pathlib import Path

root = Path(sys.argv[1])

def patch(rel, old, new):
    path = root / rel
    text = path.read_text()
    count = text.count(old)
    if count != 1:
        sys.exit(f"patch failed: {rel}: expected 1 match, found {count}")
    path.write_text(text.replace(old, new))
    print(f"patched {rel}")

# Frame interpolation: hand the frame's camera (view-projection, projection,
# time step) to the Metal backend before each presented frame is submitted.
patch(
    "glue/rexglue-sdk-main/src/graphics/gta4_native/metal_frame_frontend.inc",
    "    if(!frame_backend_->Submit(plan,present.device!=0,error,&final))return false;",
    """    if(present.device&&!diagnostic_scan) {
      const EnvironmentalDataV1* theft4_env=environmental_data.get();
      const uint64_t theft4_fi_fields=EnvironmentalFieldBit(EnvironmentalField::kViewProjectionMatrix)|
          EnvironmentalFieldBit(EnvironmentalField::kProjectionMatrix);
      theft4_fi_note_camera(theft4_env?theft4_env->view_projection_matrix.data():nullptr,
          theft4_env?theft4_env->projection_matrix.data():nullptr,
          theft4_env&&(theft4_env->valid_fields&theft4_fi_fields)==theft4_fi_fields,
          theft4_env?theft4_env->time_step_seconds:0.0f);
    }
    if(!frame_backend_->Submit(plan,present.device!=0,error,&final))return false;""",
)
patch(
    "glue/rexglue-sdk-main/src/graphics/gta4_native/metal_frame_frontend.inc",
    "struct Gta4NativeGraphicsSystem::NativeMetalFrameState {",
    """extern "C" void theft4_fi_note_camera(const float*,const float*,int,float);
struct Gta4NativeGraphicsSystem::NativeMetalFrameState {""",
)
