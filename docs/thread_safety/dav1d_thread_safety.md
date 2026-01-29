# dav1d AV1 Decoder Thread Safety Analysis

## Executive Summary

The dav1d AV1 decoder library is **well-designed for thread safety** in its primary use case: creating independent decoder contexts that can be used from different threads. The library employs proper synchronization primitives (mutexes, condition variables, atomics) and uses `pthread_once` for one-time global initialization.

**Key Findings:**

1. **Independent decoder contexts are thread-safe**: Each `Dav1dContext` created via `dav1d_open()` is fully independent and can be used from separate threads without external synchronization.

2. **Single context is NOT thread-safe for concurrent API calls**: A single decoder context must not have its API functions called concurrently from multiple threads.

3. **Global initialization is thread-safe**: The library uses `pthread_once` to ensure one-time initialization is safe even when multiple threads call `dav1d_open()` simultaneously.

4. **Internal multi-threading is well-synchronized**: The library's internal worker threads use proper mutex/condition variable synchronization.

5. **Minor concerns exist with global mutable state** (non-critical, see details below).

---

## Detailed Analysis

### 1. Global Variables and Static State

#### 1.1 Thread-Safe Global Initialization (lib.c:139-140)

```c
// File: /deps/dav1d_src/src/lib.c
static pthread_once_t initted = PTHREAD_ONCE_INIT;
pthread_once(&initted, init_internal);
```

The library uses `pthread_once` to ensure that `init_internal()` is called exactly once, even if multiple threads call `dav1d_open()` concurrently. This initializes:
- CPU feature flags (`dav1d_init_cpu()`)
- Wedge masks (`dav1d_init_ii_wedge_masks()`)
- Intra edge trees (`dav1d_init_intra_edge_tree()`)
- Quantization matrix tables (`dav1d_init_qm_tables()`)
- Thread subsystem (`dav1d_init_thread()`)

**Verdict:** Thread-safe initialization.

#### 1.2 CPU Flags (cpu.c:60-61)

```c
// File: /deps/dav1d_src/src/cpu.c
unsigned dav1d_cpu_flags = 0U;
unsigned dav1d_cpu_flags_mask = ~0U;
```

These global variables store CPU feature detection results. They are:
- Written once during initialization via `dav1d_init_cpu()`
- Read-only thereafter during normal operation

**Potential Issue:** `dav1d_set_cpu_flags_mask()` is a public API that can modify `dav1d_cpu_flags_mask` at any time without synchronization. However:
- This is a testing/debugging API
- Typical applications set this once before opening decoders
- The write is atomic for aligned unsigned integers on most platforms

**Risk Level:** Low (testing API, single-word atomic on most platforms)

#### 1.3 Scan Tables (scan.c:304-375)

```c
// File: /deps/dav1d_src/src/scan.c
static uint8_t last_nonzero_col_from_eob_4x4[16];
// ... more tables ...
static pthread_once_t initted = PTHREAD_ONCE_INIT;
```

The scan tables have their own `pthread_once` guard and are lazily initialized on first use via `dav1d_init_last_nonzero_col_from_eob_tables()`. This is called from `itx_tmpl.c:310`.

**Verdict:** Thread-safe (uses `pthread_once`).

#### 1.4 Wedge Masks (wedge.c:86)

```c
// File: /deps/dav1d_src/src/wedge.c
Dav1dMasks dav1d_masks;
```

This large global structure is initialized once via `dav1d_init_ii_wedge_masks()` during the main `init_internal()` call. The comment explicitly states:

```c
// This function is guaranteed to be called only once
```

**Verdict:** Thread-safe (write-once during init, read-only thereafter).

#### 1.5 Intra Edge Tree (intra_edge.c:44-53)

```c
// File: /deps/dav1d_src/src/intra_edge.c
static struct {
    EdgeBranch branch_sb128[1 + 4 + 16 + 64];
    EdgeTip tip_sb128[256];
    EdgeBranch branch_sb64[1 + 4 + 16];
    EdgeTip tip_sb64[64];
} ALIGN(nodes, 16);
```

