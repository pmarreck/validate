#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "validate_core.h"

#define COLOR_GREEN  "\033[0;32m"
#define COLOR_RED    "\033[0;31m"
#define COLOR_YELLOW "\033[1;33m"
#define COLOR_CYAN   "\033[0;36m"
#define COLOR_RESET  "\033[0m"
#define SLOW_THRESHOLD_SECONDS 5.0

static const char* validation_depth_description(es_validation_depth_t depth) {
	switch (depth) {
		case ES_VALIDATION_DEPTH_STRUCTURAL: return "structural";
		case ES_VALIDATION_DEPTH_FULL: return "fully validated";
		default: return "unknown";
	}
}

static void print_validation_result(const char* path, const es_validation_result_ex_t* result) {
	const char* format_desc = result->format_description ? result->format_description : "Unknown";
	const char* depth_desc = validation_depth_description(result->validation_depth);
	int has_malformations = result->malformation_bits != 0;
	int has_warning = result->warning_message != NULL;

	if (result->is_valid) {
		if (has_malformations || has_warning) {
			printf(COLOR_YELLOW "WARN" COLOR_RESET " %s: %s (%s)\n", path, format_desc, depth_desc);
			if (has_malformations) {
				for (int i = 0; i <= ES_MALFORMATION_MIME_WRAPPED_CONTENT; i++) {
					if (result->malformation_bits & (1ULL << i)) {
						const char* desc = es_malformation_description((es_malformation_t)i);
						printf("  " COLOR_YELLOW "->" COLOR_RESET " %s\n", desc ? desc : "Unknown issue");
					}
				}
			}
			if (has_warning) {
				printf("  " COLOR_YELLOW "->" COLOR_RESET " %s\n", result->warning_message);
			}
		} else if (result->circumvented_trivial_protection) {
			printf(COLOR_YELLOW "NOTICE" COLOR_RESET " %s: %s (%s) - trivial protection circumvented\n",
				   path, format_desc, depth_desc);
		} else {
			printf(COLOR_GREEN "OK" COLOR_RESET " %s: %s (%s)\n", path, format_desc, depth_desc);
		}
	} else {
		printf(COLOR_RED "FAIL" COLOR_RESET " %s: %s - %s\n",
			   path, format_desc, result->error_message ? result->error_message : "Unknown error");
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
		fprintf(stderr, COLOR_YELLOW "SLOW" COLOR_RESET " %s: %.2fs\n", display_path, elapsed_seconds);
	}
	if (result->is_unknown) {
		return;
	}
	print_validation_result(display_path, result);
}

static int validate_path(const char* path, size_t jobs) {
	struct stat st;
	if (stat(path, &st) != 0) {
		fprintf(stderr, COLOR_RED "Error: Cannot access path: %s\n" COLOR_RESET, path);
		return 1;
	}

	es_format_validator_t* validator = NULL;
	es_error_t err = es_format_validator_create_deep(&validator);
	if (err != ES_OK) {
		fprintf(stderr, COLOR_RED "Error: Failed to create validator\n" COLOR_RESET);
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
		fprintf(stderr, COLOR_RED "Error: Unsupported path type: %s\n" COLOR_RESET, path);
		es_format_validator_destroy(validator);
		return 1;
	}

	if (err != ES_OK) {
		fprintf(stderr, COLOR_RED "Error: Validation failed: %s\n" COLOR_RESET,
			es_core_last_error() ? es_core_last_error() : "unknown error");
		es_format_validator_destroy(validator);
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
			fprintf(stderr, COLOR_RED "Error: Out of memory while building git path\n" COLOR_RESET);
			es_format_validator_destroy(validator);
			return 1;
		}
		memcpy(git_path, path, path_len);
		memcpy(git_path + path_len, git_suffix, suffix_len + 1);
		if (access(git_path, F_OK) == 0) {
			git_checked = 1;
			printf("\n" COLOR_CYAN "Git Repository Integrity Check:" COLOR_RESET "\n");
			es_git_validation_result_t git_result;
			char git_error[256];
			err = es_git_validate_repository(path, &git_result, git_error, sizeof(git_error));
			if (err != ES_OK) {
				printf("  " COLOR_RED "FAIL" COLOR_RESET " Failed to validate: %s\n",
					es_core_last_error() ? es_core_last_error() : "unknown error");
				git_failed = 1;
			} else if (git_result.is_valid) {
				printf("  " COLOR_GREEN "OK" COLOR_RESET " Repository valid (%u objects, %u pack files)\n",
					git_result.objects_checked, git_result.packs_checked);
			} else {
				printf("  " COLOR_RED "FAIL" COLOR_RESET " Repository corrupt: %s\n",
					git_error[0] ? git_error : "unknown error");
				if (git_result.objects_corrupt > 0) {
					printf("    %u corrupt objects detected\n", git_result.objects_corrupt);
				}
				git_failed = 1;
			}
		}
		free(git_path);
	}

	printf("\n" COLOR_CYAN "Summary:" COLOR_RESET "\n");
	printf("  Valid:   " COLOR_GREEN "%zu" COLOR_RESET "\n", counts.valid_count);
	if (counts.invalid_count > 0) {
		printf("  Invalid: " COLOR_RED "%zu" COLOR_RESET "\n", counts.invalid_count);
	} else {
		printf("  Invalid: %zu\n", counts.invalid_count);
	}
	printf("  Unknown: %zu\n", counts.unknown_count);
	if (git_checked) {
		if (git_failed) {
			printf("  Git repo: " COLOR_RED "CORRUPT" COLOR_RESET "\n");
		} else {
			printf("  Git repo: " COLOR_GREEN "valid" COLOR_RESET "\n");
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
	printf("    --version   Print version\n");
	printf("    --help      Show this help\n");
	printf("    --jobs N    Number of parallel workers (0 = auto)\n");
	printf("    -j N        Alias for --jobs\n");
}

int main(int argc, char* argv[]) {
	if (argc < 2) {
		print_usage(argv[0]);
		return 2;
	}

	size_t jobs = 0;
	const char* path = NULL;

	for (int i = 1; i < argc; i++) {
		const char* arg = argv[i];
		if (strcmp(arg, "--help") == 0 || strcmp(arg, "-h") == 0) {
			print_usage(argv[0]);
			return 0;
		}
		if (strcmp(arg, "--version") == 0) {
			printf("%s\n", es_core_version());
			return 0;
		}
		if (strcmp(arg, "--jobs") == 0 || strcmp(arg, "-j") == 0) {
			if (i + 1 >= argc) {
				fprintf(stderr, COLOR_RED "Error: --jobs requires a value\n" COLOR_RESET);
				return 2;
			}
			jobs = (size_t)strtoull(argv[++i], NULL, 10);
			continue;
		}
		if (arg[0] == '-') {
			fprintf(stderr, COLOR_RED "Error: Unknown option: %s\n" COLOR_RESET, arg);
			return 2;
		}
		path = arg;
	}

	if (!path) {
		print_usage(argv[0]);
		return 2;
	}

	return validate_path(path, jobs);
}
