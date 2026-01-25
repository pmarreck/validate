#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <dirent.h>
#include <limits.h>
#include <unistd.h>
#include "validate_core.h"

#define COLOR_GREEN  "\033[0;32m"
#define COLOR_RED    "\033[0;31m"
#define COLOR_YELLOW "\033[1;33m"
#define COLOR_CYAN   "\033[0;36m"
#define COLOR_RESET  "\033[0m"

typedef struct {
	size_t valid_count;
	size_t invalid_count;
	size_t unknown_count;
} validation_counts_t;

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

static int validate_one(const char* path, const char* display_path, es_format_validator_t* validator, validation_counts_t* counts) {
	es_validation_result_ex_t result;
	es_error_t err = es_format_validate_file_ex(validator, path, &result);
	if (err != ES_OK) {
		fprintf(stderr, COLOR_RED "Error: Validation failed: %s\n" COLOR_RESET,
			es_core_last_error() ? es_core_last_error() : "unknown error");
		counts->invalid_count++;
		return 1;
	}

	if (result.is_unknown) {
		counts->unknown_count++;
		return 0;
	}

	if (result.is_valid) {
		counts->valid_count++;
	} else {
		counts->invalid_count++;
	}

	print_validation_result(display_path, &result);
	return result.is_valid ? 0 : 1;
}

static int walk_directory(const char* root, const char* path, es_format_validator_t* validator, validation_counts_t* counts) {
	DIR* dir = opendir(path);
	if (!dir) {
		fprintf(stderr, COLOR_RED "Error: Failed to open directory: %s\n" COLOR_RESET, path);
		return 1;
	}

	struct dirent* entry;
	int failures = 0;
	while ((entry = readdir(dir)) != NULL) {
		if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
			continue;
		}

		char child_path[PATH_MAX];
		int written = snprintf(child_path, sizeof(child_path), "%s/%s", path, entry->d_name);
		if (written < 0 || (size_t)written >= sizeof(child_path)) {
			fprintf(stderr, COLOR_RED "Error: Path too long: %s/%s\n" COLOR_RESET, path, entry->d_name);
			continue;
		}

		struct stat st;
		if (lstat(child_path, &st) != 0) {
			fprintf(stderr, COLOR_YELLOW "Warning: Failed to stat: %s\n" COLOR_RESET, child_path);
			continue;
		}

		if (S_ISDIR(st.st_mode)) {
			failures |= walk_directory(root, child_path, validator, counts);
			continue;
		}

		if (!S_ISREG(st.st_mode)) {
			continue;
		}

		const char* display_path = child_path;
		size_t root_len = strlen(root);
		if (strncmp(child_path, root, root_len) == 0) {
			display_path = child_path + root_len;
			if (display_path[0] == '/') {
				display_path++;
			}
		}

		failures |= validate_one(child_path, display_path, validator, counts);
	}

	closedir(dir);
	return failures;
}

static int validate_path(const char* path) {
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

	validation_counts_t counts = {0};
	int failures = 0;

	if (S_ISDIR(st.st_mode)) {
		printf("Validating: %s\n\n", path);
		failures |= walk_directory(path, path, validator, &counts);
	} else if (S_ISREG(st.st_mode)) {
		printf("Checking: %s\n", path);
		failures |= validate_one(path, path, validator, &counts);
	} else {
		fprintf(stderr, COLOR_RED "Error: Unsupported path type: %s\n" COLOR_RESET, path);
		es_format_validator_destroy(validator);
		return 1;
	}

	es_format_validator_destroy(validator);

	/* Git repository validation (only if .git exists at root) */
	int git_checked = 0;
	int git_failed = 0;
	{
		char git_path[PATH_MAX];
		snprintf(git_path, sizeof(git_path), "%s/.git", path);
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
}

int main(int argc, char* argv[]) {
	if (argc < 2) {
		print_usage(argv[0]);
		return 2;
	}

	if (strcmp(argv[1], "--help") == 0 || strcmp(argv[1], "-h") == 0) {
		print_usage(argv[0]);
		return 0;
	}

	if (strcmp(argv[1], "--version") == 0) {
		printf("%s\n", es_core_version());
		return 0;
	}

	return validate_path(argv[1]);
}
