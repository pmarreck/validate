# libjxl Thread Safety Analysis

## Executive Summary

**Overall Assessment: MOSTLY THREAD-SAFE with specific constraints**

The libjxl library is designed with thread safety in mind for its primary use case: **independent encoder/decoder instances can be safely used in parallel from different threads**. However, there are specific constraints and a small number of global state issues that users must be aware of.

**Key Findings:**

1. **Encoder/Decoder instances are NOT thread-safe**: A single `JxlDecoder` or `JxlEncoder` instance must not be accessed concurrently from multiple threads.

2. **Parallel runners are NOT re-entrant**: Only one concurrent call to `JxlThreadParallelRunner` or `JxlResizableParallelRunner` per runner instance is allowed at a time.

3. **Multiple independent instances ARE safe**: Different encoder/decoder instances can safely operate in parallel threads.

4. **Limited global state exists**: A few static/global variables exist but are either thread-safe (using atomics) or only accessed during specific conditions.

---

## Detailed Analysis

### 1. Decoder/Encoder Context Safety

#### Instance-Level Thread Safety

Each `JxlDecoder` and `JxlEncoder` instance maintains its own state and is **not designed for concurrent access**. The API documentation implicitly assumes single-threaded access per instance.

**Location:** `/lib/jxl/decode.cc`, `/lib/jxl/encode.cc`

```c
// struct JxlDecoder contains non-atomic state fields including:
// - DecoderStage stage
// - Various status flags (got_signature, got_basic_info, etc.)
// - Input/output buffer pointers
// - Frame processing state
```

**Recommendation:** Use separate encoder/decoder instances per thread, or synchronize access to shared instances externally.

#### Creation and Destruction Safety

`JxlDecoderCreate()`, `JxlDecoderDestroy()`, `JxlEncoderCreate()`, and `JxlEncoderDestroy()` are safe to call from any thread for different instances.

---

### 2. Thread Pool / Parallel Runner Analysis

#### JxlThreadParallelRunner

**Location:** `/lib/threads/thread_parallel_runner_internal.h`, `/lib/threads/thread_parallel_runner_internal.cc`

The thread parallel runner is well-designed with proper synchronization:

**Synchronization Mechanisms:**
- `std::mutex mutex_` - Guards condition variables and shared state
- `std::condition_variable workers_ready_cv_` - Signals when workers are ready
- `std::condition_variable worker_start_cv_` - Signals workers to start
- `std::atomic<uint32_t> depth_` - Detects re-entrant calls
- `std::atomic<uint32_t> num_reserved_` - Atomic task counter for work-stealing

**Critical Constraint (Line 44-46):**
```cpp
if (self->depth_.fetch_add(1, std::memory_order_acq_rel) != 0) {
    return JXL_PARALLEL_RET_RUNNER_ERROR;  // Must not re-enter.
}
```

**Documentation from header (line 17-18):**
> "Only one concurrent JxlThreadParallelRunner call per instance is allowed at a time."

#### JxlResizableParallelRunner

**Location:** `/lib/threads/resizable_parallel_runner.cc`

Similar thread safety characteristics with:
- `std::mutex state_mutex_`
- `std::condition_variable workers_can_proceed_`
- `std::condition_variable work_done_`
- `std::atomic<uint32_t> next_task_`

**Documentation:** Same single-concurrent-call constraint applies.

---

### 3. Global/Static State Analysis

#### 3.1 Thread-Local CMS Context (SAFE)

**Location:** `/lib/jxl/cms/jxl_cms.cc:798`

```cpp
static thread_local void* context_;
```

**Analysis:** This uses proper `thread_local` storage to maintain per-thread LCMS2 contexts. Each thread gets its own context, eliminating data races. This is the correct approach for the color management system.

#### 3.2 Memory Allocation Group Counter (SAFE)

**Location:** `/lib/jxl/memory_manager_internal.cc:114`

```cpp
static std::atomic<uint32_t> next_group{0};
```

**Analysis:** Uses `std::atomic` with relaxed memory ordering for a non-critical alignment optimization. Thread-safe by design.

#### 3.3 CPU Feature Detection Cache (SAFE - Static Initialization)

**Location:** `/lib/jxl/enc_fast_lossless.cc:203`

```cpp
static uint32_t cpu_features = DetectCpuFeatures();
```

**Analysis:** C++11 guarantees thread-safe static local variable initialization. The value is computed once at first use and is read-only thereafter.

#### 3.4 SIMD Vector Size Cache (SAFE - Static Initialization)

**Location:** `/lib/jpegli/simd.cc:36`

```cpp
static size_t bytes = HWY_DYNAMIC_DISPATCH(GetVectorSize)();
```

**Analysis:** Same as above - C++11 static initialization guarantees.

#### 3.5 Butteraugli Normalization Constant (SAFE - Read-Only)

**Location:** `/lib/jxl/butteraugli/butteraugli.cc:2126`

```cpp
static double print_out_normalization = ButteraugliFuzzyInverse(1.0);
```

**Analysis:** Computed once at static initialization, read-only afterward.

#### 3.6 ANS Fuzzer-Friendly Flag (POTENTIAL ISSUE)

**Location:** `/lib/jxl/enc_ans.cc:49`, `/lib/jxl/enc_ans.cc:1338-1341`

```cpp
namespace {
#if (!JXL_IS_DEBUG_BUILD)
constexpr
#endif
    bool ans_fuzzer_friendly_ = false;

// ...

void SetANSFuzzerFriendly(bool ans_fuzzer_friendly) {
#if JXL_IS_DEBUG_BUILD  // Guard against accidental / malicious changes.
  ans_fuzzer_friendly_ = ans_fuzzer_friendly;
#endif
}
```

