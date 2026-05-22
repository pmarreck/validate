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

/* Total number of defined malformation bits (update when adding new entries) */
#define VALIDATE_MALFORM_COUNT 22

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
    VALIDATE_STR_LABEL_INFO = 42,
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
    VALIDATE_ARG_APPEND = 10,
    VALIDATE_ARG_JSON = 11,
    VALIDATE_ARG_NDJSON = 12,
    VALIDATE_ARG_ABOUT = 13,
    VALIDATE_ARG_MAX_MEMORY = 14,
    VALIDATE_ARG_TEST_COVERAGE = 15,
    VALIDATE_ARG_MODES = 16,
    VALIDATE_ARG_SHOTGUN_BYTES = 17,
    VALIDATE_ARG_NO_HEATMAP = 18,
    VALIDATE_ARG_PER_MODE_HEATMAP = 19,
    VALIDATE_ARG_COVERAGE_JOBS = 20,
    VALIDATE_ARG_EARLY_STOP_RADIUS = 21,
    VALIDATE_ARG_NO_EARLY_STOP = 22,
    VALIDATE_ARG_NO_PROGRESS = 23,
    VALIDATE_ARG_STRICT = 24,
    VALIDATE_ARG_NO_STRICT = 25,
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
    VALIDATE_ENV_MAX_MEMORY = 10,
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

/**
 * Get total system memory in bytes.
 * Returns 0 if detection fails.
 */
uint64_t validate_system_memory(void);

/**
 * Set maximum memory budget for validation in bytes.
 * Workers will throttle when RSS approaches this limit.
 * Pass 0 to use default (system_memory / 2).
 * Must be called BEFORE validate_batch().
 */
void validate_set_max_memory(uint64_t bytes);

/**
 * Get current maximum memory budget.
 * Returns the value set by validate_set_max_memory, or the default.
 */
uint64_t validate_get_max_memory(void);

/**
 * Snapshot of the active memory-budget state. Populated by
 * validate_get_memory_usage() while a batch is running. All sizes are
 * in bytes; counts are unsigned. `current_rss` is best-effort and may
 * be 0 on platforms where we can't query process RSS (e.g. Windows
 * pre-implementation).
 */
typedef struct {
    uint64_t total_bytes;       /* configured budget cap */
    uint64_t available_bytes;   /* bytes currently unreserved */
    uint64_t active_tasks;      /* tasks holding reservations right now */
    uint64_t current_rss;       /* process RSS, 0 if unavailable */
} validate_memory_usage_t;

/**
 * Get a snapshot of memory budget state.
 *
 * Cheap to call (single mutex acquire on the budget + 3 atomic reads +
 * RSS syscall). Intended for GUI memory meters polling at ~500ms
 * intervals. Safe to call from any thread, including while
 * validate_batch is running.
 *
 * @param out  output struct; zero-cleared on failure.
 * @return     0 (VALIDATE_OK) on success; 1 if `out` is NULL; 2 if no
 *             batch is currently running.
 */
int validate_get_memory_usage(validate_memory_usage_t* out);
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

/* ========== Test Coverage (corruption detection testing) ========== */

/**
 * Progress callback for test coverage.
 * Called before each round with current round, total rounds, and detected count.
 */
typedef void (*validate_coverage_progress_t)(void* ctx, uint32_t round, uint32_t total, uint32_t detected);

/**
 * Corruption-mode bitmask values for validate_test_coverage.
 * Each bit enables one mode. Pass 0 to enable all default modes (first 6).
 * boundary and sparse_noise are opt-in and must be specified explicitly.
 */
#define VALIDATE_COVERAGE_MODE_SNIPER       (1u << 0)
#define VALIDATE_COVERAGE_MODE_SHOTGUN      (1u << 1)
#define VALIDATE_COVERAGE_MODE_HEADER       (1u << 2)
#define VALIDATE_COVERAGE_MODE_TAIL         (1u << 3)
#define VALIDATE_COVERAGE_MODE_ZEROED       (1u << 4)
#define VALIDATE_COVERAGE_MODE_XOR          (1u << 5)
#define VALIDATE_COVERAGE_MODE_SPARSE_NOISE (1u << 6)
#define VALIDATE_COVERAGE_MODE_BOUNDARY     (1u << 7)
#define VALIDATE_COVERAGE_MODE_BOLTER       (1u << 8)
/* "Bolter" = flip ALL 8 bits of one random byte (XOR with 0xFF) —
 * intermediate granularity between sniper (1 bit) and shotgun (4 KB).
 * Named after Warhammer 40K's bolter (single big projectile, not a
 * single bullet, not a spray of pellets). */
