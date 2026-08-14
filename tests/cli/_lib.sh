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

# ---------------------------------------------------------------------------
# In-place byte mutation that PROVES the corruption landed.
#
# Why not dd: interactive shells in this fleet shadow coreutils dd with a
# safety wrapper (~/Code/rm_safe/bin/dd) that REFUSES of=<existing file>
# writes — rc=1, nothing written. Mutations done via
# `printf .. | dd of=.. conv=notrunc 2>/dev/null` silently never landed under
# that wrapper, leaving the "corrupt" fixture byte-identical to the clean one
# and making corruption tests vacuous outside the nix sandbox. Rule installed
# here: a corruption test must prove its corruption exists. These helpers
# rebuild the file (head + payload + tail) into a temp, mv it over FILE, then
# VERIFY that the size is unchanged AND the bytes actually changed vs a
# pre-mutation copy. NEVER use dd for fixture mutation.

# _mutate_splice FILE OFFSET PAYLOADFILE COUNT
# Internal: splice PAYLOADFILE's first COUNT bytes into FILE at OFFSET by
# rebuilding into a same-directory temp, preserving FILE's mode bits (tests
# mutate executables), then mv over FILE. Returns 0 on a verified mutation,
# 2 if the result is byte-identical to the original (vacuous mutation),
# 1 on any other error. On failure FILE keeps its original content.
_mutate_splice() {
	local file="$1" offset="$2" payload="$3" count="$4"
	local size mode pre tmp new_size
	if [ ! -f "$file" ]; then
		printf 'MUTATION ERROR: no such file: %s\n' "$file" >&2
		return 1
	fi
	if ! [[ "$offset" =~ ^[0-9]+$ ]] || ! [[ "$count" =~ ^[0-9]+$ ]]; then
		printf 'MUTATION ERROR: non-integer offset/count (%s/%s) for %s\n' \
			"$offset" "$count" "$file" >&2
		return 1
	fi
	size="$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file")"
	if [ "$((offset + count))" -gt "$size" ]; then
		printf 'MUTATION ERROR: offset %s + %s byte(s) exceeds size %s of %s (refusing to extend)\n' \
			"$offset" "$count" "$size" "$file" >&2
		return 1
	fi
	mode="$(stat -c%a "$file" 2>/dev/null || stat -f%Lp "$file")"
	pre="$(mktemp "${TMPDIR:-/tmp}/mutate_pre.XXXXXX")" || return 1
	tmp="$(mktemp "${file}.mut.XXXXXX")" || { unlink "$pre" 2>/dev/null || true; return 1; }
	if ! cp "$file" "$pre"; then
		printf 'MUTATION ERROR: cannot snapshot %s for verification\n' "$file" >&2
		unlink "$tmp" 2>/dev/null || true
		unlink "$pre" 2>/dev/null || true
		return 1
	fi
	{
		head -c "$offset" "$file"
		head -c "$count" "$payload"
		tail -c "+$((offset + count + 1))" "$file"
	} > "$tmp"
	new_size="$(stat -c%s "$tmp" 2>/dev/null || stat -f%z "$tmp")"
	if [ "$new_size" -ne "$size" ]; then
		printf 'MUTATION FAILED: size drifted (%s -> %s) rebuilding %s — mutation NOT applied\n' \
			"$size" "$new_size" "$file" >&2
		unlink "$tmp" 2>/dev/null || true
		unlink "$pre" 2>/dev/null || true
		return 1
	fi
	if [ -n "$mode" ]; then
		chmod "$mode" "$tmp" 2>/dev/null || true
	fi
	if ! mv "$tmp" "$file"; then
		printf 'MUTATION ERROR: cannot replace %s\n' "$file" >&2
		unlink "$tmp" 2>/dev/null || true
		unlink "$pre" 2>/dev/null || true
		return 1
	fi
	if cmp -s "$pre" "$file"; then
		printf 'MUTATION FAILED: %s is byte-identical after writing %s byte(s) at offset %s — corruption did NOT land (vacuous mutation)\n' \
			"$file" "$count" "$offset" >&2
		unlink "$pre" 2>/dev/null || true
		return 2
	fi
	unlink "$pre" 2>/dev/null || true
	return 0
}

