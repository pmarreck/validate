/* Enable POSIX extensions (strdup, etc.) on strict C99/C11 systems like musl */
#define _POSIX_C_SOURCE 200809L

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/stat.h>
#include <dirent.h>
#include <time.h>
#include <stdarg.h>
#include <stdatomic.h>
#if defined(_WIN32)
#include <windows.h>
#include <psapi.h>
#include <io.h>
#define isatty _isatty
#define STDIN_FILENO 0
#define STDOUT_FILENO 1
#define STDERR_FILENO 2
#define PATH_SEP '\\'
#define IS_PATH_SEP(c) ((c) == '/' || (c) == '\\')
#else
#include <unistd.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/time.h>
#include <pthread.h>
#define PATH_SEP '/'
#define IS_PATH_SEP(c) ((c) == '/')
#endif
#if defined(__APPLE__)
#include <mach/mach.h>
#endif
#include "validate_core.h"

/* ========== Multi-Output Destination System ========== */
/*
 * Supports colon-delimited output destinations for *_OUT environment variables.
 * Special tokens: @stdout, @stderr
 * Windows-aware parsing: Don't split on colons in C:\ style paths
 */

#define MAX_OUTPUT_DESTINATIONS 8

typedef struct {
	FILE* handles[MAX_OUTPUT_DESTINATIONS];
	int count;
	int owns_handle[MAX_OUTPUT_DESTINATIONS];  /* 1 if we opened it (need to close) */
	int muted;  /* 1 if @null was specified - no output at all */
} output_dest_t;

static output_dest_t g_ok_out;
static output_dest_t g_warn_out;
static output_dest_t g_fail_out;
static output_dest_t g_unknown_out;
static output_dest_t g_slow_out;
static output_dest_t g_debug_out;
static output_dest_t g_begin_out;

/* RTL bidirectional text support */
static int g_rtl_enabled = 0;
static const char* RLM = "\xE2\x80\x8F"; /* U+200F Right-to-Left Mark (UTF-8) */

/* Mutex to synchronize output and TUI rendering */
#if defined(_WIN32)
static CRITICAL_SECTION g_output_lock;
static int g_output_lock_initialized = 0;
#else
static pthread_mutex_t g_output_lock = PTHREAD_MUTEX_INITIALIZER;
#endif

/* Forward declarations for color variables (defined later) */
static const char* COLOR_YELLOW;

static void output_dest_init(output_dest_t* dest) {
	dest->count = 0;
	dest->muted = 0;
	for (int i = 0; i < MAX_OUTPUT_DESTINATIONS; i++) {
		dest->handles[i] = NULL;
		dest->owns_handle[i] = 0;
	}
}

static void output_dest_add(output_dest_t* dest, FILE* handle, int owns) {
	if (dest->count >= MAX_OUTPUT_DESTINATIONS) return;
	dest->handles[dest->count] = handle;
	dest->owns_handle[dest->count] = owns;
	dest->count++;
}

static void output_dest_close(output_dest_t* dest) {
	for (int i = 0; i < dest->count; i++) {
		if (dest->owns_handle[i] && dest->handles[i]) {
			fclose(dest->handles[i]);
		}
		dest->handles[i] = NULL;
		dest->owns_handle[i] = 0;
	}
	dest->count = 0;
}

/* Check if position is at a Windows drive letter (e.g., "C:" in "C:\path") */
static int is_windows_drive_colon(const char* spec, const char* colon_pos) {
	/* Must have exactly one character before colon */
	if (colon_pos - spec != 1) return 0;
	/* Must be a letter */
	char c = spec[0];
	if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z'))) return 0;
	/* Must have backslash or slash after colon (or end of string for bare "C:") */
	char next = colon_pos[1];
	return (next == '\\' || next == '/' || next == '\0');
}

/* Parse a single destination token and add to dest */
static int parse_single_dest(const char* token, size_t len, output_dest_t* dest) {
	if (len == 0) return 0;  /* Skip empty tokens */

	/* Check for special tokens */
	if (len == 5 && strncmp(token, "@null", 5) == 0) {
		/* @null must appear alone - mark as muted and don't add any handles */
		if (dest->count > 0) {
			fprintf(stderr, "Error: @null must be the only output destination\n");
			return -1;
		}
		dest->muted = 1;
		return 0;
	}
	/* Error if trying to add destinations to a muted output */
	if (dest->muted) {
		fprintf(stderr, "Error: @null must be the only output destination\n");
		return -1;
	}
	if (len == 7 && strncmp(token, "@stdout", 7) == 0) {
		output_dest_add(dest, stdout, 0);
		return 0;
	}
	if (len == 7 && strncmp(token, "@stderr", 7) == 0) {
		output_dest_add(dest, stderr, 0);
		return 0;
	}

	/* It's a file path - need to null-terminate for fopen */
	char* path = (char*)malloc(len + 1);
	if (!path) return -1;
	memcpy(path, token, len);
	path[len] = '\0';

	FILE* f = fopen(path, "a");
	if (!f) {
		fprintf(stderr, "%sWarning: failed to open output path: %s (%s)\n",
				COLOR_YELLOW ? COLOR_YELLOW : "", path, strerror(errno));
		free(path);
		return -1;
	}
	free(path);
	output_dest_add(dest, f, 1);
	return 0;
}

/* Parse colon-delimited output specification */
static int parse_output_spec(const char* spec, output_dest_t* dest) {
	if (!spec || spec[0] == '\0') return 0;

	const char* start = spec;
	const char* p = spec;

	while (*p) {
		if (*p == ':') {
			/* Check if this is a Windows drive letter */
			if (start == spec && is_windows_drive_colon(start, p)) {
				/* Skip this colon, it's part of a Windows path */
				p++;
				continue;
			}
			/* Also check for drive letter in middle of spec (after another path) */
			if (p > start && p - start >= 1) {
				const char* potential_drive = p - 1;
				/* If we're at X: where X is letter and next is \ or /, skip */
				if (potential_drive >= start &&
					((potential_drive[0] >= 'A' && potential_drive[0] <= 'Z') ||
					 (potential_drive[0] >= 'a' && potential_drive[0] <= 'z')) &&
					(potential_drive == start || potential_drive[-1] == ':') &&
					(p[1] == '\\' || p[1] == '/')) {
					p++;
					continue;
				}
			}

			/* This is a real delimiter */
			if (parse_single_dest(start, p - start, dest) != 0) {
				/* Continue despite errors - best effort */
			}
			start = p + 1;
		}
		p++;
	}

	/* Handle last token */
	if (start < p) {
		parse_single_dest(start, p - start, dest);
	}

	return 0;
}

/* Write formatted output to all destinations */
static void write_to_outputs(output_dest_t* dest, const char* fmt, ...) {
	va_list args;
	for (int i = 0; i < dest->count; i++) {
		if (dest->handles[i]) {
			va_start(args, fmt);
			vfprintf(dest->handles[i], fmt, args);
			va_end(args);
			fflush(dest->handles[i]);
		}
	}
}

/* Write string without formatting (for pre-formatted output) */
static void write_str_to_outputs(output_dest_t* dest, const char* str) {
	for (int i = 0; i < dest->count; i++) {
		if (dest->handles[i]) {
			fputs(str, dest->handles[i]);
			fflush(dest->handles[i]);
		}
	}
}

/* ========== KV-US-RS Parser ========== */
/*
 * Simple parser for KV-US-RS format (Key-Value with Unit/Record Separators).
 * Format: key1<US>value1<RS>key2<US>value2<RS>...
 * Where <US> = 0x1F, <RS> = 0x1E
 */

/* Stateful parser for iterating through all key-value pairs.
 * Used for rich metadata extraction where we need to enumerate
 * all returned fields rather than look up specific keys. */
typedef struct {
	const char* data;      /* Original string (not owned) */
	const char* pos;       /* Current position */
} kv_parser_t;

__attribute__((unused))
static void kv_parser_init(kv_parser_t* parser, const char* data) {
	parser->data = data;
	parser->pos = data;
}

/* Find a value by key. Returns pointer to value (within data), or NULL if not found.
 * Sets *value_len to the length of the value. */
