# Highway SIMD Library Thread Safety Analysis

**Library Version:** 1.2.0+ (current as of analysis: 1.3.0)
**Repository:** https://github.com/google/highway
**Analysis Date:** 2026-01-29
**Analyzed By:** Thread safety audit for validate project

---

## Executive Summary

The Google Highway SIMD library is **generally thread-safe for typical usage patterns**, but has several important caveats:

1. **The core dynamic dispatch mechanism uses `std::atomic` for the chosen target mask**, making concurrent reads safe during normal operation.

2. **RISC-V (RVV) target is explicitly documented as NOT thread-safe** due to limitations when `HWY_NO_LIBCXX` is defined.

3. **Two global non-atomic variables exist** (`supported_targets_for_test_` and `supported_mask_`) that are intended to be modified only from a single thread before parallel execution begins.

4. **CPU feature detection (CPUID/getauxval) is inherently safe** but may be called redundantly by multiple threads during the first `HWY_DYNAMIC_DISPATCH` call.

5. **Static initialization uses thread-safe patterns** (C++11 magic statics and `std::atomic`).

**Overall Assessment:** Safe for production use in multi-threaded applications when following the documented usage patterns. No upstream patches are required for standard use cases.

---

## Detailed Analysis

### 1. Global Variables and Static State

#### 1.1 Critical Global Variables in `targets.cc`

```cpp
// Line 777
static int64_t supported_targets_for_test_ = 0;

// Line 780
static int64_t supported_mask_ = LimitsMax<int64_t>();
```

**Thread Safety Status:** NOT ATOMIC

**Risk Assessment:** LOW for production code

**Rationale:**
- `supported_targets_for_test_` is explicitly documented as "Only written to from a single thread before the test starts" (line 776)
- `supported_mask_` is modified only by `DisableTargets()`, which is intended for configuration before multi-threaded execution
- Both are read by `SupportedTargets()` without synchronization

**Mitigations:**
- Call `DisableTargets()` and `SetSupportedTargetsForTest()` only from the main thread before spawning worker threads
- These functions are typically only used during initialization or testing

#### 1.2 Chosen Target Singleton

```cpp
// targets.cc, line 816-819
HWY_DLLEXPORT ChosenTarget& GetChosenTarget() {
  static ChosenTarget chosen_target;
  return chosen_target;
}
```

**Thread Safety Status:** SAFE (C++11 magic statics)

**Rationale:**
- C++11 guarantees thread-safe initialization of function-local static variables
- The `ChosenTarget` singleton is initialized exactly once, even under concurrent access

#### 1.3 ChosenTarget Mask Storage

```cpp
// targets.h, lines 369-380
#if defined(HWY_NO_LIBCXX)
  int64_t LoadMask() const { return mask_; }
  void StoreMask(int64_t mask) { mask_ = mask; }
  int64_t mask_{1};
#else
  int64_t LoadMask() const { return mask_.load(); }
  void StoreMask(int64_t mask) { mask_.store(mask); }
  std::atomic<int64_t> mask_{1};
#endif
```

**Thread Safety Status:** CONDITIONALLY SAFE

**Key Finding:** The official comment in targets.h states:
> "thread-safe except on RVV" (line 340)

**Rationale:**
- When `HWY_NO_LIBCXX` is NOT defined (standard case): Uses `std::atomic<int64_t>` - fully thread-safe
- When `HWY_NO_LIBCXX` IS defined (embedded/RVV case): Uses plain `int64_t` - NOT thread-safe

---

### 2. CPU Feature Detection and Caching

#### 2.1 Detection Functions

**Location:** `targets.cc`, `DetectTargets()` function (multiple arch-specific versions)

**Thread Safety Status:** SAFE but REDUNDANT

**Rationale:**
- CPU feature detection (CPUID on x86, getauxval on Linux/ARM) reads hardware state
- These operations are inherently thread-safe (read-only hardware queries)
- However, multiple threads calling `SupportedTargets()` simultaneously during first dispatch may redundantly call `DetectTargets()`

**Code Path:**
```cpp
// targets.cc, lines 797-814
HWY_DLLEXPORT int64_t SupportedTargets() {
  int64_t targets = supported_targets_for_test_;
  if (HWY_LIKELY(targets == 0)) {
    targets = DetectTargets();  // May be called redundantly
    GetChosenTarget().Update(targets);
  }
  targets &= supported_mask_;
  return targets == 0 ? HWY_STATIC_TARGET : targets;
}
```

