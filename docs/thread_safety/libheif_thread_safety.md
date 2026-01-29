# libheif Thread Safety Analysis

**Analysis Date:** January 2026
**libheif Version:** Current HEAD (cloned January 2026)
**Repository:** https://github.com/strukturag/libheif

## Executive Summary

libheif has **partial thread safety support** that is conditional on compile-time flags. When `ENABLE_MULTITHREADING_SUPPORT` is enabled (the default), the library provides mutex protection for critical global state including initialization, plugin management, and some shared data structures. However, several thread safety concerns exist that require careful attention from application developers.

**Key Findings:**

1. **CONDITIONAL SAFETY**: Thread safety is only available when built with `ENABLE_MULTITHREADING_SUPPORT=ON` (default). Building without this flag removes all mutex protection.

2. **SAFE WITH PRECAUTIONS**: The library is generally safe to use from multiple threads IF:
   - `heif_init()` is called before any multithreaded access
   - Each `heif_context` is accessed from only one thread at a time (or protected externally)
   - Parallel tile decoding uses internal synchronization

3. **POTENTIAL RACE CONDITIONS**: Several areas have identified risks including lazy initialization, static mutexes in function scope, and shared plugin registry access.

---

## Detailed Analysis

### 1. Global Variables and Static State

#### 1.1 Plugin Registry (CRITICAL)

**File:** `/libheif/plugin_registry.cc`

```cpp
std::set<const heif_decoder_plugin*> s_decoder_plugins;

std::multiset<std::unique_ptr<heif_encoder_descriptor>,
              encoder_descriptor_priority_order> s_encoder_descriptors;
```

**Issue:** These are global containers that store registered decoder and encoder plugins. They are:
- Modified during plugin registration (`register_decoder()`, `register_encoder()`)
- Read during decoding operations via `get_decoder_plugins()` and `get_encoder_descriptors()`
- Cleared during `heif_deinit()` via `heif_unregister_decoder_plugins()` and `heif_unregister_encoder_plugins()`

**Risk Level:** HIGH - Concurrent modification/access without external synchronization can cause undefined behavior.

**Current Mitigation:** The library uses lazy initialization through `load_plugins_if_not_initialized_yet()` which is called before accessing these containers, but the initialization path itself has a race condition (see Section 2).

#### 1.2 Static Initialization of Default Plugins (CRITICAL)

**File:** `/libheif/plugin_registry.cc`, lines 138-145

```cpp
static class Register_Default_Plugins
{
public:
  Register_Default_Plugins()
  {
    register_default_plugins();
  }
} dummy;
```

**Issue:** This uses the "static initialization" pattern which registers plugins at program load time. The comment states:
> "Note: we cannot move this to 'heif_init' because we have to make sure that this is initialized AFTER the two global std::set above."

This relies on C++ static initialization order within a translation unit but can be problematic with:
- Dynamic library loading/unloading
- Multiple compilation units

**Risk Level:** MEDIUM - Generally works due to single translation unit, but fragile.

#### 1.3 Library Initialization Counter

**File:** `/libheif/init.cc`, lines 85-86

```cpp
static int heif_library_initialization_count = 0;
static bool default_plugins_registered = true;
```

**Issue:** The initialization count is checked outside the mutex lock in `load_plugins_if_not_initialized_yet()`:

```cpp
void load_plugins_if_not_initialized_yet()
{
  if (heif_library_initialization_count == 0) {  // READ WITHOUT LOCK
    heif_init(nullptr);
  }
}
```

**Risk Level:** HIGH - Classic TOCTOU (time-of-check-time-of-use) race condition. Two threads could both see `count == 0` and both attempt initialization.

The comment in the code acknowledges this intentional design:
> "Note: it is important that we increase the counter AFTER initialization such that 'load_plugins_if_not_initialized_yet()' can check this without having to lock the mutex."

This optimization trades safety for performance but creates a race window during first initialization.

#### 1.4 Loaded Plugins List

**File:** `/libheif/init.cc`, line 193

```cpp
static std::vector<loaded_plugin> sLoadedPlugins;
```

**Risk Level:** MEDIUM - Protected by `heif_init_mutex()` for all access (load, unload operations).

#### 1.5 Memory Usage Tracking

**File:** `/libheif/security_limits.cc`, line 107