static const char* kv_find(const char* data, const char* key, size_t* value_len) {
	if (!data || !key) return NULL;
	size_t key_len = strlen(key);
	const char* p = data;

	while (*p) {
		/* Find end of key (US or end of string) */
		const char* key_end = p;
		while (*key_end && *key_end != VALIDATE_US && *key_end != VALIDATE_RS) {
			key_end++;
		}

		size_t this_key_len = key_end - p;

		/* Check if this is our key */
		if (this_key_len == key_len && memcmp(p, key, key_len) == 0) {
			/* Found it! Value starts after US */
			if (*key_end == VALIDATE_US) {
				const char* value_start = key_end + 1;
				const char* value_end = value_start;
				while (*value_end && *value_end != VALIDATE_RS) {
					value_end++;
				}
				if (value_len) *value_len = value_end - value_start;
				return value_start;
			}
			/* Key with no value (shouldn't happen in well-formed data) */
			if (value_len) *value_len = 0;
			return key_end;
		}

		/* Skip to next record */
		p = key_end;
		if (*p == VALIDATE_US) {
			/* Skip value */
			p++;
			while (*p && *p != VALIDATE_RS) p++;
		}
		if (*p == VALIDATE_RS) p++;
	}

	return NULL;
}

/* Get string value, copying to provided buffer. Returns 0 on success. */
static int kv_get_str(const char* data, const char* key, char* buf, size_t buf_size) {
	size_t value_len = 0;
	const char* value = kv_find(data, key, &value_len);
	if (!value) {
		if (buf_size > 0) buf[0] = '\0';
		return -1;
	}
	size_t copy_len = (value_len < buf_size - 1) ? value_len : buf_size - 1;
	memcpy(buf, value, copy_len);
	buf[copy_len] = '\0';
	return 0;
}

/* Get boolean value. Returns 0 (false) or 1 (true). */
static int kv_get_bool(const char* data, const char* key) {
	size_t value_len = 0;
	const char* value = kv_find(data, key, &value_len);
	if (!value || value_len == 0) return 0;
	/* Falsy: "F", "0", empty */
	if (value_len == 1 && (value[0] == 'F' || value[0] == '0')) return 0;
	/* Everything else is truthy */
	return 1;
}

/* Get uint64 value. Returns 0 on error or if not found. */
static uint64_t kv_get_u64(const char* data, const char* key) {
	size_t value_len = 0;
	const char* value = kv_find(data, key, &value_len);
	if (!value || value_len == 0) return 0;

	/* Copy to temp buffer for strtoul */
	char buf[32];
	size_t copy_len = (value_len < sizeof(buf) - 1) ? value_len : sizeof(buf) - 1;
	memcpy(buf, value, copy_len);
	buf[copy_len] = '\0';

	/* Support hex (0x) and binary (0b) */
	if (copy_len >= 2 && buf[0] == '0' && buf[1] == 'x') {
		return strtoull(buf + 2, NULL, 16);
	}
	if (copy_len >= 2 && buf[0] == '0' && buf[1] == 'b') {
		return strtoull(buf + 2, NULL, 2);
	}
	return strtoull(buf, NULL, 10);
}

/* Get int64 value. Returns 0 on error or if not found. */
static int64_t kv_get_i64(const char* data, const char* key) {
	size_t value_len = 0;
	const char* value = kv_find(data, key, &value_len);
	if (!value || value_len == 0) return 0;

	char buf[32];
	size_t copy_len = (value_len < sizeof(buf) - 1) ? value_len : sizeof(buf) - 1;
	memcpy(buf, value, copy_len);
	buf[copy_len] = '\0';

	return strtoll(buf, NULL, 10);
}

/* ========== File Path Collection ========== */

typedef struct {
	char** paths;
	uint32_t* ids;
	size_t* sizes;      /* File sizes in bytes */
	size_t count;
	size_t capacity;
	size_t max_files;   /* 0 = unlimited */
	size_t total_bytes; /* Sum of all file sizes */
} path_list_t;

static int path_list_init(path_list_t* list, size_t initial_capacity, size_t max_files) {
	list->paths = (char**)malloc(initial_capacity * sizeof(char*));
	list->ids = (uint32_t*)malloc(initial_capacity * sizeof(uint32_t));
	list->sizes = (size_t*)malloc(initial_capacity * sizeof(size_t));
	if (!list->paths || !list->ids || !list->sizes) {
		free(list->paths);
		free(list->ids);
		free(list->sizes);
		return -1;
	}
	list->count = 0;
	list->capacity = initial_capacity;
	list->max_files = max_files;
	list->total_bytes = 0;
	return 0;
}

static void path_list_free(path_list_t* list) {
	for (size_t i = 0; i < list->count; i++) {
		free(list->paths[i]);
	}
	free(list->paths);
	free(list->ids);
	free(list->sizes);
	list->paths = NULL;
	list->ids = NULL;
	list->sizes = NULL;
	list->count = 0;
	list->capacity = 0;
	list->total_bytes = 0;
}

/* Progress display for file enumeration */
static int g_show_enum_progress = 0;
static size_t g_last_progress_count = 0;

static void show_enum_progress(size_t count) {
	if (!g_show_enum_progress) return;
	/* Only update every 100 files or if count changed significantly to reduce flicker */
	if (count - g_last_progress_count >= 100 || count < 100) {
		fprintf(stderr, "\r");
		fprintf(stderr, validate_tr(VALIDATE_STR_SCANNING_FILES_FOUND), count);
		fflush(stderr);
		g_last_progress_count = count;
	}
}

static void finish_enum_progress(void) {
	if (!g_show_enum_progress) return;
	/* Clear the progress line */
	fprintf(stderr, "\r\033[K");
	fflush(stderr);
	g_last_progress_count = 0;
}

static int path_list_add(path_list_t* list, const char* path, size_t file_size) {
	if (list->max_files > 0 && list->count >= list->max_files) {
		return 0;  /* Silently stop adding (hit limit) */
	}
	if (list->count >= list->capacity) {
		size_t new_capacity = list->capacity * 2;
		char** new_paths = (char**)realloc(list->paths, new_capacity * sizeof(char*));
		uint32_t* new_ids = (uint32_t*)realloc(list->ids, new_capacity * sizeof(uint32_t));
		size_t* new_sizes = (size_t*)realloc(list->sizes, new_capacity * sizeof(size_t));
		if (!new_paths || !new_ids || !new_sizes) return -1;
		list->paths = new_paths;
		list->ids = new_ids;
		list->sizes = new_sizes;
		list->capacity = new_capacity;
	}
	list->paths[list->count] = strdup(path);
	if (!list->paths[list->count]) return -1;
	list->ids[list->count] = (uint32_t)list->count;
	list->sizes[list->count] = file_size;
	list->total_bytes += file_size;
	list->count++;
	show_enum_progress(list->count);
	return 0;
}

/* Recursive directory enumeration */
static int enumerate_directory(const char* dir_path, path_list_t* list);

/* Helper to check if path ends with a suffix */
static int ends_with(const char* path, size_t len, const char* suffix) {
	size_t suffix_len = strlen(suffix);
	if (len < suffix_len) return 0;
	return strcmp(path + len - suffix_len, suffix) == 0;
}

/* Check if a path is a bundle directory that should be
 * validated as a single unit rather than recursed into.
 * Bundles: .git, .app, .framework, .bundle */
static int is_bundle_directory(const char* path) {
	size_t len = strlen(path);

	/* Check for .git (special case: must be standalone component) */
	if (len >= 4 && ends_with(path, len, ".git")) {
		/* Either exactly ".git" or ends with "/.git" */
		if (len == 4 || path[len - 5] == '/') {
			return 1;
		}
	}

	/* macOS bundles - directory extensions */
	if (ends_with(path, len, ".app")) return 1;
	if (ends_with(path, len, ".framework")) return 1;
	if (ends_with(path, len, ".bundle")) return 1;

	return 0;
}

static int enumerate_path(const char* path, path_list_t* list) {
	struct stat st;
	if (stat(path, &st) != 0) {
		/* Skip inaccessible files (broken symlinks, permission denied, etc.)
		 * rather than failing the entire enumeration */
		return 0;
	}

	if (S_ISREG(st.st_mode)) {
		return path_list_add(list, path, (size_t)st.st_size);
	} else if (S_ISDIR(st.st_mode)) {
		/* Check if this is a bundle directory (e.g., .git) */
		if (is_bundle_directory(path)) {
			/* Add bundle directory as a single validation item - don't recurse */
			return path_list_add(list, path, (size_t)st.st_size);
		}
		return enumerate_directory(path, list);
	}
	/* Skip other types (symlinks, devices, etc.) */
	return 0;
}

