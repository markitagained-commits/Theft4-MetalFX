#include "theft4_frame_interpolation.h"
#include "theft4_native_metal.h"
#include "theft4_perf_stats.h"
#include "theft4_retail_mode.h"
#include <algorithm>
#import <MetalFX/MetalFX.h>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <mutex>

namespace {
struct Camera {
  std::array<float,16> vp{}, proj{};
  bool valid=false;       // view-projection valid (needed for motion vectors)
  bool proj_valid=false;  // projection valid (only refines interpolator camera)
  float dt=0;
  uint64_t serial=0;
};
std::mutex camera_mutex;
Camera latest_camera;
std::atomic<int> status{0};

bool Invert(const float* m, float* out) {
  float inv[16];
  inv[0]=m[5]*m[10]*m[15]-m[5]*m[11]*m[14]-m[9]*m[6]*m[15]+m[9]*m[7]*m[14]+m[13]*m[6]*m[11]-m[13]*m[7]*m[10];
  inv[4]=-m[4]*m[10]*m[15]+m[4]*m[11]*m[14]+m[8]*m[6]*m[15]-m[8]*m[7]*m[14]-m[12]*m[6]*m[11]+m[12]*m[7]*m[10];
  inv[8]=m[4]*m[9]*m[15]-m[4]*m[11]*m[13]-m[8]*m[5]*m[15]+m[8]*m[7]*m[13]+m[12]*m[5]*m[11]-m[12]*m[7]*m[9];
  inv[12]=-m[4]*m[9]*m[14]+m[4]*m[10]*m[13]+m[8]*m[5]*m[14]-m[8]*m[6]*m[13]-m[12]*m[5]*m[10]+m[12]*m[6]*m[9];
  inv[1]=-m[1]*m[10]*m[15]+m[1]*m[11]*m[14]+m[9]*m[2]*m[15]-m[9]*m[3]*m[14]-m[13]*m[2]*m[11]+m[13]*m[3]*m[10];
  inv[5]=m[0]*m[10]*m[15]-m[0]*m[11]*m[14]-m[8]*m[2]*m[15]+m[8]*m[3]*m[14]+m[12]*m[2]*m[11]-m[12]*m[3]*m[10];
  inv[9]=-m[0]*m[9]*m[15]+m[0]*m[11]*m[13]+m[8]*m[1]*m[15]-m[8]*m[3]*m[13]-m[12]*m[1]*m[11]+m[12]*m[3]*m[9];
  inv[13]=m[0]*m[9]*m[14]-m[0]*m[10]*m[13]-m[8]*m[1]*m[14]+m[8]*m[2]*m[13]+m[12]*m[1]*m[10]-m[12]*m[2]*m[9];
  inv[2]=m[1]*m[6]*m[15]-m[1]*m[7]*m[14]-m[5]*m[2]*m[15]+m[5]*m[3]*m[14]+m[13]*m[2]*m[7]-m[13]*m[3]*m[6];
  inv[6]=-m[0]*m[6]*m[15]+m[0]*m[7]*m[14]+m[4]*m[2]*m[15]-m[4]*m[3]*m[14]-m[12]*m[2]*m[7]+m[12]*m[3]*m[6];
  inv[10]=m[0]*m[5]*m[15]-m[0]*m[7]*m[13]-m[4]*m[1]*m[15]+m[4]*m[3]*m[13]+m[12]*m[1]*m[7]-m[12]*m[3]*m[5];
  inv[14]=-m[0]*m[5]*m[14]+m[0]*m[6]*m[13]+m[4]*m[1]*m[14]-m[4]*m[2]*m[13]-m[12]*m[1]*m[6]+m[12]*m[2]*m[5];
  inv[3]=-m[1]*m[6]*m[11]+m[1]*m[7]*m[10]+m[5]*m[2]*m[11]-m[5]*m[3]*m[10]-m[9]*m[2]*m[7]+m[9]*m[3]*m[6];
  inv[7]=m[0]*m[6]*m[11]-m[0]*m[7]*m[10]-m[4]*m[2]*m[11]+m[4]*m[3]*m[10]+m[8]*m[2]*m[7]-m[8]*m[3]*m[6];
  inv[11]=-m[0]*m[5]*m[11]+m[0]*m[7]*m[9]+m[4]*m[1]*m[11]-m[4]*m[3]*m[9]-m[8]*m[1]*m[7]+m[8]*m[3]*m[5];
  inv[15]=m[0]*m[5]*m[10]-m[0]*m[6]*m[9]-m[4]*m[1]*m[10]+m[4]*m[2]*m[9]+m[8]*m[1]*m[6]-m[8]*m[2]*m[5];
  const float det=m[0]*inv[0]+m[1]*inv[4]+m[2]*inv[8]+m[3]*inv[12];
  if(!std::isfinite(det)||std::fabs(det)<1e-20f)return false;
  for(int i=0;i<16;++i)out[i]=inv[i]/det;
  return true;
}

// Must match FIConstants in the shader source below.
struct MotionConstants {
  float inv_vp[16];
  float prev_vp[16];
  float size[2];
  float sign;
  float pad;
};

const char* kShaderSource = R"MSL(
#include <metal_stdlib>
using namespace metal;
struct FIV { float4 p [[position]]; };
vertex FIV theft4_fi_vs(uint id [[vertex_id]]) {
  float2 uv = float2((id << 1) & 2, id & 2);
  FIV o; o.p = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0); return o;
}
fragment float4 theft4_fi_copy(FIV in [[stage_in]], texture2d<float> src [[texture(0)]]) {
  uint2 c = min(uint2(in.p.xy), uint2(src.get_width() - 1, src.get_height() - 1));
  return src.read(c);
}
struct FIConstants { float4x4 inv_vp; float4x4 prev_vp; float2 size; float sign; float pad; };
struct FIMotionOut { float2 motion [[color(0)]]; float depth [[depth(any)]]; };
fragment FIMotionOut theft4_fi_motion(FIV in [[stage_in]], depth2d<float> d [[texture(0)]],
                                      constant FIConstants& k [[buffer(0)]]) {
  float2 uv = in.p.xy / k.size;
  uint2 dc = min(uint2(uv * float2(d.get_width(), d.get_height())),
                 uint2(d.get_width() - 1, d.get_height() - 1));
  float z = d.read(dc);
  FIMotionOut o; o.depth = z; o.motion = float2(0.0);
  // Row-vector guest matrices are bound unchanged, so clip = M^T * v here.
  float4 w = k.inv_vp * float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, z, 1.0);
  if (abs(w.w) > 1e-7) {
    w /= w.w;
    float4 pc = k.prev_vp * w;
    if (pc.w > 1e-6) {
      float2 pn = pc.xy / pc.w;
      float2 puv = float2(pn.x * 0.5 + 0.5, 0.5 - pn.y * 0.5);
      o.motion = (puv - uv) * k.sign;
    }
  }
  return o;
}
// Same pass for a multisampled scene depth (MSAA on): sample 0 of each pixel.
fragment FIMotionOut theft4_fi_motion_ms(FIV in [[stage_in]], depth2d_ms<float> d [[texture(0)]],
                                         constant FIConstants& k [[buffer(0)]]) {
  float2 uv = in.p.xy / k.size;
  uint2 dc = min(uint2(uv * float2(d.get_width(), d.get_height())),
                 uint2(d.get_width() - 1, d.get_height() - 1));
  float z = d.read(dc, 0);
  FIMotionOut o; o.depth = z; o.motion = float2(0.0);
  float4 w = k.inv_vp * float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, z, 1.0);
  if (abs(w.w) > 1e-7) {
    w /= w.w;
    float4 pc = k.prev_vp * w;
    if (pc.w > 1e-6) {
      float2 pn = pc.xy / pc.w;
      float2 puv = float2(pn.x * 0.5 + 0.5, 0.5 - pn.y * 0.5);
      o.motion = (puv - uv) * k.sign;
    }
  }
  return o;
}
)MSL";

