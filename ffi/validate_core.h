/**
 * validate - C API
 *
 * This header defines the C ABI for the validate core library.
 *
 * Memory ownership:
 * - Strings returned by core: valid until next call on same handle.
 * - Handles: caller owns; must call corresponding destroy.
 * - Error strings: thread-local; valid until next error on same thread.
 */

#ifndef VALIDATE_CORE_H
#define VALIDATE_CORE_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ABI version for compatibility checking */
#define ES_ABI_VERSION_MAJOR 0
#define ES_ABI_VERSION_MINOR 1

/* Error codes - stable, never reused or changed */
typedef enum {
    ES_OK = 0,

    /* IO errors (1000-1999) */
    ES_ERR_IO_NOT_DIRECTORY = 1001,
    ES_ERR_IO_ENUMERATION_FAILED = 1002,
    ES_ERR_IO_READ_FAILED = 1003,
    ES_ERR_IO_WRITE_FAILED = 1004,
    ES_ERR_IO_PERMISSION_DENIED = 1005,
    ES_ERR_IO_FILE_NOT_FOUND = 1006,

    /* Validation errors (5000-5999) */
    ES_ERR_INVALID_PATH = 5001,
    ES_ERR_INVALID_UTF8 = 5002,
    ES_ERR_PATH_TOO_LONG = 5003,

    /* Internal errors (9000-9999) */
    ES_ERR_INTERNAL = 9001,
    ES_ERR_OUT_OF_MEMORY = 9002,

    /* Cancelled (10000+) */
    ES_ERR_CANCELLED = 10000,
} error_t;

/**
 * Returns the library version string.
 * @return Version string (e.g., "0.1.0"). Valid for lifetime of library.
 */
const char* core_version(void);

/**
 * Returns the last error message for the current thread.
 * @return Error message or NULL if no error. Valid until next error on this thread.
 */
const char* core_last_error(void);

/**
 * Clears the last error for the current thread.
 */
void core_clear_error(void);

/**
 * Pre-initialize all decoder libraries for thread safety.
 * Call this ONCE from the main thread BEFORE spawning worker threads.
 * This triggers lazy SIMD detection and global state initialization
 * in all C libraries, preventing race conditions during parallel validation.
 */
void core_preinit(void);

/* ========== Format Validation ========== */

/**
 * Opaque format validator handle.
 */
typedef struct format_validator format_validator_t;

/**
 * File format enumeration.
 */
typedef enum {
    ES_FORMAT_UNKNOWN = 0,
    ES_FORMAT_PNG = 1,
    ES_FORMAT_JPEG = 2,
    ES_FORMAT_GIF = 3,
    ES_FORMAT_BMP = 4,
    ES_FORMAT_WEBP = 5,
    ES_FORMAT_TIFF = 6,
    ES_FORMAT_ZIP = 7,
    ES_FORMAT_EPUB = 8,
    ES_FORMAT_DOCX = 9,
    ES_FORMAT_XLSX = 10,
    ES_FORMAT_PPTX = 11,
    ES_FORMAT_PDF = 12
} file_format_t;

/**
 * Validation result structure.
 */
typedef struct {
    file_format_t format;     /**< Detected file format */
    int is_valid;                /**< 1 if valid, 0 if invalid */
    const char* error_message;   /**< Error message if invalid, NULL if valid */
} validation_result_t;

/**
 * Validation depth.
 */
typedef enum {
    ES_VALIDATION_DEPTH_STRUCTURAL = 0,
    ES_VALIDATION_DEPTH_FULL = 1
} validation_depth_t;

/**
 * Malformation types (bit positions for malformation bitset).
 */