static int enumerate_directory(const char* dir_path, path_list_t* list) {
	DIR* dir = opendir(dir_path);
	if (!dir) {
		/* Skip inaccessible directories (permission denied, etc.)
		 * rather than failing the entire enumeration. */
		int saved_errno = errno;
		fprintf(stderr, "\033[1;33mWARN\033[0m Skipping inaccessible directory: %s (%s)\n",
		        dir_path, strerror(saved_errno));
		return 0;
	}

	struct dirent* entry;
	while ((entry = readdir(dir)) != NULL) {
		/* Skip . and .. */
		if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
			continue;
		}

		/* Check max_files limit */
		if (list->max_files > 0 && list->count >= list->max_files) {
			break;
		}

		/* Build full path (handle trailing separator in dir_path) */
		size_t dir_len = strlen(dir_path);
		size_t name_len = strlen(entry->d_name);
		int needs_sep = (dir_len > 0 && !IS_PATH_SEP(dir_path[dir_len - 1])) ? 1 : 0;
		size_t path_len = dir_len + needs_sep + name_len;
		char* full_path = (char*)malloc(path_len + 1);
		if (!full_path) {
			closedir(dir);
			return -1;
		}

		memcpy(full_path, dir_path, dir_len);
		if (needs_sep) {
			full_path[dir_len] = PATH_SEP;
		}
		memcpy(full_path + dir_len + needs_sep, entry->d_name, name_len + 1);

		int rc = enumerate_path(full_path, list);
		free(full_path);

		if (rc != 0) {
			closedir(dir);
			return rc;
		}
	}

	closedir(dir);
	return 0;
}

/* Color support - these get set to empty strings if colors are disabled */
static const char* COLOR_GREEN = "\033[0;32m";
static const char* COLOR_RED = "\033[0;31m";
static const char* COLOR_YELLOW = "\033[1;33m";
static const char* COLOR_CYAN = "\033[0;36m";
static const char* COLOR_RESET = "\033[0m";
#define SLOW_THRESHOLD_NS (5LL * 1000000000LL)  /* 5 seconds in nanoseconds */

static int g_colors_enabled = 0;

static void init_colors(void) {
	/* Respect NO_COLOR environment variable (https://no-color.org/) */
	if (getenv("NO_COLOR") != NULL) {
		return;
	}

	/* Check if stdout is a terminal */
#ifdef _WIN32
	if (!isatty(_fileno(stdout))) {
		return;
	}
#else
	if (!isatty(STDOUT_FILENO)) {
		return;
	}
#endif

#ifdef _WIN32
	/* On Windows, try to enable ANSI escape sequences */
	HANDLE hOut = GetStdHandle(STD_OUTPUT_HANDLE);
	if (hOut == INVALID_HANDLE_VALUE) {
		return;
	}

	DWORD dwMode = 0;
	if (!GetConsoleMode(hOut, &dwMode)) {
		return;
	}

	/* ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004 */
	dwMode |= 0x0004;
	if (!SetConsoleMode(hOut, dwMode)) {
		/* Failed to enable ANSI - older Windows or unsupported terminal */
		return;
	}
#endif

	/* Colors are supported */
	g_colors_enabled = 1;
}

static void disable_colors(void) {
	COLOR_GREEN = "";
	COLOR_RED = "";
	COLOR_YELLOW = "";
	COLOR_CYAN = "";
	COLOR_RESET = "";
}

static void enable_colors(void) {
	COLOR_GREEN = "\033[0;32m";
	COLOR_RED = "\033[0;31m";
	COLOR_YELLOW = "\033[1;33m";
	COLOR_CYAN = "\033[0;36m";
	COLOR_RESET = "\033[0m";
	g_colors_enabled = 1;
}

/* Initialize all output destinations from environment variables */
static void init_output_destinations(void) {
	/* Initialize all destinations */
	output_dest_init(&g_ok_out);
	output_dest_init(&g_warn_out);
	output_dest_init(&g_fail_out);
	output_dest_init(&g_unknown_out);
	output_dest_init(&g_slow_out);
	output_dest_init(&g_debug_out);
	output_dest_init(&g_begin_out);

	/* Parse environment variables or use defaults.
	 * validate_getenv() checks all locale aliases (e.g., FAIL_OUT, FEHLER_AUS, ECHEC_SORTIE). */
	const char* ok_spec = validate_getenv(VALIDATE_ENV_OK_OUT);
	const char* warn_spec = validate_getenv(VALIDATE_ENV_WARN_OUT);
	const char* fail_spec = validate_getenv(VALIDATE_ENV_FAIL_OUT);
	const char* unknown_spec = validate_getenv(VALIDATE_ENV_UNKNOWN_OUT);
	const char* slow_spec = validate_getenv(VALIDATE_ENV_SLOW_OUT);
	const char* debug_spec = validate_getenv(VALIDATE_ENV_DEBUG_OUT);
	const char* begin_spec = validate_getenv(VALIDATE_ENV_BEGIN_OUT);

	/* OK_OUT: default to stdout */
	if (ok_spec && ok_spec[0] != '\0') {
		parse_output_spec(ok_spec, &g_ok_out);
	} else {
		output_dest_add(&g_ok_out, stdout, 0);
	}

	/* WARN_OUT: default to stdout */
	if (warn_spec && warn_spec[0] != '\0') {
		parse_output_spec(warn_spec, &g_warn_out);
	} else {
		output_dest_add(&g_warn_out, stdout, 0);
	}

	/* FAIL_OUT: default to stderr */
	if (fail_spec && fail_spec[0] != '\0') {
		parse_output_spec(fail_spec, &g_fail_out);
	} else {
		output_dest_add(&g_fail_out, stderr, 0);
	}

	/* UNKNOWN_OUT: default to stdout */
	if (unknown_spec && unknown_spec[0] != '\0') {
		parse_output_spec(unknown_spec, &g_unknown_out);
	} else {
		output_dest_add(&g_unknown_out, stdout, 0);
	}

	/* SLOW_OUT: default to stdout */
	if (slow_spec && slow_spec[0] != '\0') {
		parse_output_spec(slow_spec, &g_slow_out);
	} else {
		output_dest_add(&g_slow_out, stdout, 0);
	}

	/* DEBUG_OUT: default to @null (muted) unless set */
	if (debug_spec && debug_spec[0] != '\0') {
		parse_output_spec(debug_spec, &g_debug_out);
	} else {
		g_debug_out.muted = 1;  /* Default: no debug output */
	}

	/* BEGIN_OUT: default to @null (muted) unless set
	 * Shows which files are starting validation - useful for debugging crashes */
	if (begin_spec && begin_spec[0] != '\0') {
		parse_output_spec(begin_spec, &g_begin_out);
	} else {
		g_begin_out.muted = 1;  /* Default: no begin output */
	}
}

static void shutdown_output_destinations(void) {
	output_dest_close(&g_ok_out);
	output_dest_close(&g_warn_out);
	output_dest_close(&g_fail_out);
	output_dest_close(&g_unknown_out);
	output_dest_close(&g_slow_out);
	output_dest_close(&g_debug_out);
	output_dest_close(&g_begin_out);
}

static size_t get_env_max_files(void) {
	const char* env = validate_getenv(VALIDATE_ENV_MAX_FILES);
	if (!env || env[0] == '\0') {
		return 0;
	}
	char* end = NULL;
	unsigned long long value = strtoull(env, &end, 10);
	if (end == env || value == 0) {
		return 0;
	}
	return (size_t)value;
}

/* ========== Validation Counts ========== */

typedef struct {
	size_t valid_count;
	size_t invalid_count;
	size_t unknown_count;
} validation_counts_t;

/* ========== Result Printing ========== */

/* Lock/unlock helpers for output synchronization (prevents TUI race conditions) */
static void output_lock(void) {
#if defined(_WIN32)
	if (!g_output_lock_initialized) {
		InitializeCriticalSection(&g_output_lock);
		g_output_lock_initialized = 1;
	}
	EnterCriticalSection(&g_output_lock);
#else
	pthread_mutex_lock(&g_output_lock);
#endif
}

static void output_unlock(void) {
#if defined(_WIN32)
	LeaveCriticalSection(&g_output_lock);
#else
	pthread_mutex_unlock(&g_output_lock);
#endif
}

/* Write to an output destination, with colors only for stdout/stderr when colors enabled */
static void write_colored_line(output_dest_t* dest, const char* color_code,
							   const char* label, const char* rest) {
	if (dest->muted) return;  /* @null - no output */
	char line_buf[4096];
	for (int i = 0; i < dest->count; i++) {
		FILE* f = dest->handles[i];
		if (!f) continue;

		/* Use colors only for stdout/stderr when colors are enabled */
		const char* rtl_prefix = (g_rtl_enabled && (f == stdout || f == stderr)) ? RLM : "";
		if (g_colors_enabled && (f == stdout || f == stderr)) {
			snprintf(line_buf, sizeof(line_buf), "%s%s%s%s%s\n",
					 rtl_prefix, color_code, label, COLOR_RESET, rest);
		} else {
			snprintf(line_buf, sizeof(line_buf), "%s%s%s\n", rtl_prefix, label, rest);
		}
		fputs(line_buf, f);
		fflush(f);
	}
}

