# libvpx Thread Safety Analysis

## Executive Summary

libvpx (VP8/VP9 codec library) provides **partial thread safety** with important caveats. The library is designed for internal multi-threaded decoding/encoding but requires external synchronization when:

1. Multiple codec instances are initialized concurrently from different threads
2. The worker interface is modified globally
3. Debug/mismatch utilities are used (debug builds only)

**Key Finding**: When built with `--enable-multithread` (the default), codec initialization (`vpx_codec_dec_init`, `vpx_codec_enc_init`) is thread-safe due to proper use of `pthread_once`. However, when built with `--disable-multithread`, initialization is explicitly **not thread-safe** as documented in the public headers.

Each codec context (`vpx_codec_ctx_t`) is independent and can be used from a single thread without external locks after initialization. Multiple contexts can decode/encode in parallel from different threads.

## Thread Safety Model

### Safe Operations (After Initialization)

- **Independent codec instances**: Each `vpx_codec_ctx_t` instance is self-contained
- **Parallel decoding**: Multiple decoder instances can process different streams concurrently
- **Internal threading**: VP8/VP9 decoders support multi-threaded decoding within a single instance (controlled by `cfg.threads`)
- **Frame retrieval**: `vpx_codec_get_frame()` is safe when called from the same thread that owns the context

### Unsafe Operations Requiring External Synchronization

1. **Concurrent initialization** (when `--disable-multithread`): Requires a mutex
2. **Sharing a codec context between threads**: Never safe
3. **Global worker interface modification**: `vpx_set_worker_interface()` is not thread-safe
4. **Debug utilities**: Static global state in debug builds

## Detailed Analysis

### 1. Global Variables and Static State

#### 1.1 Worker Interface (`vpx_util/vpx_thread.c`)

**Location**: `/vpx_util/vpx_thread.c:204`

```c
static VPxWorkerInterface g_worker_interface = { init,   reset,   sync,
                                                 launch, execute, end };
```

**Risk**: MEDIUM - This global can be modified via `vpx_set_worker_interface()`, which is not thread-safe.

**Documentation** (from `vpx_thread.h:80`):
> "This function is not thread-safe. Return false in case of invalid pointer or methods."

**Mitigation**: Only call `vpx_set_worker_interface()` before any encoding/decoding operations begin, ideally during application startup.

#### 1.2 VP9 Decoder Initialization (`vp9/decoder/vp9_decoder.c`)

**Location**: `/vp9/decoder/vp9_decoder.c:40-50`

```c
static void initialize_dec(void) {
  static volatile int init_done = 0;

  if (!init_done) {
    vp9_rtcd();
    vpx_dsp_rtcd();
    vpx_scale_rtcd();
    vp9_init_intra_predictors();
    init_done = 1;
  }
}
```

**Risk**: LOW (with `--enable-multithread`) - This function is called via `once(initialize_dec)` on line 192 of `vp9_decoder_create()`, which uses proper synchronization.

**Risk**: HIGH (with `--disable-multithread`) - The `once()` fallback performs no synchronization:

```c
// From vpx_ports/vpx_once.h:107-114
static void once(void (*func)(void)) {
  static volatile int done;

  if (!done) {
    func();
    done = 1;
  }
}
```

This is a classic check-then-act race condition.

#### 1.3 RTCD (Runtime CPU Detection) Initialization

**Locations**:
- `/vp8/common/rtcd.c:15`: `void vp8_rtcd(void) { once(setup_rtcd_internal); }`
- `/vp9/common/vp9_rtcd.c:15`: `void vp9_rtcd(void) { once(setup_rtcd_internal); }`
- `/vpx_dsp/vpx_dsp_rtcd.c:15`: `void vpx_dsp_rtcd(void) { once(setup_rtcd_internal); }`
- `/vpx_scale/vpx_scale_rtcd.c:15`: `void vpx_scale_rtcd(void) { once(setup_rtcd_internal); }`

**Risk**: Same as 1.2 - protected by `once()`, which is safe with multithread enabled.

**Analysis**: The `once()` mechanism uses `pthread_once()` on POSIX systems and `InterlockedCompareExchange` on Windows, providing proper thread safety for the common case.

#### 1.4 Debug Utilities (`vpx_util/vpx_debug_util.c`)

**Location**: `/vpx_util/vpx_debug_util.c`

```c
#if CONFIG_BITSTREAM_DEBUG || CONFIG_MISMATCH_DEBUG
static int frame_idx_w = 0;
static int frame_idx_r = 0;
// ... more static global state
static int result_queue[QUEUE_MAX_SIZE];
static int prob_queue[QUEUE_MAX_SIZE];
static int queue_r = 0;
static int queue_w = 0;
// ...
#endif
```

**Risk**: HIGH - Completely unprotected static global state.

**Mitigation**: These are only compiled when `CONFIG_BITSTREAM_DEBUG` or `CONFIG_MISMATCH_DEBUG` is enabled, which is not the default. Avoid these in production multi-threaded environments.

### 2. Thread-Local Storage Usage

