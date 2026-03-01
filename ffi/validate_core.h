/**
 * validate - C API
 *
 * Simple FFI-friendly API returning KV-US-RS formatted strings.
 *
 * Result Format (KV-US-RS):
 *   key1<US>value1<RS>key2<US>value2<RS>...
 *   Where <US> = 0x1F (Unit Separator), <RS> = 0x1E (Record Separator)
 *
 * Standard Keys:
 *   fmt_id        - Format identifier (e.g., "png", "git_repository")
 *   fmt_cat       - Category (e.g., "image", "bundle", "document")
 *   fmt_desc      - Human-readable description
 *   valid         - Boolean: validation passed
 *   unknown       - Boolean: format not recognized
 *   err           - Error message (empty if none)
 *   err_code      - Symbolic error code (e.g., "failed_to_read", empty if none)
 *   err_detail    - Technical detail string (e.g., "PNG signature", empty if none)
 *   warn          - Warning message (empty if none)
 *   depth_u8      - Validation depth (0=structural, 1=full)
 *   malform_u64   - Malformation bitset (see malformation constants)
 *   bypass_prot   - Boolean: circumvented trivial protection
 *   via_ffmpeg    - Boolean: used external ffmpeg for validation
 *   elapsed_ns_u64 - Elapsed time in nanoseconds
 *
 * Type Suffixes:
 *   _u8, _u16, _u32, _u64 - Unsigned integers (decimal, 0x hex, or 0b binary)
 *   _ns, _ms, _s          - Time units (with size suffix, e.g., elapsed_ns_u64)
 *   No suffix             - UTF-8 string or boolean
 *
 * Boolean Semantics:
 *   Falsy: "F", "0", empty value, absent key
 *   Truthy: Everything else ("T", "1", "yes", any non-empty non-falsy string)
 *
 * Memory Ownership:
 *   Results are heap-allocated. Caller MUST call validate_free() when done.
 */

#ifndef VALIDATE_CORE_H
#define VALIDATE_CORE_H

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Format delimiters */
#define VALIDATE_US '\x1F'  /* Unit Separator: between key and value */
#define VALIDATE_RS '\x1E'  /* Record Separator: between key-value pairs */

/* ABI version */
#define VALIDATE_ABI_VERSION_MAJOR 2
#define VALIDATE_ABI_VERSION_MINOR 1

/* Error codes (returned by validate_batch) */
typedef enum {
    VALIDATE_OK = 0,
    VALIDATE_ERR_NULL_PATH = 1,
    VALIDATE_ERR_NULL_CALLBACK = 2,
    VALIDATE_ERR_OUT_OF_MEMORY = 3,
    VALIDATE_ERR_INTERNAL = 4,
} validate_error_t;

/* Malformation bit positions (for malform_u64 field) */
typedef enum {
    VALIDATE_MALFORM_PDF_GARBAGE_AFTER_EOF = 0,
    VALIDATE_MALFORM_PNG_ANCILLARY_CRC_ERROR = 1,
    VALIDATE_MALFORM_EXTENSION_MISMATCH = 2,
    VALIDATE_MALFORM_PDF_TRIVIAL_ENCRYPTION = 3,
    VALIDATE_MALFORM_MIME_WRAPPED_CONTENT = 4,
    VALIDATE_MALFORM_PDF_JBIG2_TRUNCATED = 5,
    VALIDATE_MALFORM_PDF_DCT_NOT_JPEG = 6,
    VALIDATE_MALFORM_VIDEO_NO_FRAMES_DECODED = 7,
    VALIDATE_MALFORM_VIDEO_UNSUPPORTED_PROFILE_NO_FFMPEG = 8,
    VALIDATE_MALFORM_XML_UNDEFINED_ENTITY = 9,
    VALIDATE_MALFORM_RAR_HEADER_CRC_MISMATCH = 10,
    VALIDATE_MALFORM_VIDEO_MIXED_NAL_PREFIX = 11,
    VALIDATE_MALFORM_PDF_MISSING_TRAILER = 12,
    VALIDATE_MALFORM_PDF_TRAILER_MISSING_SIZE = 13,
    VALIDATE_MALFORM_PDF_TRAILER_MISSING_ROOT = 14,
    VALIDATE_MALFORM_MAGIC_BYTES_CORRUPTED = 15,
    VALIDATE_MALFORM_PDF_DCT_TRUNCATED = 16,
    VALIDATE_MALFORM_PDF_JPX_DECODE_FAILED = 17,
    VALIDATE_MALFORM_PDF_CCITT_DECODE_FAILED = 18,
    VALIDATE_MALFORM_PDF_FLATE_DECODE_FAILED = 19,
    VALIDATE_MALFORM_PDF_LZW_DECODE_FAILED = 20,
    VALIDATE_MALFORM_PDF_JBIG2_DECODE_FAILED = 21,
} validate_malform_t;

