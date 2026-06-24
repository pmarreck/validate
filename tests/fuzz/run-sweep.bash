#!/usr/bin/env bash
# (helper exec'd by ./fuzz — lives in tests/fuzz/ alongside the harness sources)
#
# Builds the Tier-1 fuzz harnesses (ReleaseSafe, bounds checks ON) and runs the
# deterministic seeded mutation sweep over the corpus, then replays the committed
# minimized crashers (which must NOT crash post-fix). Exits non-zero on any
# crash/hang. SEPARATE from ./test by house convention (./test = unit/integration,
# ./fuzz = fuzzing).
set -u

# tests/fuzz/ → repo root is two levels up.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$SCRIPT_DIR"

# ── Options ────────────────────────────────────────────────────────────────
ITERS=128          # mutations per seed file
SEED=""            # default = harness built-in (deterministic)
TIMEOUT_MS=10000   # per-input hang threshold
CI_ONLY=0          # 1 = replay committed crashers only (no local corpus sweep)
NO_BUILD=0

while [[ $# -gt 0 ]]; do
	case "$1" in
		--iters) ITERS="$2"; shift 2 ;;
		--seed) SEED="$2"; shift 2 ;;
		--timeout-ms) TIMEOUT_MS="$2"; shift 2 ;;
		--ci) CI_ONLY=1; shift ;;
		--no-build) NO_BUILD=1; shift ;;
		-h|--help)
			cat <<EOF
usage: ./fuzz [--iters N] [--seed N] [--timeout-ms N] [--ci] [--no-build]
  --iters N       mutations per seed file (default $ITERS)
  --seed N        RNG seed (default: harness built-in, deterministic)
  --timeout-ms N  per-input hang threshold (default $TIMEOUT_MS)
  --ci            replay committed crashers only (no local ground-truth sweep)
  --no-build      skip the harness build (use existing zig-out/bin)
EOF
			exit 0 ;;
		*) echo "unknown arg: $1" >&2; exit 2 ;;
	esac
done

CRASH_DIR="$SCRIPT_DIR/fuzz-crashes"
mkdir -p "$CRASH_DIR"

SWEEP="$SCRIPT_DIR/zig-out/bin/fuzz-sweep"
DISPATCH="$SCRIPT_DIR/zig-out/bin/fuzz-dispatch"

# ── Build (ReleaseSafe) ──────────────────────────────────────────────────────
if [[ "$NO_BUILD" -eq 0 ]]; then
	echo "=== Building fuzz harnesses (ReleaseSafe) ==="
	# jpegz/tiffz need a zlib lib path for linkSystemLibrary("z"); the dev shell
	# supplies libjpeg/openjpeg paths but not zlib. Resolve it from nixpkgs.
	ZLIB_LIB="$(nix eval --raw nixpkgs#zlib.out 2>/dev/null)/lib"
	if ! nix develop -c zig build fuzz -Doptimize=ReleaseSafe -Dzlib-lib="$ZLIB_LIB"; then
		echo "=== fuzz build FAILED ===" >&2
		exit 1
	fi
fi

if [[ ! -x "$SWEEP" || ! -x "$DISPATCH" ]]; then
	echo "FAIL: harness binaries missing (build first, or drop --no-build)" >&2
	exit 1
fi

export MUTE_DEBUG_STATUS=1
rc=0

# ── 1. Replay committed minimized crashers (must NOT crash post-fix) ─────────
echo "=== Replaying committed crashers (tests/fuzz/corpus) ==="
replayed=0
if [[ -d tests/fuzz/corpus ]]; then
	while IFS= read -r -d '' crasher; do
		replayed=$((replayed + 1))
		if ! gtimeout 30 "$DISPATCH" < "$crasher" >/dev/null 2>&1; then
			rcc=$?
			# 0 = clean, 1/2/3 = normal validator verdict; abnormal = regression.
			case "$rcc" in
				134|137|138|139|124) echo "  REGRESSED: $crasher (rc=$rcc)"; rc=1 ;;
			esac
		fi
	done < <(find tests/fuzz/corpus -type f ! -name '*.md' -print0)
fi
echo "  replayed $replayed committed crasher(s)"

# ── 2. Local exploratory sweep over ground-truth samples ─────────────────────
if [[ "$CI_ONLY" -eq 0 ]]; then
	# ground_truth_examples is a gitignored symlink to the private validate_gui
	# repo; present locally, absent in CI. Seed the sweep from it + the committed
	# corpus. NUL-delimited so filenames with spaces survive.
	declare -a CORPUS=()
	while IFS= read -r -d '' f; do CORPUS+=("$f"); done < <(
		find -L ground_truth_examples tests/fuzz/corpus -type f \
			! -name '*.md' ! -name '*.sha256' ! -name 'README*' ! -name '*.txt' \
			-print0 2>/dev/null
	)
	if [[ "${#CORPUS[@]}" -eq 0 ]]; then
		echo "=== No local corpus (ground_truth_examples absent) — skipping sweep ==="
	else
		echo "=== Sweep: ${#CORPUS[@]} seeds × $ITERS iters ==="
		seed_arg=()
		[[ -n "$SEED" ]] && seed_arg=(--seed "$SEED")
		if ! "$SWEEP" "${seed_arg[@]}" --iters "$ITERS" --timeout-ms "$TIMEOUT_MS" \
			--crash-dir "$CRASH_DIR" "${CORPUS[@]}"; then
			scc=$?
			echo "=== SWEEP found a crash/hang (rc=$scc) — see $CRASH_DIR ===" >&2
			rc=1
		fi
	fi
fi

if [[ "$rc" -eq 0 ]]; then
	echo "=== fuzz: CLEAN ==="
else
	echo "=== fuzz: FAILURES (see above + $CRASH_DIR) ===" >&2
fi
exit "$rc"