struct State {
  id<MTLDevice> device=nil;
  uint32_t width=0,height=0;
  bool failed=false,unsupported=false;
  id<MTLFXFrameInterpolator> interpolator=nil;
  id<MTLLibrary> library=nil;
  id<MTLRenderPipelineState> copy_rgba16=nil, copy_drawable=nil, motion=nil, motion_ms=nil;
  MTLPixelFormat drawable_format=MTLPixelFormatInvalid;
  id<MTLDepthStencilState> depth_always=nil;
  std::array<id<MTLTexture>,3> colors{};
  id<MTLTexture> interpolated=nil, motion_texture=nil, depth_texture=nil;
  uint32_t color_index=0;
  bool have_previous=false;
  bool motion_ready=false;      // motion/depth were encoded for the current frame
  uint64_t motion_camera_serial=0;
  Camera previous_camera;
  bool have_previous_camera=false;
  uint64_t last_commit_ns=0;
  double interval_s=1.0/30.0;
  uint64_t sequence=0;
  bool encoded_last_frame=false;  // interpolator ran for the previous real frame
};
State state;
std::mutex state_mutex;  // render worker only in practice; guards lazy creation

// Next-launch setting: read once per process.
bool Requested() {
  static const bool requested=[NSUserDefaults.standardUserDefaults boolForKey:@THEFT4_FRAME_INTERPOLATION_KEY];
  return requested;
}
// Diagnostic motion-vector sign flip; read once instead of every frame.
float MotionSign() {
  static const float sign=[NSUserDefaults.standardUserDefaults boolForKey:@"Theft4FIMotionInvert"]?-1.f:1.f;
  return sign;
}