/* Symbolic error codes (for err_code field, maps to error_messages.zig templates) */
typedef enum {
    VALIDATE_ERR_CODE_FAILED_TO_READ = 0,
    VALIDATE_ERR_CODE_FILE_TOO_SMALL = 1,
    VALIDATE_ERR_CODE_INVALID_SIGNATURE = 2,
    VALIDATE_ERR_CODE_MISSING = 3,
    VALIDATE_ERR_CODE_FAILED_TO_SEEK = 4,
    VALIDATE_ERR_CODE_TRUNCATED = 5,
    VALIDATE_ERR_CODE_INVALID_MAGIC = 6,
    VALIDATE_ERR_CODE_INVALID_MAGIC_NUMBER = 7,
    VALIDATE_ERR_CODE_FAILED_TO_OPEN = 8,
    VALIDATE_ERR_CODE_FAILED_TO_SKIP = 9,
    VALIDATE_ERR_CODE_TOO_MANY = 10,
    VALIDATE_ERR_CODE_UNSUPPORTED = 11,
    VALIDATE_ERR_CODE_INCOMPLETE = 12,
    VALIDATE_ERR_CODE_BUFFER_TOO_SMALL = 13,
    VALIDATE_ERR_CODE_NO_VALID_X_FOUND = 14,
    VALIDATE_ERR_CODE_UNKNOWN_ELEMENT = 15,
    VALIDATE_ERR_CODE_EMPTY = 16,
    VALIDATE_ERR_CODE_FILE_TOO_LARGE = 17,
    VALIDATE_ERR_CODE_FAILED_TO_ALLOCATE = 18,
    VALIDATE_ERR_CODE_FAILED_TO_STAT = 19,
    VALIDATE_ERR_CODE_OUT_OF_MEMORY = 20,
    VALIDATE_ERR_CODE_FAILED_TO_GET = 21,
    VALIDATE_ERR_CODE_INVALID_SIGNATURE_EXPECTED = 22,
    VALIDATE_ERR_CODE_INVALID_SIGNATURE_NOT = 23,
    VALIDATE_ERR_CODE_DECOMPRESSION_FAILED = 24,
    VALIDATE_ERR_CODE_INVALID_VALUE = 25,
    VALIDATE_ERR_CODE_CHECKSUM_MISMATCH = 26,
    VALIDATE_ERR_CODE_EXCEEDS_BOUNDS = 27,
    VALIDATE_ERR_CODE_OTHER = 255,
} validate_err_code_t;

/* String IDs for validate_tr() (i18n) */
typedef enum {
    VALIDATE_STR_LABEL_OK = 0,
    VALIDATE_STR_LABEL_WARN = 1,
    VALIDATE_STR_LABEL_FAIL = 2,
    VALIDATE_STR_LABEL_NOTICE = 3,
    VALIDATE_STR_LABEL_UNKNOWN = 4,
    VALIDATE_STR_LABEL_SLOW = 5,
    VALIDATE_STR_SUMMARY_TITLE = 6,
    VALIDATE_STR_SUMMARY_INTERRUPTED = 7,
    VALIDATE_STR_SUMMARY_VALID = 8,
    VALIDATE_STR_SUMMARY_INVALID = 9,
    VALIDATE_STR_SUMMARY_UNKNOWN = 10,
    VALIDATE_STR_SUMMARY_PROCESSED = 11,
    VALIDATE_STR_DEPTH_STRUCTURAL = 12,
    VALIDATE_STR_DEPTH_FULL = 13,
    VALIDATE_STR_FULL_VALIDATION_UNAVAILABLE = 14,
    VALIDATE_STR_VIA_FFMPEG_SUFFIX = 15,
    VALIDATE_STR_SCANNING_FILES_FOUND = 16,
    VALIDATE_STR_FOUND_FILES_TO_VALIDATE = 17,
    VALIDATE_STR_CHECKING = 18,
    VALIDATE_STR_HELP_ENTROPY_SHIELD = 41,
} validate_string_id_t;

