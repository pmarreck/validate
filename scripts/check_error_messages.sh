#!/usr/bin/env bash
# Check that user-facing error/warning messages haven't changed unexpectedly.
# Run this after refactoring error strings to catch regressions.
#
# Usage: ./scripts/check_error_messages.sh [--update]
#   --update  Overwrite the golden file with current strings

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GOLDEN="$PROJECT_DIR/tests/golden_error_messages.txt"
TMPDIR="${TMPDIR:-/tmp}"

# Extract current error strings
rg -o '\.invalid\([^,]+,\s*"([^"]*)"' --no-filename -r '$1' "$PROJECT_DIR/src/core/" | sort -u > "$TMPDIR/current_errors.txt"
rg -o '\.invalidWithDepth\([^,]+,\s*"([^"]*)"' --no-filename -r '$1' "$PROJECT_DIR/src/core/" | sort -u >> "$TMPDIR/current_errors.txt"
sort -u -o "$TMPDIR/current_errors.txt" "$TMPDIR/current_errors.txt"

# Extract current warning strings
rg -o '\.okWithWarning\([^,]+,\s*"([^"]*)"' --no-filename -r '$1' "$PROJECT_DIR/src/core/" | sort -u > "$TMPDIR/current_warnings.txt"
rg -o '\.okWithDepthAndWarning\([^,]+,\s*[^,]+,\s*"([^"]*)"' --no-filename -r '$1' "$PROJECT_DIR/src/core/" | sort -u >> "$TMPDIR/current_warnings.txt"
sort -u -o "$TMPDIR/current_warnings.txt" "$TMPDIR/current_warnings.txt"

ERROR_COUNT=$(wc -l < "$TMPDIR/current_errors.txt" | tr -d ' ')
WARNING_COUNT=$(wc -l < "$TMPDIR/current_warnings.txt" | tr -d ' ')

if [ "${1:-}" = "--update" ]; then
    {
        echo "# Error/Warning Message Catalog — Golden Reference"
        echo "# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "# Commit: $(git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
        echo "#"
        echo "# This file captures every unique user-facing error and warning string."
        echo "# After refactoring, regenerate and diff to catch regressions."
        echo "#"
        echo "# ERRORS: $ERROR_COUNT"
        echo "# WARNINGS: $WARNING_COUNT"
        echo ""
        echo "=== ERRORS ==="
        cat "$TMPDIR/current_errors.txt"
        echo ""
        echo "=== WARNINGS ==="
        cat "$TMPDIR/current_warnings.txt"
    } > "$GOLDEN"
    echo "Updated golden file: $GOLDEN"
    echo "  Errors: $ERROR_COUNT"
    echo "  Warnings: $WARNING_COUNT"
    exit 0
fi

if [ ! -f "$GOLDEN" ]; then
    echo "ERROR: Golden file not found: $GOLDEN"
    echo "Run with --update to create it."
    exit 1
fi

# Extract just the error lines from golden file
sed -n '/^=== ERRORS ===/,/^=== WARNINGS ===/{ /^===/d; /^$/d; p; }' "$GOLDEN" > "$TMPDIR/golden_errors.txt"
sed -n '/^=== WARNINGS ===/,$ { /^===/d; /^$/d; p; }' "$GOLDEN" > "$TMPDIR/golden_warnings.txt"

GOLDEN_ERROR_COUNT=$(wc -l < "$TMPDIR/golden_errors.txt" | tr -d ' ')
GOLDEN_WARNING_COUNT=$(wc -l < "$TMPDIR/golden_warnings.txt" | tr -d ' ')

ERRORS_OK=true
WARNINGS_OK=true

# Diff errors
if ! diff -u "$TMPDIR/golden_errors.txt" "$TMPDIR/current_errors.txt" > "$TMPDIR/error_diff.txt" 2>&1; then
    ERRORS_OK=false
fi

# Diff warnings
if ! diff -u "$TMPDIR/golden_warnings.txt" "$TMPDIR/current_warnings.txt" > "$TMPDIR/warning_diff.txt" 2>&1; then
    WARNINGS_OK=false
fi

if $ERRORS_OK && $WARNINGS_OK; then
    echo "OK: Error/warning messages match golden file."
    echo "  Errors: $ERROR_COUNT (unchanged)"
    echo "  Warnings: $WARNING_COUNT (unchanged)"
    exit 0
fi

echo "MISMATCH: Error/warning messages differ from golden file."
echo ""

if ! $ERRORS_OK; then
    echo "--- Error message changes ($GOLDEN_ERROR_COUNT -> $ERROR_COUNT) ---"
    # Show added/removed
    ADDED=$(grep '^+[^+]' "$TMPDIR/error_diff.txt" | wc -l | tr -d ' ')
    REMOVED=$(grep '^-[^-]' "$TMPDIR/error_diff.txt" | wc -l | tr -d ' ')
    echo "  Added: $ADDED, Removed: $REMOVED"
    echo ""
    cat "$TMPDIR/error_diff.txt"
    echo ""
fi

if ! $WARNINGS_OK; then
    echo "--- Warning message changes ($GOLDEN_WARNING_COUNT -> $WARNING_COUNT) ---"
    ADDED=$(grep '^+[^+]' "$TMPDIR/warning_diff.txt" | wc -l | tr -d ' ')
    REMOVED=$(grep '^-[^-]' "$TMPDIR/warning_diff.txt" | wc -l | tr -d ' ')
    echo "  Added: $ADDED, Removed: $REMOVED"
    echo ""
    cat "$TMPDIR/warning_diff.txt"
fi

echo ""
echo "If these changes are intentional, run: $0 --update"
exit 1
