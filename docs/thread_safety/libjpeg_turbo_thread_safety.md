# libjpeg-turbo Thread Safety Analysis

**Library Version Analyzed:** 3.1.1
**Source:** https://github.com/chearon/libjpeg-turbo (Zig-wrapped version)
**Analysis Date:** 2026-01-29

## Executive Summary

libjpeg-turbo is **conditionally thread-safe** when used correctly. The library can be used safely in multi-threaded applications provided that:

1. Each thread uses its **own separate JPEG compression/decompression instance** (handle)
2. No JPEG object is shared between threads
3. Applications are aware of **global error string state** in the TurboJPEG API that may cause data races

The library does NOT contain internal mutexes or synchronization primitives. Thread safety is achieved through instance isolation rather than internal locking.

## Identified Thread Safety Issues

### 1. Global Error String (`errStr`) - TurboJPEG API Only

**Location:** `/src/turbojpeg.c`, line 60

```c
static THREAD_LOCAL char errStr[JMSG_LENGTH_MAX] = "No error";
```

**Issue Details:**
- The global error string uses `THREAD_LOCAL` storage (defined as `__thread` on POSIX systems)
- While this provides per-thread isolation for the error string itself, there are macros like `THROWG` that write to this global without strict handle binding
- The `tjTransform()` function and other functions that don't take a handle parameter use `THROWG`, which accesses the global `errStr`
- Two threads encountering fatal errors simultaneously could cause undefined behavior if one thread reads `errStr` while another writes to it

**Severity:** Medium - Only affects error handling paths in the TurboJPEG API

**Mitigation:**
- When using TurboJPEG API, use `tj3GetErrorStr(handle)` instead of `tjGetErrorStr()` to retrieve instance-specific errors
- Handle errors immediately after each API call before calling any other TurboJPEG functions

### 2. SIMD Dispatch Initialization (Fixed in 3.1.1)

**Location:** `/simd/jsimd.c`, function `init_simd()`

**Historical Issue:**
In versions prior to 2.1.5, SIMD support was stored in a global variable, causing race conditions when `jpeg_start_*compress()` was called simultaneously from multiple threads.

**Current Status (3.1.1):**
The SIMD support state is now stored **per-instance** in the master struct:

```c
// From jpegint.h, lines 101-103
struct jpeg_comp_master {
    // ...
    unsigned int simd_support;
    unsigned int simd_huffman;
};
```

The `init_simd()` function now reads/writes these values from the cinfo struct:

```c
// From simd/jsimd.c, lines 62-64
unsigned int simd_support = cinfo->is_decompressor ?
                            ((j_decompress_ptr)cinfo)->master->simd_support :
                            ((j_compress_ptr)cinfo)->master->simd_support;
```

**Severity:** Resolved in version 3.1.1

### 3. setjmp/longjmp Error Handling

**Location:** Throughout the codebase, particularly in `/src/turbojpeg.c` and `/src/jerror.c`

**Issue Details:**
- The library uses `setjmp`/`longjmp` for error recovery
- The `jmp_buf` is stored in each instance's error manager (`my_error_mgr.setjmp_buffer`)
- This is thread-safe as long as each thread has its own instance

```c
// From turbojpeg.c, lines 62-67
struct my_error_mgr {
  struct jpeg_error_mgr pub;
  jmp_buf setjmp_buffer;        // Per-instance jmp_buf
  void (*emit_message) (j_common_ptr, int);
  boolean warning, stopOnWarning;
};
```

**Severity:** Low - Safe when instances are not shared between threads

### 4. Static Const Tables (Thread-Safe)

**Locations:**
- `/src/jerror.c`: `jpeg_std_message_table[]`
- `/src/turbojpeg.c`: `sf[]`, `pf2cs[]`, `cs2pf[]`, `xformtypes[]`
- `/src/jmemmgr.c`: `first_pool_slop[]`, `extra_pool_slop[]`

**Status:** These are all `static const` and read-only, posing no thread safety concerns.

### 5. Environment Variable Reading

**Location:** `/simd/jsimd.c`, `/src/jmemmgr.c`

**Issue Details:**
- The library reads environment variables (`JSIMD_FORCE*`, `JPEGMEM`) during initialization
- `getenv()` is generally thread-safe on modern systems, but the timing of reads could cause different threads to see different configurations if environment variables are modified at runtime

**Severity:** Very Low - Environment variables should be set before multi-threaded operation begins

## Code Locations of Concern

| File | Lines | Issue | Severity |
|------|-------|-------|----------|
| `src/turbojpeg.c` | 60 | Global `errStr` with `THREAD_LOCAL` | Medium |
| `src/turbojpeg.c` | 228-265 | `THROWG` macro writes to global `errStr` | Medium |
| `simd/jsimd.c` | 56-110 | `init_simd()` - per-instance (fixed) | Resolved |
| `src/jerror.c` | 66-76 | `error_exit()` calls `exit()` - process-wide | Low |

## Memory Management Thread Safety

**Location:** `/src/jmemmgr.c`

