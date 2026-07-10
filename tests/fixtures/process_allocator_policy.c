#include <stdio.h>

#include "process_allocator_policy.h"

int main(void) {
	printf("%d\n", validate_cli_default_arena_limit(NULL));
	printf("%d\n", validate_cli_default_arena_limit(""));
	printf("%d\n", validate_cli_default_arena_limit("8"));
	return 0;
}
