# libwebp Thread Safety Analysis

**Analysis Date:** 2026-01-29
**Library Version:** 1.6.0
**Source:** https://chromium.googlesource.com/webm/libwebp

## Executive Summary

libwebp is **conditionally thread-safe** for concurrent decoding operations when used correctly. The library employs a careful initialization pattern using mutex-protected lazy initialization and thread-sanitizer-aware annotations. However, there are several important considerations:

1. **Global Function Pointer Tables**: The library uses global function pointer arrays for DSP dispatch that are lazily initialized on first use. This initialization is protected by mutexes (when `WEBP_USE_THREAD` is defined) but represents shared mutable state.

2. **First-Call Initialization Race Window**: There exists a theoretical race condition during the very first decode call in a process if multiple threads call decoding functions simultaneously before initialization completes.

3. **Decoder Instances Are NOT Shared**: Each decoder instance (`WebPIDecoder`, `VP8Decoder`) must only be used by a single thread at a time. Multiple threads CAN decode different images concurrently using separate decoder instances.

4. **Worker Interface is Global**: `WebPSetWorkerInterface()` modifies global state and is explicitly documented as NOT thread-safe.

**Overall Assessment:** Safe for concurrent use with separate decoder instances after library initialization. A one-time initialization call before spawning threads is recommended for maximum safety.

---

## Identified Thread Safety Issues

### 1. Global DSP Function Pointer Tables

**Severity:** Low (mitigated by library design)
**Risk:** Potential data race during first initialization

**Location:** Multiple files including:
- `/deps/libwebp-src/src/dsp/dec.c` (lines 724-745, 754-897)
- `/deps/libwebp-src/src/dsp/lossless.c` (lines 579-648)
- `/deps/libwebp-src/src/dsp/yuv.c` (lines 88, 611-638)
- `/deps/libwebp-src/src/dec/vp8_dec.c` (line 49)

**Details:**

The library maintains numerous global function pointer arrays that are initialized lazily:

```c
// From src/dsp/dec.c
VP8DecIdct2 VP8Transform;
VP8DecIdct VP8TransformAC3;
VP8DecIdct VP8TransformUV;
VP8DecIdct VP8TransformDC;
// ... many more

VP8PredFunc VP8PredLuma16[NUM_B_DC_MODES];
VP8PredFunc VP8PredChroma8[NUM_B_DC_MODES];
VP8PredFunc VP8PredLuma4[NUM_BMODES];
```

```c
// From src/dec/vp8_dec.c line 49
static volatile GetCoeffsFunc GetCoeffs = NULL;
```

**Mitigation in Library:**

The library uses the `WEBP_DSP_INIT_FUNC` macro pattern which provides mutex-protected initialization:

```c
// From src/dsp/cpu.h lines 212-267
#if defined(WEBP_USE_THREAD)
#define WEBP_DSP_INIT_VARS(func)               \
  static VP8CPUInfo func##_last_cpuinfo_used = \
      (VP8CPUInfo)&func##_last_cpuinfo_used;   \
  static pthread_mutex_t func##_lock = PTHREAD_MUTEX_INITIALIZER
#define WEBP_DSP_INIT(func)                                \
  do {                                                     \
    if (pthread_mutex_lock(&func##_lock)) break;           \
    if (func##_last_cpuinfo_used != VP8GetCPUInfo) func(); \
    func##_last_cpuinfo_used = VP8GetCPUInfo;              \
    (void)pthread_mutex_unlock(&func##_lock);              \
  } while (0)
```

Each initialization function:
1. Acquires a static mutex
2. Checks if already initialized (using `func##_last_cpuinfo_used` sentinel)
3. Performs initialization if needed
4. Releases mutex

Additionally, functions are marked with `WEBP_TSAN_IGNORE_FUNCTION` to suppress Thread Sanitizer warnings for known-benign concurrent writes:

```c
// From src/dsp/cpu.h lines 188-195
#define WEBP_TSAN_IGNORE_FUNCTION
#if defined(__has_feature)
#if __has_feature(thread_sanitizer)
#undef WEBP_TSAN_IGNORE_FUNCTION
#define WEBP_TSAN_IGNORE_FUNCTION __attribute__((no_sanitize_thread))
#endif
#endif
```

---

### 2. Global Worker Interface

**Severity:** Medium
**Risk:** Race condition if called concurrently with encoding/decoding

**Location:** `/deps/libwebp-src/src/utils/thread_utils.c` (lines 291-307)

**Details:**

