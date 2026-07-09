# Architecture

## Hexagonal Architecture (Ports and Adapters)

**CRITICAL DESIGN PRINCIPLE**: All clients MUST communicate with the Zig core exclusively through the C FFI layer. This includes:

- The C CLI (`cli/main.c`)
- Future Swift GUI
- Rust/Node bindings
- The sibling project `entropy_shield`
- Any other consumer

```
┌─────────────────────────────────────────────────────────────────┐
│                         CLIENTS                                 │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────────────┐    │
│  │  C CLI  │  │  Swift  │  │  Rust   │  │ entropy_shield  │    │
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

### Previous Violation (RESOLVED 2026-02-02)

~~The C CLI previously imported `path_validation` directly from Zig, bypassing the FFI.~~ This was resolved by exposing `validate_batch()` through the C API and routing all CLI validation through the FFI boundary.

---

## C FFI API Design
## Verdict Tiers: OK / WARN / FAIL

Every validation produces exactly one of three terminal verdicts. The
distinction is load-bearing — clients (CLI, GUI, future bindings) depend
on the boundary between WARN and OK.

| Verdict | Semantics |
|---|---|
| **OK**   | Canonically valid, spec-compliant. Every byte covered by an integrity check passed; the file matches every applicable specification. |
| **WARN** | "Acceptable deviation": opens/decodes/validates fine in every major real-world tool, but deviates from the applicable specification in some tolerated way. |
| **FAIL** | Actual data corruption: checksum mismatch, truncated structure, content no tool can decode. |

WARN exists because real-world file libraries are full of files that
every consumer tolerates (Adobe InDesign PDFs missing zlib Adler-32
trailers, bzip2-wrapped DMGs, PNM with a single-byte tail truncation,
etc.). If validate emitted plain OK on those, users would lose the
signal that a strict re-export would produce a cleaner file. If
validate FAILed them, users would chase phantom corruption. WARN is
the load-bearing middle.

In code, this boundary is enforced by the `ValidationResult` API:

```zig
ValidationResult.okWithDepth(format, .full)              // → OK
ValidationResult.okWithDepthAndWarning(format, .full, "...") // → WARN
ValidationResult.invalidWithDepth(format, "...", .full)  // → FAIL
```

Any new validator MUST pick one of these explicitly for every code path
returning a verdict. Tolerated deviations route through the
`okWithDepthAndWarning` path with a human-readable warning_message.

See `RULES.md` for the verdict-tier rule and `PROJECT_OVERVIEW.md` for
the user-facing framing.


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
    // in individual es_owned_result_t.is_valid = false
} es_error_t;

// Validation result (caller takes ownership, must call es_free_result)
typedef struct {
    char* format_description;        // heap-allocated
    int is_valid;
    int is_unknown;
    char* error_message;             // NULL if valid, heap-allocated
    char* warning_message;           // NULL if none, heap-allocated
    es_validation_depth_t validation_depth;
    uint64_t malformation_bits;
    int circumvented_trivial_protection;
    int validated_via_ffmpeg;
    double elapsed_seconds;
} es_owned_result_t;

// Batch item - file path with caller-provided ID
// The ID is echoed in callbacks so caller can map results to their data structures
typedef struct {
    const char* path;   // borrowed
    uint32_t id;        // caller-provided, echoed in callbacks
} es_batch_item_t;

// Progress callback - called many times per file for jumbo files (PDFs, videos)
// May be called from worker threads - caller must synchronize
typedef void (*es_progress_callback_t)(
    void* context,
    uint32_t file_id,   // echoes id from es_batch_item_t
    size_t current,     // current progress
    size_t total,       // total expected (0 if unknown)
    const char* unit    // "bytes", "frames", "pages", "images"
);

// Result callback - called once per file when validation completes
// Serialized to one thread (provides backpressure)
typedef void (*es_result_callback_t)(
    void* context,
    uint32_t file_id,                // echoes id from es_batch_item_t
    const char* path,                // borrowed, valid only during callback
    es_owned_result_t* result        // CALLER TAKES OWNERSHIP - must call es_free_result()
);
```

### API Functions

```c
// Single file validation with optional progress reporting
// - file_id: caller-provided ID, passed to progress_callback (for API consistency)
// - num_threads: parallelism budget for format-specific work (0 = auto-detect)
// - progress_callback: called during validation for progress (may be NULL)
// - Returns heap-allocated result, caller must call es_free_result()
es_owned_result_t* es_validate(
    const char* path,
    uint32_t file_id,
    int num_threads,
    es_progress_callback_t progress_callback,
    void* context
);

// Batch validation with streaming callbacks
// - items: array of {path, id} pairs
// - count: number of items
// - num_threads: total parallelism budget (0 = auto-detect)
// - result_callback: called once per file when complete (serialized to one thread)
// - progress_callback: called during validation for progress (may be NULL)
// - context: opaque pointer passed to both callbacks
// - Returns: ES_OK on completion, or halt error code
es_error_t es_validate_batch(
    const es_batch_item_t* items,
    size_t count,
    int num_threads,
    es_result_callback_t result_callback,
    es_progress_callback_t progress_callback,
    void* context
);

// Free a validation result (MUST be called for every result received)
void es_free_result(es_owned_result_t* result);

// Get default thread count (CPU cores)
int es_get_default_threads(void);
```

### File IDs

The `uint32_t file_id` pattern provides several benefits:

1. **Cheap to copy** - No string allocation or ownership management
2. **Caller-meaningful** - Caller provides IDs, maps them to their own data structures
3. **Concurrency-friendly** - When caller manages higher-level concurrency, IDs help correlate progress/results
4. **API consistency** - Same pattern for single-file and batch APIs

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