/* CLI argument IDs (returned by validate_match_arg) */
typedef enum {
    VALIDATE_ARG_HELP = 0,
    VALIDATE_ARG_VERSION = 1,
    VALIDATE_ARG_LANG = 2,
    VALIDATE_ARG_JOBS = 3,
    VALIDATE_ARG_SHUFFLE = 4,
    VALIDATE_ARG_STRESS = 5,
    VALIDATE_ARG_NO_COLOR = 6,
    VALIDATE_ARG_COLOR = 7,
    VALIDATE_ARG_SIMPLE_PROGRESS = 8,
    VALIDATE_ARG_NO_FRONTLOAD = 9,
    VALIDATE_ARG_UNKNOWN = 255,
} validate_arg_t;

/* Environment variable IDs (for validate_getenv) */
typedef enum {
    VALIDATE_ENV_OK_OUT = 0,
    VALIDATE_ENV_WARN_OUT = 1,
    VALIDATE_ENV_FAIL_OUT = 2,
    VALIDATE_ENV_UNKNOWN_OUT = 3,
    VALIDATE_ENV_SLOW_OUT = 4,
    VALIDATE_ENV_DEBUG_OUT = 5,
    VALIDATE_ENV_BEGIN_OUT = 6,
    VALIDATE_ENV_MAX_FILES = 7,
    VALIDATE_ENV_VALIDATE_DEBUG = 8,
    VALIDATE_ENV_NO_BIDI = 9,
} validate_env_t;

/* ========== Core Functions ========== */

/**
 * Returns the library version string.
 * @return Version string (e.g., "2.0.0"). Static, do not free.
 */
const char* validate_version(void);

/**
 * Pre-initialize decoder libraries for thread safety.
 * Call ONCE from main thread BEFORE spawning worker threads.
 */
void validate_init(void);

/**
 * Get recommended thread count for batch validation.
 * @return Number of threads (typically 2/3 of CPU cores)
 */
int validate_default_threads(void);

/* ========== Single File Validation ========== */

/**
 * Validate a single file.
 *
 * @param path File path (null-terminated UTF-8)
 * @return KV-US-RS formatted result string. Caller MUST call validate_free().
 *         Returns NULL on allocation failure.
 */
char* validate(const char* path);

/**
 * Free a validation result string.
 * @param result Result from validate() or callback. NULL is safe.
 */
void validate_free(char* result);

/* ========== Batch Validation ========== */

/**
 * Batch validation callback.
 * Called once per file when validation completes.
 * Caller takes ownership of result and MUST call validate_free().
 *
 * @param ctx User-provided context
 * @param id Caller-provided file ID (echoed from input)
 * @param path The file path
 * @param result KV-US-RS formatted result (CALLER MUST FREE)
 */
typedef void (*validate_callback_t)(
    void* ctx,
    uint32_t id,
    const char* path,
    char* result
);

/**
 * Begin callback type - called when validation of a file starts.
 * Useful for debugging crashes (shows which files are "in flight").
 *
 * @param ctx User-provided context
 * @param id Caller-provided file ID
 * @param path The file path about to be validated
 */
typedef void (*validate_begin_callback_t)(
    void* ctx,
    uint32_t id,
    const char* path
);

/**
 * Set a callback to be called when each file begins validation.
 * Pass NULL to disable. The callback and context are stored globally.
 *
 * @param callback Called when validation starts (NULL to disable)
 * @param ctx User context passed to callback
 */
void validate_set_begin_callback(validate_begin_callback_t callback, void* ctx);

/**
 * Validate multiple files in parallel.
 *
 * @param paths Array of file paths (null-terminated UTF-8 strings)
 * @param ids Array of caller-provided IDs (echoed in callbacks)
 * @param count Number of files
 * @param num_threads Thread count (0 = auto-detect)
 * @param callback Called once per file with result
 * @param ctx User context passed to callback
 * @return VALIDATE_OK on success, error code on failure
 */
validate_error_t validate_batch(
    const char* const* paths,
    const uint32_t* ids,
    size_t count,
    int num_threads,
    validate_callback_t callback,
    void* ctx
);

/* ========== Interrupt Control ========== */

/**
 * Signal batch validation to stop gracefully.
 * Workers will finish their current file and then stop.
 * Safe to call from signal handlers (just sets an atomic flag).
 */