id<MTLRenderPipelineState> FIPipeline(id<MTLLibrary> library, NSString* fragment,
                                   MTLPixelFormat color, MTLPixelFormat depth) {
  MTLRenderPipelineDescriptor* d=[MTLRenderPipelineDescriptor new];
  d.vertexFunction=[library newFunctionWithName:@"theft4_fi_vs"];
  d.fragmentFunction=[library newFunctionWithName:fragment];
  d.colorAttachments[0].pixelFormat=color;
  d.depthAttachmentPixelFormat=depth;
  NSError* error=nil;
  auto pipeline=[library.device newRenderPipelineStateWithDescriptor:d error:&error];
  if(!pipeline)std::fprintf(stderr,"theft4-fi: pipeline %s failed: %s\n",fragment.UTF8String,
                           error.localizedDescription.UTF8String?:"");
  return pipeline;
}

id<MTLTexture> MakeTexture(id<MTLDevice> device, MTLPixelFormat format, uint32_t w, uint32_t h,
                           MTLTextureUsage usage) {
  MTLTextureDescriptor* t=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
      width:w height:h mipmapped:NO];
  t.storageMode=MTLStorageModePrivate;t.usage=usage;
  return [device newTextureWithDescriptor:t];
}

bool Create(id<MTLDevice> device,uint32_t w,uint32_t h) {
  state=State{};state.device=device;state.width=w;state.height=h;
  if(![MTLFXFrameInterpolatorDescriptor supportsDevice:device]) {
    state.unsupported=true;status.store(-1);
    std::fprintf(stderr,"theft4-fi: MTLFXFrameInterpolatorDescriptor supportsDevice: NO\n");
    return false;
  }
  MTLFXFrameInterpolatorDescriptor* d=[MTLFXFrameInterpolatorDescriptor new];
  d.colorTextureFormat=MTLPixelFormatRGBA16Float;
  d.outputTextureFormat=MTLPixelFormatRGBA16Float;
  d.depthTextureFormat=MTLPixelFormatDepth32Float;
  d.motionTextureFormat=MTLPixelFormatRG16Float;
  d.inputWidth=w;d.inputHeight=h;d.outputWidth=w;d.outputHeight=h;
  state.interpolator=[d newFrameInterpolatorWithDevice:device];
  NSError* error=nil;
  id<MTLLibrary> library=[device newLibraryWithSource:@(kShaderSource) options:nil error:&error];
  if(!state.interpolator||!library) {
    std::fprintf(stderr,"theft4-fi: creation failed interpolator=%d library=%d %s\n",
                 state.interpolator!=nil,library!=nil,error.localizedDescription.UTF8String?:"");
    state.failed=true;status.store(-2);return false;
  }
  state.copy_rgba16=FIPipeline(library,@"theft4_fi_copy",MTLPixelFormatRGBA16Float,MTLPixelFormatInvalid);
  state.motion=FIPipeline(library,@"theft4_fi_motion",MTLPixelFormatRG16Float,MTLPixelFormatDepth32Float);
  // Optional: only used when the scene depth is multisampled.
  state.motion_ms=FIPipeline(library,@"theft4_fi_motion_ms",MTLPixelFormatRG16Float,MTLPixelFormatDepth32Float);
  MTLDepthStencilDescriptor* ds=[MTLDepthStencilDescriptor new];
  ds.depthCompareFunction=MTLCompareFunctionAlways;ds.depthWriteEnabled=YES;
  state.depth_always=[device newDepthStencilStateWithDescriptor:ds];
  const auto color_usage=state.interpolator.colorTextureUsage|MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
  for(auto& c:state.colors)c=MakeTexture(device,MTLPixelFormatRGBA16Float,w,h,color_usage);
  state.interpolated=MakeTexture(device,MTLPixelFormatRGBA16Float,w,h,
      state.interpolator.outputTextureUsage|MTLTextureUsageShaderRead);
  state.motion_texture=MakeTexture(device,MTLPixelFormatRG16Float,w,h,
      state.interpolator.motionTextureUsage|MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead);
  state.depth_texture=MakeTexture(device,MTLPixelFormatDepth32Float,w,h,
      state.interpolator.depthTextureUsage|MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead);
  bool ok=state.copy_rgba16&&state.motion&&state.depth_always&&state.interpolated&&
          state.motion_texture&&state.depth_texture;
  for(auto& c:state.colors)ok=ok&&c;
  if(!ok){state.failed=true;status.store(-2);return false;}
  // Drawable copy pipeline is created on first present (needs the layer format).
  state.library=library;
  std::fprintf(stderr,"theft4-fi: MetalFX frame interpolator ready %ux%u\n",w,h);
  status.store(-3);
  return true;
}