**Analysis:** This is a **potential thread-safety issue** in DEBUG builds only:
- In release builds: `constexpr bool` - completely safe
- In debug builds: Non-atomic write from `SetANSFuzzerFriendly()`

**Severity:** Low - Only affects debug builds and is explicitly documented as "Not thread-safe" in `/lib/jxl/enc_ans.h:157`.

**Mitigation:** Documented in code comment at `/tools/djxl_fuzzer_corpus.cc:414`:
> "The ans_fuzzer_friendly setting is not thread safe and therefore done in [single-threaded context]"

#### 3.7 Butteraugli Temp Image Lock (SAFE)

**Location:** `/lib/jxl/butteraugli/butteraugli.h:202`

```cpp
mutable std::atomic_flag temp_in_use_ = ATOMIC_FLAG_INIT;
```

**Analysis:** Proper atomic flag for synchronizing access to temporary buffer.

---

### 4. LCMS2 Color Transform Thread Safety

**Location:** `/lib/jxl/cms/jxl_cms.cc:1298-1301`

```cpp
// Use cmsFLAGS_NOCACHE to disable the 1-pixel cache and make calling
// cmsDoTransform() thread-safe.
const uint32_t flags = cmsFLAGS_NOCACHE | cmsFLAGS_BLACKPOINTCOMPENSATION |
                       cmsFLAGS_HIGHRESPRECALC;
```

**Analysis:** The library explicitly uses `cmsFLAGS_NOCACHE` to ensure thread-safe color transforms. This is the correct approach for multi-threaded usage.

---

### 5. Callback Thread Safety

#### Image Output Callbacks

**Location:** `/lib/include/jxl/decode.h:1024-1025`

Documentation explicitly states:
> "The callback may be called simultaneously by different threads when using a threaded parallel runner, on different pixels."

**User Responsibility:** Callback implementations must be thread-safe.

#### Debug Image Callbacks (Encoder)

**Location:** `/lib/include/jxl/encode.h:1551-1552`

Same threading model as decoder callbacks.

---

### 6. Internal ThreadPool Constraints

**Location:** `/lib/jxl/base/data_parallel.h:45`

```cpp
// Not thread-safe - no two calls to Run may overlap.
```

The internal `ThreadPool::Run()` method is not designed for concurrent invocation on the same pool instance.

---

## Identified Thread Safety Issues

### Issue 1: ANS Fuzzer-Friendly Global State (Debug Builds Only)

**Severity:** Low
**Affected Code:** `/lib/jxl/enc_ans.cc`
**Condition:** Only in `JXL_IS_DEBUG_BUILD` configurations
**Impact:** Potential data race if `SetANSFuzzerFriendly()` is called while encoding is in progress

**Mitigation:**
- Only call `SetANSFuzzerFriendly()` before any encoding operations
- In production builds, the variable is `constexpr` and safe

### Issue 2: Single-Instance Parallel Runner Constraint

**Severity:** Medium (Design Constraint, Not Bug)
**Affected Code:** All parallel runners
**Impact:** Re-entering a parallel runner will fail with `JXL_PARALLEL_RET_RUNNER_ERROR`

**Mitigation:**
- Create separate parallel runner instances for concurrent encoding/decoding operations
- Or use a single parallel runner sequentially across different codec instances

---

## Recommended Mitigations for Safe Multi-threaded Usage

### For Library Users

1. **Use separate instances per thread:**
   ```c
   // Thread 1
   JxlDecoder* dec1 = JxlDecoderCreate(NULL);
   void* runner1 = JxlThreadParallelRunnerCreate(NULL, num_threads);

   // Thread 2
   JxlDecoder* dec2 = JxlDecoderCreate(NULL);
   void* runner2 = JxlThreadParallelRunnerCreate(NULL, num_threads);
   ```

2. **Do not share decoder/encoder instances across threads without external synchronization**

3. **Do not call `SetANSFuzzerFriendly()` in debug builds during encoding operations**

4. **Ensure image output callbacks are thread-safe** when using parallel runners

### For Upstream Improvements (Not Critical)

1. **Consider making `ans_fuzzer_friendly_` atomic** in debug builds for consistency, though this is not necessary for production use.

2. **Add explicit thread-safety documentation** to the main API headers (decode.h, encode.h) stating:
   - Single instance = single-thread access pattern
   - Multiple instances = safe for multi-threaded use

---

## Conclusion

The libjxl library exhibits good thread-safety design for its intended use case. The key constraint is that individual codec instances and parallel runner instances should not be shared across concurrent operations. When following this pattern, the library is safe for multi-threaded applications.

**No upstream patches are needed** for production usage. The identified global state issues are either:
1. Already thread-safe (using atomics or thread-local storage)
2. Only present in debug builds with documented constraints
3. Read-only after initialization

**Thread Safety Rating: GOOD** - Suitable for multi-threaded applications when following the documented constraints.

---

## References

- Source analyzed: libjxl main branch (cloned 2026-01-29)
- Repository: https://github.com/libjxl/libjxl
- Key files examined:
  - `/lib/include/jxl/decode.h`
  - `/lib/include/jxl/encode.h`
  - `/lib/include/jxl/parallel_runner.h`
  - `/lib/include/jxl/thread_parallel_runner.h`
  - `/lib/threads/thread_parallel_runner_internal.h`
  - `/lib/threads/thread_parallel_runner_internal.cc`
  - `/lib/threads/resizable_parallel_runner.cc`
  - `/lib/jxl/decode.cc`
  - `/lib/jxl/encode.cc`
  - `/lib/jxl/cms/jxl_cms.cc`
  - `/lib/jxl/enc_ans.cc`
  - `/lib/jxl/base/data_parallel.h`
  - `/lib/jxl/memory_manager_internal.cc`