The memory manager is **instance-scoped**:
- Each JPEG object gets its own memory manager instance via `jinit_memory_mgr()`
- Memory pools are stored in the `my_memory_mgr` struct, which is allocated per-instance
- No global memory pools or shared state

```c
// From jmemmgr.c, lines 123-145
typedef struct {
  struct jpeg_memory_mgr pub;
  small_pool_ptr small_list[JPOOL_NUMPOOLS];  // Per-instance
  large_pool_ptr large_list[JPOOL_NUMPOOLS];  // Per-instance
  // ...
} my_memory_mgr;
```

## Decoder/Encoder Context Creation/Destruction Safety

### Creation (Thread-Safe)

Functions `jpeg_CreateCompress()` and `jpeg_CreateDecompress()` are safe to call from multiple threads simultaneously because:
- They allocate new memory for each instance
- They initialize the instance's own memory manager
- No global state is modified (SIMD state is now per-instance)

### Destruction (Thread-Safe with Caveats)

Functions `jpeg_destroy_compress()` and `jpeg_destroy_decompress()` are safe to call from multiple threads when:
- Each thread destroys only its own instance
- The instance is not being used by another thread

## Recommended Mitigations

### For Application Developers

1. **One instance per thread**: Create a separate `tjhandle` or `jpeg_compress_struct`/`jpeg_decompress_struct` for each thread

2. **Initialize early**: Create JPEG instances before spawning worker threads if possible, to ensure SIMD detection completes without contention

3. **Use instance-specific error handling**:
   ```c
   // Prefer this:
   char *err = tj3GetErrorStr(handle);

   // Over this (uses global state):
   char *err = tjGetErrorStr();
   ```

4. **Thread-local instances**: Use thread-local storage for JPEG handles if threads are long-lived:
   ```c
   static __thread tjhandle tls_handle = NULL;

   tjhandle get_thread_handle(void) {
       if (!tls_handle) {
           tls_handle = tj3Init(TJINIT_DECOMPRESS);
       }
       return tls_handle;
   }
   ```

5. **Error handling**: Check for errors immediately after each API call, before any other thread might trigger an error

### For Zig Integration

When wrapping libjpeg-turbo in Zig:

1. Store JPEG handles in thread-local state or ensure single-threaded access via Zig's `@atomicRmw` or `std.Thread.Mutex`

2. Consider wrapping the TurboJPEG error retrieval to capture errors immediately:
   ```zig
   fn decodeJpeg(data: []const u8) !Image {
       const handle = tj3Init(TJINIT_DECOMPRESS);
       defer tj3Destroy(handle);

       if (tj3DecompressHeader(handle, data.ptr, data.len) < 0) {
           // Capture error immediately while still in same thread context
           const err_str = tj3GetErrorStr(handle);
           return error.JpegDecodeError;
       }
       // ...
   }
   ```

## Upstream Patch Considerations

### Not Required

The current version (3.1.1) has addressed the major SIMD initialization race condition. The remaining issues with `errStr` are:

1. **Mitigated by `THREAD_LOCAL`**: The `errStr` variable uses thread-local storage, providing per-thread isolation
2. **Architectural limitation**: Fully fixing this would require API changes to functions like `tjBufSize()` that don't take handles

### Potential Improvements (Optional)

If contributing upstream:

1. Add a `tj3GetLastError()` function that takes a handle and always returns instance-specific errors
2. Deprecate functions that use global error state
3. Add explicit thread-safety documentation to the public headers

## Version History of Thread Safety Fixes

| Version | Fix |
|---------|-----|
| 2.1.5 | Attempted to make SIMD support variable thread-local (had issues) |
| 3.0.0 | Introduced `tj3*` API with better instance isolation |
| 3.1.0+ | SIMD support stored per-instance in master struct |

## Testing Recommendations

To verify thread safety in your application:

1. Run with ThreadSanitizer (TSan):
   ```bash
   CFLAGS="-fsanitize=thread" zig build
   ```

2. Stress test with multiple threads encoding/decoding simultaneously

3. Test error paths by intentionally triggering errors from multiple threads

## References

- [GitHub Issue #396: Thread safety with TurboJPEG API](https://github.com/libjpeg-turbo/libjpeg-turbo/issues/396)
- [GitHub Issue #446: Thread safety with SIMD dispatch](https://github.com/libjpeg-turbo/libjpeg-turbo/issues/446)
- [GitHub Issue #65: Multiple threads discussion](https://github.com/libjpeg-turbo/libjpeg-turbo/issues/65)
- [SourceForge Thread: TurboJPEG API thread-safety](https://sourceforge.net/p/libjpeg-turbo/mailman/message/30335490/)

## Conclusion

libjpeg-turbo 3.1.1 is suitable for multi-threaded use with the following caveats:

- **Safe**: Using separate instances per thread, standard libjpeg API
- **Mostly Safe**: Using separate instances per thread, TurboJPEG API (watch for global error string)
- **Unsafe**: Sharing instances between threads, modifying environment variables after thread creation

The library's thread safety model is "instance isolation" rather than "internal synchronization," which is a common and efficient approach for codec libraries.