# mutate_bytes FILE OFFSET BYTE...
# Overwrite len(BYTE...) bytes at OFFSET in FILE with the given byte values
# (hex, e.g. ff or 0x1F). Fails LOUDLY (rc 1) if the file would grow, if the
# rebuilt size drifts, or if the result is byte-identical to the original —
# a corruption test must prove its corruption exists. Multi-byte fields must
# be written in ONE call so the changed-vs-original check spans the whole
# field (individual bytes of a field often already hold the target value).
mutate_bytes() {
	local file="$1" offset="$2"
	shift 2
	local n=$# payload="" b h rc=0
	if [ "$n" -lt 1 ]; then
		printf 'MUTATION ERROR: mutate_bytes %s: need at least one byte value\n' "$file" >&2
		return 1
	fi
	for b in "$@"; do
		b="${b#0x}"
		b="${b#0X}"
		if ! [[ "$b" =~ ^[0-9a-fA-F]{1,2}$ ]]; then
			printf 'MUTATION ERROR: bad byte value %s (want hex like ff or 0x1f)\n' "$b" >&2
			return 1
		fi
		printf -v h '%02x' "$((16#$b))"
		payload+="\\x$h"
	done
	local payload_tmp
	payload_tmp="$(mktemp "${TMPDIR:-/tmp}/mutate_payload.XXXXXX")" || return 1
	printf '%b' "$payload" > "$payload_tmp"
	_mutate_splice "$file" "$offset" "$payload_tmp" "$n" || rc=$?
	unlink "$payload_tmp" 2>/dev/null || true
	[ "$rc" -eq 0 ]
}