#### 2.2 CPUID Implementation

**Location:** `hwy/x86_cpuid.h`

```cpp
static inline void Cpuid(const uint32_t level, const uint32_t count,
                         uint32_t* HWY_RESTRICT abcd)
```

**Thread Safety Status:** SAFE

**Rationale:**
- Pure function with no side effects
- Reads CPU registers which are consistent across threads
- No global state modified

---

### 3. Dynamic Dispatch Mechanism

#### 3.1 First Call Path (FunctionCache)

**Location:** `highway.h`, `FunctionCache` class

```cpp
template <const FuncPtr* table>
static RetType ChooseAndCall(Args... args) {
  ChosenTarget& chosen_target = GetChosenTarget();
  chosen_target.Update(SupportedTargets());  // Atomic store
  return (table[chosen_target.GetIndex()])(args...);  // Atomic load
}
```

**Thread Safety Status:** SAFE (with atomic mask)

**Rationale:**
- `Update()` performs atomic store
- `GetIndex()` performs atomic load
- Table pointers are compile-time constants
- Race condition benign: multiple threads may both "win" the race to initialize, but they store the same value

#### 3.2 Subsequent Calls

**Location:** `highway.h`, `HWY_DYNAMIC_DISPATCH` macro

```cpp
#define HWY_DYNAMIC_POINTER(FUNC_NAME) \
  (HWY_DISPATCH_TABLE(FUNC_NAME)[hwy::GetChosenTarget().GetIndex()])
```

**Thread Safety Status:** SAFE

**Rationale:**
- `GetIndex()` performs atomic load of mask
- Table access is read-only after initialization
- Function pointer dereference is safe

---

### 4. Static Initialization Concerns

#### 4.1 Function Tables (HWY_EXPORT)

```cpp
static decltype(&HWY_STATIC_DISPATCH(FUNC_NAME)) const HWY_DISPATCH_TABLE(
    FUNC_NAME)[static_cast<size_t>(HWY_MAX_DYNAMIC_TARGETS + 2)] = {
  &decltype(...)::template ChooseAndCall<...>,
  HWY_CHOOSE_TARGET_LIST(FUNC_NAME),
  HWY_CHOOSE_FALLBACK(FUNC_NAME),
};
```

**Thread Safety Status:** SAFE

**Rationale:**
- Static arrays of function pointers
- Initialized at load time with constant values
- No dynamic initialization order issues

#### 4.2 Abort/Warn Handlers

**Location:** `abort.cc`

```cpp
std::atomic<WarnFunc>& AtomicWarnFunc() {
  static std::atomic<WarnFunc> func;
  return func;
}

std::atomic<AbortFunc>& AtomicAbortFunc() {
  static std::atomic<AbortFunc> func;
  return func;
}
```

**Thread Safety Status:** SAFE

**Rationale:**
- Uses `std::atomic` for handler pointers
- Magic static initialization is thread-safe
- `SetWarnFunc()`/`SetAbortFunc()` use `exchange()` for atomic swap

---

### 5. Other Thread Safety Considerations

#### 5.1 Aligned Allocator

**Location:** `aligned_allocator.cc`

```cpp
size_t NextAlignedOffset() {
  static std::atomic<size_t> next{0};
  // ...
  const size_t group = next.fetch_add(1, std::memory_order_relaxed) % kGroups;
  // ...
}
```

**Thread Safety Status:** SAFE

**Rationale:**
- Uses `std::atomic` with `memory_order_relaxed`
- Provides anti-aliasing offset rotation
- Thread-safe for concurrent allocations

#### 5.2 Profiler (When Enabled)

**Location:** `profiler.h`, `StringTable` class

**Thread Safety Status:** SAFE

**Rationale:**
- Uses `std::atomic` with proper memory ordering
- Compare-and-swap for concurrent name registration
- Lock-free design

#### 5.3 Thread Pool

**Location:** `contrib/thread_pool/thread_pool.h`

**Thread Safety Status:** INTERNAL SAFETY ONLY

**Note from documentation:**
> "Not thread-safe - concurrent parallel-for in the same ThreadPool are forbidden unless NumWorkers() == 1 or end <= begin + 1"

---

## Identified Thread Safety Issues

### Issue 1: Non-Atomic Global Variables

**Severity:** LOW
**Location:** `targets.cc`, lines 777 and 780