Initialized once during `init_internal()` via `dav1d_init_intra_edge_tree()`. Comment confirms single initialization:

```c
// This function is guaranteed to be called only once
```

**Verdict:** Thread-safe (write-once during init, read-only thereafter).

#### 1.6 QM Tables (qm.c:1648)

```c
// File: /deps/dav1d_src/src/qm.c
// This function is guaranteed to be called only once
COLD void dav1d_init_qm_tables(void) { ... }
```

Quantization matrix tables are initialized once during `init_internal()`.

**Verdict:** Thread-safe (write-once during init, read-only thereafter).

### 2. Thread-Local Storage Usage

The dav1d library does **not** use explicit thread-local storage (`__thread` or `thread_local`). Instead, each worker thread receives its own `Dav1dTaskContext` structure containing all per-thread state:

```c
// File: /deps/dav1d_src/src/internal.h:389
struct Dav1dTaskContext {
    const Dav1dContext *c;
    const Dav1dFrameContext *f;
    Dav1dTileState *ts;
    int bx, by;
    // ... per-thread scratch buffers ...
};
```

**Verdict:** Clean design - no TLS complications.

### 3. Mutex/Lock Usage Patterns

#### 3.1 Task Thread Synchronization

The library uses a hierarchical locking structure for its internal multi-threading:

**Global Task Thread Data (internal.h:133-163):**
```c
struct TaskThreadData {
    pthread_mutex_t lock;
    pthread_cond_t cond;
    atomic_uint first;
    unsigned cur;
    atomic_uint reset_task_cur;
    atomic_int cond_signaled;
    struct {
        int exec, finished;
        pthread_cond_t cond;
        // ... film grain state ...
        atomic_int progress[2];
    } delayed_fg;
    int inited;
};
```

**Per-Frame Task Thread Data (internal.h:322-345):**
```c
struct {
    pthread_mutex_t lock;
    pthread_cond_t cond;
    struct TaskThreadData *ttd;
    struct Dav1dTask *tasks, *tile_tasks[2], init_task;
    // ... task management ...
    struct { // async task insertion
        atomic_int merge;
        pthread_mutex_t lock;
        Dav1dTask *head, *tail;
    } pending_tasks;
} task_thread;
```

**Per-Worker Thread Data (thread_data.h:33-38):**
```c
struct thread_data {
    pthread_t thread;
    pthread_cond_t cond;
    pthread_mutex_t lock;
    int inited;
};
```

#### 3.2 Lock Ordering

The worker thread function (`thread_task.c:550-936`) follows a consistent locking pattern:
1. Acquire `ttd->lock` (global task lock)
2. Search for available work
3. Release lock before executing task
4. Re-acquire lock for task completion signaling

**Verdict:** Well-structured mutex hierarchy prevents deadlocks.

#### 3.3 Memory Pool Synchronization (mem.c)

```c
// File: /deps/dav1d_src/src/mem.c:224
void dav1d_mem_pool_push(Dav1dMemPool *const pool, Dav1dMemPoolBuffer *const buf) {
    pthread_mutex_lock(&pool->lock);
    // ... pool operations ...
    pthread_mutex_unlock(&pool->lock);
}

Dav1dMemPoolBuffer *dav1d_mem_pool_pop(Dav1dMemPool *const pool, const size_t size) {
    pthread_mutex_lock(&pool->lock);
    // ... pool operations ...
    pthread_mutex_unlock(&pool->lock);
}
```

Each memory pool has its own mutex. Pools are per-context, so no cross-context contention.

**Verdict:** Thread-safe memory pooling.

### 4. Reference Counting (ref.h/ref.c)

```c
// File: /deps/dav1d_src/src/ref.h:42,62,70
struct Dav1dRef {
    void *data;
    const void *const_data;
    atomic_int ref_cnt;  // Atomic reference count
    // ...
};

static inline void dav1d_ref_inc(Dav1dRef *const ref) {
    atomic_fetch_add_explicit(&ref->ref_cnt, 1, memory_order_relaxed);
}

// File: /deps/dav1d_src/src/ref.c:81
void dav1d_ref_dec(Dav1dRef **const pref) {
    // ...
    if (atomic_fetch_sub(&ref->ref_cnt, 1) == 1) {
        // Last reference - free
    }
}
```

