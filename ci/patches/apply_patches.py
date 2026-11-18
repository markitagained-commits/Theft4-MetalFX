#!/usr/bin/env python3
"""Theft4-MetalFX: small, asserted source patches applied after the overlay copy.

Each patch must match exactly once, so a changed base fails the build loudly
instead of silently skipping the change.
"""
import sys
from pathlib import Path

if len(sys.argv) != 2:
    sys.exit("usage: apply_patches.py <Theft4 source root (overlay already copied)>")
root = Path(sys.argv[1])
if not root.is_dir():
    sys.exit(f"patch failed: source root {root} does not exist")

def patch(rel, old, new):
    path = root / rel
    if not path.is_file():
        sys.exit(f"patch failed: {rel}: file not found under {root} (upstream layout changed?)")
    text = path.read_text()
    if new in text:
        # Both patches keep their anchor inside the replacement, so a second
        # run would insert the block again. Treat it as already applied.
        print(f"already patched {rel}")
        return
    count = text.count(old)
    if count != 1:
        # Show what was expected, so a changed upstream base is easy to rebase.
        first = old.strip().splitlines()[0] if old.strip() else old
        sys.exit(f"patch failed: {rel}: expected 1 match, found {count}\n"
                 f"  anchor starts with: {first!r}")
    path.write_text(text.replace(old, new))
    print(f"patched {rel}")

# Frame interpolation: hand the frame's camera (view-projection, projection,
# time step) to the Metal backend before each presented frame is submitted.
patch(
    "glue/rexglue-sdk-main/src/graphics/gta4_native/metal_frame_frontend.inc",
    "    if(!frame_backend_->Submit(plan,present.device!=0,error,&final))return false;",
    """    if(present.device&&!diagnostic_scan) {
      const EnvironmentalDataV1* theft4_env=environmental_data.get();
      // bit 0: view-projection valid (motion vectors), bit 1: projection valid
      // (interpolator camera only). Motion must not depend on the projection.
      const uint64_t theft4_fi_fields=theft4_env?theft4_env->valid_fields:0;
      const int theft4_fi_valid=
          ((theft4_fi_fields&EnvironmentalFieldBit(EnvironmentalField::kViewProjectionMatrix))?1:0)|
          ((theft4_fi_fields&EnvironmentalFieldBit(EnvironmentalField::kProjectionMatrix))?2:0);
      theft4_fi_note_camera(theft4_env?theft4_env->view_projection_matrix.data():nullptr,
          theft4_env?theft4_env->projection_matrix.data():nullptr,
          theft4_fi_valid,
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
