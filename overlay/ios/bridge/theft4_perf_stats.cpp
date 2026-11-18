#include "theft4_perf_stats.h"

#include <atomic>
#include <os/lock.h>
#include <time.h>

namespace {
constexpr uint64_t kCapacity = 32768;  // ~9 min at 60 events/s, bounded RAM
theft4_perf_event ring[kCapacity];
uint64_t head = 0;  // protected by lock
os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
std::atomic<bool> enabled{false};
std::atomic<uint64_t> timeouts{0};
thread_local uint64_t submit_begin_ns = 0;
std::atomic<uint64_t> rendered_total{0};
std::atomic<uint64_t> generated_total{0};
}  // namespace

uint64_t theft4_perf_now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

uint64_t theft4_perf_start(void) {
  os_unfair_lock_lock(&lock);
  const uint64_t cursor = head;
  os_unfair_lock_unlock(&lock);
  timeouts.store(0, std::memory_order_relaxed);
  enabled.store(true, std::memory_order_release);
  return cursor;
}
void theft4_perf_stop(void) { enabled.store(false, std::memory_order_release); }
bool theft4_perf_enabled(void) { return enabled.load(std::memory_order_relaxed); }

void theft4_perf_record(const theft4_perf_event* event) {
  if (!event || !enabled.load(std::memory_order_relaxed)) return;
  if (event->kind == THEFT4_PERF_EVENT_SLOT_TIMEOUT) timeouts.fetch_add(1, std::memory_order_relaxed);
  os_unfair_lock_lock(&lock);
  ring[head % kCapacity] = *event;
  ++head;
  os_unfair_lock_unlock(&lock);
}

void theft4_perf_mark_submit_begin(void) {
  submit_begin_ns = enabled.load(std::memory_order_relaxed) ? theft4_perf_now_ns() : 0;
}
uint64_t theft4_perf_take_submit_begin(void) {
  const uint64_t value = submit_begin_ns;
  submit_begin_ns = 0;
  return value;
}

uint32_t theft4_perf_read(uint64_t* cursor, theft4_perf_event* out, uint32_t capacity, uint64_t* lost) {
  if (!cursor || !out || !capacity) return 0;
  if (lost) *lost = 0;
  os_unfair_lock_lock(&lock);
  if (head > *cursor + kCapacity) {
    if (lost) *lost = head - kCapacity - *cursor;
    *cursor = head - kCapacity;
  }
  uint32_t count = 0;
  while (*cursor < head && count < capacity) out[count++] = ring[(*cursor)++ % kCapacity];
  os_unfair_lock_unlock(&lock);
  return count;
}
uint64_t theft4_perf_slot_timeouts(void) { return timeouts.load(std::memory_order_relaxed); }

void theft4_perf_count_rendered(void) { rendered_total.fetch_add(1, std::memory_order_relaxed); }
void theft4_perf_count_generated(void) { generated_total.fetch_add(1, std::memory_order_relaxed); }
uint64_t theft4_perf_rendered_total(void) { return rendered_total.load(std::memory_order_relaxed); }
uint64_t theft4_perf_generated_total(void) { return generated_total.load(std::memory_order_relaxed); }
