#ifndef VALIDATE_PROCESS_ALLOCATOR_POLICY_H
#define VALIDATE_PROCESS_ALLOCATOR_POLICY_H

#ifndef VALIDATE_HAVE_GLIBC
#if defined(__linux__) && defined(__GLIBC__)
#define VALIDATE_HAVE_GLIBC 1
#else
#define VALIDATE_HAVE_GLIBC 0
#endif
#endif

#define VALIDATE_DEFAULT_GLIBC_ARENA_LIMIT 2

/* Keep allocator policy pure and separately testable from the mallopt adapter.
 * An explicit MALLOC_ARENA_MAX value always wins; non-glibc allocators are
 * untouched because their arena/zone controls have different semantics. */
static inline int validate_cli_default_arena_limit(const char* explicit_value) {
#if VALIDATE_HAVE_GLIBC
	return explicit_value == NULL ? VALIDATE_DEFAULT_GLIBC_ARENA_LIMIT : 0;
#else
	(void)explicit_value;
	return 0;
#endif
}

#endif