// Camera parameters for the interpolator, from the guest projection matrix
// (row-major D3D style: [0]=x scale, [5]=y scale, [10]/[14] depth terms).
void ConfigureCamera(const Camera& c) {
  // Without a valid projection the defaults below are used (fov 60, 0.1..5000).
  static const std::array<float,16> kNoProjection{};
  const float* p=c.proj_valid?c.proj.data():kNoProjection.data();
  float fov=60.f,aspect=float(state.width)/float(std::max(1u,state.height)),near_plane=0.1f,far_plane=5000.f;
  bool reversed=false;
  if(std::isfinite(p[5])&&std::fabs(p[5])>1e-4f) {
    fov=2.f*std::atan(1.f/std::fabs(p[5]))*180.f/float(M_PI);
    if(std::fabs(p[0])>1e-4f)aspect=std::fabs(p[5]/p[0]);
  }
  const float a=p[10],b=p[14];
  if(std::isfinite(a)&&std::isfinite(b)&&std::fabs(a)>1e-7f) {
    // Depth of view distance t: z(t)=(a*t+b)/t for both handedness variants
    // (sign folded into |.|). Solve z=0 and z=1 for the two planes.
    const float t0=std::fabs(b/a), t1=std::fabs(a-1.f)>1e-7f?std::fabs(b/(a-1.f)):0.f;
    if(t0>0&&t1>0) {
      reversed=t0>t1;  // z=0 farther than z=1 -> reversed depth
      near_plane=std::min(t0,t1);far_plane=std::max(t0,t1);
    }
  }
  auto fi=state.interpolator;
  fi.fieldOfView=fov;fi.aspectRatio=aspect;fi.nearPlane=near_plane;fi.farPlane=far_plane;
  fi.depthReversed=reversed;
}

void CopyPass(id<MTLCommandBuffer> cb,id<MTLRenderPipelineState> pipeline,id<MTLTexture> src,id<MTLTexture> dst) {
  MTLRenderPassDescriptor* rp=[MTLRenderPassDescriptor renderPassDescriptor];
  rp.colorAttachments[0].texture=dst;rp.colorAttachments[0].loadAction=MTLLoadActionDontCare;
  rp.colorAttachments[0].storeAction=MTLStoreActionStore;
  auto e=[cb renderCommandEncoderWithDescriptor:rp];
  [e setRenderPipelineState:pipeline];[e setFragmentTexture:src atIndex:0];
  [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[e endEncoding];
}
}  // namespace

// valid: bit 0 = view-projection valid, bit 1 = projection valid.
extern "C" void theft4_fi_note_camera(const float* vp,const float* proj,int valid,float dt) {
  if(!Requested())return;  // no work at all while frame generation is off
  std::lock_guard lock(camera_mutex);
  latest_camera.valid=(valid&1)&&vp;
  latest_camera.proj_valid=(valid&2)&&proj;
  if(vp)std::memcpy(latest_camera.vp.data(),vp,64);
  if(proj)std::memcpy(latest_camera.proj.data(),proj,64);
  latest_camera.dt=dt;++latest_camera.serial;
}
extern "C" int theft4_fi_status(void) {
  if(!Requested())return 0;
  return status.load();
}

