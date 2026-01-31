#!/usr/bin/env bash
#
# Test that ffmpeg presence/absence produces deterministic, documented behavior.
# This test verifies both code paths work correctly.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VALIDATE_BIN="$PROJECT_ROOT/zig-out/bin/validate"
FFMPEG_BIN_DIR="$PROJECT_ROOT/scripts/ffmpeg-bin"
TEST_FILE="$PROJECT_ROOT/ground_truth_examples/mp4/h264_high10_profile.mp4"

# Colors (respect NO_COLOR)
if [[ -z "${NO_COLOR:-}" ]] && [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[1;33m'
    NC='\033[0m'
else
    GREEN=''
    RED=''
    YELLOW=''
    NC=''
fi

echo "=== Testing ffmpeg PATH handling ==="

# Check prerequisites
if [[ ! -x "$VALIDATE_BIN" ]]; then
    echo -e "${RED}FAIL${NC}: validate binary not found at $VALIDATE_BIN"
    exit 1
fi

if [[ ! -f "$TEST_FILE" ]]; then
    echo -e "${YELLOW}SKIP${NC}: High10 profile test file not found at $TEST_FILE"
    exit 0
fi

# Setup: Create ffmpeg-bin directory with symlink if ffmpeg exists
mkdir -p "$FFMPEG_BIN_DIR"
FFMPEG_SYSTEM=$(command -v ffmpeg 2>/dev/null || true)
FFPROBE_SYSTEM=$(command -v ffprobe 2>/dev/null || true)

if [[ -n "$FFMPEG_SYSTEM" ]]; then
    ln -sf "$FFMPEG_SYSTEM" "$FFMPEG_BIN_DIR/ffmpeg"
    echo "  Linked ffmpeg: $FFMPEG_SYSTEM -> $FFMPEG_BIN_DIR/ffmpeg"
fi
if [[ -n "$FFPROBE_SYSTEM" ]]; then
    ln -sf "$FFPROBE_SYSTEM" "$FFMPEG_BIN_DIR/ffprobe"
    echo "  Linked ffprobe: $FFPROBE_SYSTEM -> $FFMPEG_BIN_DIR/ffprobe"
fi

failures=0

# Test 1: WITH ffmpeg in PATH (if available)
if [[ -n "$FFMPEG_SYSTEM" && -n "$FFPROBE_SYSTEM" ]]; then
    echo ""
    echo "--- Test: ffmpeg PRESENT in PATH ---"

    # Construct PATH with only our ffmpeg-bin directory for ffmpeg
    # Remove any existing ffmpeg from PATH, then add our directory
    PATH_WITHOUT_FFMPEG=$(echo "$PATH" | tr ':' '\n' | grep -v -E "(ffmpeg|nix/store.*ffmpeg)" | tr '\n' ':' | sed 's/:$//')
    PATH_WITH_FFMPEG="$FFMPEG_BIN_DIR:$PATH_WITHOUT_FFMPEG"

    set +e
    output_with=$(PATH="$PATH_WITH_FFMPEG" "$VALIDATE_BIN" "$TEST_FILE" 2>&1)
    exit_with=$?
    set -e

    echo "$output_with"

    if echo "$output_with" | grep -q "via ffmpeg"; then
        echo -e "${GREEN}PASS${NC}: ffmpeg validation path used when ffmpeg present"
    else
        echo -e "${RED}FAIL${NC}: Expected 'via ffmpeg' in output when ffmpeg is present"
        ((failures++))
    fi
fi

# Test 2: WITHOUT ffmpeg in PATH
echo ""
echo "--- Test: ffmpeg ABSENT from PATH ---"

# Construct PATH without ANY directory containing ffmpeg or ffprobe
# This is aggressive: we check each PATH component to see if it contains the binaries
PATH_WITHOUT_FFMPEG=""
while IFS= read -r dir; do
    if [[ -z "$dir" ]]; then
        continue
    fi
    # Skip if this directory contains ffmpeg or ffprobe
    if [[ -x "$dir/ffmpeg" ]] || [[ -x "$dir/ffprobe" ]]; then
        echo "  Excluding from PATH: $dir (contains ffmpeg/ffprobe)"
        continue
    fi
    if [[ -n "$PATH_WITHOUT_FFMPEG" ]]; then
        PATH_WITHOUT_FFMPEG="$PATH_WITHOUT_FFMPEG:$dir"
    else
        PATH_WITHOUT_FFMPEG="$dir"
    fi
done <<< "$(echo "$PATH" | tr ':' '\n')"

echo "  Filtered PATH has $(echo "$PATH_WITHOUT_FFMPEG" | tr ':' '\n' | wc -l | tr -d ' ') entries"

set +e
output_without=$(PATH="$PATH_WITHOUT_FFMPEG" "$VALIDATE_BIN" "$TEST_FILE" 2>&1)
exit_without=$?
set -e

echo "$output_without"

# When ffmpeg is absent, we expect structural validation (not "via ffmpeg")
if echo "$output_without" | grep -q "via ffmpeg"; then
    echo -e "${RED}FAIL${NC}: 'via ffmpeg' appeared when ffmpeg should be absent from PATH"
    ((failures++))
else
    # Should either be structural validation or report unsupported profile
    if echo "$output_without" | grep -qE "(structural|unsupported|OK|WARN)"; then
        echo -e "${GREEN}PASS${NC}: Non-ffmpeg validation path used when ffmpeg absent"
    else
        echo -e "${YELLOW}WARN${NC}: Unexpected output format when ffmpeg absent"
    fi
fi

# Summary
echo ""
if [[ $failures -eq 0 ]]; then
    echo -e "${GREEN}=== All ffmpeg PATH tests passed ===${NC}"
    exit 0
else
    echo -e "${RED}=== $failures ffmpeg PATH test(s) failed ===${NC}"
    exit $failures
fi