typedef enum {
    ES_MALFORMATION_PDF_GARBAGE_AFTER_EOF = 0,
    ES_MALFORMATION_PNG_ANCILLARY_CRC_ERROR = 1,
    ES_MALFORMATION_EXTENSION_MISMATCH = 2,
    ES_MALFORMATION_PDF_TRIVIAL_ENCRYPTION = 3,
    ES_MALFORMATION_MIME_WRAPPED_CONTENT = 4,
    ES_MALFORMATION_PDF_JBIG2_TRUNCATED = 5,
    ES_MALFORMATION_PDF_DCT_NOT_JPEG = 6,
    ES_MALFORMATION_VIDEO_NO_FRAMES_DECODED = 7,
    ES_MALFORMATION_XML_UNDEFINED_ENTITY = 8,
    ES_MALFORMATION_RAR_HEADER_CRC_MISMATCH = 9,
    ES_MALFORMATION_VIDEO_MIXED_NAL_PREFIX = 10,
    ES_MALFORMATION_PDF_MISSING_TRAILER = 11,
    ES_MALFORMATION_PDF_TRAILER_MISSING_SIZE = 12,
    ES_MALFORMATION_PDF_TRAILER_MISSING_ROOT = 13,
    ES_MALFORMATION_MAGIC_BYTES_CORRUPTED = 14,
    ES_MALFORMATION_LAST = ES_MALFORMATION_MAGIC_BYTES_CORRUPTED
} malformation_t;

/**
 * Extended validation result (strings valid until next call on same validator).
 */
typedef struct {
    const char* format_description; /**< Human-readable format description */
    int is_valid;                   /**< 1 if valid, 0 if invalid */
    int is_unknown;                 /**< 1 if format unknown */
    const char* error_message;      /**< Error message if invalid, NULL if valid */
    const char* warning_message;    /**< Warning message if any, NULL otherwise */
    validation_depth_t validation_depth; /**< Depth of validation performed */
    uint64_t malformation_bits;     /**< Bitset of malformation_t values */
    int circumvented_trivial_protection; /**< 1 if trivial protection was bypassed */
    int validated_via_ffmpeg;       /**< 1 if video validation used external ffmpeg CLI */
} validation_result_ex_t;

/**
 * Aggregate validation counts.
 */
typedef struct {
    size_t valid_count;
    size_t invalid_count;
    size_t unknown_count;
} validation_counts_t;

/**
 * Callback invoked for each validated file.
 * Strings are valid until next callback on the same validator.
 */
typedef void (*validation_callback_t)(
    void* user_data,
    const char* display_path,
    const validation_result_ex_t* result,
    double elapsed_seconds
);

/**
 * Creates a new format validator.
 * @param out Pointer to receive the validator handle.
 * @return ES_OK on success.
 */
error_t format_validator_create(format_validator_t** out);

/**
 * Creates a new deep format validator.
 * @param out Pointer to receive the validator handle.
 * @return ES_OK on success.
 */
error_t format_validator_create_deep(format_validator_t** out);

/**
 * Destroys a format validator.
 * @param validator The validator handle.
 */
void format_validator_destroy(format_validator_t* validator);

/**
 * Enables or disables format validation.
 * @param validator The validator handle.
 * @param enabled 1 to enable, 0 to disable.
 */
void format_validator_set_enabled(format_validator_t* validator, int enabled);

/**
 * Checks if format validation is enabled.
 * @param validator The validator handle.
 * @return 1 if enabled, 0 if disabled.
 */
int format_validator_is_enabled(const format_validator_t* validator);

/**
 * Validates a file at the given path.
 * @param validator The validator handle.
 * @param path The file path (null-terminated).
 * @param out Pointer to receive the validation result.
 * @return ES_OK on success.
 */
error_t format_validate_file(
    format_validator_t* validator,
    const char* path,
    validation_result_t* out
);

/**
 * Validates a file and returns extended results.
 * Strings are valid until next call on same validator.
 * @param validator The validator handle.
 * @param path The file path (null-terminated).
 * @param out Pointer to receive the extended validation result.
 * @return ES_OK on success.
 */