namespace theft4::metal::fi {
namespace { thread_local bool presented_frame=false; }
void MarkPresentedFrame(bool presented){presented_frame=presented;}
bool PresentedFrameMarked(){return presented_frame;}
bool Active(id<MTLDevice> device,uint32_t w,uint32_t h) {
  if(!Requested()||!device||!w||!h)return false;
  std::lock_guard lock(state_mutex);
  if(state.device==device&&state.width==w&&state.height==h)return !state.failed&&!state.unsupported&&state.interpolator;
  if(state.device==device&&(state.failed||state.unsupported)&&state.width==w&&state.height==h)return false;
  return Create(device,w,h);
}

void EncodeMotion(Frame& frame,id<MTLTexture> scene_depth) {
  std::lock_guard lock(state_mutex);
  state.motion_ready=false;
  if(!state.interpolator||!scene_depth)return;
  Camera camera;{std::lock_guard c(camera_mutex);camera=latest_camera;}
  if(!camera.valid)return;
  // Combined depth/stencil binds directly as depth2d (the depth aspect is
  // sampled). A Depth32Float view of Depth32Float_Stencil8 is not a valid
  // texture-view reinterpretation, so no view is created here.
  id<MTLTexture> depth=scene_depth;
  const MTLPixelFormat depth_format=depth.pixelFormat;
  if(depth_format!=MTLPixelFormatDepth32Float&&depth_format!=MTLPixelFormatDepth32Float_Stencil8&&
     depth_format!=MTLPixelFormatDepth16Unorm)return;
  const bool multisampled=depth.textureType==MTLTextureType2DMultisample;
  if(!multisampled&&depth.textureType!=MTLTextureType2D)return;
  id<MTLRenderPipelineState> pipeline=multisampled?state.motion_ms:state.motion;
  if(!pipeline)return;
  MotionConstants k{};
  if(!Invert(camera.vp.data(),k.inv_vp))return;
  const Camera& prev=state.have_previous_camera?state.previous_camera:camera;
  std::memcpy(k.prev_vp,prev.vp.data(),64);
  k.size[0]=float(state.width);k.size[1]=float(state.height);
  k.sign=MotionSign();
  std::string error;
  const bool encoded=frame.EncodeExternal([&](id<MTLCommandBuffer> cb) {
    MTLRenderPassDescriptor* rp=[MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture=state.motion_texture;
    rp.colorAttachments[0].loadAction=MTLLoadActionDontCare;rp.colorAttachments[0].storeAction=MTLStoreActionStore;
    rp.depthAttachment.texture=state.depth_texture;
    rp.depthAttachment.loadAction=MTLLoadActionDontCare;rp.depthAttachment.storeAction=MTLStoreActionStore;
    auto e=[cb renderCommandEncoderWithDescriptor:rp];
    if(!theft4_retail_mode())e.label=@"Theft4 MetalFX FI motion+depth";
    [e setRenderPipelineState:pipeline];[e setDepthStencilState:state.depth_always];
    [e setFragmentTexture:depth atIndex:0];[e setFragmentBytes:&k length:sizeof k atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[e endEncoding];
  },error);
  if(!encoded)return;
  state.motion_ready=true;state.motion_camera_serial=camera.serial;
  ConfigureCamera(camera);
  state.previous_camera=camera;state.have_previous_camera=true;
}

bool Present(id<MTLCommandQueue> queue,CAMetalLayer* layer,id<MTLTexture> color,uint64_t commit_ns,std::string& error) {
  std::lock_guard lock(state_mutex);
  if(!state.interpolator||!queue||!layer||!color){error="Frame interpolation unavailable";return false;}
  if(!state.copy_drawable||state.drawable_format!=layer.pixelFormat) {
    id<MTLLibrary> library=state.library;
    state.copy_drawable=library?FIPipeline(library,@"theft4_fi_copy",layer.pixelFormat,MTLPixelFormatInvalid):nil;
    state.drawable_format=layer.pixelFormat;
    if(!state.copy_drawable){error="Frame interpolation drawable pipeline failed";return false;}
  }
  if(state.last_commit_ns&&commit_ns>state.last_commit_ns) {
    const double interval=double(commit_ns-state.last_commit_ns)/1e9;
    if(interval<0.25)state.interval_s=state.interval_s*0.8+interval*0.2;
  }
  state.last_commit_ns=commit_ns;
  // Presented-frame cap: the game runs at its 30 FPS limit, and with frame
  // generation on the cap applies to PRESENTED frames (generated + real =
  // 30/s), so every drawable is held at least 1/30 s. Drawable back-pressure
  // then paces the real frames to ~15/s.
  constexpr double kPresentedCapInterval=1.0/30.0;
  const double half=std::max(kPresentedCapInterval,std::clamp(state.interval_s*0.5,1.0/120.0,1.0/15.0));
  const uint32_t index=state.color_index;
  id<MTLTexture> current=state.colors[index];
  id<MTLTexture> previous=state.colors[(index+2)%3];
  const bool interpolate=state.have_previous&&state.motion_ready;
  const uint64_t sequence=++state.sequence;
  const bool perf=theft4_perf_enabled();
  id<MTLCommandBuffer> cb=[queue commandBuffer];
  if(!cb){error="Frame interpolation command buffer failed";return false;}
  CopyPass(cb,state.copy_rgba16,color,current);
  if(interpolate) {
    auto fi=state.interpolator;
    fi.colorTexture=current;fi.prevColorTexture=previous;
    fi.depthTexture=state.depth_texture;fi.motionTexture=state.motion_texture;
    fi.outputTexture=state.interpolated;
    fi.motionVectorScaleX=float(state.width);fi.motionVectorScaleY=float(state.height);
    fi.jitterOffsetX=0;fi.jitterOffsetY=0;  // no TAA jitter in this renderer
    fi.deltaTime=float(state.interval_s);
    // prevColorTexture must be the colorTexture of the previous encode; when
    // the previous real frame skipped interpolation, restart history.
    fi.shouldResetHistory=!state.encoded_last_frame;
    [fi encodeToCommandBuffer:cb];
    id<CAMetalDrawable> generated=[layer nextDrawable];
    if(generated) {
      CopyPass(cb,state.copy_drawable,state.interpolated,generated.texture);
      if(perf) {
        id<MTLCommandBuffer> owner=cb;
        [generated addPresentedHandler:^(id<MTLDrawable> shown) {
          theft4_perf_event p{};p.kind=THEFT4_PERF_EVENT_PRESENTED;p.sequence=uint64_t(shown.drawableID);
          p.gpu_end_ns=shown.presentedTime>0?uint64_t(shown.presentedTime*1e9):0;p.value=1;
          theft4_perf_record(&p);
          theft4_perf_event g{};g.kind=THEFT4_PERF_EVENT_INTERPOLATED;g.sequence=sequence;g.commit_ns=commit_ns;
          g.gpu_start_ns=uint64_t(owner.GPUStartTime*1e9);g.gpu_end_ns=uint64_t(owner.GPUEndTime*1e9);
          g.value=p.gpu_end_ns>commit_ns?p.gpu_end_ns-commit_ns:0;
          theft4_perf_record(&g);
        }];
      }
      [cb presentDrawable:generated afterMinimumDuration:half];
      theft4_perf_count_generated();
    }
  }
  [cb commit];
  // The real frame follows in its own command buffer and display slot.
  id<MTLCommandBuffer> real=[queue commandBuffer];
  id<CAMetalDrawable> drawable=real?[layer nextDrawable]:nil;
  if(drawable) {
    CopyPass(real,state.copy_drawable,current,drawable.texture);
    if(perf) [drawable addPresentedHandler:^(id<MTLDrawable> shown) {
      theft4_perf_event p{};p.kind=THEFT4_PERF_EVENT_PRESENTED;p.sequence=uint64_t(shown.drawableID);
      p.gpu_end_ns=shown.presentedTime>0?uint64_t(shown.presentedTime*1e9):0;p.value=0;
      theft4_perf_record(&p);
    }];
    [real presentDrawable:drawable afterMinimumDuration:interpolate?half:kPresentedCapInterval];
  }
  [real commit];
  state.have_previous=true;state.color_index=(index+1)%3;state.motion_ready=false;
  state.encoded_last_frame=interpolate;
  status.store(interpolate?1:-3);
  return true;
}
}  // namespace theft4::metal::fi