```c
static WebPWorkerInterface g_worker_interface = {Init, Reset, Sync,
                                                 Launch, Execute, End};

int WebPSetWorkerInterface(const WebPWorkerInterface* const winterface) {
  if (winterface == NULL || winterface->Init == NULL ||
      winterface->Reset == NULL || winterface->Sync == NULL ||
      winterface->Launch == NULL || winterface->Execute == NULL ||
      winterface->End == NULL) {
    return 0;
  }
  g_worker_interface = *winterface;  // Non-atomic struct copy!
  return 1;
}

const WebPWorkerInterface* WebPGetWorkerInterface(void) {
  return &g_worker_interface;
}
```

**Header Documentation (thread_utils.h line 79):**
```c
// This function is not thread-safe.
```

**Risk:** If `WebPSetWorkerInterface()` is called while decoding operations are in progress, partial reads of the interface struct could occur, leading to calling invalid function pointers.

---

### 3. Global CPU Info Function Pointer

**Severity:** Low
**Risk:** Inconsistent CPU feature detection if modified at runtime

**Location:** `/deps/libwebp-src/src/dsp/cpu.c` (lines 169-251)

**Details:**

```c
WEBP_EXTERN VP8CPUInfo VP8GetCPUInfo;
VP8CPUInfo VP8GetCPUInfo = x86CPUInfo;  // or other platform-specific default
```

This global function pointer can be modified by applications to disable CPU features (e.g., setting to NULL disables SIMD). However, the DSP initialization checks are designed to handle this:

```c
if (func##_last_cpuinfo_used != VP8GetCPUInfo) func();
```

If `VP8GetCPUInfo` changes between calls, re-initialization will occur (mutex-protected).

---

### 4. Clip Tables Initialization

**Severity:** Low (mostly mitigated)
**Risk:** Race during first initialization if `USE_STATIC_TABLES=0`

**Location:** `/deps/libwebp-src/src/dsp/dec_clip_tables.c` (lines 311-346)

**Details:**

When `USE_STATIC_TABLES` is 0 (non-default), tables are initialized at runtime:

```c
#if (USE_STATIC_TABLES == 0)
static uint8_t abs0[255 + 255 + 1];
static int8_t sclip1[893 + 892 + 1];
static int8_t sclip2[112 + 112 + 1];
static uint8_t clip1[255 + 511 + 1];

static volatile int tables_ok = 0;

WEBP_TSAN_IGNORE_FUNCTION void VP8InitClipTables(void) {
  int i;
  if (!tables_ok) {
    // ... table initialization ...
    tables_ok = 1;
  }
}
#endif
```

**Mitigation:**
- Default build uses `USE_STATIC_TABLES=1` with pre-computed tables
- Uses `volatile` flag and `WEBP_TSAN_IGNORE_FUNCTION`
- Initialization is idempotent (same values written)

---

### 5. Gamma Tables Initialization

**Severity:** Low
**Risk:** Race during first initialization

**Location:** `/deps/libwebp-src/src/dsp/yuv.c` (lines 232-251)

**Details:**

```c
static int kLinearToGammaTab[GAMMA_TAB_SIZE + 1];
static uint16_t kGammaToLinearTab[256];
static volatile int kGammaTablesOk = 0;

WEBP_DSP_INIT_FUNC(WebPInitGammaTables) {
  if (!kGammaTablesOk) {
    // ... compute tables ...
    kGammaTablesOk = 1;
  }
}
```

Uses `WEBP_DSP_INIT_FUNC` pattern for mutex-protected initialization.

---

### 6. Debug Memory Tracking (Non-Production)

**Severity:** N/A (debug-only code)
**Risk:** Complete lack of thread safety in debug memory tracking

**Location:** `/deps/libwebp-src/src/utils/utils.c` (lines 61-79)

**Details:**

When `PRINT_MEM_INFO` is defined (debug builds only):

```c
static int num_malloc_calls = 0;
static int num_calloc_calls = 0;
static int num_free_calls = 0;
static int countdown_to_fail = 0;
static MemBlock* all_blocks = NULL;
static size_t total_mem = 0;
static size_t total_mem_allocated = 0;
static size_t high_water_mark = 0;
static size_t mem_limit = 0;
static int exit_registered = 0;
```

Comment in source (lines 28-29):
```c
// ... For debugging/tuning purpose only (it's slow,
// and not multi-thread safe!).
```

This is explicitly documented as not thread-safe and only for debugging.

---

## Decoder State Management

### Per-Instance State (Thread-Safe Pattern)

Each decode operation should use its own decoder instance:

```c
// VP8Decoder allocation (vp8_dec.c line 71-81)
VP8Decoder* VP8New(void) {
  VP8Decoder* const dec = (VP8Decoder*)WebPSafeCalloc(1ULL, sizeof(*dec));
  if (dec != NULL) {
    SetOk(dec);
    WebPGetWorkerInterface()->Init(&dec->worker);
    dec->ready = 0;
    dec->num_parts_minus_one = 0;
    InitGetCoeffs();  // Triggers DSP init if needed
  }
  return dec;
}
```

The `VP8Decoder` struct contains all state needed for decoding a single image. Multiple threads can safely decode different images using separate decoder instances.

### Worker Thread Support

The library has built-in multi-threading support for decoding:

```c
// From thread_utils.h
typedef struct {
  void* impl;  // platform-dependent implementation worker details
  WebPWorkerStatus status;
  WebPWorkerHook hook;
  void* data1;
  void* data2;
  int had_error;
} WebPWorker;
```

The worker implementation uses proper synchronization primitives (mutex + condition variable):

```c
// From thread_utils.c (POSIX path)
typedef struct {
  pthread_mutex_t mutex;
  pthread_cond_t condition;
  pthread_t thread;
} WebPWorkerImpl;
```

---

## Code Locations Summary

| Issue | File | Lines | Severity |
|-------|------|-------|----------|
| DSP function pointer tables | `src/dsp/dec.c` | 724-897 | Low |
| DSP function pointer tables | `src/dsp/lossless.c` | 579-648 | Low |
| DSP function pointer tables | `src/dsp/yuv.c` | 88, 611-638 | Low |
| GetCoeffs function pointer | `src/dec/vp8_dec.c` | 49 | Low |
| Global worker interface | `src/utils/thread_utils.c` | 291-307 | Medium |
| VP8GetCPUInfo global | `src/dsp/cpu.c` | 169-251 | Low |
| Clip tables (if dynamic) | `src/dsp/dec_clip_tables.c` | 311-346 | Low |
| Gamma tables | `src/dsp/yuv.c` | 232-251 | Low |
| Debug memory tracking | `src/utils/utils.c` | 61-79 | N/A |

---

## Recommended Mitigations

### For Library Users

1. **Call a decode function once before spawning threads:**
   ```c
   // In main thread before creating worker threads:
   WebPDecoderConfig config;
   WebPInitDecoderConfig(&config);
   // This triggers all DSP initialization
   ```

2. **Never call `WebPSetWorkerInterface()` after starting parallel decodes:**
   The documentation explicitly states this function is not thread-safe.

3. **Use separate decoder instances per thread:**
   ```c
   // Each thread should create its own decoder
   WebPIDecoder* idec = WebPINewDecoder(&output_buffer);
   // ... use idec ...
   WebPIDelete(idec);
   ```

4. **Avoid modifying `VP8GetCPUInfo` at runtime:**
   If CPU feature control is needed, set it once before any decode operations.

### For the validate Project

When using libwebp in multi-threaded validation:

```c
// Recommended initialization in main() or module init:
void init_webp_thread_safe(void) {
    // Force DSP initialization by doing a minimal decode setup
    WebPDecoderConfig config;
    if (WebPInitDecoderConfig(&config)) {
        // Config initialization triggers DSP init
        // No actual decode needed
    }
}
```

---

## Whether Upstream Patches Are Needed

**No upstream patches are required** for normal multi-threaded use cases.

The libwebp library has been carefully designed with thread safety in mind:

1. The `WEBP_DSP_INIT_FUNC` macro pattern provides proper mutex protection for initialization
2. Thread sanitizer annotations (`WEBP_TSAN_IGNORE_FUNCTION`) are used appropriately
3. The library explicitly documents which functions are not thread-safe
4. Per-instance state isolation allows safe concurrent decoding

**Potential Improvements (optional):**

1. **Explicit initialization API:** An explicit `WebPInit()` function that users could call to force all lazy initialization would eliminate any theoretical first-call races. However, this would be a minor API addition, not a bug fix.

2. **Atomic operations for sentinel flags:** Using C11 atomics for initialization flags like `tables_ok` and `kGammaTablesOk` would be more formally correct, though the current `volatile` + TSAN annotation approach works in practice.

---

## Conclusion

libwebp is safe for concurrent use in multi-threaded applications when:
- Each thread uses its own decoder instance
- `WebPSetWorkerInterface()` is not called during active decode operations
- (Recommended) A single decode operation is performed before spawning threads to ensure initialization

The library's thread safety mechanisms are well-designed and appropriate for production use.
