/* Deterministic complexity regression test for the CLI's queue-size selector.
 * It includes the production translation unit so the comparison count measures
 * the exact partition code used to choose the scatter threshold. */
#define VALIDATE_QUEUE_SELECTION_TEST 1
#define main validate_cli_entrypoint
#include "../../cli/main.c"
#undef main

enum input_shape {
	ascending,
	descending,
	equal,
};

static int check_shape(const char* name, enum input_shape shape) {
	const size_t count = 100000;
	const size_t percentile = 90;
	const size_t expected = shape == equal ? 7 : (count * percentile) / 100;
	/* Three-way partitioning may compare an unequal value with its pivot twice;
	 * 40N leaves room for those deterministic passes while rejecting the former
	 * ~9,500N Lomuto path by more than two orders of magnitude. */
	const size_t comparison_limit = count * 40;
	size_t* values = malloc(count * sizeof(*values));
	size_t* indices = malloc(count * sizeof(*indices));
	if (values == NULL || indices == NULL) {
		fprintf(stderr, "FAIL: %s allocation failed\n", name);
		free(values);
		free(indices);
		return 1;
	}

	for (size_t i = 0; i < count; i++) {
		switch (shape) {
		case ascending:
			values[i] = i;
			break;
		case descending:
			values[i] = count - 1 - i;
			break;
		case equal:
			values[i] = 7;
			break;
		}
		indices[i] = i;
	}

	queue_selection_reset_comparisons();
	const size_t actual = quickselect(values, indices, 0, count - 1, (count * percentile) / 100);
	const size_t comparisons = queue_selection_comparisons();
	free(values);
	free(indices);

	if (actual != expected) {
		fprintf(stderr, "FAIL: %s P90 was %zu, expected %zu\n", name, actual, expected);
		return 1;
	}
	if (comparisons > comparison_limit) {
		fprintf(stderr, "FAIL: %s used %zu comparisons (limit %zu)\n", name, comparisons, comparison_limit);
		return 1;
	}
	return 0;
}

int main(void) {
	return check_shape("ascending", ascending) ||
		check_shape("descending", descending) ||
		check_shape("equal", equal);
}
