/* Enable POSIX extensions (strdup, etc.) on strict C99/C11 systems like musl */
#define _POSIX_C_SOURCE 200809L

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
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

/* ========== File Path Collection ========== */

typedef struct {
	char** paths;
	size_t count;
	size_t capacity;
	size_t max_files;  /* 0 = unlimited */
} path_list_t;

static int path_list_init(path_list_t* list, size_t initial_capacity, size_t max_files) {
	list->paths = (char**)malloc(initial_capacity * sizeof(char*));
	if (!list->paths) return -1;
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
	list->paths = NULL;
	list->count = 0;
	list->capacity = 0;
}

static int path_list_add(path_list_t* list, const char* path) {
	if (list->max_files > 0 && list->count >= list->max_files) {
		return 0;  /* Silently stop adding (hit limit) */
	}
	if (list->count >= list->capacity) {
		size_t new_capacity = list->capacity * 2;
		char** new_paths = (char**)realloc(list->paths, new_capacity * sizeof(char*));
		if (!new_paths) return -1;
		list->paths = new_paths;
		list->capacity = new_capacity;
	}
	list->paths[list->count] = strdup(path);
	if (!list->paths[list->count]) return -1;
	list->count++;
	return 0;
}

/* Recursive directory enumeration */
static int enumerate_directory(const char* dir_path, path_list_t* list);

/* Check if a path is a bundle directory (e.g., .git) that should be
 * validated as a single unit rather than recursed into. */
static int is_bundle_directory(const char* path) {
	size_t len = strlen(path);
	/* Check for path ending in "/.git" or exactly ".git" */
	if (len >= 4) {
		const char* last4 = path + len - 4;
		if (strcmp(last4, ".git") == 0) {
			/* Either exactly ".git" or ends with "/.git" */
			if (len == 4 || path[len - 5] == '/') {
				return 1;
			}
		}
	}
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
		 * rather than failing the entire enumeration.
		 * This matches how enumerate_path() handles inaccessible files. */
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
#define SLOW_THRESHOLD_SECONDS 5.0

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

static FILE* g_mem_telemetry_file = NULL;
static int g_mem_telemetry_enabled = 0;
static size_t g_mem_telemetry_every = 1;
static size_t g_mem_telemetry_count = 0;
static size_t g_mem_telemetry_last_rss = 0;
static FILE* g_unknown_out = NULL;
static int g_unknown_out_enabled = 0;

static int env_truthy(const char* value) {
	if (!value || value[0] == '\0') {
		return 0;
	}
	if (strcmp(value, "1") == 0 || strcmp(value, "true") == 0 || strcmp(value, "TRUE") == 0 ||
		strcmp(value, "yes") == 0 || strcmp(value, "YES") == 0 || strcmp(value, "on") == 0 ||
		strcmp(value, "ON") == 0) {
		return 1;
	}
	return 0;
}

static size_t parse_env_size(const char* value, size_t fallback) {
	if (!value || value[0] == '\0') {
		return fallback;
	}
	char* end = NULL;
	unsigned long long parsed = strtoull(value, &end, 10);
	if (end == value || parsed == 0) {
		return fallback;
	}
	return (size_t)parsed;
}

static size_t get_rss_bytes(void) {
#if defined(__APPLE__)
	mach_task_basic_info_data_t info;
	mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
	if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) {
		return 0;
	}
	return (size_t)info.resident_size;
#elif defined(__linux__)
	FILE* statm = fopen("/proc/self/statm", "r");
	if (!statm) {
		return 0;
	}
	long resident_pages = 0;
	if (fscanf(statm, "%*s %ld", &resident_pages) != 1) {
		fclose(statm);
		return 0;
	}
	fclose(statm);
	long page_size = sysconf(_SC_PAGESIZE);
	if (page_size <= 0 || resident_pages <= 0) {
		return 0;
	}
	return (size_t)resident_pages * (size_t)page_size;
#elif defined(_WIN32)
	PROCESS_MEMORY_COUNTERS pmc;
	HANDLE process = GetCurrentProcess();
	if (GetProcessMemoryInfo(process, &pmc, sizeof(pmc)) == 0) {
		return 0;
	}
	return (size_t)pmc.WorkingSetSize;
#else
	return 0;
#endif
}

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