```cpp
static std::map<const heif_security_limits*, memory_stats> sMemoryUsage;
```

**Issue:** This global map tracks memory usage per security context.

**Mitigation:** Properly protected by `get_memory_usage_mutex()` for all access.

**Risk Level:** LOW - Correctly synchronized.

#### 1.6 Global Security Limits

**File:** `/libheif/security_limits.cc`, lines 27-58

```cpp
heif_security_limits global_security_limits{ ... };
heif_security_limits disabled_security_limits{ ... };
```

**Issue:** Global configuration objects that may be read concurrently.

**Risk Level:** LOW - These are initialized at startup and typically only read (not modified) during normal operation.

### 2. Initialization and Shutdown Race Conditions

#### 2.1 Lazy Initialization Race (CRITICAL)

**File:** `/libheif/init.cc`, lines 100-105

```cpp
void load_plugins_if_not_initialized_yet()
{
  if (heif_library_initialization_count == 0) {
    heif_init(nullptr);
  }
}
```

**Race Scenario:**
1. Thread A: Checks `heif_library_initialization_count == 0`, true
2. Thread B: Checks `heif_library_initialization_count == 0`, true
3. Thread A: Enters `heif_init()`, acquires mutex, starts initialization
4. Thread B: Enters `heif_init()`, blocks on mutex
5. Thread A: Completes initialization, increments counter to 1
6. Thread B: Acquires mutex, `count` is now 1, skips initialization
7. Both threads proceed - **generally safe** due to idempotent design

**However:** The race between the check and `heif_init()` could cause issues if:
- A third thread calls `heif_deinit()` while B is blocked
- Plugin initialization has side effects that shouldn't run concurrently

**Risk Level:** MEDIUM - Designed to be "safe enough" but not formally correct.

#### 2.2 Shutdown During Active Use

**File:** `/libheif/init.cc`, lines 145-169

The comment in the code warns:
```cpp
// If the client application calls heif_deinit() in parallel to some other
// libheif function, it is really broken.
```

**Risk Level:** HIGH - No protection against calling `heif_deinit()` while decoding operations are in progress. Application must ensure proper lifecycle management.

### 3. Mutex Usage Patterns

#### 3.1 Recursive Mutex for Initialization

**File:** `/libheif/init.cc`, lines 91-95

```cpp
static std::recursive_mutex& heif_init_mutex()
{
  static std::recursive_mutex init_mutex;
  return init_mutex;
}
```

**Pattern:** Returns reference to function-local static mutex. This is thread-safe in C++11 and later (guaranteed by the standard).

**Usages:**
- `heif_init()` - line 111
- `heif_deinit()` - line 148
- `heif_load_plugin()` - line 217
- `heif_unload_plugin()` - line 307
- `heif_unload_all_plugins()` - line 334

**Risk Level:** LOW - Correct use of recursive mutex for nested calls.

#### 3.2 Static Mutexes in Parallel Tile Decoding (CONCERN)

**File:** `/libheif/image-items/grid.cc`

```cpp
// Line 464-465
static std::mutex progressMutex;
std::lock_guard<std::mutex> lock(progressMutex);

// Line 482-489
static std::mutex warningsMutex;
std::lock_guard<std::mutex> lock(warningsMutex);

// Line 526-527
static std::mutex createImageMutex;
std::lock_guard<std::mutex> lock(createImageMutex);
```

**Issue:** Function-local static mutexes are used for synchronization during parallel tile decoding. While these are thread-safe to initialize (C++11 guarantee), they create global synchronization points that serialize certain operations across ALL concurrent decode operations, not just within a single image.

**Risk Level:** MEDIUM - May cause unexpected contention when decoding multiple images in parallel.

#### 3.3 Box Read Mutex

**File:** `/libheif/box.cc`, lines 1771-1773

```cpp
#if ENABLE_MULTITHREADING_SUPPORT
  static std::mutex read_mutex;
  std::lock_guard<std::mutex> lock(read_mutex);
#endif
```

**Issue:** Protects `read_from_file_data_items()` for parallel tile decoding.

**Risk Level:** LOW - Correct but may limit parallelism.

#### 3.4 Color Conversion Operations Mutex

**File:** `/libheif/color-conversion/colorconversion.cc`, lines 214-215

```cpp
#if ENABLE_MULTITHREADING_SUPPORT
  static std::mutex init_ops_mutex;
  std::lock_guard<std::mutex> lock(init_ops_mutex);
#endif
```