Reference counting uses C11 atomics with appropriate memory ordering.

**Verdict:** Thread-safe reference counting.

### 5. Decoder Context Creation/Destruction Safety

#### 5.1 Context Creation (lib.c:138-299)

`dav1d_open()` performs the following:
1. Calls `pthread_once(&initted, init_internal)` for global init
2. Allocates a new `Dav1dContext`
3. Initializes per-context memory pools (each with own mutex)
4. Creates worker threads with proper mutex/cond initialization
5. Worker threads block waiting for work immediately after creation

**Thread Safety:** Multiple threads can safely call `dav1d_open()` concurrently - each will get an independent context.

#### 5.2 Context Destruction (lib.c:600-703)

`dav1d_close()` performs:
1. Calls `dav1d_flush()` to stop in-flight work
2. Sets `die` flag for all worker threads
3. Broadcasts condition to wake workers
4. Joins all worker threads
5. Destroys mutexes and frees resources

**Thread Safety:** A context must not have API calls in progress from other threads when `dav1d_close()` is called.

#### 5.3 Flush Operation (lib.c:524-598)

`dav1d_flush()` uses the atomic `flush` flag:
```c
atomic_store(c->flush, 1);
pthread_mutex_lock(&c->task_thread.lock);
for (unsigned i = 0; i < c->n_tc; i++) {
    while (!tc->task_thread.flushed) {
        pthread_cond_wait(&tc->task_thread.td.cond, &c->task_thread.lock);
    }
}
// ... cleanup ...
atomic_store(c->flush, 0);
```

Workers check the flush flag and park themselves when set:
```c
// thread_task.c:560-561
if (atomic_load(c->flush)) goto park;
```

**Verdict:** Safe flush mechanism using atomics and condition variables.

### 6. Atomic Operations Usage

The library uses C11 atomics extensively for lock-free progress tracking:

**Frame Progress (internal.h:278-280):**
```c
atomic_int entropy_progress;
atomic_int deblock_progress;
atomic_uint *frame_progress, *copy_lpf_progress;
```

**Task State (internal.h:328-333):**
```c
atomic_int init_done;
atomic_int done[2];
atomic_int error;
atomic_int task_counter;
```

**Tile Progress (internal.h:364):**
```c
atomic_int progress[2 /* 0: reconstruction, 1: entropy */];
```

These atomics enable lock-free progress checking in the worker threads, improving performance while maintaining correctness.

**Verdict:** Proper use of atomics for progress tracking.

### 7. Allocation Tracking (Debug Feature)

When `TRACK_HEAP_ALLOCATIONS` is enabled (mem.c:34-217):

```c
static pthread_mutex_t track_alloc_mutex = PTHREAD_MUTEX_INITIALIZER;
```

All allocation tracking operations are protected by this mutex.

**Verdict:** Thread-safe debug feature.

---

## Identified Thread Safety Issues

### Issue 1: `dav1d_set_cpu_flags_mask()` Race Condition

**Location:** `/deps/dav1d_src/src/cpu.c:80-82`

```c
COLD void dav1d_set_cpu_flags_mask(const unsigned mask) {
    dav1d_cpu_flags_mask = mask;
}
```

**Description:** This public API function modifies a global variable without synchronization. If called while decoders are running, it could cause inconsistent CPU feature detection.

**Severity:** Low

**Mitigation:**
- Only call `dav1d_set_cpu_flags_mask()` before creating any decoder contexts
- This is already the expected usage pattern (testing/debugging API)

### Issue 2: No API-Level Thread Safety for Single Context

**Location:** All public API functions

**Description:** The public API functions (`dav1d_send_data`, `dav1d_get_picture`, `dav1d_flush`, `dav1d_close`) do not use any mutual exclusion. Calling these concurrently on the same context leads to undefined behavior.

