#!/usr/bin/env bash
# The release publisher has a no-write validation mode so stale links can be
# rejected deterministically without creating a worktree or contacting Git.
set -u

SITE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$SITE_DIR/.." && pwd)"
source "$HOME/dotfiles/bin/src/capture.bash"

failures=0
fail() { echo "not ok: $1"; failures=$((failures + 1)); }

export VALIDATE_GUI_RELEASES_FILE="$SITE_DIR/tests/fixtures/current_releases.toml"
declare out err rc
capture "$ROOT/publish-validate-pics" --check
if [ "$rc" -ne 0 ]; then
	fail "fresh manifest check failed ($rc): $err"
fi
if ! printf '%s' "$out" | grep -qF '4 fresh platform link(s)'; then
	fail "fresh manifest check did not report all platforms"
fi

export VALIDATE_GUI_RELEASES_FILE="$SITE_DIR/tests/fixtures/expired_releases.toml"
capture "$ROOT/publish-validate-pics" --check
if [ "$rc" -eq 0 ]; then
	fail "expired manifest check succeeded"
fi
if ! printf '%s' "$err" | grep -qF 'expired'; then
	fail "expired manifest failure did not identify expiry"
fi
unset VALIDATE_GUI_RELEASES_FILE

if grep -qF 'publish-validate-pics' "$ROOT/build"; then
	fail "./build must not publish the website"
fi

if [ "$failures" -eq 0 ]; then
	echo "test_publish_validate_pics: all assertions passed"
	exit 0
fi
echo "test_publish_validate_pics: $failures assertion(s) failed"
exit 1