error_t format_validate_file_ex(
    format_validator_t* validator,
    const char* path,
    validation_result_ex_t* out
);

/**
 * Validates a file or directory tree using parallel workers.
 * @param validator The validator handle.
 * @param path File or directory path (null-terminated).
 * @param jobs Number of worker threads (0 = auto).
 * @param callback Callback invoked for each file (may be NULL).
 * @param user_data User-provided callback context.
 * @param out_counts Pointer to receive aggregate counts.
 * @return ES_OK on success.
 */
error_t format_validate_path_parallel(
    format_validator_t* validator,
    const char* path,
    size_t jobs,
    validation_callback_t callback,
    void* user_data,
    validation_counts_t* out_counts
);

/**
 * Validation options for parallel path validation.
 */
typedef struct {
    size_t jobs;    /**< Number of worker threads (0 = auto) */
    int shuffle;    /**< Shuffle file order before validation (helps expose race conditions) */
    uint64_t seed;  /**< Random seed for shuffling (0 = use system time) */
} validation_options_t;

/**
 * Validates a file or directory tree using parallel workers with extended options.
 * @param validator The validator handle.
 * @param path File or directory path (null-terminated).
 * @param options Validation options.
 * @param callback Callback invoked for each file (may be NULL).
 * @param user_data User-provided callback context.
 * @param out_counts Pointer to receive aggregate counts.
 * @return ES_OK on success.
 */
error_t format_validate_path_parallel_ex(
    format_validator_t* validator,
    const char* path,
    const validation_options_t* options,
    validation_callback_t callback,
    void* user_data,
    validation_counts_t* out_counts
);

/**
 * Gets description for a malformation type.
 * @param malformation The malformation enum.
 * @return Null-terminated description string.
 */
const char* malformation_description(malformation_t malformation);

/**
 * Gets the description for a file format.
 * @param format The file format.
 * @return Null-terminated description string.
 */
const char* file_format_description(file_format_t format);

/**
 * Checks if a format has a validator.
 * @param format The file format.
 * @return 1 if a validator exists, 0 otherwise.
 */
int file_format_has_validator(file_format_t format);

/* ========== Git Repository Validation ========== */

/**
 * Git repository validation result.
 */
typedef struct {
    int is_valid;
    uint32_t objects_checked;
    uint32_t objects_valid;
    uint32_t objects_corrupt;
    uint32_t packs_checked;
    uint32_t packs_valid;
} git_validation_result_t;

/**
 * Validate a Git repository.
 * @param path Repository path.
 * @param out Pointer to receive validation result.
 * @param error_buf Optional buffer to receive error message (UTF-8).
 * @param error_buf_len Buffer length.
 */
error_t git_validate_repository(
    const char* path,
    git_validation_result_t* out,
    char* error_buf,
    size_t error_buf_len
);

/* ========== New Simplified API (Hexagonal Architecture) ========== */
/*
 * These functions provide a simpler interface that doesn't require
 * validator handles. Results are heap-allocated and caller takes ownership.
 * See ARCHITECTURE.md for design rationale.
 *
 * Key design points:
 * - Caller provides uint32_t file IDs (cheap to copy, caller maps to their data)
 * - Progress callbacks for jumbo files (PDFs, videos)
 * - Result callbacks serialized to one thread (backpressure)
 * - Caller owns results and must call free_result()
 */

/**
 * Owned validation result - caller must free with free_result().
 * All strings are heap-allocated and owned by this struct.
 */
typedef struct {
    char* format_description;       /**< Human-readable format description (heap-allocated) */
    int is_valid;                   /**< 1 if valid, 0 if invalid */
    int is_unknown;                 /**< 1 if format unknown */
    char* error_message;            /**< Error message if invalid, NULL if valid (heap-allocated) */
    char* warning_message;          /**< Warning message if any, NULL otherwise (heap-allocated) */
    validation_depth_t validation_depth; /**< Depth of validation performed */
    uint64_t malformation_bits;     /**< Bitset of malformation_t values */
    int circumvented_trivial_protection; /**< 1 if trivial protection was bypassed */
    int validated_via_ffmpeg;       /**< 1 if video validation used external ffmpeg CLI */
    double elapsed_seconds;         /**< Time taken to validate */
} owned_result_t;

