# libde265 HEVC Decoder Thread Safety Analysis

## Executive Summary

libde265 is an open-source HEVC (H.265) decoder that supports multi-threaded decoding via Wavefront Parallel Processing (WPP) and tile-based parallelism. After thorough analysis of the source code (version from GitHub strukturag/libde265), the library has **partial thread safety** with the following key findings:

1. **Separate decoder contexts are thread-safe**: Multiple `de265_decoder_context` instances can be used concurrently in different threads without interference.

2. **A single decoder context is NOT thread-safe for concurrent API calls**: All API functions on a given decoder context must be called from a single thread (or with external synchronization).

3. **Internal multi-threading is well-implemented**: The library's internal thread pool for WPP/tile parallelism uses proper synchronization primitives.

4. **Global state issues exist**: Several global/static variables create potential race conditions during library initialization and in debug/logging code.

---

## Detailed Analysis

### 1. Library Initialization/Shutdown (de265_init/de265_free)

**Location**: `/libde265/de265.cc` (lines 191-240)

The library uses a reference-counted initialization pattern with proper mutex protection:

```cpp
static int de265_init_count;

static std::mutex& de265_init_mutex()
{
  static std::mutex de265_init_mutex;
  return de265_init_mutex;
}

LIBDE265_API de265_error de265_init()
{
  std::lock_guard<std::mutex> lock(de265_init_mutex());
  de265_init_count++;
  // ... initialization code
}
```

**Assessment**: The initialization is thread-safe. The use of a function-local static mutex with `std::lock_guard` ensures proper synchronization. The `de265_new_decoder()` function implicitly calls `de265_init()`, and `de265_free_decoder()` calls `de265_free()`.

**Issue**: None - this is correctly implemented.

---

### 2. Global Static Variables

#### 2.1 Scan Order Tables

**Location**: `/libde265/scan.cc` (lines 23-32, 92-100)

```cpp
static position scan0 = { 0,0 };
static position scan_h_1[ 2* 2], scan_v_1[ 2* 2], scan_d_1[ 2* 2];
// ... more static arrays
static position* scan_h[7] = { &scan0,scan_h_1,scan_h_2,scan_h_3,scan_h_4,scan_h_5 };
```

These tables are initialized once during `de265_init()` via `init_scan_orders()` and are read-only thereafter.

**Assessment**: Safe after initialization. The mutex in `de265_init()` ensures these are fully initialized before any decoder uses them.

#### 2.2 Context Index Lookup Table

**Location**: `/libde265/slice.cc` (line 1971)

```cpp
uint8_t* ctxIdxLookup[4][2][2][4];
```

This global array is allocated and initialized in `alloc_and_init_significant_coeff_ctxIdx_lookupTable()` called during `de265_init()` and freed in `free_significant_coeff_ctxIdx_lookupTable()` during `de265_free()`.

**Assessment**: Safe after initialization, protected by the init mutex.

#### 2.3 Logging Variables

**Location**: `/libde265/util.cc` (lines 43-51, 76, 235)

```cpp
static int current_poc=0;
static int log_poc_start=-9999;
static bool disable_log[NUMBER_OF_LogModules];
static int disable_logging_OLD=0;
static int verbosity = 0;
static long logcnt[10];
static void (*debug_image_output_func)(const struct de265_image*, int slot) = NULL;
```

**Issue - THREAD SAFETY CONCERN**: These variables are modified and read without synchronization:
- `de265_set_verbosity()` writes to `verbosity` without locking
- Logging functions read these variables without synchronization
- `debug_set_image_output()` sets a function pointer without synchronization

**Severity**: Low to Medium. In practice, logging configuration is typically set once at startup. However, calling `de265_set_verbosity()` while decoding is in progress could cause data races.

#### 2.4 CABAC Debug Counter

**Location**: `/libde265/cabac.cc` (lines 133, 736)

```cpp
#ifdef DE265_LOG_TRACE
int logcnt=1;
int encBinCnt=1;
#endif
```

**Issue**: These counters are incremented in decode/encode functions without synchronization when tracing is enabled.

**Severity**: Low. Only affects debug builds with trace logging enabled.

