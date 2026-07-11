#!/usr/bin/env bash
# A missing GUI sibling is normal outside the paired checkout. A permission
# denial is likewise non-fatal for ordinary static generation, but the
# explicit publisher must refuse to ship without readable current links.
set -u

SITE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$SITE_DIR/.." && pwd)"
FIXTURE="$SITE_DIR/tests/fixtures/current_releases.toml"
source "$HOME/dotfiles/bin/src/capture.bash"

failures=0
fail() { echo "not ok: $1"; failures=$((failures + 1)); }
restore_fixture_mode() { chmod 644 "$FIXTURE"; }
trap restore_fixture_mode EXIT

if ! chmod 000 "$FIXTURE"; then
	fail "could not make the release fixture unreadable"
fi

export VALIDATE_GUI_RELEASES_FILE="$FIXTURE"
declare out err rc
capture "$ROOT/site/generate"
if [ "$rc" -ne 0 ]; then
	fail "ordinary generation failed for inaccessible release input ($rc): $err"
fi
if ! printf '%s' "$err" | grep -qF 'WARN: current release manifest unavailable'; then
	fail "ordinary generation did not warn about inaccessible release input"
fi
if grep -qF 'class="release-downloads"' "$ROOT/docs/index.html"; then
	fail "ordinary generation rendered links from inaccessible release input"
fi

capture "$ROOT/publish-validate-pics" --check
if [ "$rc" -eq 0 ]; then
	fail "publisher check accepted an inaccessible release input"
fi
if ! printf '%s' "$err" | grep -qF 'cannot read'; then
	fail "publisher check did not identify the unreadable input"
fi
unset VALIDATE_GUI_RELEASES_FILE

if [ "$failures" -eq 0 ]; then
	echo "test_release_manifest_access: all assertions passed"
	exit 0
fi
echo "test_release_manifest_access: $failures assertion(s) failed"
exit 1
