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
		fprintf(stderr, "\rScanning... %zu files found", count);
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

	/* Parse environment variables or use defaults */
	const char* ok_spec = getenv("OK_OUT");
	const char* warn_spec = getenv("WARN_OUT");
	const char* fail_spec = getenv("FAIL_OUT");
	const char* unknown_spec = getenv("UNKNOWN_OUT");
	const char* slow_spec = getenv("SLOW_OUT");
	const char* debug_spec = getenv("DEBUG_OUT");
	const char* begin_spec = getenv("BEGIN_OUT");

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
	const char* env = getenv("MAX_FILES");
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
		if (g_colors_enabled && (f == stdout || f == stderr)) {
			snprintf(line_buf, sizeof(line_buf), "%s%s%s%s\n",
					 color_code, label, COLOR_RESET, rest);
		} else {
			snprintf(line_buf, sizeof(line_buf), "%s%s\n", label, rest);
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

	const char* depth_str = (depth == 1) ? "fully validated" : "structural";

	/* Build depth description with optional ffmpeg suffix */
	char depth_desc[64];
	if (via_ffmpeg) {
		snprintf(depth_desc, sizeof(depth_desc), "%s, via ffmpeg", depth_str);
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
				for (int i = 0; i < 15; i++) {
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
			write_colored_line(&g_warn_out, COLOR_YELLOW, "WARN", rest_buf);
		} else if (bypass_prot) {
			/* NOTICE is a special OK case, goes to g_ok_out */
			snprintf(rest_buf, sizeof(rest_buf), " %s: %s (%s) - trivial protection circumvented",
					 path, fmt_desc, depth_desc);
			write_colored_line(&g_ok_out, COLOR_YELLOW, "NOTICE", rest_buf);
		} else {
			/* OK goes to g_ok_out */
			snprintf(rest_buf, sizeof(rest_buf), " %s: %s (%s)", path, fmt_desc, depth_desc);
			write_colored_line(&g_ok_out, COLOR_GREEN, "OK", rest_buf);
		}
	} else {
		/* FAIL goes to g_fail_out - all details on one line */
		char fail_details[1024] = "";
		int fail_pos = 0;
		fail_pos += snprintf(fail_details, sizeof(fail_details), "%s",
			err_msg[0] ? err_msg : "Unknown error");
		if (has_malformations) {
			for (int i = 0; i < 15; i++) {
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
		write_colored_line(&g_fail_out, COLOR_RED, "FAIL", rest_buf);
	}
}

/* Global file list pointer for callback to access file sizes */
static path_list_t* g_file_list_ptr = NULL;

/* Simple flag for TUI enabled state (set before validation starts) */
static int g_tui_enabled = 0;

/* Forward declarations for progress system (full definitions later) */
typedef struct progress_state_s progress_state_t;
static progress_state_t* g_progress_ptr = NULL;
static void progress_update(progress_state_t* state, size_t file_size, uint64_t elapsed_ms);
static void progress_render(progress_state_t* state);

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

	/* Update progress counters (atomic, no lock needed) */
	size_t file_size = 0;
	if (g_progress_ptr && g_file_list_ptr) {
		/* Find the file size for this file_id */
		int found = 0;
		for (size_t i = 0; i < g_file_list_ptr->count; i++) {
			if (g_file_list_ptr->ids[i] == file_id) {
				file_size = g_file_list_ptr->sizes[i];
				found = 1;
				break;
			}
		}
		/* Debug: check if file_id was found */
		if (!found && getenv("VALIDATE_DEBUG")) {
			fprintf(stderr, "[DEBUG] WARNING: file_id=%u not found in list!\n", file_id);
		}
		/* Update progress if TUI enabled */
		if (g_tui_enabled) {
			/* Ensure minimum 1ms to prevent division-by-zero in rate calculation.
			 * Small files may process in under 1ms. */
			uint64_t elapsed_ms = (elapsed_ns >= 1000000) ? (uint64_t)(elapsed_ns / 1000000) : 1;
			progress_update(g_progress_ptr, file_size, elapsed_ms);
		}
	}

	/* Check if unknown */
	int is_unknown = kv_get_bool(result, "unknown");
	int is_valid = kv_get_bool(result, "valid");

	/* Lock for output + render sequence to prevent race conditions.
	 * This ensures output goes to the scrolling region BEFORE we render
	 * the progress bar in the fixed bottom area. */
	output_lock();

	/* Print result line(s) - these go to the scrolling region */
	if (is_unknown) {
		if (counts) counts->unknown_count++;
		char rest_buf[2048];
		snprintf(rest_buf, sizeof(rest_buf), " %s: Unknown", path);
		write_colored_line(&g_unknown_out, COLOR_CYAN, "UNKNOWN", rest_buf);
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
		write_colored_line(&g_slow_out, COLOR_YELLOW, "SLOW", rest_buf);
	}

	/* Now render progress bar AFTER output (in the fixed bottom area) */
	if (g_tui_enabled && g_progress_ptr) {
		progress_render(g_progress_ptr);
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

	if (getenv("VALIDATE_DEBUG")) {
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

	if (getenv("VALIDATE_DEBUG")) {
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
 * Professional progress display with ETA calculation.
 * Shows status bar at bottom of terminal with:
 * - File count progress (123/456)
 * - Elapsed time (01:23)
 * - ETA (computed immediately; stabilizes as sample window fills)
 * - Progress bar [=====>    ] 45%
 */

#define ETA_SAMPLE_COUNT 100

typedef struct {
	size_t bytes;
	uint64_t elapsed_ms;
} eta_sample_t;

typedef struct {
	eta_sample_t samples[ETA_SAMPLE_COUNT];
	size_t head;
	size_t count;
	size_t total_bytes;        /* Running total for O(1) updates */
	uint64_t total_elapsed_ms; /* Running total */
} eta_fifo_t;

struct progress_state_s {
	size_t total_files;
	size_t total_bytes;
	_Atomic size_t completed_files;
	_Atomic size_t completed_bytes;
#if defined(_WIN32)
	CRITICAL_SECTION lock;
#else
	pthread_mutex_t lock;
#endif
	eta_fifo_t eta;
	uint64_t start_time_ms;
	_Atomic int terminal_width;
	_Atomic int terminal_height;
	_Atomic int resize_pending;
	int tui_enabled;
	int simple_progress;
};

static progress_state_t g_progress;

/* Cross-platform time utilities */
static uint64_t get_current_time_ms(void) {
#if defined(_WIN32)
	FILETIME ft;
	GetSystemTimeAsFileTime(&ft);
	uint64_t t = ((uint64_t)ft.dwHighDateTime << 32) | ft.dwLowDateTime;
	return t / 10000;  /* Convert 100ns to ms */
#else
	struct timeval tv;
	gettimeofday(&tv, NULL);
	return (uint64_t)tv.tv_sec * 1000 + (uint64_t)tv.tv_usec / 1000;
#endif
}

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

/* UTF-8 support detection */
static int g_vt_processing_enabled = 0;

static int detect_utf8_support(void) {
#if defined(_WIN32)
	/* Check if we successfully enabled VT processing and have UTF-8 code page */
	return (GetConsoleOutputCP() == 65001) && g_vt_processing_enabled;
#else
	const char* lang = getenv("LANG");
	const char* lc_all = getenv("LC_ALL");
	const char* term = getenv("TERM");
	if ((lang && strstr(lang, "UTF-8")) ||
		(lang && strstr(lang, "utf-8")) ||
		(lc_all && strstr(lc_all, "UTF-8")) ||
		(lc_all && strstr(lc_all, "utf-8")) ||
		(term && (strstr(term, "xterm") || strstr(term, "256color")))) {
		return 1;
	}
	return 0;
#endif
}

static const char* get_hr_char(int simple) {
	if (simple || !detect_utf8_support()) {
		return "-";
	}
	return "\xe2\x94\x80";  /* UTF-8 encoding of ─ (U+2500) */
}

/* ETA FIFO operations */
static void eta_fifo_init(eta_fifo_t* fifo) {
	fifo->head = 0;
	fifo->count = 0;
	fifo->total_bytes = 0;
	fifo->total_elapsed_ms = 0;
}

static void eta_fifo_push(eta_fifo_t* fifo, size_t bytes, uint64_t elapsed_ms) {
	/* If FIFO is full, subtract the oldest sample from running totals */
	if (fifo->count == ETA_SAMPLE_COUNT) {
		eta_sample_t* oldest = &fifo->samples[fifo->head];
		fifo->total_bytes -= oldest->bytes;
		fifo->total_elapsed_ms -= oldest->elapsed_ms;
	}

	/* Add new sample */
	size_t idx = (fifo->head + fifo->count) % ETA_SAMPLE_COUNT;
	if (fifo->count == ETA_SAMPLE_COUNT) {
		/* Overwrite oldest, move head */
		idx = fifo->head;
		fifo->head = (fifo->head + 1) % ETA_SAMPLE_COUNT;
	} else {
		fifo->count++;
	}

	fifo->samples[idx].bytes = bytes;
	fifo->samples[idx].elapsed_ms = elapsed_ms;
	fifo->total_bytes += bytes;
	fifo->total_elapsed_ms += elapsed_ms;
}

/* Get processing rate in bytes per millisecond */
static double eta_fifo_get_rate(eta_fifo_t* fifo) {
	if (fifo->count == 0 || fifo->total_elapsed_ms == 0) return 0.0;
	return (double)fifo->total_bytes / (double)fifo->total_elapsed_ms;
}

/* Format time as MM:SS or H:MM:SS */
static void format_time(uint64_t ms, char* buf, size_t buf_size) {
	uint64_t total_secs = ms / 1000;
	uint64_t hours = total_secs / 3600;
	uint64_t mins = (total_secs % 3600) / 60;
	uint64_t secs = total_secs % 60;

	if (hours > 0) {
		snprintf(buf, buf_size, "%llu:%02llu:%02llu",
				 (unsigned long long)hours,
				 (unsigned long long)mins,
				 (unsigned long long)secs);
	} else {
		snprintf(buf, buf_size, "%02llu:%02llu",
				 (unsigned long long)mins,
				 (unsigned long long)secs);
	}
}

/* Build progress bar string */
static void build_progress_bar(char* buf, size_t buf_size, int percent, int width) {
	if (width < 5 || buf_size < (size_t)width * 4 + 32) {  /* Extra space for UTF-8 and ANSI codes */
		buf[0] = '\0';
		return;
	}

	/* Simple ASCII fallback: [=====>    ] */
	int inner_width = width - 2;  /* Subtract brackets */
	int filled = (percent * inner_width) / 100;
	if (filled > inner_width) filled = inner_width;

	buf[0] = '[';
	int pos = 1;
	for (int i = 0; i < filled && pos < (int)buf_size - 2; i++) {
		buf[pos++] = '=';
	}
	if (filled > 0 && filled < inner_width && pos < (int)buf_size - 2) {
		buf[pos - 1] = '>';
	}
	for (int i = filled; i < inner_width && pos < (int)buf_size - 2; i++) {
		buf[pos++] = ' ';
	}
	buf[pos++] = ']';
	buf[pos] = '\0';
}

/* Signal handling for terminal resize (Unix only) */
#if !defined(_WIN32)
/* SIGWINCH may not be defined on all systems */
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

/* Initialize progress state */
static void progress_init(progress_state_t* state, size_t total_files, size_t total_bytes, int simple) {
	state->total_files = total_files;
	state->total_bytes = total_bytes;
	atomic_store(&state->completed_files, 0);
	atomic_store(&state->completed_bytes, 0);
#if defined(_WIN32)
	InitializeCriticalSection(&state->lock);
#else
	pthread_mutex_init(&state->lock, NULL);
#endif
	eta_fifo_init(&state->eta);
	state->start_time_ms = get_current_time_ms();

	int width, height;
	get_terminal_size(&width, &height);
	atomic_store(&state->terminal_width, width);
	atomic_store(&state->terminal_height, height);
	atomic_store(&state->resize_pending, 0);
	state->simple_progress = simple;

	/* Enable TUI if:
	 * - stderr is a TTY (not piped/redirected)
	 * - More than 1 file to validate (progress bar is pointless for single file)
	 * - Not using simple progress mode
	 * - Terminal height is at least 5 lines (need room for scrolling region + status)
	 */
	int is_tty = isatty(STDERR_FILENO);
	state->tui_enabled = is_tty && total_files > 1 && !simple && height >= 5;

	/* Debug output for TUI enablement - only when VALIDATE_DEBUG is set */
	if (getenv("VALIDATE_DEBUG")) {
		fprintf(stderr, "[TUI] is_tty=%d, files=%zu, simple=%d, height=%d -> enabled=%d\n",
				is_tty, total_files, simple, height, state->tui_enabled);
		fprintf(stderr, "[TUI] total_bytes=%zu\n", total_bytes);
	}

#if !defined(_WIN32)
	/* Set up signal handlers for terminal resize and clean exit */
	if (state->tui_enabled) {
		struct sigaction sa;

		/* SIGWINCH for terminal resize */
		sa.sa_handler = sigwinch_handler;
		sigemptyset(&sa.sa_mask);
		sa.sa_flags = SA_RESTART;
		sigaction(SIGWINCH, &sa, NULL);

		/* SIGINT for clean Ctrl+C exit (restore terminal before dying) */
		sa.sa_handler = sigint_handler;
		sigemptyset(&sa.sa_mask);
		sa.sa_flags = 0;  /* Don't restart, we want to exit */
		sigaction(SIGINT, &sa, NULL);

		/* Set up scrolling region: lines 1 to (height-2), reserving bottom 2 lines
		 * for progress bar. This allows stdout to scroll normally without
		 * interfering with the fixed progress display at the bottom.
		 *
		 * ANSI escape sequences:
		 * \033[?7l     - Disable line wrap (prevents issues at edge)
		 * \033[1;Nr    - Set scrolling region to lines 1 through N
		 * \033[H       - Move cursor to top-left of scrolling region
		 * \033[<row>H  - Move to specific row (for drawing progress)
		 */
		int scroll_bottom = height - 2;
		if (scroll_bottom < 1) scroll_bottom = 1;

		/* Set scrolling region (screen was already cleared before "Found X files") */
		fprintf(stderr, "\033[1;%dr", scroll_bottom);
		fflush(stderr);
	}
#else
	/* Windows: TUI with scrolling regions requires different approach */
	/* For now, disable TUI on Windows until we implement Console API version */
	state->tui_enabled = 0;
#endif
}

static void progress_cleanup(progress_state_t* state) {
#if defined(_WIN32)
	DeleteCriticalSection(&state->lock);
#else
	pthread_mutex_destroy(&state->lock);
#endif

	/* Clean up TUI and reset terminal state */
	if (state->tui_enabled) {
		int height = atomic_load(&state->terminal_height);

		/* First, clear the progress bar lines BEFORE resetting scrolling region.
		 * This ensures they disappear cleanly. */
		fprintf(stderr, "\033[%d;1H\033[K", height - 1);  /* Clear HR line */
		fprintf(stderr, "\033[%d;1H\033[K", height);       /* Clear progress line */

		/* Reset scrolling region to full terminal.
		 * Note: \033[r also moves cursor to position (1,1) on most terminals. */
		fprintf(stderr, "\033[r");

		/* Re-enable line wrap */
		fprintf(stderr, "\033[?7h");

		/* Move cursor to the very bottom of the terminal.
		 * Use 999 as a large number that gets clamped to actual height. */
		fprintf(stderr, "\033[999;1H");

		/* Scroll the screen so cursor stays at bottom with room for Summary.
		 * Using stdout here so it syncs with the printf Summary output. */
		fflush(stderr);
		printf("\n");  /* One newline to scroll and position for Summary */
		fflush(stdout);
	}

	/* Disable TUI flag so atexit handler won't send another \033[r
	 * (which would move cursor back to 1,1 after Summary is printed) */
	g_tui_enabled = 0;
}

/* atexit handler to restore terminal on abnormal exit (e.g., Ctrl+C) */
static void restore_terminal_on_exit(void) {
	if (g_tui_enabled) {
		/* Reset scrolling region and re-enable line wrap */
		fprintf(stderr, "\033[r\033[?7h");
		fflush(stderr);
	}
}

/* Update progress after completing a file */
static void progress_update(progress_state_t* state, size_t file_size, uint64_t elapsed_ms) {
	if (!state->tui_enabled) return;  /* Skip overhead when TUI disabled */

	atomic_fetch_add(&state->completed_files, 1);
	atomic_fetch_add(&state->completed_bytes, file_size);

	/* Update ETA FIFO (needs lock for the complex struct) */
#if defined(_WIN32)
	EnterCriticalSection(&state->lock);
#else
	pthread_mutex_lock(&state->lock);
#endif
	eta_fifo_push(&state->eta, file_size, elapsed_ms);
#if defined(_WIN32)
	LeaveCriticalSection(&state->lock);
#else
	pthread_mutex_unlock(&state->lock);
#endif
}

/* Render progress display */
static void progress_render(progress_state_t* state) {
	if (!state->tui_enabled) return;

	/* Poll terminal size on every render for responsive resize handling.
	 * This is more reliable than SIGWINCH alone since some environments
	 * (like tmux resize-pane) don't generate the signal. */
	int new_width, new_height;
	get_terminal_size(&new_width, &new_height);

	int old_height = atomic_load(&state->terminal_height);
	if (new_height != old_height) {
		/* Height changed - re-setup scrolling region */
		int scroll_bottom = new_height - 2;
		if (scroll_bottom < 1) scroll_bottom = 1;
		fprintf(stderr, "\033[1;%dr", scroll_bottom);
	}

	atomic_store(&state->terminal_width, new_width);
	atomic_store(&state->terminal_height, new_height);

#if !defined(_WIN32)
	/* Also reset signal flag if it was set */
	g_resize_signal = 0;
#endif

	int term_width = atomic_load(&state->terminal_width);
	if (term_width < 40) return;  /* Too narrow for meaningful display */

	/* Debug width values if VALIDATE_DEBUG is set */
	static int debug_printed = 0;
	if (getenv("VALIDATE_DEBUG") && debug_printed < 5) {
		size_t cb = atomic_load(&state->completed_bytes);
		size_t cf = atomic_load(&state->completed_files);
		fprintf(stderr, "[TUI] files=%zu/%zu bytes=%zu/%zu\n",
				cf, state->total_files, cb, state->total_bytes);
		debug_printed++;
	}

	size_t completed = atomic_load(&state->completed_files);
	size_t completed_bytes = atomic_load(&state->completed_bytes);
	uint64_t now = get_current_time_ms();
	uint64_t elapsed = now - state->start_time_ms;

	/* Calculate percentage */
	int percent = 0;
	if (state->total_bytes > 0) {
		percent = (int)((completed_bytes * 100) / state->total_bytes);
	} else if (state->total_files > 0) {
		percent = (int)((completed * 100) / state->total_files);
	}
	if (percent > 100) percent = 100;

	/* Format elapsed time */
	char elapsed_str[16];
	format_time(elapsed, elapsed_str, sizeof(elapsed_str));

	/* Calculate and format ETA */
	char eta_str[32];
#if defined(_WIN32)
	EnterCriticalSection(&state->lock);
#else
	pthread_mutex_lock(&state->lock);
#endif
	size_t samples = state->eta.count;
	double rate = eta_fifo_get_rate(&state->eta);
#if defined(_WIN32)
	LeaveCriticalSection(&state->lock);
#else
	pthread_mutex_unlock(&state->lock);
#endif

	/* Compute ETA using elapsed-time extrapolation based on percentage.
	 * The bytes-based rate from FIFO doesn't work well because:
	 * - Small files have high overhead per byte (constant overhead dominates)
	 * - This causes wildly wrong ETAs when file sizes vary
	 * Instead: if X% done in T seconds, remaining = T * (100-X)/X */
	(void)samples;  /* Unused now */
	(void)rate;     /* Unused now */
	if (percent <= 0 || percent >= 100 || elapsed == 0) {
		snprintf(eta_str, sizeof(eta_str), "--:--");
	} else {
		uint64_t eta_ms = (elapsed * (100 - percent)) / percent;
		format_time(eta_ms, eta_str, sizeof(eta_str));
	}

	/* Build the status line */
	char count_str[32];
	snprintf(count_str, sizeof(count_str), "(%zu/%zu)", completed, state->total_files);

	/* Calculate available space for progress bar */
	/* Format: (123/456)  01:23  ETA 02:34  [=====>    ] 45% */
	int fixed_len = (int)strlen(count_str) + 2 + (int)strlen(elapsed_str) + 6 +
					(int)strlen(eta_str) + 2 + 5;  /* 5 for " 100%" */
	int bar_width = term_width - fixed_len;
	if (bar_width < 10) bar_width = 10;

	/* Get terminal height for cursor positioning */
	int term_height = atomic_load(&state->terminal_height);

	/* Save cursor position, draw progress at bottom, restore cursor.
	 * This allows the progress bar to update without disturbing
	 * the scrolling output above it.
	 *
	 * Layout (bottom 2 lines):
	 *   Line height-1: Horizontal rule (visual separator)
	 *   Line height:   Progress bar with stats
	 */
	fprintf(stderr, "\033[s");  /* Save cursor position */

	/* Draw horizontal rule on line height-1 */
	fprintf(stderr, "\033[%d;1H\033[K", term_height - 1);
	if (state->simple_progress) {
		/* Simple ASCII horizontal rule */
		for (int i = 0; i < term_width; i++) {
			fprintf(stderr, "-");
		}
	} else {
		/* Fancy UTF-8 box drawing with color */
		fprintf(stderr, "\033[38;5;240m");  /* Dark gray color */
		for (int i = 0; i < term_width; i++) {
			fprintf(stderr, "─");  /* UTF-8 box drawing horizontal */
		}
		fprintf(stderr, "\033[0m");  /* Reset color */
	}

	/* Draw progress bar on last line */
	fprintf(stderr, "\033[%d;1H\033[K", term_height);

	if (state->simple_progress) {
		/* Simple ASCII progress bar - buffer needs to fit widest terminals */
		char bar_str[1024];
		build_progress_bar(bar_str, sizeof(bar_str), percent, bar_width);
		fprintf(stderr, "%s  %s  ETA %s  %s %3d%%",
				count_str, elapsed_str, eta_str, bar_str, percent);
	} else {
		/* Fancy progress bar with UTF-8 blocks and color gradient */
		/* Print stats first */
		fprintf(stderr, "\033[38;5;245m%s\033[0m  ", count_str);  /* Dim count */
		fprintf(stderr, "\033[38;5;75m%s\033[0m  ", elapsed_str);  /* Cyan elapsed */
		fprintf(stderr, "\033[38;5;245mETA \033[38;5;75m%s\033[0m  ", eta_str);  /* Cyan ETA */

		/* Fancy progress bar: ▓▓▓▓▓▓▓▓░░░░░░ */
		/* Using block characters with color gradient from cyan (38) to blue (33) */
		int inner_width = bar_width - 2;  /* Account for brackets */
		int filled = (percent * inner_width) / 100;
		if (filled > inner_width) filled = inner_width;

		/* Partial block characters for sub-cell precision: ▏▎▍▌▋▊▉█ */
		/* Each represents 1/8 of a cell */
		static const char* partial_blocks[] = {" ", "▏", "▎", "▍", "▌", "▋", "▊", "▉", "█"};

		/* Calculate fractional fill for sub-cell precision */
		int fill_eighths = (percent * inner_width * 8) / 100;
		int full_blocks = fill_eighths / 8;
		int partial = fill_eighths % 8;

		fprintf(stderr, "\033[38;5;39m");  /* Bright cyan for filled */
		for (int i = 0; i < full_blocks && i < inner_width; i++) {
			fprintf(stderr, "█");
		}
		if (full_blocks < inner_width && partial > 0) {
			fprintf(stderr, "%s", partial_blocks[partial]);
			full_blocks++;  /* Count the partial as taking a slot */
		}
		fprintf(stderr, "\033[38;5;238m");  /* Dark gray for empty */
		for (int i = full_blocks; i < inner_width; i++) {
			fprintf(stderr, "░");
		}
		fprintf(stderr, "\033[0m");  /* Reset */

		/* Percentage with color based on progress */
		if (percent >= 90) {
			fprintf(stderr, " \033[38;5;46m%3d%%\033[0m", percent);  /* Green */
		} else if (percent >= 50) {
			fprintf(stderr, " \033[38;5;226m%3d%%\033[0m", percent);  /* Yellow */
		} else {
			fprintf(stderr, " \033[38;5;75m%3d%%\033[0m", percent);  /* Cyan */
		}
	}

	fprintf(stderr, "\033[u");  /* Restore cursor position */
	fflush(stderr);
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

	/* Collect positional arguments (paths) */
	const char** paths = NULL;
	size_t path_count = 0;
	size_t path_capacity = 0;

	for (int i = 1; i < argc; i++) {
		const char* arg = argv[i];
		/* Help: --help, -h (and /help, /h, /? on Windows) */
		if (strcmp(arg, "--help") == 0 || strcmp(arg, "-h") == 0
#ifdef _WIN32
		    || strcmp(arg, "/help") == 0 || strcmp(arg, "/h") == 0 || strcmp(arg, "/?") == 0
#endif
		) {
			print_usage(argv[0]);
			free(paths);
			return 0;
		}
		/* Version: --version (and /version on Windows) */
		if (strcmp(arg, "--version") == 0
#ifdef _WIN32
		    || strcmp(arg, "/version") == 0
#endif
		) {
			printf("%s\n", validate_version());
			free(paths);
			return 0;
		}
		/* Shuffle: --shuffle */
		if (strcmp(arg, "--shuffle") == 0) {
			shuffle = 1;
			continue;
		}
		/* Stress: --stress N */
		if (strcmp(arg, "--stress") == 0) {
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
		}
		/* Jobs: --jobs, -j (and /jobs, /j on Windows) */
		if (strcmp(arg, "--jobs") == 0 || strcmp(arg, "-j") == 0
#ifdef _WIN32
		    || strcmp(arg, "/jobs") == 0 || strcmp(arg, "/j") == 0
#endif
		) {
			if (i + 1 >= argc) {
				fprintf(stderr, "%sError: --jobs requires a value\n%s", COLOR_RED, COLOR_RESET);
				free(paths);
				return 2;
			}
			jobs = (size_t)strtoull(argv[++i], NULL, 10);
			continue;
		}
		/* No color: --no-color */
		if (strcmp(arg, "--no-color") == 0) {
			disable_colors();
			continue;
		}
		/* Force color: --color */
		if (strcmp(arg, "--color") == 0) {
			enable_colors();  /* Force colors on even if not TTY */
			continue;
		}
		/* No frontload: --no-frontload */
		if (strcmp(arg, "--no-frontload") == 0) {
			no_frontload = 1;
			continue;
		}
		/* Simple progress: --simple-progress */
		if (strcmp(arg, "--simple-progress") == 0) {
			simple_progress = 1;
			continue;
		}
		/* Unknown option check */
		if (arg[0] == '-') {
			fprintf(stderr, "%sError: Unknown option: %s\n%s", COLOR_RED, arg, COLOR_RESET);
			free(paths);
			return 2;
		}
#ifdef _WIN32
		/* On Windows, / is an option prefix (but allow paths like C:\ or \\server) */
		if (arg[0] == '/' && arg[1] != '\0' && arg[1] != '/' && arg[1] != '\\') {
			fprintf(stderr, "%sError: Unknown option: %s\n%s", COLOR_RED, arg, COLOR_RESET);
			free(paths);
			return 2;
		}
#endif
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
		printf("Found %zu files to validate.%s\n\n", file_list.count,
			should_shuffle ? " (shuffled)" : "");
		fflush(stdout);  /* Ensure visible before TUI setup */
	} else {
		printf("Checking: %s\n", file_list.paths[0]);
		fflush(stdout);
	}

	/* Initialize progress tracking */
	g_file_list_ptr = &file_list;
	progress_init(&g_progress, file_list.count, file_list.total_bytes, simple_progress);
	g_progress_ptr = &g_progress;
	g_tui_enabled = g_progress.tui_enabled;

	/* Register atexit handler to restore terminal if process exits abnormally */
	if (g_tui_enabled) {
		atexit(restore_terminal_on_exit);
		/* Render initial progress bar immediately so user sees feedback */
		progress_render(&g_progress);
	}

	validation_counts_t counts = {0};
	validation_counts_t total_counts = {0};
	int failures = 0;

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
			atomic_store(&g_progress.completed_files, 0);
			atomic_store(&g_progress.completed_bytes, 0);
			g_progress.start_time_ms = get_current_time_ms();
			eta_fifo_init(&g_progress.eta);
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
			progress_cleanup(&g_progress);
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

	/* Debug: show final byte counts */
	if (getenv("VALIDATE_DEBUG") && g_tui_enabled) {
		size_t final_bytes = atomic_load(&g_progress.completed_bytes);
		fprintf(stderr, "[DEBUG] Final: completed_bytes=%zu total_bytes=%zu\n",
				final_bytes, g_progress.total_bytes);
	}

	/* Check if we were interrupted */
#if defined(_WIN32)
	int was_interrupted = validate_is_interrupted();
#else
	int was_interrupted = (g_sigint_count > 0) || validate_is_interrupted();
#endif

	/* Save file count before freeing */
	size_t total_file_count = file_list.count;

	/* Clean up progress display */
	progress_cleanup(&g_progress);
	g_progress_ptr = NULL;
	g_file_list_ptr = NULL;

	path_list_free(&file_list);

	/* Use total_counts for summary in stress mode, otherwise use last counts */
	validation_counts_t* summary_counts = (stress_iterations > 1) ? &total_counts : &counts;

	/* Show summary (partial if interrupted) */
	if (was_interrupted) {
		printf("\n%sInterrupted - Partial Summary:%s\n", COLOR_YELLOW, COLOR_RESET);
	} else {
		printf("\n%sSummary:%s\n", COLOR_CYAN, COLOR_RESET);
	}
	if (stress_iterations > 1) {
		printf("  Iterations: %zu\n", stress_iterations);
	}
	size_t total_processed = summary_counts->valid_count + summary_counts->invalid_count + summary_counts->unknown_count;
	if (was_interrupted) {
		printf("  Processed: %zu / %zu files\n", total_processed, total_file_count);
	}
	printf("  Valid:   %s%zu%s\n", COLOR_GREEN, summary_counts->valid_count, COLOR_RESET);
	if (summary_counts->invalid_count > 0) {
		printf("  Invalid: %s%zu%s\n", COLOR_RED, summary_counts->invalid_count, COLOR_RESET);
	} else {
		printf("  Invalid: %zu\n", summary_counts->invalid_count);
	}
	printf("  Unknown: %zu\n", summary_counts->unknown_count);

	/* Reset interrupt flag for potential future use */
	validate_reset_interrupt();

	shutdown_output_destinations();
	return (failures || was_interrupted) ? 1 : 0;
}