**Description:**
`supported_targets_for_test_` and `supported_mask_` are plain `int64_t` variables accessed without synchronization.

**Impact:**
Data race if `DisableTargets()` or `SetSupportedTargetsForTest()` called concurrently with `SupportedTargets()`.

**Recommendation:**
Document clearly that these must only be called from main thread before spawning workers. Current documentation at line 776 partially covers this.

### Issue 2: RVV Target Not Thread-Safe

**Severity:** MEDIUM (for RVV users)
**Location:** `targets.h`, lines 370-374

**Description:**
When `HWY_NO_LIBCXX` is defined (common in embedded/RISC-V contexts), the mask uses plain `int64_t` instead of `std::atomic<int64_t>`.

**Impact:**
Data race on `mask_` member if multiple threads perform first dispatch simultaneously.

**Recommendation:**
- For RVV targets, ensure `HWY_DYNAMIC_DISPATCH` is called once from main thread before parallel execution
- Alternative: Define `HWY_NO_LIBCXX` only when absolutely necessary

### Issue 3: Redundant CPU Detection

**Severity:** VERY LOW (performance, not correctness)
**Location:** `targets.cc`, `SupportedTargets()`

**Description:**
Multiple threads may call `DetectTargets()` simultaneously during initialization.

**Impact:**
Redundant CPUID/getauxval calls, but no correctness issue.

**Recommendation:**
Pre-warm the dispatch by calling `hwy::GetChosenTarget().Update(hwy::SupportedTargets())` from main thread before spawning workers.

---

## Specific Code Locations of Concern

| File | Line(s) | Concern | Severity |
|------|---------|---------|----------|
| `targets.cc` | 777-780 | Non-atomic globals | LOW |
| `targets.h` | 370-374 | Non-atomic mask (HWY_NO_LIBCXX) | MEDIUM |
| `targets.cc` | 797-809 | Redundant detection race | VERY LOW |
| `base.h` | 327-334 | GetWarnFunc/GetAbortFunc deprecated | LOW |

---

## Recommended Mitigations

### For This Project (validate)

1. **Pre-initialize dispatch at startup:**
   ```cpp
   // In main() or module initialization, before any parallel work:
   #include "hwy/highway.h"
   hwy::GetChosenTarget().Update(hwy::SupportedTargets());
   ```

2. **Avoid runtime target changes:**
   - Do not call `DisableTargets()` after parallel execution begins
   - Do not use `SetSupportedTargetsForTest()` in production code

3. **If using RVV:**
   - Ensure initialization happens single-threaded
   - Consider not defining `HWY_NO_LIBCXX` if C++ standard library is available

### General Best Practices

1. **Initialization pattern:**
   ```cpp
   int main() {
     // Force CPU detection and dispatch initialization
     (void)hwy::SupportedTargets();

     // Now safe to spawn threads that use Highway
     // ...
   }
   ```

2. **For library authors:**
   - Document that first use of `HWY_DYNAMIC_DISPATCH` should occur single-threaded
   - Or explicitly initialize in library init function

---

## Whether Upstream Patches Are Needed

**Verdict: NO upstream patches required for standard use cases.**

**Rationale:**
1. The library is documented as thread-safe (except RVV with `HWY_NO_LIBCXX`)
2. The non-atomic globals are intentionally designed for single-threaded configuration
3. The atomic implementation for the mask is correct and efficient
4. The documented usage patterns avoid all identified issues

**Potential Improvements (optional upstream suggestions):**
1. Consider making `supported_mask_` atomic for defense-in-depth
2. Add explicit documentation about pre-initialization in multi-threaded contexts
3. Consider a `HWY_INIT()` macro that makes initialization intent explicit

---

## References

- Highway README: https://github.com/google/highway/blob/master/README.md
- Highway FAQ: `g3doc/faq.md`
- Highway Quick Reference: `g3doc/quick_reference.md`
- Source files analyzed:
  - `hwy/targets.h` - ChosenTarget struct, thread safety comment
  - `hwy/targets.cc` - CPU detection, global variables
  - `hwy/highway.h` - Dynamic dispatch macros
  - `hwy/base.h` - Abort handlers
  - `hwy/abort.cc` - Atomic handler implementation
  - `hwy/aligned_allocator.cc` - Thread-safe allocator
  - `hwy/x86_cpuid.h` - CPUID wrapper
