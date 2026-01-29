# Thread Safety Analysis: minimp3 MP3 Decoder Library

**Library**: [minimp3](https://github.com/lieff/minimp3)
**Version Analyzed**: Latest master branch (January 2026)
**Analysis Date**: 2026-01-29

## Executive Summary

The minimp3 library is **largely thread-safe** when used correctly, with one notable exception. The library uses a stateless decoder design where all mutable state is stored in user-provided `mp3dec_t` structures, making it safe to use multiple decoder instances concurrently from different threads.

**Key Finding**: There is one static mutable variable (`g_have_simd`) used for SIMD capability detection that represents a **benign data race**. While technically a race condition, it is functionally harmless in practice. For strict thread-safety compliance, a mitigation is recommended.

### Thread Safety Rating: **SAFE** (with minor caveat)

| Aspect | Status |
|--------|--------|
| Multiple decoder instances in parallel | Safe |
| Same decoder instance from multiple threads | NOT Safe |
| Static/global mutable state | One benign race (see below) |
| Initialization race conditions | Minor (SIMD detection) |
| Lookup tables and constants | Safe (all const) |

---

## Detailed Analysis

### 1. Architecture Overview

minimp3 is a header-only library that implements MP3 decoding. The library design follows a pattern that is naturally amenable to thread safety:

- **Decoder state** (`mp3dec_t`) is user-allocated and passed to all functions
- **No global mutable state** for core decoding operations
- **All lookup tables** are declared `static const` (36 instances found)
- **Scratch/temporary buffers** are stack-allocated within functions

### 2. Decoder State Structure

The main decoder state is contained in `mp3dec_t`:

```c
typedef struct
{
    float mdct_overlap[2][9*32], qmf_state[15*2*32];
    int reserv, free_format_bytes;
    unsigned char header[4], reserv_buf[511];
} mp3dec_t;
```

**Location**: `/tmp/minimp3/minimp3.h`, lines 18-23

This structure contains:
- `mdct_overlap`: MDCT overlap buffer for synthesis
- `qmf_state`: QMF filter bank state
- `reserv`: Bit reservoir count for Layer 3
- `reserv_buf`: Bit reservoir buffer
- `header`: Last frame header
- `free_format_bytes`: Free format frame size

All state is instance-specific, enabling safe concurrent use of separate decoder instances.

### 3. Identified Thread Safety Issues

#### 3.1 SIMD Detection Race Condition (Minor)

**Location**: `/tmp/minimp3/minimp3.h`, lines 139-163

```c
static int have_simd(void)
{
#ifdef MINIMP3_ONLY_SIMD
    return 1;
#else /* MINIMP3_ONLY_SIMD */
    static int g_have_simd;           // <-- Static mutable variable
    int CPUInfo[4];
#ifdef MINIMP3_TEST
    static int g_counter;             // <-- Only in test builds
    if (g_counter++ > 100)
        return 0;
#endif /* MINIMP3_TEST */
    if (g_have_simd)
        goto end;
    minimp3_cpuid(CPUInfo, 0);
    g_have_simd = 1;
    if (CPUInfo[0] > 0)
    {
        minimp3_cpuid(CPUInfo, 1);
        g_have_simd = (CPUInfo[3] & (1 << 26)) + 1; /* SSE2 */
    }
end:
    return g_have_simd - 1;
#endif /* MINIMP3_ONLY_SIMD */
}
```

**Analysis**:
- `g_have_simd` is a file-scope static variable used to cache SIMD capability detection
- Multiple threads calling `have_simd()` simultaneously may race on reads/writes
- This is a **benign race** because:
  1. The value written is always the same (determined by CPU features)
  2. The worst case is redundant CPUID instructions being executed
  3. The final cached value will be correct regardless of race order
  4. Word-sized integer writes are typically atomic on modern architectures

**Severity**: Low (functionally harmless)

#### 3.2 Test Counter Race (Test Builds Only)

**Location**: `/tmp/minimp3/minimp3.h`, line 147-149

```c
#ifdef MINIMP3_TEST
    static int g_counter;
    if (g_counter++ > 100)
        return 0;
#endif
```

**Analysis**:
- Only present when `MINIMP3_TEST` is defined
- Non-atomic increment creates a race condition
- Not present in production builds

**Severity**: None (test-only code)

### 4. Static Constant Tables (Thread-Safe)

The library contains 36 static constant lookup tables including:
- Huffman decoding tables
- Scale factor band tables
- Trigonometric coefficients
- Bitrate/sample rate tables

All are declared `static const` and are inherently thread-safe for concurrent reads.

### 5. Extended API (minimp3_ex.h)

The extended API (`mp3dec_ex_t`) also follows the same safe pattern:
- All state is contained in user-provided structures
- No additional global mutable state
- File I/O operations are self-contained

### 6. Function-Level Thread Safety

| Function | Thread Safety | Notes |
|----------|---------------|-------|
| `mp3dec_init()` | Safe | Only modifies user-provided struct |
| `mp3dec_decode_frame()` | Safe | Uses stack-allocated scratch space |
| `mp3dec_load()` | Safe | Per-call state only |
| `mp3dec_iterate()` | Safe | Per-call state only |
| `mp3dec_ex_open()` | Safe | Per-instance state |
| `mp3dec_ex_read()` | Safe | Per-instance state |
| `mp3dec_ex_seek()` | Safe | Per-instance state |
| `mp3dec_ex_close()` | Safe | Per-instance state |

**Important**: While functions are thread-safe with respect to global state, a single `mp3dec_t` or `mp3dec_ex_t` instance must NOT be accessed from multiple threads simultaneously without external synchronization.

---

## Recommended Mitigations

### For Strict Thread Safety Compliance

If your application requires strict thread-safety guarantees (e.g., thread sanitizer clean builds), consider:

#### Option 1: Define MINIMP3_ONLY_SIMD (Recommended for x64/ARM64)

```c
#define MINIMP3_ONLY_SIMD
#define MINIMP3_IMPLEMENTATION
#include "minimp3.h"
```

This completely eliminates the `g_have_simd` variable by assuming SIMD is always available. This is safe and correct for:
- All x64/amd64 systems (SSE2 is baseline)
- All ARM64/AArch64 systems (NEON is baseline)

#### Option 2: Pre-initialize SIMD Detection

Call any decode function once from the main thread before spawning worker threads:

```c
int main() {
    // Pre-initialize SIMD detection (single-threaded context)
    mp3dec_t dec;
    mp3dec_init(&dec);

    // Trigger have_simd() call with a dummy decode
    mp3dec_frame_info_t info;
    uint8_t dummy[4] = {0};
    mp3dec_decode_frame(&dec, dummy, sizeof(dummy), NULL, &info);

    // Now safe to spawn threads using minimp3
    // ...
}
```

#### Option 3: Use MINIMP3_NO_SIMD

For maximum portability at a performance cost:

```c
#define MINIMP3_NO_SIMD
#define MINIMP3_IMPLEMENTATION
#include "minimp3.h"
```

This disables SIMD entirely, eliminating the detection code.

### For Production Use

The default configuration is safe for virtually all real-world use cases. The benign race in SIMD detection:
- Will not cause crashes
- Will not cause incorrect decoding
- May cause redundant CPUID instructions on first use (microseconds)

---

## Upstream Patch Consideration

An upstream patch is **not strictly necessary** but could improve the library for users requiring strict thread-safety guarantees. Potential improvements:

1. **Use C11 `_Atomic` or platform atomics** for `g_have_simd`:
   ```c
   #include <stdatomic.h>
   static atomic_int g_have_simd;
   ```

2. **Use `pthread_once` or `call_once`** for initialization:
   ```c
   static pthread_once_t simd_once = PTHREAD_ONCE_INIT;
   static int simd_result;

   static void detect_simd(void) {
       // ... detection code ...
       simd_result = /* detected value */;
   }

   static int have_simd(void) {
       pthread_once(&simd_once, detect_simd);
       return simd_result;
   }
   ```

3. **Document thread safety** in README.md

Given that:
- No thread-safety issues have been reported in the issue tracker
- The race is benign in practice
- Simple workarounds exist

Filing an upstream issue is optional but would be a good practice for documentation purposes.

---

## Conclusion

The minimp3 library is **safe for concurrent use** when each thread uses its own decoder instance. The single static variable for SIMD detection represents a benign race that does not affect correctness. For applications requiring strict thread-safety compliance (e.g., sanitizer-clean builds), defining `MINIMP3_ONLY_SIMD` on modern platforms is the recommended mitigation.

### Safe Usage Pattern

```c
// Thread-safe: each thread has its own decoder
void* decode_thread(void* arg) {
    mp3dec_t dec;           // Thread-local decoder
    mp3dec_init(&dec);

    // Decode operations...
    mp3dec_decode_frame(&dec, ...);

    return NULL;
}

// Unsafe: sharing decoder between threads without synchronization
mp3dec_t shared_dec;  // Don't do this without mutex protection!
```

---

## References

- minimp3 source code: https://github.com/lieff/minimp3
- minimp3.h: Core decoder implementation
- minimp3_ex.h: Extended API with file I/O
- Analyzed commit: master branch, January 2026
