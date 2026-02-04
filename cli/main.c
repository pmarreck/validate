/* Enable POSIX extensions (strdup, etc.) on strict C99/C11 systems like musl */
#define _POSIX_C_SOURCE 200809L

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/stat.h>
#include <dirent.h>
#include <time.h>
#if defined(_WIN32)
#include <windows.h>
#include <psapi.h>
#include <io.h>
#define isatty _isatty
#else
#include <unistd.h>
#endif
#if defined(__APPLE__)
#include <mach/mach.h>
#endif
#include "validate_core.h"

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
	size_t count;
	size_t capacity;
	size_t max_files;  /* 0 = unlimited */
} path_list_t;

static int path_list_init(path_list_t* list, size_t initial_capacity, size_t max_files) {
	list->paths = (char**)malloc(initial_capacity * sizeof(char*));
	list->ids = (uint32_t*)malloc(initial_capacity * sizeof(uint32_t));
	if (!list->paths || !list->ids) {
		free(list->paths);
		free(list->ids);
		return -1;
	}
	list->count = 0;
	list->capacity = initial_capacity;
	list->max_files = max_files;
	return 0;
}

static void path_list_free(path_list_t* list) {
	for (size_t i = 0; i < list->count; i++) {
		free(list->paths[i]);
	}
	free(list->paths);
	free(list->ids);
	list->paths = NULL;
	list->ids = NULL;
	list->count = 0;
	list->capacity = 0;
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

static int path_list_add(path_list_t* list, const char* path) {
	if (list->max_files > 0 && list->count >= list->max_files) {
		return 0;  /* Silently stop adding (hit limit) */
	}
	if (list->count >= list->capacity) {
		size_t new_capacity = list->capacity * 2;
		char** new_paths = (char**)realloc(list->paths, new_capacity * sizeof(char*));
		uint32_t* new_ids = (uint32_t*)realloc(list->ids, new_capacity * sizeof(uint32_t));
		if (!new_paths || !new_ids) return -1;
		list->paths = new_paths;
		list->ids = new_ids;
		list->capacity = new_capacity;
	}
	list->paths[list->count] = strdup(path);
	if (!list->paths[list->count]) return -1;
	list->ids[list->count] = (uint32_t)list->count;
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
		return path_list_add(list, path);
	} else if (S_ISDIR(st.st_mode)) {
		/* Check if this is a bundle directory (e.g., .git) */
		if (is_bundle_directory(path)) {
			/* Add bundle directory as a single validation item - don't recurse */
			return path_list_add(list, path);
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

		/* Build full path (handle trailing slash in dir_path) */
		size_t dir_len = strlen(dir_path);
		size_t name_len = strlen(entry->d_name);
		int needs_slash = (dir_len > 0 && dir_path[dir_len - 1] != '/') ? 1 : 0;
		size_t path_len = dir_len + needs_slash + name_len;
		char* full_path = (char*)malloc(path_len + 1);
		if (!full_path) {
			closedir(dir);
			return -1;
		}

		memcpy(full_path, dir_path, dir_len);
		if (needs_slash) {
			full_path[dir_len] = '/';
		}
		memcpy(full_path + dir_len + needs_slash, entry->d_name, name_len + 1);

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

static FILE* g_unknown_out = NULL;
static int g_unknown_out_enabled = 0;

static void init_unknown_out(void) {
	const char* path = getenv("UNKNOWN_OUT");
	if (!path || path[0] == '\0') {
		return;
	}
	g_unknown_out = fopen(path, "a");
	if (!g_unknown_out) {
		fprintf(stderr, "%sWarning: failed to open UNKNOWN_OUT path: %s\n%s", COLOR_YELLOW, path, COLOR_RESET);
		return;
	}
	g_unknown_out_enabled = 1;
}

static void shutdown_unknown_out(void) {
	if (g_unknown_out) {
		fclose(g_unknown_out);
		g_unknown_out = NULL;
	}
	g_unknown_out_enabled = 0;
}

static FILE* g_fail_out = NULL;
static int g_fail_out_enabled = 0;

static void init_fail_out(void) {
	const char* path = getenv("FAIL_OUT");
	if (!path || path[0] == '\0') {
		return;
	}
	g_fail_out = fopen(path, "a");
	if (!g_fail_out) {
		fprintf(stderr, "%sWarning: failed to open FAIL_OUT path: %s\n%s", COLOR_YELLOW, path, COLOR_RESET);
		return;
	}
	g_fail_out_enabled = 1;
}

static void shutdown_fail_out(void) {
	if (g_fail_out) {
		fclose(g_fail_out);
		g_fail_out = NULL;
	}
	g_fail_out_enabled = 0;
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
	int via_videotoolbox = kv_get_bool(result, "via_videotoolbox");

	const char* depth_str = (depth == 1) ? "fully validated" : "structural";

	/* Build depth description with optional ffmpeg/videotoolbox suffix */
	char depth_desc[64];
	if (via_videotoolbox) {
		snprintf(depth_desc, sizeof(depth_desc), "%s, via VideoToolbox", depth_str);
	} else if (via_ffmpeg) {
		snprintf(depth_desc, sizeof(depth_desc), "%s, via ffmpeg", depth_str);
	} else {
		snprintf(depth_desc, sizeof(depth_desc), "%s", depth_str);
	}

	int has_malformations = (malform_bits != 0);
	int has_warning = (warn_msg[0] != '\0');

	if (is_valid) {
		if (has_malformations || has_warning) {
			printf("%sWARN%s %s: %s (%s)\n", COLOR_YELLOW, COLOR_RESET, path, fmt_desc, depth_desc);
			if (has_malformations) {
				for (int i = 0; i < 15; i++) {
					if (malform_bits & (1ULL << i)) {
						const char* desc = validate_malform_desc(i);
						printf("  %s->%s %s\n", COLOR_YELLOW, COLOR_RESET, desc ? desc : "Unknown issue");
					}
				}
			}
			if (has_warning) {
				printf("  %s->%s %s\n", COLOR_YELLOW, COLOR_RESET, warn_msg);
			}
		} else if (bypass_prot) {
			printf("%sNOTICE%s %s: %s (%s) - trivial protection circumvented\n",
				   COLOR_YELLOW, COLOR_RESET, path, fmt_desc, depth_desc);
		} else {
			printf("%sOK%s %s: %s (%s)\n", COLOR_GREEN, COLOR_RESET, path, fmt_desc, depth_desc);
		}
	} else {
		/* FAILs go to stderr for easy redirection */
		fprintf(stderr, "%sFAIL%s %s: %s - %s\n",
			   COLOR_RED, COLOR_RESET, path, fmt_desc,
			   err_msg[0] ? err_msg : "Unknown error");
		/* Also write to FAIL_OUT file if configured (without colors) */
		if (g_fail_out_enabled && g_fail_out) {
			fprintf(g_fail_out, "FAIL %s: %s - %s\n", path, fmt_desc,
				   err_msg[0] ? err_msg : "Unknown error");
		}
		/* Also show malformations for invalid files */
		if (has_malformations) {
			for (int i = 0; i < 15; i++) {
				if (malform_bits & (1ULL << i)) {
					const char* desc = validate_malform_desc(i);
					fprintf(stderr, "  %s->%s %s\n", COLOR_YELLOW, COLOR_RESET, desc ? desc : "Unknown issue");
					if (g_fail_out_enabled && g_fail_out) {
						fprintf(g_fail_out, "  -> %s\n", desc ? desc : "Unknown issue");
					}
				}
			}
		}
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
	(void)file_id;

	/* Get elapsed time in nanoseconds */
	int64_t elapsed_ns = kv_get_i64(result, "elapsed_ns_u64");

	if (elapsed_ns >= SLOW_THRESHOLD_NS) {
		double elapsed_s = (double)elapsed_ns / 1000000000.0;
		fprintf(stderr, "%sSLOW%s %s: %.2fs\n", COLOR_YELLOW, COLOR_RESET, path, elapsed_s);
	}

	/* Check if unknown */
	int is_unknown = kv_get_bool(result, "unknown");
	int is_valid = kv_get_bool(result, "valid");

	if (is_unknown) {
		if (counts) counts->unknown_count++;
		if (g_unknown_out_enabled && g_unknown_out) {
			fprintf(g_unknown_out, "UNKNOWN %s\n", path);
			fflush(g_unknown_out);
		} else {
			printf("%sUNKNOWN%s %s: Unknown\n", COLOR_CYAN, COLOR_RESET, path);
		}
	} else if (is_valid) {
		if (counts) counts->valid_count++;
		print_validation_result(path, result);
	} else {
		if (counts) counts->invalid_count++;
		print_validation_result(path, result);
	}

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
	}
}

static void print_usage(const char* program) {
	printf("validate - Deterministic file format validation\n\n");
	printf("USAGE:\n");
	printf("    %s <path>\n", program);
	printf("\n");
	printf("OPTIONS:\n");
#ifdef _WIN32
	printf("    /version, --version   Print version\n");
	printf("    /?, /h, /help, --help Show this help\n");
	printf("    /j N, /jobs N         Number of parallel workers (0 = auto)\n");
	printf("    --no-color            Disable colored output\n");
	printf("    --color               Force colored output (even when piping)\n");
	printf("    --shuffle             Shuffle file order (helps expose race conditions)\n");
	printf("    --stress N            Repeat validation N times with shuffling\n");
#else
	printf("    --version    Print version\n");
	printf("    --help       Show this help\n");
	printf("    --jobs N     Number of parallel workers (0 = auto)\n");
	printf("    -j N         Alias for --jobs\n");
	printf("    --no-color   Disable colored output\n");
	printf("    --color      Force colored output (even when piping)\n");
	printf("    --shuffle    Shuffle file order (helps expose race conditions)\n");
	printf("    --stress N   Repeat validation N times with shuffling\n");
#endif
	printf("\n");
	printf("ENVIRONMENT:\n");
	printf("    NO_COLOR      Disable colored output\n");
	printf("    FAIL_OUT      Path to append failed validation results\n");
	printf("    UNKNOWN_OUT   Path to append unknown file paths\n");
	printf("    MAX_FILES     Limit number of files to validate\n");
	printf("\n");
	printf("OUTPUT:\n");
	printf("    OK      Valid file (stdout)\n");
	printf("    WARN    Valid file with non-fatal issues (stdout)\n");
	printf("    FAIL    Invalid file (stderr)\n");
	printf("    UNKNOWN Unrecognized format (stdout, or UNKNOWN_OUT if set)\n");
	printf("\n");
	printf("FAILs go to stderr for easy redirection (2>fails.log).\n");
	printf("OK, WARN, and UNKNOWN go to stdout.\n");
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

	init_unknown_out();
	init_fail_out();

	const size_t max_files = get_env_max_files();

	/* Collect ALL files from ALL paths into a single list */
	path_list_t file_list;
	if (path_list_init(&file_list, 1024, max_files) != 0) {
		fprintf(stderr, "%sError: Out of memory\n%s", COLOR_RED, COLOR_RESET);
		free(paths);
		shutdown_unknown_out();
		shutdown_fail_out();
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
				path_list_add(&file_list, paths[i]);
			} else {
				enumerate_directory(paths[i], &file_list);
			}
		} else if (S_ISREG(st.st_mode)) {
			path_list_add(&file_list, paths[i]);
		} else {
			fprintf(stderr, "%sWarning: Skipping unsupported path type: %s\n%s", COLOR_YELLOW, paths[i], COLOR_RESET);
		}
	}
	finish_enum_progress();
	free(paths);

	if (file_list.count == 0) {
		printf("No files found.\n");
		path_list_free(&file_list);
		shutdown_unknown_out();
		shutdown_fail_out();
		return 0;
	}

	if (any_directories || file_list.count > 1) {
		printf("Found %zu files to validate.%s\n\n", file_list.count,
			(shuffle || stress_iterations > 1) ? " (shuffled)" : "");
	} else {
		printf("Checking: %s\n", file_list.paths[0]);
	}

	validation_counts_t counts = {0};
	validation_counts_t total_counts = {0};
	int failures = 0;

	const size_t iterations = (stress_iterations > 0) ? stress_iterations : 1;
	int should_shuffle = shuffle || (stress_iterations > 1);

	for (size_t iter = 0; iter < iterations; iter++) {
		if (stress_iterations > 1) {
			printf("%s=== Stress iteration %zu/%zu ===%s\n", COLOR_CYAN, iter + 1, iterations, COLOR_RESET);
		}

		if (should_shuffle) {
			shuffle_paths(&file_list, iter + 1);
		}

		counts = (validation_counts_t){0};

		validate_error_t err = validate_batch(
			(const char* const*)file_list.paths,
			file_list.ids,
			file_list.count,
			(int)jobs,
			on_validation_result,
			&counts
		);

		if (err != VALIDATE_OK) {
			fprintf(stderr, "%sError: Validation failed: %s\n%s", COLOR_RED,
				validate_last_error() ? validate_last_error() : "unknown error", COLOR_RESET);
			path_list_free(&file_list);
			shutdown_unknown_out();
		shutdown_fail_out();
			return 1;
		}

		total_counts.valid_count += counts.valid_count;
		total_counts.invalid_count += counts.invalid_count;
		total_counts.unknown_count += counts.unknown_count;

		if (counts.invalid_count > 0) {
			failures = 1;
		}
	}

	path_list_free(&file_list);

	/* Use total_counts for summary in stress mode, otherwise use last counts */
	validation_counts_t* summary_counts = (stress_iterations > 1) ? &total_counts : &counts;

	printf("\n%sSummary:%s\n", COLOR_CYAN, COLOR_RESET);
	if (stress_iterations > 1) {
		printf("  Iterations: %zu\n", stress_iterations);
	}
	printf("  Valid:   %s%zu%s\n", COLOR_GREEN, summary_counts->valid_count, COLOR_RESET);
	if (summary_counts->invalid_count > 0) {
		printf("  Invalid: %s%zu%s\n", COLOR_RED, summary_counts->invalid_count, COLOR_RESET);
	} else {
		printf("  Invalid: %zu\n", summary_counts->invalid_count);
	}
	printf("  Unknown: %zu\n", summary_counts->unknown_count);

	shutdown_unknown_out();
		shutdown_fail_out();
	return failures ? 1 : 0;
}