**Severity:** Medium (documentation issue)

**Mitigation:**
- Application must serialize access to a single decoder context
- Create multiple decoder contexts for parallel decoding workloads
- Document this limitation clearly

### Issue 3: Logger Callback Thread Safety

**Location:** `/deps/dav1d_src/include/dav1d/dav1d.h:49-59`

```c
typedef struct Dav1dLogger {
    void *cookie;
    void (*callback)(void *cookie, const char *format, va_list ap);
} Dav1dLogger;
```

**Description:** The logger callback can be invoked from any worker thread. If the callback is not thread-safe, this could cause issues.

**Severity:** Low (application responsibility)

**Mitigation:**
- Ensure logger callbacks are thread-safe
- Use thread-safe logging implementations (fprintf with FILE* is typically thread-safe)

---

## Recommended Mitigations

### For Library Users

1. **Context Isolation:** Create separate decoder contexts for each thread if concurrent decoding is needed.

2. **CPU Mask Timing:** Call `dav1d_set_cpu_flags_mask()` only before any `dav1d_open()` calls.

3. **Thread-Safe Callbacks:** Ensure custom picture allocators and logger callbacks are thread-safe.

4. **Serial API Access:** Do not call `dav1d_send_data()`, `dav1d_get_picture()`, `dav1d_flush()`, or `dav1d_close()` on the same context from multiple threads simultaneously.

### For Library Maintainers (Potential Upstream Improvements)

1. **Documentation:** Add explicit thread safety documentation to the public header file describing:
   - Independent contexts are thread-safe
   - Single context requires external synchronization
   - Callback thread safety requirements

2. **CPU Mask API:** Consider making `dav1d_set_cpu_flags_mask()` return an error if called after any context has been opened, or use an atomic store with acquire/release semantics.

3. **Optional API Mutex:** For ease of use, consider adding an optional mode where a per-context mutex protects all API calls (with performance trade-off).

---

## Upstream Patches Needed

**No critical upstream patches are required.** The library is well-designed for its intended use case. The identified issues are:

1. Documentation clarifications (not code changes)
2. Optional API improvements for defense-in-depth

The dav1d library follows industry best practices for video decoder thread safety:
- Per-context isolation
- One-time initialization via `pthread_once`
- Proper mutex hierarchy for internal threading
- Atomic reference counting
- Lock-free progress tracking with atomics

---

## Code Locations Summary

| Component | File | Lines | Status |
|-----------|------|-------|--------|
| Global Init | `src/lib.c` | 53-59, 138-140 | Thread-safe (pthread_once) |
| CPU Flags | `src/cpu.c` | 60-61, 80-82 | Minor race potential |
| Reference Counting | `src/ref.h`, `src/ref.c` | 42, 62, 70, 74, 81 | Thread-safe (atomics) |
| Memory Pools | `src/mem.c` | 224-274 | Thread-safe (per-pool mutex) |
| Task Threading | `src/thread_task.c` | 550-936 | Thread-safe (mutex/cond) |
| Context Creation | `src/lib.c` | 138-299 | Thread-safe |
| Context Destruction | `src/lib.c` | 600-703 | Single-threaded only |
| Wedge Masks | `src/wedge.c` | 86, 207-299 | Write-once, read-only |
| Intra Edge | `src/intra_edge.c` | 44-53, 126-148 | Write-once, read-only |
| QM Tables | `src/qm.c` | 1648+ | Write-once, read-only |
| Scan Tables | `src/scan.c` | 304-375 | Thread-safe (pthread_once) |

---

## Conclusion

The dav1d library is **safe for multi-threaded use** when following these guidelines:

1. Use separate decoder contexts for concurrent decoding
2. Do not call multiple API functions on the same context simultaneously
3. Ensure callbacks (logger, allocator) are thread-safe
4. Set CPU flags mask before opening any decoders

No upstream patches are strictly necessary, though documentation improvements would benefit users.
