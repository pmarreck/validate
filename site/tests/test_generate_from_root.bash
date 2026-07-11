#!/usr/bin/env bash
# The publish command executes site/generate by absolute path from a clean
# worktree root, so the generator must not depend on its caller's directory.
set -u

SITE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$SITE_DIR/.." && pwd)"
source "$HOME/dotfiles/bin/src/capture.bash"

export VALIDATE_GUI_RELEASES_FILE="$SITE_DIR/tests/fixtures/current_releases.toml"
declare out err rc
capture "$ROOT/site/generate"
unset VALIDATE_GUI_RELEASES_FILE

if [ "$rc" -ne 0 ]; then
	echo "not ok: root invocation failed ($rc): $err"
	exit 1
fi
if ! printf '%s' "$err" | grep -qF '100 pages'; then
	echo "not ok: root invocation did not render all locale pages"
	exit 1
fi
echo "test_generate_from_root: all assertions passed"
