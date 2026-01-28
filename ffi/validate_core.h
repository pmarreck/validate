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
} es_error_t;

/**
 * Returns the library version string.
 * @return Version string (e.g., "0.1.0"). Valid for lifetime of library.
 */
const char* es_core_version(void);

/**
 * Returns the last error message for the current thread.
 * @return Error message or NULL if no error. Valid until next error on this thread.
 */
const char* es_core_last_error(void);

/**
 * Clears the last error for the current thread.
 */
void es_core_clear_error(void);

/* ========== Format Validation ========== */

/**
 * Opaque format validator handle.
 */
typedef struct es_format_validator es_format_validator_t;

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
} es_file_format_t;

/**
 * Validation result structure.
 */
typedef struct {
    es_file_format_t format;     /**< Detected file format */
    int is_valid;                /**< 1 if valid, 0 if invalid */
    const char* error_message;   /**< Error message if invalid, NULL if valid */
} es_validation_result_t;

/**
 * Validation depth.
 */
typedef enum {
    ES_VALIDATION_DEPTH_STRUCTURAL = 0,
    ES_VALIDATION_DEPTH_FULL = 1
} es_validation_depth_t;

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
    ES_MALFORMATION_LAST = ES_MALFORMATION_PDF_TRAILER_MISSING_ROOT
} es_malformation_t;

/**
 * Extended validation result (strings valid until next call on same validator).
 */
typedef struct {
    const char* format_description; /**< Human-readable format description */
    int is_valid;                   /**< 1 if valid, 0 if invalid */
    int is_unknown;                 /**< 1 if format unknown */
    const char* error_message;      /**< Error message if invalid, NULL if valid */
    const char* warning_message;    /**< Warning message if any, NULL otherwise */
    es_validation_depth_t validation_depth; /**< Depth of validation performed */
    uint64_t malformation_bits;     /**< Bitset of es_malformation_t values */
    int circumvented_trivial_protection; /**< 1 if trivial protection was bypassed */
} es_validation_result_ex_t;

/**
 * Aggregate validation counts.
 */
typedef struct {
    size_t valid_count;
    size_t invalid_count;
    size_t unknown_count;
} es_validation_counts_t;

/**
 * Callback invoked for each validated file.
 * Strings are valid until next callback on the same validator.
 */
typedef void (*es_validation_callback_t)(
    void* user_data,
    const char* display_path,
    const es_validation_result_ex_t* result,
    double elapsed_seconds
);

/**
 * Creates a new format validator.
 * @param out Pointer to receive the validator handle.
 * @return ES_OK on success.
 */
es_error_t es_format_validator_create(es_format_validator_t** out);

/**
 * Creates a new deep format validator.
 * @param out Pointer to receive the validator handle.
 * @return ES_OK on success.
 */
es_error_t es_format_validator_create_deep(es_format_validator_t** out);

/**
 * Destroys a format validator.
 * @param validator The validator handle.
 */
void es_format_validator_destroy(es_format_validator_t* validator);

/**
 * Enables or disables format validation.
 * @param validator The validator handle.
 * @param enabled 1 to enable, 0 to disable.
 */
void es_format_validator_set_enabled(es_format_validator_t* validator, int enabled);

/**
 * Checks if format validation is enabled.
 * @param validator The validator handle.
 * @return 1 if enabled, 0 if disabled.
 */
int es_format_validator_is_enabled(const es_format_validator_t* validator);

/**
 * Validates a file at the given path.
 * @param validator The validator handle.
 * @param path The file path (null-terminated).
 * @param out Pointer to receive the validation result.
 * @return ES_OK on success.
 */
es_error_t es_format_validate_file(
    es_format_validator_t* validator,
    const char* path,
    es_validation_result_t* out
);

/**
 * Validates a file and returns extended results.
 * Strings are valid until next call on same validator.
 * @param validator The validator handle.
 * @param path The file path (null-terminated).
 * @param out Pointer to receive the extended validation result.
 * @return ES_OK on success.
 */
es_error_t es_format_validate_file_ex(
    es_format_validator_t* validator,
    const char* path,
    es_validation_result_ex_t* out
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
es_error_t es_format_validate_path_parallel(
    es_format_validator_t* validator,
    const char* path,
    size_t jobs,
    es_validation_callback_t callback,
    void* user_data,
    es_validation_counts_t* out_counts
);

/**
 * Gets description for a malformation type.
 * @param malformation The malformation enum.
 * @return Null-terminated description string.
 */
const char* es_malformation_description(es_malformation_t malformation);

/**
 * Gets the description for a file format.
 * @param format The file format.
 * @return Null-terminated description string.
 */
const char* es_file_format_description(es_file_format_t format);

/**
 * Checks if a format has a validator.
 * @param format The file format.
 * @return 1 if a validator exists, 0 otherwise.
 */
int es_file_format_has_validator(es_file_format_t format);

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
} es_git_validation_result_t;

/**
 * Validate a Git repository.
 * @param path Repository path.
 * @param out Pointer to receive validation result.
 * @param error_buf Optional buffer to receive error message (UTF-8).
 * @param error_buf_len Buffer length.
 */
es_error_t es_git_validate_repository(
    const char* path,
    es_git_validation_result_t* out,
    char* error_buf,
    size_t error_buf_len
);

#ifdef __cplusplus
}
#endif

#endif /* VALIDATE_CORE_H */