static void init_mem_telemetry(void) {
	const char* enabled = getenv("MEM_TELEMETRY");
	if (!env_truthy(enabled)) {
		return;
	}
	const char* every = getenv("MEM_TELEMETRY_EVERY");
	g_mem_telemetry_every = parse_env_size(every, 1);

	const char* path = getenv("MEM_TELEMETRY_PATH");
	if (path && path[0] != '\0') {
		g_mem_telemetry_file = fopen(path, "a");
		if (!g_mem_telemetry_file) {
			fprintf(stderr, "%sError: Failed to open MEM_TELEMETRY_PATH=%s\n%s", COLOR_RED, path, COLOR_RESET);
			return;
		}
	} else {
		g_mem_telemetry_file = stderr;
	}
	setvbuf(g_mem_telemetry_file, NULL, _IOLBF, 0);
	g_mem_telemetry_enabled = 1;
}

static void shutdown_mem_telemetry(void) {
	if (g_mem_telemetry_enabled && g_mem_telemetry_file && g_mem_telemetry_file != stderr) {
		fclose(g_mem_telemetry_file);
	}
	g_mem_telemetry_file = NULL;
	g_mem_telemetry_enabled = 0;
}

static void log_mem_telemetry(const char* path, const owned_result_t* result, double elapsed_seconds) {
	if (!g_mem_telemetry_enabled) {
		return;
	}
	g_mem_telemetry_count += 1;
	if (g_mem_telemetry_every > 1 && (g_mem_telemetry_count % g_mem_telemetry_every) != 0) {
		return;
	}
	const size_t rss_bytes = get_rss_bytes();
	if (rss_bytes == 0) {
		return;
	}
	const double rss_mb = (double)rss_bytes / (1024.0 * 1024.0);
	const long delta_bytes = (long)rss_bytes - (long)g_mem_telemetry_last_rss;
	g_mem_telemetry_last_rss = rss_bytes;
	fprintf(g_mem_telemetry_file,
		"MEM rss=%.1fMB delta=%ldB elapsed=%.3fs format=%s path=%s\n",
		rss_mb,
		delta_bytes,
		elapsed_seconds,
		result->format_description ? result->format_description : "Unknown",
		path);
}

static const char* validation_depth_description(validation_depth_t depth) {
	switch (depth) {
		case ES_VALIDATION_DEPTH_STRUCTURAL: return "structural";
		case ES_VALIDATION_DEPTH_FULL: return "fully validated";
	}
	return "unknown";
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

static void print_validation_result(const char* path, const owned_result_t* result) {
	const char* format_desc = result->format_description ? result->format_description : "Unknown";
	const char* base_depth_desc = validation_depth_description(result->validation_depth);
	/* Build depth description with optional ffmpeg suffix */
	char depth_desc_buf[64];
	if (result->validated_via_ffmpeg) {
		snprintf(depth_desc_buf, sizeof(depth_desc_buf), "%s, via ffmpeg", base_depth_desc);
	} else {
		snprintf(depth_desc_buf, sizeof(depth_desc_buf), "%s", base_depth_desc);
	}
	const char* depth_desc = depth_desc_buf;
	int has_malformations = result->malformation_bits != 0;
	int has_warning = result->warning_message != NULL;

	if (result->is_valid) {
		if (has_malformations || has_warning) {
			printf("%sWARN%s %s: %s (%s)\n", COLOR_YELLOW, COLOR_RESET, path, format_desc, depth_desc);
			if (has_malformations) {
				for (int i = 0; i <= ES_MALFORMATION_LAST; i++) {
					if (result->malformation_bits & (1ULL << i)) {
						const char* desc = malformation_description((malformation_t)i);
						printf("  %s->%s %s\n", COLOR_YELLOW, COLOR_RESET, desc ? desc : "Unknown issue");
					}
				}
			}
			if (has_warning) {
				printf("  %s->%s %s\n", COLOR_YELLOW, COLOR_RESET, result->warning_message);
			}
		} else if (result->circumvented_trivial_protection) {
			printf("%sNOTICE%s %s: %s (%s) - trivial protection circumvented\n",
				   COLOR_YELLOW, COLOR_RESET, path, format_desc, depth_desc);
		} else {
			printf("%sOK%s %s: %s (%s)\n", COLOR_GREEN, COLOR_RESET, path, format_desc, depth_desc);
		}
	} else {
		printf("%sFAIL%s %s: %s - %s\n",
			   COLOR_RED, COLOR_RESET, path, format_desc, result->error_message ? result->error_message : "Unknown error");
		/* Also show malformations for invalid files (helps diagnose multiple issues) */
		if (has_malformations) {
			for (int i = 0; i <= ES_MALFORMATION_LAST; i++) {
				if (result->malformation_bits & (1ULL << i)) {
					const char* desc = malformation_description((malformation_t)i);
					printf("  %s->%s %s\n", COLOR_YELLOW, COLOR_RESET, desc ? desc : "Unknown issue");
				}
			}
		}
	}
}

/* Callback context for batch validation - uses validation_counts_t from header */

/* New batch validation callback (hexagonal architecture) */
static void on_validation_result(
	void* context,
	uint32_t file_id,
	const char* path,
	owned_result_t* result
) {
	validation_counts_t* counts = (validation_counts_t*)context;
	(void)file_id;  /* Not currently used, but available for future features */

	/* elapsed_seconds is now part of the result */
	double elapsed_seconds = result->elapsed_seconds;

	if (elapsed_seconds >= SLOW_THRESHOLD_SECONDS) {
		fprintf(stderr, "%sSLOW%s %s: %.2fs\n", COLOR_YELLOW, COLOR_RESET, path, elapsed_seconds);
	}

	/* Update counts */
	if (result->is_unknown) {
		if (counts) counts->unknown_count++;
		if (g_unknown_out_enabled && g_unknown_out) {
			fprintf(g_unknown_out, "UNKNOWN %s\n", path);
			fflush(g_unknown_out);
		} else {
			printf("%sUNKNOWN%s %s: Unknown\n", COLOR_CYAN, COLOR_RESET, path);
		}
		log_mem_telemetry(path, result, elapsed_seconds);
	} else if (result->is_valid) {
		if (counts) counts->valid_count++;
		print_validation_result(path, result);
		log_mem_telemetry(path, result, elapsed_seconds);
	} else {
		if (counts) counts->invalid_count++;
		print_validation_result(path, result);
		log_mem_telemetry(path, result, elapsed_seconds);
	}

	/* IMPORTANT: We take ownership of result, must free it */
	free_result(result);
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
	}
}