# mutate_bytes_from FILE OFFSET SRCFILE COUNT
# Same as mutate_bytes but the COUNT replacement bytes are read from SRCFILE
# (the /dev/urandom shotgun cases), once, up front. A byte-identical result
# with COUNT >= 16 is an outright failure; with COUNT < 16 it retries ONCE
# with freshly read bytes (a tiny random payload can genuinely coincide),
# then fails. Returns 1 loudly on failure.
mutate_bytes_from() {
	local file="$1" offset="$2" srcfile="$3" count="$4"
	local payload_tmp got rc=0
	if ! [[ "$count" =~ ^[0-9]+$ ]] || [ "$count" -lt 1 ]; then
		printf 'MUTATION ERROR: bad COUNT %s for %s\n' "$count" "$file" >&2
		return 1
	fi
	if [ ! -r "$srcfile" ]; then
		printf 'MUTATION ERROR: unreadable byte source: %s\n' "$srcfile" >&2
		return 1
	fi
	payload_tmp="$(mktemp "${TMPDIR:-/tmp}/mutate_payload.XXXXXX")" || return 1
	head -c "$count" "$srcfile" > "$payload_tmp"
	got="$(stat -c%s "$payload_tmp" 2>/dev/null || stat -f%z "$payload_tmp")"
	if [ "$got" -ne "$count" ]; then
		printf 'MUTATION ERROR: read only %s of %s byte(s) from %s\n' "$got" "$count" "$srcfile" >&2
		unlink "$payload_tmp" 2>/dev/null || true
		return 1
	fi
	_mutate_splice "$file" "$offset" "$payload_tmp" "$count" || rc=$?
	if [ "$rc" -eq 2 ] && [ "$count" -lt 16 ]; then
		printf 'MUTATION RETRY: rereading %s byte(s) from %s (tiny payload may coincide)\n' \
			"$count" "$srcfile" >&2
		head -c "$count" "$srcfile" > "$payload_tmp"
		got="$(stat -c%s "$payload_tmp" 2>/dev/null || stat -f%z "$payload_tmp")"
		if [ "$got" -eq "$count" ]; then
			rc=0
			_mutate_splice "$file" "$offset" "$payload_tmp" "$count" || rc=$?
		fi
	fi
	unlink "$payload_tmp" 2>/dev/null || true
	[ "$rc" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Self-test — runs ONLY when this lib is executed directly
# (`bash tests/cli/_lib.sh`), never when sourced. The ./test runner skips this
# file via its [[ -x ]] filter (kept non-executable on purpose, see header).
# Witnesses that the mutation helpers refuse to report success for vacuous
# (no-op) mutations — the exact failure mode the wrapper-dd regression hid.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	st_fails=0
	st_dir="$(mktemp -d "${TMPDIR:-/tmp}/mutate_selftest.XXXXXX")"
	trap 'mv "$st_dir" ~/.Trash/ 2>/dev/null || rm -rf "$st_dir"' EXIT

	st_pass() { printf '  PASS: %s\n' "$1"; }
	st_fail() { printf '  FAIL: %s\n' "$1" >&2; st_fails=$((st_fails + 1)); }

	# 1. No-op single-byte write must return 1 LOUDLY, not claim success.
	printf 'ABCDEF' > "$st_dir/f1"
	err="$( { mutate_bytes "$st_dir/f1" 2 43; } 2>&1 )"; rc=$?   # 'C' over 'C'
	if [ "$rc" -ne 0 ] && grep -q 'MUTATION FAILED' <<<"$err"; then
		st_pass "no-op mutation refused (rc=$rc, loud)"
	else
		st_fail "no-op mutation not refused (rc=$rc, err=$err)"
	fi

	# 2. Real mutation succeeds, content exact, size unchanged.
	err="$( { mutate_bytes "$st_dir/f1" 2 0x5A; } 2>&1 )"; rc=$?
	if [ "$rc" -eq 0 ] && [ -z "$err" ] && [ "$(cat "$st_dir/f1")" = "ABZDEF" ]; then
		st_pass "real mutation lands (ABCDEF -> ABZDEF), quiet on success"
	else
		st_fail "real mutation wrong (rc=$rc, content=$(cat "$st_dir/f1"), err=$err)"
	fi

	# 3. Write past EOF refused (size may never drift).
	err="$( { mutate_bytes "$st_dir/f1" 5 aa bb; } 2>&1 )"; rc=$?
	if [ "$rc" -ne 0 ] && grep -q 'refusing to extend' <<<"$err" && [ "$(cat "$st_dir/f1")" = "ABZDEF" ]; then
		st_pass "past-EOF write refused, file untouched"
	else
		st_fail "past-EOF write not refused (rc=$rc, err=$err)"
	fi

	# 4. Mode bits survive the rebuild (self_integrity mutates executables).
	printf 'ABCDEF' > "$st_dir/f2"
	chmod 755 "$st_dir/f2"
	mutate_bytes "$st_dir/f2" 0 ff 2>/dev/null
	f2_mode="$(stat -c%a "$st_dir/f2" 2>/dev/null || stat -f%Lp "$st_dir/f2")"
	if [ "$f2_mode" = "755" ]; then
		st_pass "mode bits preserved across rebuild (755)"
	else
		st_fail "mode bits lost across rebuild (got $f2_mode)"
	fi

	# 5. mutate_bytes_from: COUNT>=16 identical source is an outright failure.
	head -c 32 /dev/zero > "$st_dir/f3"
	err="$( { mutate_bytes_from "$st_dir/f3" 8 /dev/zero 16; } 2>&1 )"; rc=$?
	if [ "$rc" -ne 0 ] && grep -q 'MUTATION FAILED' <<<"$err"; then
		st_pass "vacuous 16-byte source mutation refused"
	else
		st_fail "vacuous 16-byte source mutation not refused (rc=$rc, err=$err)"
	fi

	# 6. mutate_bytes_from: COUNT<16 vacuous retries once, then fails.
	err="$( { mutate_bytes_from "$st_dir/f3" 8 /dev/zero 4; } 2>&1 )"; rc=$?
	if [ "$rc" -ne 0 ] && grep -q 'MUTATION RETRY' <<<"$err" && grep -q 'MUTATION FAILED' <<<"$err"; then
		st_pass "tiny vacuous source mutation retried once, then refused"
	else
		st_fail "tiny vacuous source mutation handling wrong (rc=$rc, err=$err)"
	fi

	# 7. mutate_bytes_from happy path: 16 random bytes over zeros must land.
	err="$( { mutate_bytes_from "$st_dir/f3" 8 /dev/urandom 16; } 2>&1 )"; rc=$?
	f3_size="$(stat -c%s "$st_dir/f3" 2>/dev/null || stat -f%z "$st_dir/f3")"
	if [ "$rc" -eq 0 ] && [ -z "$err" ] && [ "$f3_size" -eq 32 ]; then
		st_pass "urandom source mutation lands, size stable (32)"
	else
		st_fail "urandom source mutation wrong (rc=$rc, size=$f3_size, err=$err)"
	fi

	if [ "$st_fails" -ne 0 ]; then
		printf '_lib.sh mutation-helper self-test: %d FAILURE(S)\n' "$st_fails" >&2
		exit 1
	fi
	printf '_lib.sh mutation-helper self-test: all checks passed\n'
	exit 0
fi