---

### 3. Decoder Context Safety

#### 3.1 Thread Pool Implementation

**Location**: `/libde265/threads.h` and `/libde265/threads.cc`

The thread pool uses proper C++11 synchronization:

```cpp
class thread_pool
{
public:
  bool stopped;
  std::deque<thread_task*> tasks;
  std::thread thread[MAX_THREADS];
  int num_threads;
  int num_threads_working;
  std::mutex  mutex;
  std::condition_variable  cond_var;
};
```

The worker threads properly lock the mutex before accessing shared state:

```cpp
static void worker_thread(thread_pool* pool)
{
  while(true) {
    thread_task* task = nullptr;
    {
      std::unique_lock<std::mutex> lock(pool->mutex);
      // ... wait and get task
    }
    task->work();
    std::unique_lock<std::mutex> lock(pool->mutex);
    pool->num_threads_working--;
  }
}
```

**Assessment**: The thread pool implementation is correct.

#### 3.2 Progress Locks for CTB Synchronization

**Location**: `/libde265/threads.h` (lines 49-68) and `/libde265/threads.cc`

```cpp
class de265_progress_lock
{
public:
  void wait_for_progress(int progress);
  void set_progress(int progress);
private:
  int mProgress;
  std::mutex mutex;
  std::condition_variable cond;
};
```

**Issue - POTENTIAL RACE CONDITION**: In `wait_for_progress()`:

```cpp
void de265_progress_lock::wait_for_progress(int progress)
{
  if (mProgress >= progress) {  // Read without lock!
    return;
  }
  std::unique_lock<std::mutex> lock(mutex);
  while (mProgress < progress) {
    cond.wait(lock);
  }
}
```

The initial check of `mProgress` is done without holding the mutex. While this is a common optimization pattern, it technically constitutes a data race since `mProgress` is not atomic. On x86 architectures this is generally safe due to strong memory ordering, but it's not portable.

**Severity**: Low. The pattern is commonly used and works correctly on x86/x64. The fallback path with proper locking ensures correctness even if the racy read gives a stale value.

---

### 4. NAL Parser Thread Safety

**Location**: `/libde265/nal-parser.cc` and `/libde265/nal-parser.h`

The NAL parser (`NAL_Parser` class) has no internal synchronization. It uses:
- `std::queue<NAL_unit*> NAL_queue`
- `std::vector<NAL_unit*> NAL_free_list`

**Issue**: The NAL parser is not thread-safe. Calling `push_data()` or `pop_from_NAL_queue()` concurrently would cause undefined behavior.

**Severity**: Medium. This is expected behavior - the decoder context should be used from a single thread. But it's undocumented.

---

### 5. Context Model Table Reference Counting

**Location**: `/libde265/contextmodel.cc` and `/libde265/contextmodel.h`

The `context_model_table` class uses manual reference counting:

```cpp
class context_model_table
{
private:
  context_model* model;
  int* refcnt;  // Plain int, not atomic!
};

context_model_table::context_model_table(const context_model_table& src)
{
  if (src.refcnt) {
    (*(src.refcnt))++;  // Non-atomic increment!
  }
  refcnt = src.refcnt;
  model  = src.model;
}
```

**Issue - THREAD SAFETY CONCERN**: The reference count is a plain `int*`, not `std::atomic<int>*`. If context model tables are copied across threads, reference count corruption could occur.

**Severity**: Medium. Within a single decoder context, this is used in the internal thread pool where worker threads have their own copies. Cross-decoder-context sharing is not typical usage.

---

### 6. Image ID Generation

**Location**: `/libde265/image.cc` (line 249)

```cpp
static std::atomic<uint32_t> s_next_image_ID(0);
ID = s_next_image_ID++;
```

**Assessment**: Correctly uses `std::atomic` for thread-safe ID generation across all decoder contexts.

---

### 7. Decoded Picture Buffer (DPB)

**Location**: `/libde265/dpb.cc` and `/libde265/dpb.h`

The DPB uses `std::vector` and `std::deque` containers without synchronization:

```cpp
class decoded_picture_buffer {
  std::vector<de265_image*> dpb;
  std::vector<de265_image*> reorder_output_queue;
  std::deque<de265_image*> image_output_queue;
};
```

**Assessment**: The DPB is not thread-safe for concurrent access. This is expected since it's part of the decoder context which should be accessed from a single thread.

---

## Thread Safety Guarantees and Warnings

### What IS Thread-Safe:

1. **Multiple independent decoders**: Creating multiple `de265_decoder_context` instances and using each from its own thread is safe.

2. **Library initialization**: `de265_init()` and `de265_free()` are thread-safe and can be called from any thread.

3. **Internal WPP/tile parallelism**: The library's internal multi-threading for decoding a single frame is properly synchronized.

4. **Image ID generation**: Unique image IDs are generated atomically across all decoders.

### What is NOT Thread-Safe:

1. **Single decoder context**: All API calls on a single `de265_decoder_context` must be serialized. Do not call `de265_push_data()` from one thread while calling `de265_decode()` from another.

2. **Logging configuration**: `de265_set_verbosity()` should not be called while decoding is in progress.

3. **Debug image output**: `debug_set_image_output()` is not thread-safe.

---

## Identified Thread Safety Issues

| Issue | Location | Severity | Type |
|-------|----------|----------|------|
| Non-atomic progress check | `threads.cc:wait_for_progress()` | Low | Data race (benign on x86) |
| Non-atomic reference counting | `contextmodel.cc` | Medium | Potential corruption |
| Unsynchronized logging globals | `util.cc` | Low | Data race |
| Unsynchronized debug counters | `cabac.cc` | Low | Data race (debug only) |

---

## Recommended Mitigations

### For Library Users:

1. **Use one thread per decoder context**: Create a separate `de265_decoder_context` for each decoding thread.

2. **Configure logging before decoding**: Call `de265_set_verbosity()` before creating any decoder contexts or after all decoders are destroyed.

3. **Initialize once**: Call `de265_init()` once at application startup from the main thread before creating any decoders.

4. **External synchronization if needed**: If you must share a decoder context across threads (not recommended), wrap all API calls with a mutex.

### For Library Maintainers (Potential Upstream Patches):

1. **Make progress lock check atomic**:
   ```cpp
   std::atomic<int> mProgress;  // Instead of int mProgress
   ```

2. **Use atomic reference counting**:
   ```cpp
   std::atomic<int>* refcnt;  // Instead of int* refcnt
   ```

3. **Document thread safety guarantees**: Add explicit documentation to `de265.h` about thread safety expectations.

4. **Protect logging configuration**:
   ```cpp
   static std::atomic<int> verbosity{0};
   ```

---

## Whether Upstream Patches Are Needed

**Priority: Low to Medium**

The current implementation is safe for the most common use cases:
- One decoder per thread (fully safe)
- Single-threaded applications (fully safe)
- Multi-threaded decoding within a single decoder (fully safe)

Upstream patches would be beneficial for:
1. Improved documentation of thread safety guarantees
2. Fixing the non-atomic reference counting in `context_model_table` for edge cases
3. Making `de265_progress_lock::mProgress` atomic for strict C++ compliance

The existing codebase has already addressed major threading issues (see commit `42ce2b73` "fix multithreading race conditions"). The remaining issues are minor and do not affect typical usage patterns.

---

## References

- Source repository: https://github.com/strukturag/libde265
- Analyzed version: Latest main branch (cloned 2026-01-29)
- Key files analyzed:
  - `/libde265/de265.cc` - Main API implementation
  - `/libde265/de265.h` - Public API header
  - `/libde265/threads.cc` / `threads.h` - Thread pool and synchronization
  - `/libde265/decctx.cc` / `decctx.h` - Decoder context
  - `/libde265/contextmodel.cc` / `contextmodel.h` - CABAC context models
  - `/libde265/nal-parser.cc` / `nal-parser.h` - NAL parsing
  - `/libde265/scan.cc` - Global scan order tables
  - `/libde265/util.cc` - Logging utilities
  - `/libde265/image.cc` - Image allocation
  - `/libde265/dpb.cc` - Decoded picture buffer