/* Write a detail line (indented sub-information) */
static void write_detail_line(output_dest_t* dest, const char* color_code, const char* text) {
	char line_buf[4096];
	for (int i = 0; i < dest->count; i++) {
		FILE* f = dest->handles[i];
		if (!f) continue;

		if (g_colors_enabled && (f == stdout || f == stderr)) {
			snprintf(line_buf, sizeof(line_buf), "  %s->%s %s\n", color_code, COLOR_RESET, text);
		} else {
			snprintf(line_buf, sizeof(line_buf), "  -> %s\n", text);
		}
		fputs(line_buf, f);
		fflush(f);
	}
}

/* Write debug output to DEBUG_OUT (muted by default unless DEBUG_OUT is set) */
static void debug_printf(const char* fmt, ...) {
	if (g_debug_out.muted) return;
	char line_buf[4096];
	va_list args;
	va_start(args, fmt);
	vsnprintf(line_buf, sizeof(line_buf), fmt, args);
	va_end(args);

	for (int i = 0; i < g_debug_out.count; i++) {
		FILE* f = g_debug_out.handles[i];
		if (!f) continue;
		fputs(line_buf, f);
		fflush(f);
	}
}

static void print_validation_result(const char* path, const char* result) {
	char fmt_desc[256];
	char err_msg[1024];
	char warn_msg[1024];

	kv_get_str(result, "fmt_desc", fmt_desc, sizeof(fmt_desc));
	kv_get_str(result, "err", err_msg, sizeof(err_msg));
	kv_get_str(result, "warn", warn_msg, sizeof(warn_msg));

	int is_valid = kv_get_bool(result, "valid");
	int depth = (int)kv_get_u64(result, "depth_u8");
	uint64_t malform_bits = kv_get_u64(result, "malform_u64");
	int bypass_prot = kv_get_bool(result, "bypass_prot");
	int via_ffmpeg = kv_get_bool(result, "via_ffmpeg");

	/* Get depth description from KV result (i18n-translated), fall back to numeric */
	char depth_str_buf[128];
	int got_depth_desc = kv_get_str(result, "depth_desc", depth_str_buf, sizeof(depth_str_buf));
	const char* depth_str = (got_depth_desc == 0 && depth_str_buf[0]) ? depth_str_buf
		: ((depth == 1) ? "fully validated" : "structural");

	/* Build depth description with optional ffmpeg suffix */
	char depth_desc[128];
	if (via_ffmpeg) {
		const char* ffmpeg_suffix = validate_tr(VALIDATE_STR_VIA_FFMPEG_SUFFIX);
		snprintf(depth_desc, sizeof(depth_desc), "%s, %s",
			depth_str, ffmpeg_suffix ? ffmpeg_suffix : "via ffmpeg");
	} else {
		snprintf(depth_desc, sizeof(depth_desc), "%s", depth_str);
	}

	int has_malformations = (malform_bits != 0);
	int has_warning = (warn_msg[0] != '\0');

	char rest_buf[2048];

	if (is_valid) {
		if (has_malformations || has_warning) {
			/* WARN goes to g_warn_out - all warnings on one line in brackets */
			char warn_details[1024] = "";
			int warn_pos = 0;
			int first_warn = 1;
			if (has_malformations) {
				for (int i = 0; i < 22; i++) {
					if (malform_bits & (1ULL << i)) {
						const char* desc = validate_malform_desc(i);
						if (desc) {
							warn_pos += snprintf(warn_details + warn_pos, sizeof(warn_details) - warn_pos,
								"%s%s", first_warn ? "" : "; ", desc);
							first_warn = 0;
						}
					}
				}
			}
			if (has_warning) {
				warn_pos += snprintf(warn_details + warn_pos, sizeof(warn_details) - warn_pos,
					"%s%s", first_warn ? "" : "; ", warn_msg);
			}
			snprintf(rest_buf, sizeof(rest_buf), " %s: %s (%s) [%s]", path, fmt_desc, depth_desc, warn_details);
			write_colored_line(&g_warn_out, COLOR_YELLOW, validate_tr(VALIDATE_STR_LABEL_WARN), rest_buf);
		} else if (bypass_prot) {
			/* NOTICE is a special OK case, goes to g_ok_out */
			snprintf(rest_buf, sizeof(rest_buf), " %s: %s (%s) - trivial protection circumvented",
					 path, fmt_desc, depth_desc);
			write_colored_line(&g_ok_out, COLOR_YELLOW, validate_tr(VALIDATE_STR_LABEL_NOTICE), rest_buf);
		} else {
			/* OK goes to g_ok_out */
			snprintf(rest_buf, sizeof(rest_buf), " %s: %s (%s)", path, fmt_desc, depth_desc);
			write_colored_line(&g_ok_out, COLOR_GREEN, validate_tr(VALIDATE_STR_LABEL_OK), rest_buf);
		}
	} else {
		/* FAIL goes to g_fail_out - all details on one line */
		char fail_details[1024] = "";
		int fail_pos = 0;
		fail_pos += snprintf(fail_details, sizeof(fail_details), "%s",
			err_msg[0] ? err_msg : "Unknown error");
		if (has_malformations) {
			for (int i = 0; i < 22; i++) {
				if (malform_bits & (1ULL << i)) {
					const char* desc = validate_malform_desc(i);
					if (desc) {
						fail_pos += snprintf(fail_details + fail_pos, sizeof(fail_details) - fail_pos,
							"; %s", desc);
					}
				}
			}
		}
		snprintf(rest_buf, sizeof(rest_buf), " %s: %s [%s]", path, fmt_desc, fail_details);
		write_colored_line(&g_fail_out, COLOR_RED, validate_tr(VALIDATE_STR_LABEL_FAIL), rest_buf);
	}
}

/* Global file list pointer for callback to access file sizes */
static path_list_t* g_file_list_ptr = NULL;

/* Progress state — backed by progrez library via validate_progress_* FFI */
static int g_tui_enabled = 0;
static int g_term_width = 80;
static int g_term_height = 24;
static int g_simple_progress = 0;

/* Forward declarations for progress system */
static void progress_update_simple(size_t file_size);
static void progress_render_new(void);
static void progress_render_force(int force);

/* Begin callback - called when validation of a file starts */
static void on_validation_begin(
	void* context,
	uint32_t file_id,
	const char* path
) {
	(void)context;
	(void)file_id;
	if (g_begin_out.muted) return;

	/* Write BEGIN line to configured output(s) */
	for (int i = 0; i < g_begin_out.count; i++) {
		FILE* f = g_begin_out.handles[i];
		if (!f) continue;
		fprintf(f, "BEGIN %s\n", path);
		fflush(f);
	}
}

/* Batch validation callback */
static void on_validation_result(
	void* context,
	uint32_t file_id,
	const char* path,
	char* result
) {
	validation_counts_t* counts = (validation_counts_t*)context;

	/* Get elapsed time in nanoseconds */
	int64_t elapsed_ns = kv_get_i64(result, "elapsed_ns_u64");

	/* Look up file size for progress tracking (read-only on file list, no lock needed) */
	size_t file_size = 0;
	if (g_file_list_ptr) {
		for (size_t i = 0; i < g_file_list_ptr->count; i++) {
			if (g_file_list_ptr->ids[i] == file_id) {
				file_size = g_file_list_ptr->sizes[i];
				break;
			}
		}
	}

	/* Check if unknown */
	int is_unknown = kv_get_bool(result, "unknown");
	int is_valid = kv_get_bool(result, "valid");

	/* Lock for output + progress update + render to prevent race conditions.
	 * The progress update (counter increment + state mutation) MUST be inside
	 * the lock because progrez state has no internal synchronization. */
	output_lock();

	/* Update progress counters under lock (progrez state is not thread-safe) */
	if (g_tui_enabled) {
		progress_update_simple(file_size);
	}

	/* Print result line(s) - these go to the scrolling region */
	if (is_unknown) {
		if (counts) counts->unknown_count++;
		char rest_buf[2048];
		snprintf(rest_buf, sizeof(rest_buf), " %s: Unknown", path);
		write_colored_line(&g_unknown_out, COLOR_CYAN, validate_tr(VALIDATE_STR_LABEL_UNKNOWN), rest_buf);
	} else if (is_valid) {
		if (counts) counts->valid_count++;
		print_validation_result(path, result);
	} else {
		if (counts) counts->invalid_count++;
		print_validation_result(path, result);
	}

	/* Print slow warning if applicable */
	if (elapsed_ns >= SLOW_THRESHOLD_NS) {
		double elapsed_s = (double)elapsed_ns / 1000000000.0;
		char rest_buf[2048];
		snprintf(rest_buf, sizeof(rest_buf), " %s: %.2fs", path, elapsed_s);
		write_colored_line(&g_slow_out, COLOR_YELLOW, validate_tr(VALIDATE_STR_LABEL_SLOW), rest_buf);
	}

	/* Now render progress bar AFTER output (in the fixed bottom area) */
	if (g_tui_enabled) {
		progress_render_new();
	}

	output_unlock();

	/* IMPORTANT: We take ownership of result, must free it */
	validate_free(result);
}

