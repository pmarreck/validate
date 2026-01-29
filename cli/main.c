#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
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

static void log_mem_telemetry(const char* path, const es_validation_result_ex_t* result, double elapsed_seconds) {
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

static const char* validation_depth_description(es_validation_depth_t depth) {
	switch (depth) {
		case ES_VALIDATION_DEPTH_STRUCTURAL: return "structural";
		case ES_VALIDATION_DEPTH_FULL: return "fully validated";
		default: return "unknown";
	}
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

static void print_validation_result(const char* path, const es_validation_result_ex_t* result) {
	const char* format_desc = result->format_description ? result->format_description : "Unknown";
	const char* depth_desc = validation_depth_description(result->validation_depth);
	int has_malformations = result->malformation_bits != 0;
	int has_warning = result->warning_message != NULL;

	if (result->is_valid) {
		if (has_malformations || has_warning) {
			printf("%sWARN%s %s: %s (%s)\n", COLOR_YELLOW, COLOR_RESET, path, format_desc, depth_desc);
			if (has_malformations) {
				for (int i = 0; i <= ES_MALFORMATION_LAST; i++) {
					if (result->malformation_bits & (1ULL << i)) {
						const char* desc = es_malformation_description((es_malformation_t)i);
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
		// Also show malformations for invalid files (helps diagnose multiple issues)
		if (has_malformations) {
			for (int i = 0; i <= ES_MALFORMATION_LAST; i++) {
				if (result->malformation_bits & (1ULL << i)) {
					const char* desc = es_malformation_description((es_malformation_t)i);
					printf("  %s->%s %s\n", COLOR_YELLOW, COLOR_RESET, desc ? desc : "Unknown issue");
				}
			}
		}
	}
}

static void on_validation(
	void* user_data,
	const char* display_path,
	const es_validation_result_ex_t* result,
	double elapsed_seconds
) {
	(void)user_data;
	if (elapsed_seconds >= SLOW_THRESHOLD_SECONDS) {
		fprintf(stderr, "%sSLOW%s %s: %.2fs\n", COLOR_YELLOW, COLOR_RESET, display_path, elapsed_seconds);
	}
	if (result->is_unknown) {
		if (g_unknown_out_enabled && g_unknown_out) {
			fprintf(g_unknown_out, "UNKNOWN %s\n", display_path);
			fflush(g_unknown_out);
		} else {
			printf("%sUNKNOWN%s %s: Unknown\n", COLOR_CYAN, COLOR_RESET, display_path);
		}
		log_mem_telemetry(display_path, result, elapsed_seconds);
		return;
	}
	print_validation_result(display_path, result);
	log_mem_telemetry(display_path, result, elapsed_seconds);
}

static int validate_path(const char* path, size_t jobs) {
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

	es_format_validator_t* validator = NULL;
	es_error_t err = es_format_validator_create_deep(&validator);
	if (err != ES_OK) {
		fprintf(stderr, "%sError: Failed to create validator\n%s", COLOR_RED, COLOR_RESET);
		shutdown_unknown_out();
		return 1;
	}

	es_validation_counts_t counts = {0};
	int failures = 0;

	if (S_ISDIR(st.st_mode)) {
		printf("Validating: %s\n\n", path);
		err = es_format_validate_path_parallel(validator, path, jobs, on_validation, NULL, &counts);
	} else if (S_ISREG(st.st_mode)) {
		printf("Checking: %s\n", path);
		err = es_format_validate_path_parallel(validator, path, jobs, on_validation, NULL, &counts);
	} else {
		fprintf(stderr, "%sError: Unsupported path type: %s\n%s", COLOR_RED, path, COLOR_RESET);
		es_format_validator_destroy(validator);
		shutdown_unknown_out();
		return 1;
	}

	if (err != ES_OK) {
		fprintf(stderr, "%sError: Validation failed: %s\n%s", COLOR_RED,
			es_core_last_error() ? es_core_last_error() : "unknown error", COLOR_RESET);
		es_format_validator_destroy(validator);
		shutdown_unknown_out();
		return 1;
	}

	es_format_validator_destroy(validator);

	/* Git repository validation (only if .git exists at root) */
	int git_checked = 0;
	int git_failed = 0;
	{
		const char* git_suffix = "/.git";
		size_t path_len = strlen(path);
		size_t suffix_len = strlen(git_suffix);
		char* git_path = (char*)malloc(path_len + suffix_len + 1);
		if (!git_path) {
			fprintf(stderr, "%sError: Out of memory while building git path\n%s", COLOR_RED, COLOR_RESET);
			es_format_validator_destroy(validator);
			shutdown_unknown_out();
			return 1;
		}
		memcpy(git_path, path, path_len);
		memcpy(git_path + path_len, git_suffix, suffix_len + 1);
		if (access(git_path, F_OK) == 0) {
			git_checked = 1;
			printf("\n%sGit Repository Integrity Check:%s\n", COLOR_CYAN, COLOR_RESET);
			es_git_validation_result_t git_result;
			char git_error[256];
			err = es_git_validate_repository(path, &git_result, git_error, sizeof(git_error));
			if (err != ES_OK) {
				printf("  %sFAIL%s Failed to validate: %s\n", COLOR_RED, COLOR_RESET,
					es_core_last_error() ? es_core_last_error() : "unknown error");
				git_failed = 1;
			} else if (git_result.is_valid) {
				printf("  %sOK%s Repository valid (%u objects, %u pack files)\n",
					COLOR_GREEN, COLOR_RESET, git_result.objects_checked, git_result.packs_checked);
			} else {
				printf("  %sFAIL%s Repository corrupt: %s\n", COLOR_RED, COLOR_RESET,
					git_error[0] ? git_error : "unknown error");
				if (git_result.objects_corrupt > 0) {
					printf("    %u corrupt objects detected\n", git_result.objects_corrupt);
				}
				git_failed = 1;
			}
		}
		free(git_path);
	}

	printf("\n%sSummary:%s\n", COLOR_CYAN, COLOR_RESET);
	printf("  Valid:   %s%zu%s\n", COLOR_GREEN, counts.valid_count, COLOR_RESET);
	if (counts.invalid_count > 0) {
		printf("  Invalid: %s%zu%s\n", COLOR_RED, counts.invalid_count, COLOR_RESET);
	} else {
		printf("  Invalid: %zu\n", counts.invalid_count);
	}
	printf("  Unknown: %zu\n", counts.unknown_count);
	if (git_checked) {
		if (git_failed) {
			printf("  Git repo: %sCORRUPT%s\n", COLOR_RED, COLOR_RESET);
		} else {
			printf("  Git repo: %svalid%s\n", COLOR_GREEN, COLOR_RESET);
		}
	}

	if (counts.invalid_count > 0 || git_failed) {
		failures = 1;
	}

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
#else
	printf("    --version    Print version\n");
	printf("    --help       Show this help\n");
	printf("    --jobs N     Number of parallel workers (0 = auto)\n");
	printf("    -j N         Alias for --jobs\n");
	printf("    --no-color   Disable colored output\n");
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
			printf("%s\n", es_core_version());
			return 0;
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
	int rc = validate_path(path, jobs);
	shutdown_mem_telemetry();
	shutdown_unknown_out();
	return rc;
}