/* Default modes — sniper + shotgun. These two together cover per-byte
 * (sniper) and per-region (shotgun) detection; passing 0 to validate_test_coverage's
 * modes_bitmask resolves to this. */
#define VALIDATE_COVERAGE_MODES_DEFAULT \
    (VALIDATE_COVERAGE_MODE_SNIPER | VALIDATE_COVERAGE_MODE_SHOTGUN)
/* All six historically-shipped modes (sniper, shotgun, header, tail, zeroed, xor).
 * Use --modes all in the CLI to opt back in. */
#define VALIDATE_COVERAGE_MODES_ALL \
    (VALIDATE_COVERAGE_MODE_SNIPER | VALIDATE_COVERAGE_MODE_SHOTGUN | \
     VALIDATE_COVERAGE_MODE_HEADER | VALIDATE_COVERAGE_MODE_TAIL | \
     VALIDATE_COVERAGE_MODE_ZEROED | VALIDATE_COVERAGE_MODE_XOR)
/* Backwards-compatible alias for the old name. Prefer MODES_ALL. */
#define VALIDATE_COVERAGE_MODES_DEFAULT_ALL VALIDATE_COVERAGE_MODES_ALL

/**
 * Run corruption-detection coverage testing on a file.
 *
 * Baseline-validates the file first (aborts if invalid), then runs N rounds:
 *   memcpy bytes -> apply random corruption -> validate -> record hit/miss.
 * All in-memory; no disk writes.
 *
 * @param path           File to test (must be valid for baseline check)
 * @param rounds         Number of corruption rounds (typical: 100-1000)
 * @param seed           PRNG seed (0 for deterministic; use time() for random)
 * @param shotgun_bytes  Bytes overwritten by shotgun/header/tail/zeroed/xor (default 4096)
 * @param modes_bitmask  Bitmask of VALIDATE_COVERAGE_MODE_* values. 0 = all six
 *                       default modes (boundary + sparse_noise stay opt-in).
 * @param heatmap_width  Width in cells for the rendered heatmap (clamped to
 *                       [40, 400]). 0 skips heatmap rendering entirely.
 * @param jobs           Number of worker threads. 0 = auto-detect CPU count
 *                       (capped at 16). 1 = single-threaded. Each worker
 *                       gets its own FormatValidator and a PRNG seed of
 *                       base_seed + worker_id.
 * @param early_stop_radius Adaptive early-stop threshold expressed as the
 *                       half-width of the 95% Wilson CI over the per-mode
 *                       detection rate. After every 100 rounds, every enabled
 *                       mode is checked; if all are at or under this radius,
 *                       the run stops short. Saves time on extreme bimodal
 *                       formats (PNG=100%, BMP=0%) without hurting precision
 *                       on near-50% rates. Mapping:
 *                         - 0.0 → use library default (0.025 = ±2.5%)
 *                         - <0  → disabled (run all `rounds`)
 *                         - >0  → use as the threshold directly
 * @param progress_cb    Optional progress callback (ignored when jobs > 1)
 * @param progress_ctx   Optional context pointer passed to progress_cb
 * @return KV-US-RS result string. Caller MUST validate_free(). NULL on error.
 *         Result includes keys `rounds` (actual completed),
 *         `requested_rounds` (cap), `early_stop_radius` (effective threshold),
 *         and `early_stopped` (1 if rounds < requested_rounds).
 */
char* validate_test_coverage(const char* path, uint32_t rounds, uint64_t seed,
                             uint32_t shotgun_bytes, uint32_t modes_bitmask,
                             uint32_t heatmap_width, uint32_t jobs,
                             double early_stop_radius,
                             validate_coverage_progress_t progress_cb, void* progress_ctx,
                             bool strict);
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
