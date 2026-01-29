# OpenJPEG Thread Safety Analysis

**Library Version:** 2.5.4
**Analysis Date:** 2026-01-29
**Analyzed Source:** https://github.com/uclouvain/openjpeg (tag v2.5.4)

## Executive Summary

OpenJPEG provides **internal multi-threading support** for accelerating encode/decode operations within a single codec context. However, the library has **no explicit thread safety guarantees** for concurrent use of **multiple codec instances** from different threads.

**Key Findings:**

1. **Each codec instance (opj_codec_t) should be used from a single thread at a time** - the library does not protect codec contexts with internal locks
2. **Multiple independent codec instances CAN be used concurrently** from different threads, with certain caveats around global/static state
3. The library contains **global static state on Windows** that has a potential race condition during initialization
4. Look-up tables are **read-only after initialization** and thus thread-safe
5. Thread pools are **contained within codec instances**, avoiding cross-instance contention

**Risk Assessment:** MEDIUM - Safe for common use cases with proper application-level synchronization.

---

## Detailed Analysis

### 1. Global Variables and Static State

#### 1.1 Windows TLS Key Initialization (CRITICAL)

**Location:** `/src/lib/openjp2/thread.c`, lines 109-111

```c
static DWORD TLSKey = 0;
static volatile LONG inTLSLockedSection = 0;
static volatile int TLSKeyInit = OPJ_FALSE;
```

**Issue:** On Windows, the TLS (Thread-Local Storage) key is allocated lazily during the first call to `opj_cond_create()`. The initialization uses a spin-lock pattern with `InterlockedCompareExchange` to protect the allocation:

```c
while (OPJ_TRUE) {
#if HAVE_INTERLOCKED_COMPARE_EXCHANGE
    if (InterlockedCompareExchange(&inTLSLockedSection, 1, 0) == 0)
#endif
    {
        if (!TLSKeyInit) {
            TLSKey = TlsAlloc();
            TLSKeyInit = OPJ_TRUE;
        }
#if HAVE_INTERLOCKED_COMPARE_EXCHANGE
        InterlockedCompareExchange(&inTLSLockedSection, 0, 1);
#endif
        break;
    }
}
```

**Concerns:**
- On MinGW 32-bit builds, `HAVE_INTERLOCKED_COMPARE_EXCHANGE` is undefined, removing the atomic protection entirely
- The spin-lock is a busy-wait, though the window is small
- This is only triggered when thread support is enabled and conditions are used

**Severity:** LOW-MEDIUM on Windows, negligible on POSIX systems

**Mitigation:** Ensure the first codec creation happens from a single thread, or pre-warm the library by creating a dummy codec/condition before multi-threaded usage.

#### 1.2 VLC Tables Initialization Flag

**Location:** `/src/lib/openjp2/t1_ht_generate_luts.c`, line 970

```c
OPJ_BOOL vlc_tables_initialized = OPJ_FALSE;
```

**Assessment:** This is part of the LUT generation tool (`t1_ht_generate_luts.c`), NOT the runtime library. The actual VLC tables used at runtime (`t1_ht_luts.h`) are statically initialized `const` arrays - they are **read-only and thread-safe**.

**Severity:** NONE (not used at runtime)

#### 1.3 Look-Up Tables (LUTs)

**Location:** `/src/lib/openjp2/t1_luts.h`, `/src/lib/openjp2/t1_ht_luts.h`

All LUTs are declared as `static const`:
- `lut_ctxno_zc[2048]`
- `lut_ctxno_sc[256]`
- `lut_spb[256]`
- `lut_nmsedec_sig[]`
- `lut_nmsedec_ref[]`
- `vlc_tbl0[1024]`
- `vlc_tbl1[1024]`

**Assessment:** These are compile-time constants, read-only at runtime. **Fully thread-safe**.

---

### 2. Thread-Local Storage (TLS) Usage

OpenJPEG uses a custom TLS implementation for storing per-worker-thread data within thread pools.

**Location:** `/src/lib/openjp2/thread.c`, `/src/lib/openjp2/thread.h`, `/src/lib/openjp2/tls_keys.h`

```c
#define OPJ_TLS_KEY_T1  0  // Key for T1 decoder context
```

**Usage Pattern:**
- Each worker thread in a thread pool has its own `opj_tls_t` structure
- The T1 tier-1 decoder caches its context in TLS to avoid repeated allocation/deallocation:

```c
// In t1.c
t1 = (opj_t1_t*) opj_tls_get(tls, OPJ_TLS_KEY_T1);
if (t1 == NULL) {
    t1 = opj_t1_create(OPJ_FALSE);
    opj_tls_set(tls, OPJ_TLS_KEY_T1, t1, opj_t1_destroy_wrapper);
}
```

**Assessment:** This TLS is **per-thread-pool**, not global. Each codec has its own thread pool, so TLS contexts are isolated between codec instances. **Thread-safe within the intended usage model**.

---

### 3. Mutex and Lock Usage

#### 3.1 Thread Pool Implementation

**Location:** `/src/lib/openjp2/thread.c`

The thread pool uses proper synchronization:

```c
struct opj_thread_pool_t {
    opj_worker_thread_t*             worker_threads;
    int                              worker_threads_count;
    opj_cond_t*                      cond;
    opj_mutex_t*                     mutex;
    volatile opj_worker_thread_state state;
    opj_job_list_t*                  job_queue;
    volatile int                     pending_jobs_count;
    opj_worker_thread_list_t*        waiting_worker_thread_list;
    int                              waiting_worker_thread_count;
    opj_tls_t*                       tls;
    int                              signaling_threshold;
};
```

**Key mutex-protected operations:**
- Job submission (`opj_thread_pool_submit_job`)
- Job retrieval (`opj_thread_pool_get_next_job`)
- Wait for completion (`opj_thread_pool_wait_completion`)
- Pool destruction (`opj_thread_pool_destroy`)

**Assessment:** The internal thread pool is **well-synchronized** and correctly handles producer-consumer patterns.

#### 3.2 Platform-Specific Mutex Implementation

**POSIX (pthread):**
```c
struct opj_mutex_t {
    pthread_mutex_t mutex;
};
```

**Windows:**
```c
struct opj_mutex_t {
    CRITICAL_SECTION cs;
};
```

**Assessment:** Standard, correct implementations. **Thread-safe**.

---

### 4. Decoder/Encoder Context Safety

#### 4.1 Codec Structure

**Location:** `/src/lib/openjp2/opj_codec.h`

```c
typedef struct opj_codec_private {
    union {
        struct opj_decompression { ... } m_decompression;
        struct opj_compression { ... } m_compression;
    } m_codec_data;
    void * m_codec;           // J2K or JP2 specific context
    opj_event_mgr_t m_event_mgr;
    OPJ_BOOL is_decompressor;
    // Function pointers...
} opj_codec_private_t;
```

**Location:** `/src/lib/openjp2/j2k.h` (partial)

```c
struct opj_j2k {
    // ... many fields ...
    struct opj_tcd *    m_tcd;
    opj_thread_pool_t* m_tp;  // Per-codec thread pool
    // ...
};
```

**Key Observation:** Each codec instance contains:
- Its own thread pool (`m_tp`)
- Its own tile coder/decoder (`m_tcd`)
- Its own event manager
- All state needed for encode/decode operations

**Assessment:** Codec instances are **fully independent** - they do not share any mutable state. Multiple codecs can operate concurrently from different threads.

#### 4.2 API Usage Constraints

From `openjpeg.h` documentation:

```c
/**
 * This function must be called after opj_setup_decoder() and
 * before opj_read_header() for the decoding side, or after opj_setup_encoder()
 * and before opj_start_compress() for the encoding side.
 */
OPJ_API OPJ_BOOL OPJ_CALLCONV opj_codec_set_threads(opj_codec_t *p_codec,
        int num_threads);
```

**Important:** Thread configuration must be done during setup, before processing begins. The thread pool cannot be safely reconfigured during operation.

---

### 5. Parallel Processing Implementation

#### 5.1 Multi-Threaded Decoding/Encoding

OpenJPEG parallelizes operations within a single codec:

**DWT (Discrete Wavelet Transform):**
- Horizontal and vertical passes run in parallel across rows/columns
- Jobs submitted via `opj_thread_pool_submit_job()`
- Synchronization via `opj_thread_pool_wait_completion()`

**Tier-1 (T1) Coding:**
- Code-block processing parallelized
- Each thread uses TLS-cached T1 context
- Results aggregated with mutex protection

**Locations:**
- `/src/lib/openjp2/dwt.c` - DWT parallelization
- `/src/lib/openjp2/t1.c` - T1 encoding/decoding parallelization