**Issue:** Protects initialization of the color conversion operation pool.

**Risk Level:** LOW - Initialization is idempotent.

#### 3.5 File Read Mutex (Disabled)

**File:** `/libheif/file.cc`, line 624

```cpp
// std::lock_guard<std::mutex> guard(m_read_mutex);
// TODO: I think that this is not needed anymore because this function
// is not used for image data anymore.
```

**Issue:** The read mutex in `HeifFile` is defined but not used in `get_uncompressed_item_data()`. The developer comment suggests uncertainty about whether it's needed.

**Risk Level:** MEDIUM - May indicate incomplete thread safety analysis.

### 4. Context and Object Safety

#### 4.1 HeifContext Thread Safety

**File:** `/libheif/context.cc`, `/libheif/context.h`

**Finding:** `HeifContext` objects (wrapped by `heif_context`) have **NO internal thread synchronization**. All operations on a context are expected to be serialized by the caller.

**Safe Pattern:**
```c
// Each thread has its own context
heif_context* ctx = heif_context_alloc();
// ... use ctx only from this thread ...
heif_context_free(ctx);
```

**Unsafe Pattern:**
```c
// Shared context accessed from multiple threads - UNSAFE
heif_context* shared_ctx = heif_context_alloc();
// Thread 1: heif_decode_image(handle1, ...)
// Thread 2: heif_decode_image(handle2, ...)  // RACE CONDITION
```

**Risk Level:** HIGH for shared contexts - Application must provide external synchronization.

#### 4.2 Encoder/Decoder Plugin Safety

Codec plugins (libde265, x265, libaom, dav1d, etc.) have their own thread safety characteristics:
- Some plugins may create worker threads internally
- The `heif_decoding_options` has `num_codec_threads` to control this
- libheif's `heif_context_set_max_decoding_threads()` controls libheif's parallelism but "Note that this setting only affects libheif itself. The codecs itself may still use multi-threaded decoding."

**Risk Level:** MEDIUM - Depends on underlying codec implementation.

### 5. Plugin Loading Thread Safety

#### 5.1 Dynamic Plugin Loading

**Files:** `/libheif/init.cc`, `/libheif/plugins_unix.cc`, `/libheif/plugins_windows.cc`

Plugin loading (`heif_load_plugin()`) is protected by `heif_init_mutex()`, making it thread-safe. However:

1. Plugins may have their own initialization code that runs during `dlopen()`
2. Plugin registration modifies global plugin containers

**Risk Level:** MEDIUM - Safe within libheif, but plugin code quality varies.

### 6. Thread-Local Storage Usage

**Finding:** libheif does **NOT** use thread-local storage (`thread_local` or `__thread`). All state is either:
- Global (with mutex protection)
- Per-context (no internal synchronization)
- Stack-local

This is a **positive finding** as it avoids TLS-related complexity and portability issues.

### 7. Progress Callbacks and Cancellation

**File:** `/libheif/api/libheif/heif_decoding.h`, lines 67-72

```cpp
// Any of the progress functions may be called from background threads.
void (* start_progress)(enum heif_progress_step step, int max_progress, void* progress_user_data);
void (* on_progress)(enum heif_progress_step step, int progress, void* progress_user_data);
void (* end_progress)(enum heif_progress_step step, void* progress_user_data);
```

**Important:** The comment explicitly states callbacks "may be called from background threads." Application code MUST ensure callback implementations are thread-safe.

**Risk Level:** MEDIUM - Caller responsibility, clearly documented.

---

## Recommended Mitigations

### For Application Developers

1. **Always call `heif_init()` before multithreaded usage:**
   ```c
   // In main thread, before spawning worker threads
   heif_init(NULL);

   // ... spawn threads ...

   // After all threads complete
   heif_deinit();
   ```

2. **Use per-thread contexts:**
   ```c
   // Each worker thread should have its own context
   void* decode_worker(void* arg) {
       heif_context* ctx = heif_context_alloc();
       // ... decode using ctx ...
       heif_context_free(ctx);
       return NULL;
   }
   ```