libvpx does **not** use thread-local storage (`__thread` or `thread_local`). All per-context state is stored in the codec context structures (`vpx_codec_ctx_t`, `VP8D_COMP`, `VP9Decoder`, etc.).

### 3. Mutex/Lock Usage Patterns

#### 3.1 VP8 Decoder Threading (`vp8/decoder/threading.c`)

The VP8 decoder uses semaphores for row-based multi-threaded decoding:

```c
// Thread coordination
vp8_sem_t h_event_start_decoding[MAX_THREADS];
vp8_sem_t h_event_end_decoding;
```

Uses `vpx_atomic_int` for row synchronization:
```c
vpx_atomic_store_release(&pbi->mt_current_mb_col[mb_row], mb_col - 1);
// ...
vp8_atomic_spin_wait(mb_col, last_row_current_mb_col, nsync);
```

#### 3.2 VP9 Decoder Threading (`vp9/common/vp9_thread_common.c`)

VP9 uses mutex/condition variables for loop filter synchronization:

```c
pthread_mutex_t *mutex;      // Per-row mutex
pthread_cond_t *cond;        // Per-row condition variable
pthread_mutex_t *lf_mutex;   // Global loop filter mutex
```

Row synchronization pattern:
```c
static INLINE void sync_read(VP9LfSync *const lf_sync, int r, int c) {
  pthread_mutex_lock(mutex);
  while (c > lf_sync->cur_sb_col[r - 1] - nsync) {
    pthread_cond_wait(&lf_sync->cond[r - 1], mutex);
  }
  pthread_mutex_unlock(mutex);
}
```

#### 3.3 VPxWorker Interface (`vpx_util/vpx_thread.c`)

Each worker has its own mutex and condition variable:

```c
struct VPxWorkerImpl {
  pthread_mutex_t mutex_;
  pthread_cond_t condition_;
  pthread_t thread_;
};
```

The state machine is properly synchronized:
```c
static void change_state(VPxWorker *const worker, VPxWorkerStatus new_status) {
  if (worker->impl_ == NULL) return;
  pthread_mutex_lock(&worker->impl_->mutex_);
  // wait for worker to finish
  while (worker->status_ != VPX_WORKER_STATUS_OK) {
    pthread_cond_wait(&worker->impl_->condition_, &worker->impl_->mutex_);
  }
  // ...
  pthread_mutex_unlock(&worker->impl_->mutex_);
}
```

### 4. Initialization/Shutdown Race Conditions

#### 4.1 Decoder Context Creation

**VP8**: `vp8_decoder_create_threads()` in `/vp8/decoder/threading.c:615-672`
- Creates worker threads
- Initializes semaphores
- Thread-safe when called from a single thread per context

**VP9**: `vp9_decoder_create()` in `/vp9/decoder/vp9_decoder.c:169-217`
- Uses `once(initialize_dec)` for global initialization
- Creates loop filter worker
- Thread-safe for context creation itself

#### 4.2 Decoder Context Destruction

**VP8**: `vp8_decoder_remove_threads()` in `/vp8/decoder/threading.c:809-843`
```c
void vp8_decoder_remove_threads(VP8D_COMP *pbi) {
  if (vpx_atomic_load_acquire(&pbi->b_multithreaded_rd)) {
    vpx_atomic_store_release(&pbi->b_multithreaded_rd, 0);
    // Signal threads to exit
    for (i = 0; i < pbi->allocated_decoding_thread_count; ++i) {
      vp8_sem_post(&pbi->h_event_start_decoding[i]);
      pthread_join(pbi->h_decoding_thread[i], NULL);
    }
    // Cleanup...
  }
}
```

**VP9**: `vp9_decoder_remove()` in `/vp9/decoder/vp9_decoder.c:219-253`
```c
void vp9_decoder_remove(VP9Decoder *pbi) {
  vpx_get_worker_interface()->end(&pbi->lf_worker);
  for (i = 0; i < pbi->num_tile_workers; ++i) {
    vpx_get_worker_interface()->end(&pbi->tile_workers[i]);
  }
  // Cleanup...
}
```

Both implementations properly join/end worker threads before freeing resources.

### 5. Atomic Operations (`vpx_util/vpx_atomics.h`)

libvpx provides portable atomic operations:

```c
typedef struct vpx_atomic_int {
  volatile int value;
} vpx_atomic_int;

static INLINE void vpx_atomic_store_release(vpx_atomic_int *atomic, int value) {
#if defined(VPX_USE_ATOMIC_BUILTINS)
  __atomic_store_n(&atomic->value, value, __ATOMIC_RELEASE);
#else
  vpx_atomic_memory_barrier();
  atomic->value = value;
#endif
}

static INLINE int vpx_atomic_load_acquire(const vpx_atomic_int *atomic) {
#if defined(VPX_USE_ATOMIC_BUILTINS)
  return __atomic_load_n(&atomic->value, __ATOMIC_ACQUIRE);
#else
  int v = atomic->value;
  vpx_atomic_memory_barrier();
  return v;
#endif
}
```