**Assessment:** Internal parallelization is **well-implemented** with proper synchronization.

---

### 6. Memory Allocation

**Location:** `/src/lib/openjp2/opj_malloc.c`

OpenJPEG uses wrappers around standard allocation functions:
- `opj_malloc()` - standard malloc
- `opj_calloc()` - standard calloc
- `opj_aligned_malloc()` - POSIX memalign / Windows _aligned_malloc
- `opj_free()` - standard free

**Assessment:** These are **stateless wrappers** - thread safety depends on the underlying allocator (typically thread-safe on modern systems).

---

## Identified Thread Safety Issues

### Issue 1: Windows TLS Lazy Initialization Race

**Severity:** LOW-MEDIUM
**Platforms Affected:** Windows (especially MinGW 32-bit)
**Code Location:** `/src/lib/openjp2/thread.c`, lines 123-138

**Description:** The Windows implementation uses a spin-lock pattern for lazy TLS key allocation that may have a race condition on certain builds.

**Impact:** Potential double-allocation of TLS key if two threads create conditions simultaneously before the library is initialized.

**Recommended Mitigation:**
```c
// Application code: initialize before multi-threaded use
void initialize_openjpeg_once() {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, []() {
        opj_codec_t* dummy = opj_create_decompress(OPJ_CODEC_J2K);
        if (dummy) opj_destroy_codec(dummy);
    });
}
```

### Issue 2: No API-Level Thread Safety Documentation

**Severity:** LOW
**Impact:** Users may incorrectly assume thread safety

**Description:** The public API (`openjpeg.h`) does not explicitly document thread safety guarantees.

**Recommendation:** Add documentation clarifying:
- Each codec instance must be used from one thread at a time
- Multiple codec instances can be used concurrently
- Thread pool configuration must happen before processing

---

## Recommendations

### For Application Developers

1. **DO NOT** share a single `opj_codec_t` instance between threads without external synchronization

2. **DO** create separate codec instances for each thread that needs JPEG 2000 processing:
   ```c
   // Thread 1
   opj_codec_t* codec1 = opj_create_decompress(OPJ_CODEC_JP2);
   // ... use codec1 ...
   opj_destroy_codec(codec1);

   // Thread 2 (concurrent)
   opj_codec_t* codec2 = opj_create_decompress(OPJ_CODEC_JP2);
   // ... use codec2 ...
   opj_destroy_codec(codec2);
   ```

3. **DO** configure threading during setup:
   ```c
   opj_codec_t* codec = opj_create_decompress(OPJ_CODEC_JP2);
   opj_setup_decoder(codec, &parameters);
   opj_codec_set_threads(codec, num_threads);  // Before read_header!
   opj_read_header(stream, codec, &image);
   opj_decode(codec, stream, image);
   ```

4. **CONSIDER** initializing the library from the main thread before spawning worker threads (especially on Windows)

5. **DO NOT** call `opj_codec_set_threads()` during active processing

### For Upstream Patches

1. **Windows TLS initialization** could be improved with proper atomic operations or a static initializer pattern

2. **API documentation** should explicitly state thread safety guarantees

3. **Consider** adding `OPJ_THREADSAFE` compile-time option that adds per-codec mutexes for applications that want to share codecs (at performance cost)

---

## Conclusion

OpenJPEG v2.5.4 is **safe for multi-threaded applications** when used correctly:

- Create separate codec instances per thread or protect shared codecs with application-level locks
- The library's internal multi-threading (for DWT/T1 acceleration) is properly synchronized
- Global/static state is minimal and read-only at runtime (except Windows TLS initialization)

**No upstream patches are strictly required** for safe multi-threaded operation, provided applications follow the documented usage pattern. The Windows TLS initialization issue is a minor concern that could be improved but is unlikely to cause problems in practice.

---

## References

- OpenJPEG GitHub: https://github.com/uclouvain/openjpeg
- Version analyzed: v2.5.4
- Key source files:
  - `/src/lib/openjp2/thread.c` - Threading primitives
  - `/src/lib/openjp2/thread.h` - Thread API
  - `/src/lib/openjp2/openjpeg.c` - Public API implementation
  - `/src/lib/openjp2/opj_codec.h` - Codec structures
  - `/src/lib/openjp2/t1.c` - Tier-1 coding with TLS
  - `/src/lib/openjp2/dwt.c` - DWT with thread pool