void validate_interrupt(void);

/**
 * Check if interrupt was requested.
 * @return Non-zero if validate_interrupt() was called.
 */
int validate_is_interrupted(void);

/**
 * Reset interrupt flag.
 * Call before starting a new batch to clear any previous interrupt.
 */
void validate_reset_interrupt(void);

/* ========== Git Repository Validation ========== */

/**
 * Validate a Git repository.
 * Returns KV-US-RS format with additional git-specific fields:
 *   obj_checked_u32, obj_valid_u32, obj_corrupt_u32
 *   packs_checked_u32, packs_valid_u32
 *
 * @param path Path to .git directory
 * @return KV-US-RS formatted result. Caller MUST call validate_free().
 */
char* validate_git(const char* path);

/* ========== Utility Functions ========== */

/**
 * Get description for a malformation bit (i18n-aware).
 * @param bit Bit position (0-21)
 * @return Description string. Static, do not free.
 */
const char* validate_malform_desc(int bit);

/* ========== Internationalization ========== */

/**
 * Set the global locale for translated strings.
 * @param lang Locale code (e.g., "en", "de", "de_DE.UTF-8").
 *             Pass NULL to auto-detect from $LANG/$LC_MESSAGES.
 */
void validate_set_locale(const char* lang);

/**
 * Check if the current locale is a right-to-left language (Arabic, Hebrew, Farsi).
 * @return Non-zero if RTL, zero otherwise.
 */
int validate_is_rtl(void);

/**
 * Get a translated string by numeric ID.
 * @param string_id One of the VALIDATE_STR_* constants.
 * @return Translated string, or NULL for invalid IDs. Static, do not free.
 */
const char* validate_tr(uint32_t string_id);

/* ========== CLI Alias Functions ========== */

/**
 * Match a CLI argument keyword against all locale aliases.
 * The keyword should NOT include the -- or - prefix (e.g., pass "hilfe" not "--hilfe").
 * Matches against all 22 locales simultaneously.
 *
 * @param keyword Argument keyword (null-terminated UTF-8)
 * @return VALIDATE_ARG_* constant, or VALIDATE_ARG_UNKNOWN (255) if not recognized
 */
uint8_t validate_match_arg(const char* keyword);

/**
 * Look up an environment variable by checking all locale aliases.
 * For example, validate_getenv(VALIDATE_ENV_FAIL_OUT) will check
 * "FAIL_OUT", "FEHLER_AUS", "ECHEC_SORTIE", etc.
 *
 * @param env_id One of the VALIDATE_ENV_* constants
 * @return Environment variable value (first non-empty match), or NULL
 */
const char* validate_getenv(uint8_t env_id);

/* ========== Progress Bar (backed by progrez library) ========== */

/**
 * Initialize progress state with a label.
 * @param label Display label (e.g., "validate")
 */
void validate_progress_init(const char* label);

/**
 * Detect and cache terminal capabilities.
 * @param is_tty Whether stderr is a TTY
 * @param simple Force ASCII mode (no unicode, no color)
 * @param width Terminal width in columns
 */
void validate_progress_detect_caps(bool is_tty, bool simple, uint16_t width);

/**
 * Set determinate mode with known totals.
 * @param files Total number of files (0 = not tracking)
 * @param bytes Total bytes across all files (0 = not tracking)
 */
void validate_progress_set_determinate(uint64_t files, uint64_t bytes);

/** Set indeterminate mode (spinner, no percentage). */
void validate_progress_set_indeterminate(void);

/**
 * Record completion of one file.
 * @param file_bytes Size of the completed file in bytes
 */
void validate_progress_update(uint64_t file_bytes);

/**
 * Render the progress bar into a caller-provided buffer.
 * @param buf Output buffer
 * @param buf_size Buffer capacity
 * @param width Current terminal width
 * @return Number of bytes written (not null-terminated)
 */
size_t validate_progress_render_line(char* buf, size_t buf_size, uint16_t width);

/* ========== Error Reporting ========== */

/**
 * Get the last error message (thread-local).
 * @return Error message or NULL. Valid until next call on this thread.
 */
const char* validate_last_error(void);

/**
 * Clear the last error (thread-local).
 */
void validate_clear_error(void);

#ifdef __cplusplus
}
#endif

#endif /* VALIDATE_CORE_H */