3. **Protect shared contexts with external mutex:**
   ```c
   pthread_mutex_t ctx_mutex = PTHREAD_MUTEX_INITIALIZER;
   heif_context* shared_ctx;

   void decode_with_shared_context(...) {
       pthread_mutex_lock(&ctx_mutex);
       // ... use shared_ctx ...
       pthread_mutex_unlock(&ctx_mutex);
   }
   ```

4. **Make progress callbacks thread-safe:**
   ```c
   static atomic_int progress_value;

   void on_progress(enum heif_progress_step step, int progress, void* data) {
       atomic_store(&progress_value, progress);  // Thread-safe update
   }
   ```

5. **Do not call `heif_deinit()` while operations are in progress.**

### For Library Integrators (Building libheif)

1. **Enable multithreading support:**
   ```bash
   cmake -DENABLE_MULTITHREADING_SUPPORT=ON ...
   ```

2. **Consider disabling parallel tile decoding if you manage parallelism externally:**
   ```bash
   cmake -DENABLE_PARALLEL_TILE_DECODING=OFF ...
   ```

3. **Test with thread sanitizer:**
   ```bash
   cmake -DCMAKE_CXX_FLAGS="-fsanitize=thread" ...
   ```

---

## Potential Upstream Patches

### Issue 1: Initialization Race Condition

**Location:** `/libheif/init.cc`, line 100-105

**Current Code:**
```cpp
void load_plugins_if_not_initialized_yet()
{
  if (heif_library_initialization_count == 0) {
    heif_init(nullptr);
  }
}
```

**Proposed Fix:**
```cpp
void load_plugins_if_not_initialized_yet()
{
#if ENABLE_MULTITHREADING_SUPPORT
  std::lock_guard<std::recursive_mutex> lock(heif_init_mutex());
#endif
  if (heif_library_initialization_count == 0) {
    heif_init(nullptr);
  }
}
```

**Trade-off:** Adds overhead to every operation that calls this function. The current design intentionally accepts the race for performance.

### Issue 2: Static Mutex Contention in Grid Decoding

**Location:** `/libheif/image-items/grid.cc`

**Problem:** Static mutexes cause global contention across all decode operations.

**Proposed Fix:** Move mutexes to per-grid or per-context level:
```cpp
class ImageItem_Grid {
private:
    mutable std::mutex m_progress_mutex;
    mutable std::mutex m_warnings_mutex;
    mutable std::mutex m_create_image_mutex;
    // ...
};
```

### Issue 3: Document Thread Safety Guarantees

**Location:** Public headers (`heif.h`, `heif_context.h`, etc.)

**Proposal:** Add explicit documentation about thread safety:
```c
/**
 * @threadsafety This function is thread-safe.
 * Multiple threads may call this function concurrently.
 */
heif_error heif_init(heif_init_params*);

/**
 * @threadsafety heif_context objects are NOT thread-safe.
 * Access to a context must be serialized by the caller, or each thread
 * should use its own context.
 */
heif_context* heif_context_alloc(void);
```

---

## Summary Table

| Component | Thread Safety | Risk Level | Notes |
|-----------|--------------|------------|-------|
| `heif_init()`/`heif_deinit()` | Thread-safe | LOW | Protected by recursive mutex |
| Plugin loading | Thread-safe | LOW | Protected by init mutex |
| Plugin registry access | Race possible | HIGH | Lazy init has TOCTOU race |
| `heif_context` operations | NOT thread-safe | HIGH | Caller must synchronize |
| Parallel tile decoding | Internal sync | MEDIUM | Static mutexes cause contention |
| Progress callbacks | Caller responsibility | MEDIUM | Documented requirement |
| Memory tracking | Thread-safe | LOW | Properly synchronized |
| Color conversion init | Thread-safe | LOW | Idempotent with mutex |

---

## Conclusion

libheif provides reasonable thread safety for common use cases when built with `ENABLE_MULTITHREADING_SUPPORT=ON`. The main requirement for safe concurrent usage is:

1. **Initialize first:** Call `heif_init()` before any multithreaded access
2. **Don't share contexts:** Use one `heif_context` per thread, or provide external synchronization
3. **Safe callbacks:** Ensure progress/cancel callbacks are thread-safe

The identified race condition in lazy initialization is a known trade-off for performance. For maximum safety in security-critical applications, explicit initialization with `heif_init()` before threading is strongly recommended.

Upstream patches to improve documentation and reduce static mutex contention would benefit the library but are not strictly required for safe usage with the recommended patterns.