/* Shuffle array using Fisher-Yates algorithm */
static void shuffle_paths(path_list_t* list, uint64_t seed) {
	if (list->count <= 1) return;

	/* Simple LCG PRNG (good enough for shuffling) */
	uint64_t state = seed ? seed : (uint64_t)time(NULL);
	for (size_t i = list->count - 1; i > 0; i--) {
		state = state * 6364136223846793005ULL + 1442695040888963407ULL;
		size_t j = state % (i + 1);
		char* tmp = list->paths[i];
		list->paths[i] = list->paths[j];
		list->paths[j] = tmp;
		uint32_t tmp_id = list->ids[i];
		list->ids[i] = list->ids[j];
		list->ids[j] = tmp_id;
		size_t tmp_size = list->sizes[i];
		list->sizes[i] = list->sizes[j];
		list->sizes[j] = tmp_size;
	}
}

/* ========== Frontloading Large Files ========== */
/*
 * Process top 10% largest files first to prevent apparent hangs at the end
 * when only large files remain. Uses quickselect to find P90 threshold.
 */

/* Swap elements at indices i and j */
static void path_list_swap(path_list_t* list, size_t i, size_t j) {
	if (i == j) return;
	char* tmp_path = list->paths[i];
	list->paths[i] = list->paths[j];
	list->paths[j] = tmp_path;
	uint32_t tmp_id = list->ids[i];
	list->ids[i] = list->ids[j];
	list->ids[j] = tmp_id;
	size_t tmp_size = list->sizes[i];
	list->sizes[i] = list->sizes[j];
	list->sizes[j] = tmp_size;
}

/* Quickselect partition - returns pivot index */
static size_t quickselect_partition(size_t* arr, size_t* indices, size_t left, size_t right) {
	size_t pivot = arr[right];
	size_t i = left;
	for (size_t j = left; j < right; j++) {
		if (arr[j] <= pivot) {
			size_t tmp = arr[i]; arr[i] = arr[j]; arr[j] = tmp;
			size_t tmp_idx = indices[i]; indices[i] = indices[j]; indices[j] = tmp_idx;
			i++;
		}
	}
	size_t tmp = arr[i]; arr[i] = arr[right]; arr[right] = tmp;
	size_t tmp_idx = indices[i]; indices[i] = indices[right]; indices[right] = tmp_idx;
	return i;
}

/* Quickselect to find the k-th smallest element */
static size_t quickselect(size_t* arr, size_t* indices, size_t left, size_t right, size_t k) {
	if (left == right) return arr[left];

	size_t pivot_index = quickselect_partition(arr, indices, left, right);
	if (k == pivot_index) {
		return arr[k];
	} else if (k < pivot_index) {
		return quickselect(arr, indices, left, pivot_index - 1, k);
	} else {
		return quickselect(arr, indices, pivot_index + 1, right, k);
	}
}

/* Find the file size at the given percentile (0-100) */
static size_t find_percentile_size(path_list_t* list, int percentile) {
	if (list->count == 0) return 0;

	/* Create a copy of sizes array for quickselect (it modifies the array) */
	size_t* sizes_copy = (size_t*)malloc(list->count * sizeof(size_t));
	size_t* indices = (size_t*)malloc(list->count * sizeof(size_t));
	if (!sizes_copy || !indices) {
		free(sizes_copy);
		free(indices);
		return 0;
	}

	for (size_t i = 0; i < list->count; i++) {
		sizes_copy[i] = list->sizes[i];
		indices[i] = i;
	}

	size_t k = (list->count * (size_t)percentile) / 100;
	if (k >= list->count) k = list->count - 1;

	size_t result = quickselect(sizes_copy, indices, 0, list->count - 1, k);

	free(sizes_copy);
	free(indices);
	return result;
}

/* Frontload large files: move files >= P90 size to front with stable partition */
static void frontload_large_files(path_list_t* list) {
	if (list->count <= 10) return;  /* Not enough files to matter */

	size_t threshold = find_percentile_size(list, 90);
	if (threshold == 0) return;  /* All files are empty or error occurred */

	if (validate_getenv(VALIDATE_ENV_VALIDATE_DEBUG)) {
		fprintf(stderr, "[DEBUG] Frontload: P90 threshold=%zu bytes\n", threshold);
	}

	/* Stable partition: collect indices of large files, then rearrange */
	size_t* large_indices = (size_t*)malloc(list->count * sizeof(size_t));
	size_t* small_indices = (size_t*)malloc(list->count * sizeof(size_t));
	if (!large_indices || !small_indices) {
		free(large_indices);
		free(small_indices);
		return;
	}

	size_t large_count = 0;
	size_t small_count = 0;

	for (size_t i = 0; i < list->count; i++) {
		if (list->sizes[i] >= threshold) {
			large_indices[large_count++] = i;
		} else {
			small_indices[small_count++] = i;
		}
	}

	/* Create temporary arrays for the rearranged data */
	char** new_paths = (char**)malloc(list->count * sizeof(char*));
	uint32_t* new_ids = (uint32_t*)malloc(list->count * sizeof(uint32_t));
	size_t* new_sizes = (size_t*)malloc(list->count * sizeof(size_t));
	if (!new_paths || !new_ids || !new_sizes) {
		free(large_indices);
		free(small_indices);
		free(new_paths);
		free(new_ids);
		free(new_sizes);
		return;
	}

	/* Copy large files first */
	size_t dest = 0;
	for (size_t i = 0; i < large_count; i++) {
		size_t src = large_indices[i];
		new_paths[dest] = list->paths[src];
		new_ids[dest] = list->ids[src];
		new_sizes[dest] = list->sizes[src];
		dest++;
	}

	/* Then small files */
	for (size_t i = 0; i < small_count; i++) {
		size_t src = small_indices[i];
		new_paths[dest] = list->paths[src];
		new_ids[dest] = list->ids[src];
		new_sizes[dest] = list->sizes[src];
		dest++;
	}

	if (validate_getenv(VALIDATE_ENV_VALIDATE_DEBUG)) {
		/* Calculate total bytes in large vs small files */
		size_t large_bytes = 0, small_bytes = 0;
		for (size_t i = 0; i < large_count; i++) {
			large_bytes += new_sizes[i];
		}
		for (size_t i = large_count; i < dest; i++) {
			small_bytes += new_sizes[i];
		}
		fprintf(stderr, "[DEBUG] Frontload: %zu large files (%zu bytes), %zu small files (%zu bytes)\n",
				large_count, large_bytes, small_count, small_bytes);
	}

	/* Replace original arrays (don't free paths - just move pointers) */
	free(list->paths);
	free(list->ids);
	free(list->sizes);
	list->paths = new_paths;
	list->ids = new_ids;
	list->sizes = new_sizes;

	free(large_indices);
	free(small_indices);
}

/* ========== TUI Progress Bar ========== */
/*
 * Progress display backed by progrez library.
 * The progrez library handles all bar rendering, ETA, rate estimation, etc.
 * This code manages only the terminal scrolling region and cursor positioning.
 */

