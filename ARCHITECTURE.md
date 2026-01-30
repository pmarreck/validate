# Architecture

## Hexagonal Architecture (Ports and Adapters)

**CRITICAL DESIGN PRINCIPLE**: All clients MUST communicate with the Zig core exclusively through the C FFI layer. This includes:

- The C CLI (`cli/main.c`)
- Future Swift GUI
- Python/Rust/Node bindings
- The sibling project `entropy_shield`
- Any other consumer

```
┌─────────────────────────────────────────────────────────────────┐
│                         CLIENTS                                 │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────────────┐    │
│  │  C CLI  │  │  Swift  │  │ Python  │  │ entropy_shield  │    │
│  │         │  │   GUI   │  │ binding │  │   (Zig->C->Zig) │    │
│  └────┬────┘  └────┬────┘  └────┬────┘  └────────┬────────┘    │
│       │            │            │                │              │
└───────┼────────────┼────────────┼────────────────┼──────────────┘
        │            │            │                │
        ▼            ▼            ▼                ▼
┌─────────────────────────────────────────────────────────────────┐
│                      C FFI BOUNDARY                             │
│                   (ffi/validate_core.h)                         │
│                   (ffi/c_api.zig)                               │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                       ZIG CORE                                  │
│              (src/core/ - all business logic)                   │
│                                                                 │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────┐  │
│  │ format_validation│  │  thread_pool     │  │   validators │  │
│  │                  │  │                  │  │  (jpeg, pdf, │  │
│  │                  │  │                  │  │   video...)  │  │
│  └──────────────────┘  └──────────────────┘  └──────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

### Why This Matters

1. **Everyone eats the same dogfood**: The CLI has no special privileges over external bindings. If the FFI is insufficient, we discover it immediately.

2. **Forces API completeness**: Any functionality the CLI needs must be exposed through FFI, ensuring external consumers have full access.

3. **Clean separation**: I/O concerns (terminal output, file dialogs, progress bars) belong in clients. Business logic (validation, threading, format parsing) belongs in the Zig core.

4. **Testability**: The FFI boundary is a natural seam for testing.

### Current Violation (TO BE FIXED)

The C CLI currently imports `path_validation` directly from Zig, bypassing the FFI. This must be rectified by exposing proper batch validation through the C API.

---

## C FFI API Design

### Core Types

```c
// Error codes - two classes
typedef enum {
    ES_OK = 0,

    // === HALT ERRORS ===
    // These stop batch processing immediately
    ES_ERR_OUT_OF_MEMORY     = -1,
    ES_ERR_DISK_FULL         = -2,
    ES_ERR_TOO_MANY_THREADS  = -3,
    ES_ERR_INVALID_ARGUMENT  = -4,
    ES_ERR_INTERNAL          = -5,

    // === CONTINUE ERRORS ===
    // Per-file errors reported through callback, batch continues
    // (permission denied, file not found, validation failures)
    // These are NOT returned from es_validate_batch - they appear
    // in individual es_validation_result_t.is_valid = false
} es_error_t;

// Validation result (caller takes ownership, must call es_free_result)
typedef struct {
    int is_valid;
    int format;                      // es_file_format enum
    int validation_depth;            // structural, full, etc.
    char* error_message;             // NULL if valid, heap-allocated
    char* warning_message;           // NULL if none, heap-allocated
    int circumvented_trivial_protection;
    int validated_via_ffmpeg;
    // ... other fields
} es_validation_result_t;

// Callback for batch validation (called once per file, serialized to one thread)
typedef void (*es_validation_callback)(
    void* context,
    const char* path,
    es_validation_result_t* result,  // CALLER TAKES OWNERSHIP - must call es_free_result()
    double elapsed_seconds
);
```

### API Functions

```c
// Single file validation
// - num_threads: parallelism budget for format-specific work (0 = auto-detect)
// - Returns heap-allocated result, caller must call es_free_result()
es_validation_result_t* es_validate(
    const char* path,
    int num_threads
);

// Batch validation with streaming callback
// - paths: array of file paths
// - count: number of paths
// - num_threads: total parallelism budget (0 = auto-detect)
// - callback: called once per file as validation completes (serialized to one thread)
// - context: opaque pointer passed to callback
// - Returns: ES_OK on completion, or halt error code
es_error_t es_validate_batch(
    const char** paths,
    size_t count,
    int num_threads,
    es_validation_callback callback,
    void* context
);

// Free a validation result (MUST be called for every result received)
void es_free_result(es_validation_result_t* result);

// Get default thread count (CPU cores)
int es_get_default_threads(void);
```

---

## Threading Model

### Parallelism Budget

The `num_threads` parameter represents a **total parallelism budget**:

- Controls how many worker threads are available
- Format-specific validators (PDF, video) can use these workers for internal parallelism
- Setting to 1 makes everything sequential (useful for debugging, determinism)
- Setting to 0 means auto-detect (typically CPU core count)

### Callback Serialization

**Callbacks are serialized to a single thread.** This provides:

1. **Natural backpressure**: If the callback is slow (e.g., slow terminal output), validation throttles to match. Prevents unbounded memory growth.

2. **Simpler caller code**: Callers don't need thread-safe callback implementations.

3. **Ordered output option**: We could optionally guarantee callbacks in submission order.

### Format-Specific Parallelism

Some formats benefit from internal parallelism:

- **PDF**: Embedded images can be validated in parallel
- **Video (MP4/MKV)**: Frame decoding could parallelize (currently sequential)
- **Archives (ZIP)**: Entry validation could parallelize

These validators "borrow" from the thread pool budget rather than creating their own threads, avoiding oversubscription.

---

## Memory Ownership

### Callback Results

When `es_validation_callback` is called:

1. The `result` pointer is **transferred to the caller**
2. Caller **MUST** call `es_free_result(result)` when done
3. This avoids copying overhead for large results
4. Failure to free results will cause memory leaks

Example callback implementation:

```c
void my_callback(void* ctx, const char* path, es_validation_result_t* result, double elapsed) {
    // Use the result
    printf("%s: %s\n", path, result->is_valid ? "OK" : "INVALID");
    if (result->error_message) {
        printf("  Error: %s\n", result->error_message);
    }

    // MUST free when done
    es_free_result(result);
}
```

### String Fields

String fields within `es_validation_result_t` (error_message, warning_message, etc.) are:

- Heap-allocated by the Zig core
- Freed automatically by `es_free_result()`
- May be NULL (check before use)

---

## Integration with entropy_shield

The sibling project `../entropy_shield` will:

1. Call `es_validate()` on individual files before computing parity data
2. Call `es_validate_batch()` from its "validate" button
3. NOT run validation concurrently with its own parity operations

The threading abstraction (`thread_pool.zig`) is designed to be potentially shareable, but for now entropy_shield can copy the implementation if needed.

---

## File Locations

- **C FFI header**: `ffi/validate_core.h`
- **Zig FFI implementation**: `ffi/c_api.zig`
- **Thread pool**: `src/core/thread_pool.zig`
- **Zig core modules**: `src/core/`
- **C CLI**: `cli/main.c`