/**
 * Batch item - file path with caller-provided ID.
 * The ID is echoed in callbacks so caller can map results to their data structures.
 */
typedef struct {
    const char* path;   /**< File path (null-terminated, borrowed) */
    uint32_t id;        /**< Caller-provided ID, echoed in callbacks */
} batch_item_t;

/**
 * Progress callback - may be called many times per file during validation.
 * Used for jumbo files (large PDFs, long videos) to report progress.
 *
 * Thread safety: May be called from worker threads. Caller must handle synchronization.
 *
 * @param context User-provided context pointer
 * @param file_id The caller-provided ID from batch_item_t or validate()
 * @param current Current progress (interpretation depends on unit)
 * @param total Total expected (0 if unknown)
 * @param unit Progress unit: "bytes", "frames", "pages", "images", etc.
 */
typedef void (*progress_callback_t)(
    void* context,
    uint32_t file_id,
    size_t current,
    size_t total,
    const char* unit
);

/**
 * Result callback - called once per file when validation completes.
 * Serialized to a single thread (provides natural backpressure).
 *
 * IMPORTANT: Caller takes ownership of result and MUST call free_result().
 *
 * @param context User-provided context pointer
 * @param file_id The caller-provided ID from batch_item_t
 * @param path The file path (borrowed, valid only during callback)
 * @param result Validation result (CALLER TAKES OWNERSHIP - must call free_result)
 */
typedef void (*result_callback_t)(
    void* context,
    uint32_t file_id,
    const char* path,
    owned_result_t* result
);

/**
 * Validate a single file with optional progress reporting.
 *
 * @param path File path (null-terminated)
 * @param file_id Caller-provided ID, passed to progress_callback (for API consistency)
 * @param num_threads Parallelism budget for format-specific work (0 = auto-detect)
 * @param progress_callback Called during validation for progress updates (may be NULL)
 * @param context User-provided context passed to progress_callback
 * @return Heap-allocated result. Caller MUST call free_result() when done.
 *         Returns NULL on allocation failure (check core_last_error).
 */
owned_result_t* validate(
    const char* path,
    uint32_t file_id,
    int num_threads,
    progress_callback_t progress_callback,
    void* context
);

/**
 * Validate multiple files in parallel with streaming callbacks.
 *
 * Result callbacks are serialized to a single thread for backpressure and simplicity.
 * Progress callbacks may come from any worker thread - caller must synchronize.
 * Per-file errors are reported through result_callback; this function only returns
 * "halt" errors (OOM, disk full, etc.).
 *
 * @param items Array of batch items (path + caller-provided ID)
 * @param count Number of items
 * @param num_threads Total parallelism budget (0 = auto-detect)
 * @param result_callback Called once per file when validation completes
 * @param progress_callback Called during validation for progress updates (may be NULL)
 * @param context User-provided context passed to both callbacks
 * @return ES_OK on completion, or halt error code
 */
error_t validate_batch(
    const batch_item_t* items,
    size_t count,
    int num_threads,
    result_callback_t result_callback,
    progress_callback_t progress_callback,
    void* context
);

/**
 * Free an owned validation result.
 * MUST be called for every result returned by validate() or passed to callback.
 *
 * @param result The result to free (NULL is safe to pass)
 */
void free_result(owned_result_t* result);

/**
 * Get default thread count based on CPU cores.
 *
 * @return Number of CPU cores, or 4 if detection fails
 */
int get_default_threads(void);

#ifdef __cplusplus
}
#endif

#endif /* VALIDATE_CORE_H */