**Note**: Only acquire/release semantics are provided. There are no compare-and-swap or fetch-and-add operations in the public atomics API.

### 6. `vpx_once` Mechanism (`vpx_ports/vpx_once.h`)

The `once()` function provides thread-safe one-time initialization:

**Windows** (with multithread):
```c
static LONG once_state;
static void once(void (*func)(void)) {
  if (InterlockedCompareExchange(&once_state, 1, 0) == 0) {
    func();
    InterlockedIncrement(&once_state);
    return;
  }
  while (InterlockedCompareExchange(&once_state, 2, 2) != 2) {
    Sleep(0);
  }
}
```

**POSIX** (with multithread):
```c
static void once(void (*func)(void)) {
  static pthread_once_t lock = PTHREAD_ONCE_INIT;
  pthread_once(&lock, func);
}
```

**Without multithread**:
```c
static void once(void (*func)(void)) {
  static volatile int done;
  if (!done) {
    func();
    done = 1;
  }
}
```

**Important Limitation** (from header documentation):
> "These functions use static locks, and can only be used with one common argument per compilation unit."

This means you cannot safely call `vpx_once(foo)` and `vpx_once(bar)` from the same .c file.

## Documented Thread Safety Guarantees

From `/vpx/vpx_decoder.h:119-121`:
> "If the library was configured with --disable-multithread, this call is not thread safe and should be guarded with a lock if being used in a multithreaded context."

From `/vpx/vpx_encoder.h:876-878`:
> "If the library was configured with --disable-multithread, this call is not thread safe and should be guarded with a lock if being used in a multithreaded context."

From `/vpx_util/vpx_thread.h:79-80`:
> "This should be done before any workers are started, i.e., before any encoding or decoding takes place. [...] This function is not thread-safe."

## Recommended Mitigations

### For Application Developers

1. **Initialize all codec contexts before spawning worker threads**, or protect initialization with a mutex:
   ```c
   static pthread_mutex_t vpx_init_mutex = PTHREAD_MUTEX_INITIALIZER;

   vpx_codec_ctx_t* create_decoder(void) {
       vpx_codec_ctx_t *ctx = malloc(sizeof(*ctx));
       pthread_mutex_lock(&vpx_init_mutex);
       vpx_codec_dec_init(ctx, &vpx_codec_vp9_dx_algo, &cfg, 0);
       pthread_mutex_unlock(&vpx_init_mutex);
       return ctx;
   }
   ```

2. **Never share a codec context between threads**. Each thread should have its own context.

3. **Set custom worker interfaces only at startup**, before any encoding/decoding.

4. **Avoid debug builds** (`CONFIG_BITSTREAM_DEBUG`, `CONFIG_MISMATCH_DEBUG`) in production multi-threaded environments.

5. **Use internal threading** (set `cfg.threads > 1`) instead of trying to parallelize at the frame level from multiple threads calling into the same context.

### For libvpx Integration

If you're building libvpx as a dependency:

1. **Always build with `--enable-multithread`** (this is the default)
2. Consider wrapping initialization functions with your own mutex for defense-in-depth
3. Verify your build configuration includes pthread support

## Whether Upstream Patches Are Needed

**No critical patches are required** for typical use cases.

The current design is intentional:
- Multi-threaded builds properly use `pthread_once` for initialization
- Single-threaded builds document the limitation explicitly
- The global worker interface is designed to be set once at startup

**Potential improvements** (not critical):
1. The VP9 `initialize_dec()` function could be simplified to always use the `once()` wrapper rather than having its own `init_done` flag
2. The documentation could be more prominent about thread safety requirements
3. Consider adding `_Thread_local` support for debug utilities in debug builds

## Test Coverage

libvpx includes thread safety tests in `/test/vp9_thread_test.cc`:
- `VPxWorkerThreadTest`: Tests worker thread synchronization
- `VP9DecodeMultiThreadedTest`: Tests multi-threaded decoding with various thread counts (1-8)
- Tests for tile-parallel and frame-parallel decoding

## Summary Table

| Component | Thread-Safe? | Notes |
|-----------|--------------|-------|
| Codec initialization | Yes* | *Only with `--enable-multithread` |
| Per-context decoding | Yes | Single owner thread |
| Multiple contexts | Yes | Different threads OK |
| Internal threading | Yes | Properly synchronized |
| `vpx_set_worker_interface()` | No | Call only at startup |
| Debug utilities | No | Not for production |
| Sharing context between threads | No | Never safe |

## References

- libvpx source: https://chromium.googlesource.com/webm/libvpx
- Source analyzed: HEAD as of January 2025
- Key files examined:
  - `/vpx_ports/vpx_once.h`
  - `/vpx_util/vpx_thread.c`
  - `/vpx_util/vpx_atomics.h`
  - `/vp8/decoder/threading.c`
  - `/vp9/decoder/vp9_decoder.c`
  - `/vp9/common/vp9_thread_common.c`
  - `/vpx/vpx_decoder.h`
  - `/vpx/vpx_encoder.h`
