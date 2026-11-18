#pragma once
// Theft4-MetalFX: per-frame renderer statistics for Long Performance Capture.
// Producers (direct Metal renderer / Metal completion + presented handlers)
// push events into a bounded ring only while capture is enabled; the app
// drains it on its capture queue and writes CSV + JSON next to the existing
// publication-trace/renderer-timing captures. All times are host uptime
// nanoseconds (same clock base as CACurrentMediaTime / mach_absolute_time).
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
  THEFT4_PERF_EVENT_FRAME = 1,      // a direct-Metal command buffer completed
  THEFT4_PERF_EVENT_PRESENTED = 2,  // a drawable reached the display (or was dropped)
  THEFT4_PERF_EVENT_SLOT_TIMEOUT = 3,  // BeginFrame waited 50 ms and gave up
  THEFT4_PERF_EVENT_INTERPOLATED = 4   // MetalFX frame interpolator produced a frame
};

typedef struct theft4_perf_event {
  uint64_t kind;
  uint64_t sequence;       // frame sequence (FRAME/PRESENTED) or drawable id
  uint64_t commit_ns;      // FRAME: CPU time of commit; PRESENTED: 0
  uint64_t slot_wait_ns;   // FRAME/SLOT_TIMEOUT: time blocked in Renderer::BeginFrame
  uint64_t cpu_prepare_ns; // FRAME: adapter submit start -> commit (render thread)
  uint64_t cpu_encode_ns;  // FRAME: BeginFrame return -> commit
  uint64_t gpu_start_ns;   // FRAME: MTLCommandBuffer GPUStartTime
  uint64_t gpu_end_ns;     // FRAME: GPUEndTime; PRESENTED: presentedTime (0 = dropped)
  uint64_t value;          // FRAME: 1 if the frame presented a drawable; INTERPOLATED: latency ns
} theft4_perf_event;

uint64_t theft4_perf_now_ns(void);
// Capture control (main thread). Start returns the read cursor.
uint64_t theft4_perf_start(void);
void theft4_perf_stop(void);
bool theft4_perf_enabled(void);
// Producers.
void theft4_perf_record(const theft4_perf_event* event);
void theft4_perf_mark_submit_begin(void);   // render thread, start of frame submission
uint64_t theft4_perf_take_submit_begin(void); // render thread, consumed once per frame
// Consumer (capture queue). Returns copied count; *lost counts overwritten events.
uint32_t theft4_perf_read(uint64_t* cursor, theft4_perf_event* out, uint32_t capacity, uint64_t* lost);
uint64_t theft4_perf_slot_timeouts(void);

// City density state (theft4_motion_blur.cpp): configured scales, state
// (0 pending, 1 active, -1 disabled or stock) and the last value written into
// each guest multiplier (random cars, parked cars, peds, scenario cur/next),
// -1 when not written yet.
int theft4_city_density_snapshot(double* traffic, double* peds, float* values5);

#ifdef __cplusplus
}
#endif