static int validate_path(const char* path, size_t jobs, int shuffle, size_t stress_iterations) {
	struct stat st;
	if (stat(path, &st) != 0) {
		fprintf(stderr, "%sError: Cannot access path: %s\n%s", COLOR_RED, path, COLOR_RESET);
		return 1;
	}

	init_unknown_out();

	const size_t max_files = get_env_max_files();
	if (max_files > 0 && S_ISDIR(st.st_mode)) {
		printf("%sNote:%s MAX_FILES=%zu (results may be truncated)\n", COLOR_YELLOW, COLOR_RESET, max_files);
	}

	/* Enumerate files */
	path_list_t file_list;
	if (path_list_init(&file_list, 1024, max_files) != 0) {
		fprintf(stderr, "%sError: Out of memory\n%s", COLOR_RED, COLOR_RESET);
		shutdown_unknown_out();
		return 1;
	}

	if (S_ISDIR(st.st_mode)) {
		printf("Validating: %s%s\n\n", path, (shuffle || stress_iterations > 1) ? " (shuffled)" : "");
		/* Check if the directory itself is a bundle (e.g., .git) */
		if (is_bundle_directory(path)) {
			/* Bundle directory - validate as single item, don't enumerate */
			if (path_list_add(&file_list, path) != 0) {
				fprintf(stderr, "%sError: Out of memory\n%s", COLOR_RED, COLOR_RESET);
				path_list_free(&file_list);
				shutdown_unknown_out();
				return 1;
			}
		} else if (enumerate_directory(path, &file_list) != 0) {
			fprintf(stderr, "%sError: Failed to enumerate directory: %s\n%s", COLOR_RED, path, COLOR_RESET);
			path_list_free(&file_list);
			shutdown_unknown_out();
			return 1;
		}
	} else if (S_ISREG(st.st_mode)) {
		printf("Checking: %s\n", path);
		if (path_list_add(&file_list, path) != 0) {
			fprintf(stderr, "%sError: Out of memory\n%s", COLOR_RED, COLOR_RESET);
			path_list_free(&file_list);
			shutdown_unknown_out();
			return 1;
		}
	} else {
		fprintf(stderr, "%sError: Unsupported path type: %s\n%s", COLOR_RED, path, COLOR_RESET);
		path_list_free(&file_list);
		shutdown_unknown_out();
		return 1;
	}

	if (file_list.count == 0) {
		printf("No files found.\n");
		path_list_free(&file_list);
		shutdown_unknown_out();
		return 0;
	}

	/* Build batch items array */
	batch_item_t* items = (batch_item_t*)malloc(file_list.count * sizeof(batch_item_t));
	if (!items) {
		fprintf(stderr, "%sError: Out of memory\n%s", COLOR_RED, COLOR_RESET);
		path_list_free(&file_list);
		shutdown_unknown_out();
		return 1;
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

		/* Shuffle if requested */
		if (should_shuffle) {
			shuffle_paths(&file_list, iter + 1);
		}

		/* Build batch items (file_id = index for now) */
		for (size_t i = 0; i < file_list.count; i++) {
			items[i].path = file_list.paths[i];
			items[i].id = (uint32_t)i;
		}

		counts = (validation_counts_t){0};

		/* Call new hexagonal API */
		error_t err = validate_batch(
			items,
			file_list.count,
			(int)jobs,
			on_validation_result,
			NULL,  /* No progress callback for now */
			&counts
		);

		if (err != ES_OK) {
			fprintf(stderr, "%sError: Validation failed: %s\n%s", COLOR_RED,
				core_last_error() ? core_last_error() : "unknown error", COLOR_RESET);
			fflush(stderr);
			free(items);
			path_list_free(&file_list);
			shutdown_unknown_out();
			return 1;
		}

		total_counts.valid_count += counts.valid_count;
		total_counts.invalid_count += counts.invalid_count;
		total_counts.unknown_count += counts.unknown_count;

		if (counts.invalid_count > 0) {
			failures = 1;
		}
	}

	free(items);
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

	if (summary_counts->invalid_count > 0) {
		failures = 1;
	}

	shutdown_unknown_out();
	return failures;
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
	printf("    --shuffle             Shuffle file order (helps expose race conditions)\n");
	printf("    --stress N            Repeat validation N times with shuffling\n");
#else
	printf("    --version    Print version\n");
	printf("    --help       Show this help\n");
	printf("    --jobs N     Number of parallel workers (0 = auto)\n");
	printf("    -j N         Alias for --jobs\n");
	printf("    --no-color   Disable colored output\n");
	printf("    --shuffle    Shuffle file order (helps expose race conditions)\n");
	printf("    --stress N   Repeat validation N times with shuffling\n");
#endif
	printf("\n");
	printf("ENVIRONMENT:\n");
	printf("    NO_COLOR     Set to disable colored output\n");
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
	const char* path = NULL;

	for (int i = 1; i < argc; i++) {
		const char* arg = argv[i];
		/* Help: --help, -h (and /help, /h, /? on Windows) */
		if (strcmp(arg, "--help") == 0 || strcmp(arg, "-h") == 0
#ifdef _WIN32
		    || strcmp(arg, "/help") == 0 || strcmp(arg, "/h") == 0 || strcmp(arg, "/?") == 0
#endif
		) {
			print_usage(argv[0]);
			return 0;
		}
		/* Version: --version (and /version on Windows) */
		if (strcmp(arg, "--version") == 0
#ifdef _WIN32
		    || strcmp(arg, "/version") == 0
#endif
		) {
			printf("%s\n", core_version());
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
				return 2;
			}
			stress_iterations = (size_t)strtoull(argv[++i], NULL, 10);
			if (stress_iterations == 0) {
				fprintf(stderr, "%sError: --stress value must be > 0\n%s", COLOR_RED, COLOR_RESET);
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
		/* Unknown option check */
		if (arg[0] == '-') {
			fprintf(stderr, "%sError: Unknown option: %s\n%s", COLOR_RED, arg, COLOR_RESET);
			return 2;
		}
#ifdef _WIN32
		/* On Windows, / is an option prefix (but allow paths like C:\ or \\server) */
		if (arg[0] == '/' && arg[1] != '\0' && arg[1] != '/' && arg[1] != '\\') {
			fprintf(stderr, "%sError: Unknown option: %s\n%s", COLOR_RED, arg, COLOR_RESET);
			return 2;
		}
#endif
		path = arg;
	}

	if (!path) {
		print_usage(argv[0]);
		return 2;
	}

	init_mem_telemetry();

	/* Pre-initialize decoder libraries for thread safety.
	 * This must be called ONCE from main thread BEFORE spawning workers.
	 * Triggers SIMD detection and global state init in all C libraries. */
	core_preinit();

	int rc = validate_path(path, jobs, shuffle, stress_iterations);
	shutdown_mem_telemetry();
	return rc;
}
