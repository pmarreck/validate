# libfdk-aac Thread Safety Analysis

**Version Analyzed:** 2.0.3
**Analysis Date:** 2026-01-29

## Summary

libfdk-aac is **thread-safe when each decoder instance is used by only one thread**. Multiple decoder instances can safely operate in parallel from different threads without synchronization.

## Key Findings

### 1. No Global Mutable State

The library contains **no mutable global or static variables**:

- All `static` variables found are `const` lookup tables (ROM data)
- No mutex/pthread/lock usage anywhere in the codebase
- No thread-local storage (`thread_local`, `__thread`)

Examples of static const data:
- Huffman tables in `aac_rom.cpp`
- Frequency band tables in `sbr_rom.cpp`
- FFT twiddle factors in `FDK_tools_rom.cpp`

### 2. Instance-Based Architecture

The decoder uses an opaque handle pattern:

```c
HANDLE_AACDECODER aacDecoder_Open(TRANSPORT_TYPE transportFmt, UINT nrOfLayers);
void aacDecoder_Close(HANDLE_AACDECODER self);
```

All state is encapsulated in `struct AAC_DECODER_INSTANCE`:
- Bitstream buffers
- Channel info
- SBR/MPS decoder handles
- DRC processing state
- Concealment state

### 3. Memory Allocation

Memory is allocated per-instance via `FDKcalloc()` (wraps standard `calloc`):

```c
// From genericStds.cpp
void *FDKcalloc(const UINT n, const UINT size) {
    return calloc(n, size);
}
```

The `C_ALLOC_MEM` macros generate getter functions that allocate fresh memory:

```c
type *Get##name(int n) {
    return ((type *)FDKcalloc(num, sizeof(type)));
}
```

### 4. No Internal Synchronization

The library provides **no internal locking**. This is intentional - it places the synchronization burden on the caller but avoids lock overhead for single-threaded use.

## Thread Safety Model

| Scenario | Safe? | Notes |
|----------|-------|-------|
| One thread per decoder instance | Yes | Recommended usage |
| Multiple instances, multiple threads | Yes | Each thread owns its decoder |
| Shared instance, multiple threads | **No** | Requires external synchronization |
| Read-only shared config | Yes | Const tables are safe |

## Mitigations for Multi-threaded Use

### Option 1: Thread-Local Decoder (Recommended)

Create one decoder per thread. This is the simplest and most efficient approach:

```c
// Thread-local decoder pool pattern
static _Thread_local HANDLE_AACDECODER tls_decoder = NULL;

HANDLE_AACDECODER get_thread_decoder(void) {
    if (tls_decoder == NULL) {
        tls_decoder = aacDecoder_Open(TT_MP4_RAW, 1);
    }
    return tls_decoder;
}
```

### Option 2: Mutex per Decoder

If you must share a decoder across threads:

```c
typedef struct {
    HANDLE_AACDECODER decoder;
    pthread_mutex_t lock;
} ThreadSafeDecoder;

AAC_DECODER_ERROR decode_frame_safe(ThreadSafeDecoder *tsd, ...) {
    pthread_mutex_lock(&tsd->lock);
    AAC_DECODER_ERROR err = aacDecoder_DecodeFrame(tsd->decoder, ...);
    pthread_mutex_unlock(&tsd->lock);
    return err;
}
```

### Option 3: Decoder Pool

For high-throughput scenarios, use a pool of decoders:

```c
// Pool with N decoders for N concurrent decode operations
HANDLE_AACDECODER decoder_pool[POOL_SIZE];
sem_t pool_semaphore;
```

## Files Examined

- `/libAACdec/src/aacdecoder_lib.cpp` - Main decoder API
- `/libAACdec/src/aacdecoder.h` - Instance structure definition
- `/libAACdec/src/aac_ram.cpp` - Memory allocation
- `/libSYS/src/genericStds.cpp` - System abstraction layer
- `/libSYS/include/genericStds.h` - Memory macros

## Conclusion

libfdk-aac follows a clean instance-based design with no shared mutable state. It is safe for parallel use when each decoder instance is confined to a single thread. For shared-instance scenarios, external synchronization is required.
