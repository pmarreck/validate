#!/usr/bin/env bash
# Shared helpers for CLI tests.
#
# This is NOT a test itself — it is kept non-executable on purpose so the
# ./test runner's `[[ -x ]]` filter skips it; tests `source` it.

# skip_if_missing PATH...
#
# If any PATH is absent, print a loud SKIP line and exit 77. The ./test runner
# treats exit 77 as SKIP (visible, not counted as a failure). Ground-truth
# fixtures live in the sibling private repo ../validate_gui and are symlinked in
# by ./test when present; on a checkout without that sibling they are absent, and
# a fixture-dependent test should SKIP loudly rather than hard-FAIL. This is a
# loud skip (never silent) per the project's no-silent-skip rule.
skip_if_missing() {
	local p
	for p in "$@"; do
		if [ ! -e "$p" ]; then
			printf 'SKIP: %s — ground-truth fixture not available: %s (provision ../validate_gui)\n' \
				"$(basename "$0")" "$p" >&2
			exit 77
		fi
	done
}