/* Cross-platform terminal size */
static void get_terminal_size(int* width, int* height) {
#if defined(_WIN32)
	CONSOLE_SCREEN_BUFFER_INFO csbi;
	HANDLE h = GetStdHandle(STD_ERROR_HANDLE);
	if (h != INVALID_HANDLE_VALUE && GetConsoleScreenBufferInfo(h, &csbi)) {
		*width = csbi.srWindow.Right - csbi.srWindow.Left + 1;
		*height = csbi.srWindow.Bottom - csbi.srWindow.Top + 1;
	} else {
		*width = 80;
		*height = 24;
	}
#else
	struct winsize ws;
	if (ioctl(STDERR_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0 && ws.ws_row > 0) {
		*width = ws.ws_col;
		*height = ws.ws_row;
	} else {
		/* Fallback to reasonable defaults */
		*width = 80;
		*height = 24;
	}
#endif
}

/* Signal handling for terminal resize (Unix only) */
#if !defined(_WIN32)
#ifndef SIGWINCH
#define SIGWINCH 28
#endif
static volatile sig_atomic_t g_resize_signal = 0;

static void sigwinch_handler(int sig) {
	(void)sig;
	g_resize_signal = 1;
}

/* Global flag to track SIGINT count - first is graceful, second is force */
static volatile sig_atomic_t g_sigint_count = 0;

/* SIGINT handler - graceful on first, force exit on second */
static void sigint_handler(int sig) {
	(void)sig;
	g_sigint_count++;

	if (g_sigint_count == 1) {
		/* First Ctrl+C: signal graceful shutdown */
		validate_interrupt();

		/* Write message directly (async-signal-safe using write()) */
		const char* msg = "\n\033[33mInterrupted - finishing current files (Ctrl+C again to force quit)...\033[0m\n";
		(void)write(STDERR_FILENO, msg, strlen(msg));
	} else {
		/* Second Ctrl+C: force exit immediately */
		/* Clean up terminal state before exiting */
		const char* cleanup = "\033[r\033[?25h\033[999;1H\n";
		(void)write(STDERR_FILENO, cleanup, strlen(cleanup));

		const char* msg = "\033[31mForce quit.\033[0m\n";
		(void)write(STDERR_FILENO, msg, strlen(msg));

		_exit(130);  /* 128 + SIGINT(2) = standard interrupted exit code */
	}
}
#endif

/* Initialize progress state (backed by progrez library) */
static void progress_init_new(size_t total_files, size_t total_bytes, int simple) {
	validate_progress_init("validate");

	int w, h;
	get_terminal_size(&w, &h);
	int is_tty = isatty(STDERR_FILENO);

	/* Enable TUI if:
	 * - stderr is a TTY (not piped/redirected)
	 * - More than 1 file to validate
	 * - Terminal height is at least 5 lines (need room for scrolling region + status)
	 */
	g_tui_enabled = is_tty && total_files > 1 && h >= 5;
	g_simple_progress = simple;

	validate_progress_detect_caps(is_tty, simple, (uint16_t)w);
	validate_progress_set_determinate((uint64_t)total_files, (uint64_t)total_bytes);
	g_term_width = w;
	g_term_height = h;

	/* Debug output for TUI enablement */
	if (validate_getenv(VALIDATE_ENV_VALIDATE_DEBUG)) {
		fprintf(stderr, "[TUI] is_tty=%d, files=%zu, simple=%d, height=%d -> enabled=%d\n",
				is_tty, total_files, simple, h, g_tui_enabled);
		fprintf(stderr, "[TUI] total_bytes=%zu\n", total_bytes);
	}

#if !defined(_WIN32)
	if (g_tui_enabled) {
		struct sigaction sa;

		/* SIGWINCH for terminal resize */
		sa.sa_handler = sigwinch_handler;
		sigemptyset(&sa.sa_mask);
		sa.sa_flags = SA_RESTART;
		sigaction(SIGWINCH, &sa, NULL);

		/* SIGINT for clean Ctrl+C exit (restore terminal before dying) */
		sa.sa_handler = sigint_handler;
		sigemptyset(&sa.sa_mask);
		sa.sa_flags = 0;
		sigaction(SIGINT, &sa, NULL);

		/* Set up scrolling region: reserve bottom 2 lines for progress */
		int scroll_bottom = h - 2;
		if (scroll_bottom < 1) scroll_bottom = 1;
		fprintf(stderr, "\033[1;%dr", scroll_bottom);
		fflush(stderr);
	}
#else
	/* Windows: TUI with scrolling regions requires Console API */
	g_tui_enabled = 0;
#endif
}

static void progress_cleanup_new(void) {
	if (!g_tui_enabled) return;

	/* Clear progress bar lines BEFORE resetting scrolling region */
	fprintf(stderr, "\033[%d;1H\033[K", g_term_height - 1);  /* Clear HR line */
	fprintf(stderr, "\033[%d;1H\033[K", g_term_height);       /* Clear progress line */

	/* Reset scrolling region to full terminal */
	fprintf(stderr, "\033[r");

	/* Re-enable line wrap */
	fprintf(stderr, "\033[?7h");

	/* Move cursor to bottom */
	fprintf(stderr, "\033[999;1H");

	/* Scroll for Summary output */
	fflush(stderr);
	printf("\n");
	fflush(stdout);

	/* Disable TUI flag so atexit handler won't double-reset */
	g_tui_enabled = 0;
}

/* atexit handler to restore terminal on abnormal exit (e.g., Ctrl+C) */
static void restore_terminal_on_exit(void) {
	if (g_tui_enabled) {
		fprintf(stderr, "\033[r\033[?7h");
		fflush(stderr);
	}
}

/* Update progress after completing a file */
static void progress_update_simple(size_t file_size) {
	validate_progress_update((uint64_t)file_size);
}

/* Draw horizontal rule on the second-to-last terminal line */
static void draw_hr(int width, int simple) {
	if (simple) {
		for (int i = 0; i < width; i++) {
			fprintf(stderr, "-");
		}
	} else {
		fprintf(stderr, "\033[38;5;240m");  /* Dark gray */
		for (int i = 0; i < width; i++) {
			fprintf(stderr, "\xe2\x94\x80");  /* ─ U+2500 */
		}
		fprintf(stderr, "\033[0m");
	}
}

/* Get monotonic time in milliseconds */
static uint64_t get_monotonic_ms(void) {
#if defined(_WIN32)
	return GetTickCount64();
#else
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
#endif
}

static uint64_t g_last_render_ms = 0;
#define RENDER_INTERVAL_MS 33  /* ~30fps cap to prevent flicker */

/* Render progress display (backed by progrez library).
 * Rate-limited to RENDER_INTERVAL_MS to avoid flicker from rapid callbacks.
 * Pass force=1 to bypass rate-limiting (e.g., initial render, final render). */
static void progress_render_force(int force) {
	if (!g_tui_enabled) return;

	/* Rate-limit: skip if rendered recently (unless forced) */
	uint64_t now_ms = get_monotonic_ms();
	if (!force && (now_ms - g_last_render_ms) < RENDER_INTERVAL_MS) return;
	g_last_render_ms = now_ms;

	/* Poll terminal size for responsive resize handling */
	int new_width, new_height;
	get_terminal_size(&new_width, &new_height);

	if (new_height != g_term_height) {
		/* Height changed — re-setup scrolling region */
		int scroll_bottom = new_height - 2;
		if (scroll_bottom < 1) scroll_bottom = 1;
		fprintf(stderr, "\033[1;%dr", scroll_bottom);
	}

	g_term_width = new_width;
	g_term_height = new_height;

#if !defined(_WIN32)
	g_resize_signal = 0;
#endif

	if (new_width < 40) return;  /* Too narrow */

	/* Disable line wrap + save cursor (prevents wrapping artifacts in fixed area) */
	fprintf(stderr, "\033[?7l\033[s");

	/* Draw horizontal rule on line height-1 */
	fprintf(stderr, "\033[%d;1H\033[K", g_term_height - 1);
	draw_hr(g_term_width, g_simple_progress);

	/* Draw progress bar on last line (rendered by progrez) */
	fprintf(stderr, "\033[%d;1H\033[K", g_term_height);

	char buf[4096];
	size_t len = validate_progress_render_line(buf, sizeof(buf), (uint16_t)g_term_width);
	if (len > 0) {
		fwrite(buf, 1, len, stderr);
	}

	/* Restore cursor + re-enable line wrap */
	fprintf(stderr, "\033[u\033[?7h");
	fflush(stderr);
}

/* Render progress display (rate-limited) */
static void progress_render_new(void) {
	progress_render_force(0);
}

static void print_usage(const char* program) {
	printf("validate - Deterministic file format validation\n\n");
	printf("USAGE:\n");
	printf("    %s <path>\n", program);
	printf("\n");
	printf("OPTIONS:\n");
#ifdef _WIN32
	printf("    /version, --version     Print version\n");
	printf("    /?, /h, /help, --help   Show this help\n");
	printf("    /j N, /jobs N           Number of parallel workers (0 = auto)\n");
	printf("    --no-color              Disable colored output\n");
	printf("    --color                 Force colored output (even when piping)\n");
	printf("    --shuffle               Shuffle file order (helps expose race conditions)\n");
	printf("    --stress N              Repeat validation N times with shuffling\n");
	printf("    --no-frontload          Don't prioritize large files (default: top 10%% largest first)\n");
	printf("    --simple-progress       Use simple ASCII progress instead of TUI status bar\n");
	printf("    --lang CODE             Set output language (e.g., en, de)\n");
#else
	printf("    --version          Print version\n");
	printf("    --help             Show this help\n");
	printf("    --jobs N           Number of parallel workers (0 = auto)\n");
	printf("    -j N               Alias for --jobs\n");
	printf("    --no-color         Disable colored output\n");
	printf("    --color            Force colored output (even when piping)\n");
	printf("    --shuffle          Shuffle file order (helps expose race conditions)\n");
	printf("    --stress N         Repeat validation N times with shuffling\n");
	printf("    --no-frontload     Don't prioritize large files (default: top 10%% largest first)\n");
	printf("    --simple-progress  Use simple ASCII progress instead of TUI status bar\n");
	printf("    --lang CODE        Set output language (e.g., en, de)\n");
#endif
	printf("\n");
	printf("ENVIRONMENT:\n");
	printf("    NO_COLOR      Disable colored output\n");
	printf("    OK_OUT        Output destinations for OK results (default: stdout)\n");
	printf("    WARN_OUT      Output destinations for WARN results (default: stdout)\n");
	printf("    FAIL_OUT      Output destinations for FAIL results (default: stderr)\n");
	printf("    UNKNOWN_OUT   Output destinations for UNKNOWN results (default: stdout)\n");
	printf("    SLOW_OUT      Output destinations for SLOW results (default: stdout)\n");
	printf("    DEBUG_OUT     Output destinations for debug messages (default: @null)\n");
	printf("    BEGIN_OUT     Output when files start validation (default: @null)\n");
	printf("                  Useful for debugging crashes - shows 'in-flight' files\n");
	printf("    MAX_FILES     Limit number of files to validate\n");
	printf("    LANG          Locale for output language (e.g., de_DE.UTF-8)\n");
	printf("    LC_MESSAGES   Locale for output language (overrides LANG)\n");
	printf("    NO_BIDI       Disable bidirectional text marks for RTL languages\n");
	printf("\n");
	printf("OUTPUT REDIRECTION:\n");
	printf("    All *_OUT variables accept colon-separated destinations.\n");
	printf("    Special tokens: @stdout, @stderr, @null (mute output)\n");
	printf("    Example: FAIL_OUT=/tmp/fails.log:@stderr (logs to file AND stderr)\n");
	printf("    Example: OK_OUT=@null (suppress OK results entirely)\n");
	printf("    Note: @null must appear alone; combining it with other destinations is an error.\n");
	printf("    Note: Windows paths like C:\\path are handled correctly.\n");
	printf("\n");
	printf("OUTPUT TYPES:\n");
	printf("    OK      Valid file (stdout by default)\n");
	printf("    WARN    Valid file with non-fatal issues (stdout by default)\n");
	printf("    FAIL    Invalid file (stderr by default)\n");
	printf("    UNKNOWN Unrecognized format (stdout by default)\n");
	printf("\n");
	printf("By default, the top 10%% largest files are processed first to prevent\n");
	printf("apparent hangs at the end when only large files remain.\n");
	printf("Use --no-frontload to disable this behavior.\n");
	printf("\n%s\n", validate_tr(VALIDATE_STR_HELP_ENTROPY_SHIELD));
	printf("Support: support@entropyshield.app\n");
}

/**
 * Parse a CLI argument string into a validate_arg_t.
 * Handles --long, -short, and /windows prefix forms.
 * Short forms (-h, -j) and Windows forms (/?, /h, /help, /j, /jobs, /version)
 * are hardcoded here. Long forms (--anything) are resolved through the
 * i18n alias system via validate_match_arg().
 */
static uint8_t parse_cli_arg(const char* arg) {
	/* Short forms (hardcoded, not localized) */
	if (strcmp(arg, "-h") == 0) return VALIDATE_ARG_HELP;
	if (strcmp(arg, "-j") == 0) return VALIDATE_ARG_JOBS;

#ifdef _WIN32
	/* Windows prefix forms */
	if (strcmp(arg, "/?") == 0) return VALIDATE_ARG_HELP;
	if (arg[0] == '/') {
		/* Strip / prefix and look up via alias system */
		uint8_t result = validate_match_arg(arg + 1);
		if (result != VALIDATE_ARG_UNKNOWN) return result;
		return VALIDATE_ARG_UNKNOWN;
	}
#endif

	/* -- prefix: strip and look up via alias system */
	if (arg[0] == '-' && arg[1] == '-') {
		return validate_match_arg(arg + 2);
	}

	return VALIDATE_ARG_UNKNOWN;
}

int main(int argc, char* argv[]) {
	/* Initialize color support based on terminal capabilities */
	init_colors();
	if (!g_colors_enabled) {
		disable_colors();
	}

	if (argc < 2) {
		print_usage(argv[0]);
		return 2;
	}

	size_t jobs = 0;
	int shuffle = 0;
	size_t stress_iterations = 0;
	int no_frontload = 0;
	int simple_progress = 0;

	/* Auto-detect locale from environment (--lang overrides this) */
	validate_set_locale(NULL);
	g_rtl_enabled = validate_is_rtl() && !validate_getenv(VALIDATE_ENV_NO_BIDI);

	/* Collect positional arguments (paths) */
	const char** paths = NULL;
	size_t path_count = 0;
	size_t path_capacity = 0;

	for (int i = 1; i < argc; i++) {
		const char* arg = argv[i];

		/* Check if this looks like an option (starts with - or / on Windows) */
		int is_option = (arg[0] == '-');
#ifdef _WIN32
		if (arg[0] == '/' && arg[1] != '\0' && arg[1] != '/' && arg[1] != '\\')
			is_option = 1;
#endif

		if (is_option) {
			uint8_t arg_id = parse_cli_arg(arg);
			switch (arg_id) {
			case VALIDATE_ARG_HELP:
				print_usage(argv[0]);
				free(paths);
				return 0;
			case VALIDATE_ARG_VERSION:
				printf("%s\n", validate_version());
				free(paths);
				return 0;
			case VALIDATE_ARG_SHUFFLE:
				shuffle = 1;
				continue;
			case VALIDATE_ARG_STRESS:
				if (i + 1 >= argc) {
					fprintf(stderr, "%sError: --stress requires a value\n%s", COLOR_RED, COLOR_RESET);
					free(paths);
					return 2;
				}
				stress_iterations = (size_t)strtoull(argv[++i], NULL, 10);
				if (stress_iterations == 0) {
					fprintf(stderr, "%sError: --stress value must be > 0\n%s", COLOR_RED, COLOR_RESET);
					free(paths);
					return 2;
				}
				continue;
			case VALIDATE_ARG_JOBS:
				if (i + 1 >= argc) {
					fprintf(stderr, "%sError: --jobs requires a value\n%s", COLOR_RED, COLOR_RESET);
					free(paths);
					return 2;
				}
				jobs = (size_t)strtoull(argv[++i], NULL, 10);
				continue;
			case VALIDATE_ARG_LANG:
				if (i + 1 >= argc) {
					fprintf(stderr, "%sError: --lang requires a value\n%s", COLOR_RED, COLOR_RESET);
					free(paths);
					return 2;
				}
				validate_set_locale(argv[++i]);
				g_rtl_enabled = validate_is_rtl() && !validate_getenv(VALIDATE_ENV_NO_BIDI);
				continue;
			case VALIDATE_ARG_NO_COLOR:
				disable_colors();
				continue;
			case VALIDATE_ARG_COLOR:
				enable_colors();  /* Force colors on even if not TTY */
				continue;
			case VALIDATE_ARG_NO_FRONTLOAD:
				no_frontload = 1;
				continue;
			case VALIDATE_ARG_SIMPLE_PROGRESS:
				simple_progress = 1;
				continue;
			default:
				fprintf(stderr, "%sError: Unknown option: %s\n%s", COLOR_RED, arg, COLOR_RESET);
				free(paths);
				return 2;
			}
		}
		/* Add positional argument to paths list */
		if (path_count >= path_capacity) {
			size_t new_capacity = path_capacity == 0 ? 8 : path_capacity * 2;
			const char** new_paths = realloc(paths, new_capacity * sizeof(const char*));
			if (!new_paths) {
				fprintf(stderr, "%sError: Out of memory\n%s", COLOR_RED, COLOR_RESET);
				free(paths);
				return 1;
			}
			paths = new_paths;
			path_capacity = new_capacity;
		}
		paths[path_count++] = arg;
	}

	if (path_count == 0) {
		print_usage(argv[0]);
		free(paths);
		return 2;
	}

	/* Pre-initialize decoder libraries for thread safety.
	 * This must be called ONCE from main thread BEFORE spawning workers. */
	validate_init();

	init_output_destinations();

	/* Register begin callback if BEGIN_OUT is configured */
	if (!g_begin_out.muted) {
		validate_set_begin_callback(on_validation_begin, NULL);
	}

	const size_t max_files = get_env_max_files();

	/* Collect ALL files from ALL paths into a single list */
	path_list_t file_list;
	if (path_list_init(&file_list, 1024, max_files) != 0) {
		fprintf(stderr, "%sError: Out of memory\n%s", COLOR_RED, COLOR_RESET);
		free(paths);
		shutdown_output_destinations();
		return 1;
	}

	int any_directories = 0;
	for (size_t i = 0; i < path_count; i++) {
		struct stat st;
		if (stat(paths[i], &st) != 0) {
			fprintf(stderr, "%sError: Cannot access path: %s\n%s", COLOR_RED, paths[i], COLOR_RESET);
			continue;
		}

		if (S_ISDIR(st.st_mode)) {
			any_directories = 1;
			if (max_files > 0 && file_list.count == 0) {
				printf("%sNote:%s MAX_FILES=%zu (results may be truncated)\n", COLOR_YELLOW, COLOR_RESET, max_files);
			}
			/* Enable progress display for directory enumeration */
#ifdef _WIN32
			g_show_enum_progress = isatty(_fileno(stderr));
#else
			g_show_enum_progress = isatty(STDERR_FILENO);
#endif
			if (is_bundle_directory(paths[i])) {
				path_list_add(&file_list, paths[i], (size_t)st.st_size);
			} else {
				enumerate_directory(paths[i], &file_list);
			}
		} else if (S_ISREG(st.st_mode)) {
			path_list_add(&file_list, paths[i], (size_t)st.st_size);
		} else {
			fprintf(stderr, "%sWarning: Skipping unsupported path type: %s\n%s", COLOR_YELLOW, paths[i], COLOR_RESET);
		}
	}
	finish_enum_progress();
	free(paths);

	if (file_list.count == 0) {
		printf("No files found.\n");
		path_list_free(&file_list);
		shutdown_output_destinations();
		return 0;
	}

	/* Frontload large files unless disabled or shuffle mode */
	int should_shuffle = shuffle || (stress_iterations > 1);
	if (!no_frontload && !should_shuffle) {
		frontload_large_files(&file_list);
	}

	/* Clear screen before starting validation output (TUI will set up scrolling region) */
	if (isatty(STDERR_FILENO) && file_list.count > 1) {
		fprintf(stderr, "\033[2J\033[H");  /* Clear screen, move to top */
		fflush(stderr);
	}

	if (any_directories || file_list.count > 1) {
		printf(validate_tr(VALIDATE_STR_FOUND_FILES_TO_VALIDATE), file_list.count);
		printf("%s\n\n", should_shuffle ? " (shuffled)" : "");
		fflush(stdout);  /* Ensure visible before TUI setup */
	} else {
		printf("%s %s\n", validate_tr(VALIDATE_STR_CHECKING), file_list.paths[0]);
		fflush(stdout);
	}

	/* Initialize progress tracking (backed by progrez library) */
	g_file_list_ptr = &file_list;
	progress_init_new(file_list.count, file_list.total_bytes, simple_progress);

	/* Register atexit handler to restore terminal if process exits abnormally */
	if (g_tui_enabled) {
		atexit(restore_terminal_on_exit);
		/* Render initial progress bar immediately so user sees feedback */
		progress_render_force(1);
	}

	validation_counts_t counts = {0};
	validation_counts_t total_counts = {0};
	int failures = 0;
	uint64_t batch_start_ms = get_monotonic_ms();

	const size_t iterations = (stress_iterations > 0) ? stress_iterations : 1;

	for (size_t iter = 0; iter < iterations; iter++) {
		if (stress_iterations > 1) {
			/* Clear progress line before iteration message */
			if (g_tui_enabled) {
				fprintf(stderr, "\r\033[K");
			}
			printf("%s=== Stress iteration %zu/%zu ===%s\n", COLOR_CYAN, iter + 1, iterations, COLOR_RESET);
		}

		if (should_shuffle) {
			shuffle_paths(&file_list, iter + 1);
		}

		counts = (validation_counts_t){0};

		/* Reset progress for each iteration in stress mode */
		if (stress_iterations > 1 && iter > 0) {
			validate_progress_init("validate");
			validate_progress_detect_caps(isatty(STDERR_FILENO), simple_progress, (uint16_t)g_term_width);
			validate_progress_set_determinate((uint64_t)file_list.count, (uint64_t)file_list.total_bytes);
		}

		validate_error_t err = validate_batch(
			(const char* const*)file_list.paths,
			file_list.ids,
			file_list.count,
			(int)jobs,
			on_validation_result,
			&counts
		);

		if (err != VALIDATE_OK) {
			/* Clean up progress display before error */
			if (g_tui_enabled) {
				fprintf(stderr, "\r\033[K");
			}
			fprintf(stderr, "%sError: Validation failed: %s\n%s", COLOR_RED,
				validate_last_error() ? validate_last_error() : "unknown error", COLOR_RESET);
			progress_cleanup_new();
			path_list_free(&file_list);
			shutdown_output_destinations();
			return 1;
		}

		total_counts.valid_count += counts.valid_count;
		total_counts.invalid_count += counts.invalid_count;
		total_counts.unknown_count += counts.unknown_count;

		if (counts.invalid_count > 0) {
			failures = 1;
		}
	}

	/* Check if we were interrupted */
#if defined(_WIN32)
	int was_interrupted = validate_is_interrupted();
#else
	int was_interrupted = (g_sigint_count > 0) || validate_is_interrupted();
#endif

	/* Save counts before freeing */
	size_t total_file_count = file_list.count;
	size_t total_byte_count = file_list.total_bytes;

	/* Clean up progress display */
	progress_cleanup_new();
	g_file_list_ptr = NULL;

	path_list_free(&file_list);

	/* Use total_counts for summary in stress mode, otherwise use last counts */
	validation_counts_t* summary_counts = (stress_iterations > 1) ? &total_counts : &counts;

	/* Show summary (partial if interrupted) */
	const char* rlm = g_rtl_enabled ? RLM : "";
	if (was_interrupted) {
		printf("\n%s%s%s%s\n", rlm, COLOR_YELLOW, validate_tr(VALIDATE_STR_SUMMARY_INTERRUPTED), COLOR_RESET);
	} else {
		printf("\n%s%s%s%s\n", rlm, COLOR_CYAN, validate_tr(VALIDATE_STR_SUMMARY_TITLE), COLOR_RESET);
	}
	if (stress_iterations > 1) {
		printf("%s  Iterations: %zu\n", rlm, stress_iterations);
	}
	size_t total_processed = summary_counts->valid_count + summary_counts->invalid_count + summary_counts->unknown_count;
	if (was_interrupted) {
		printf("%s  %s %zu / %zu files\n", rlm, validate_tr(VALIDATE_STR_SUMMARY_PROCESSED), total_processed, total_file_count);
	}
	printf("%s  %-8s %s%zu%s\n", rlm, validate_tr(VALIDATE_STR_SUMMARY_VALID), COLOR_GREEN, summary_counts->valid_count, COLOR_RESET);
	if (summary_counts->invalid_count > 0) {
		printf("%s  %-8s %s%zu%s\n", rlm, validate_tr(VALIDATE_STR_SUMMARY_INVALID), COLOR_RED, summary_counts->invalid_count, COLOR_RESET);
	} else {
		printf("%s  %-8s %zu\n", rlm, validate_tr(VALIDATE_STR_SUMMARY_INVALID), summary_counts->invalid_count);
	}
	printf("%s  %-8s %zu\n", rlm, validate_tr(VALIDATE_STR_SUMMARY_UNKNOWN), summary_counts->unknown_count);

	/* Elapsed time and throughput */
	uint64_t elapsed_ms = get_monotonic_ms() - batch_start_ms;
	if (elapsed_ms > 0 && total_processed > 0) {
		double elapsed_s = (double)elapsed_ms / 1000.0;
		double files_per_sec = (double)total_processed / elapsed_s;
		double mb_per_sec = ((double)total_byte_count / (1024.0 * 1024.0)) / elapsed_s;
		printf("%s  %-8s %.1fs (%.1f files/sec, %.1f MB/s)\n", rlm, "Time:", elapsed_s, files_per_sec, mb_per_sec);
	}

	/* Reset interrupt flag for potential future use */
	validate_reset_interrupt();

	shutdown_output_destinations();
	return (failures || was_interrupted) ? 1 : 0;
}
