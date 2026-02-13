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
TMPDIR="${TMPDIR:-/tmp}/$$"
mkdir -p "$TMPDIR"
trap "rm -rf '$TMPDIR'" EXIT

# errmsg template expansion map: function_name -> (prefix, suffix)
# These must match the definitions in src/core/error_messages.zig exactly.
declare -A ERRMSG_PREFIX=(
    [failedToRead]="Failed to read "
    [fileTooSmallFor]="File too small for "
    [invalidSignature]="Invalid "
    [missing]="Missing "
    [failedToSeek]="Failed to seek "
    [truncated]="Truncated "
    [invalidMagic]="Invalid "
    [invalidMagicNumber]="Invalid "
    [failedToOpen]="Failed to open "
    [failedToSkip]="Failed to skip "
    [tooMany]="Too many "
    [unsupported]="Unsupported "
    [incomplete]="Incomplete "
    [bufferTooSmallFor]="Buffer too small for "
    [noValidXFound]="No valid "
    [unknown]="Unknown "
    [empty]="Empty "
    [fileTooLargeFor]="File too large for "
    [failedToAllocate]="Failed to allocate "
    [failedToStat]="Failed to stat "
    [outOfMemory]="Out of memory "
    [failedToGet]="Failed to get "
    [decompressionFailed]=""
    [invalidValue]="Invalid "
    [checksumMismatch]=""
    [exceedsBounds]=""
)

declare -A ERRMSG_SUFFIX=(
    [failedToRead]=""
    [fileTooSmallFor]=""
    [invalidSignature]=" signature"
    [missing]=""
    [failedToSeek]=""
    [truncated]=""
    [invalidMagic]=" magic bytes"
    [invalidMagicNumber]=" magic number"
    [failedToOpen]=""
    [failedToSkip]=""
    [tooMany]=""
    [unsupported]=""
    [incomplete]=""
    [bufferTooSmallFor]=""
    [noValidXFound]=" found"
    [unknown]=""
    [empty]=""
    [fileTooLargeFor]=""
    [failedToAllocate]=""
    [failedToStat]=""
    [outOfMemory]=""
    [failedToGet]=""
    [decompressionFailed]=" decompression failed"
    [invalidValue]=""
    [checksumMismatch]=" checksum mismatch"
    [exceedsBounds]=" exceeds bounds"
)

# ValidationErrorCode enum variant -> errmsg function name mapping
# Used to expand .invalidCode(.fmt, .code, "detail") patterns
declare -A ERRCODE_TO_FUNC=(
    [failed_to_read]="failedToRead"
    [file_too_small]="fileTooSmallFor"
    [invalid_signature]="invalidSignature"
    [missing]="missing"
    [failed_to_seek]="failedToSeek"
    [truncated]="truncated"
    [invalid_magic]="invalidMagic"
    [invalid_magic_number]="invalidMagicNumber"
    [failed_to_open]="failedToOpen"
    [failed_to_skip]="failedToSkip"
    [too_many]="tooMany"
    [unsupported]="unsupported"
    [incomplete]="incomplete"
    [buffer_too_small]="bufferTooSmallFor"
    [no_valid_x_found]="noValidXFound"
    [unknown_element]="unknown"
    [empty]="empty"
    [file_too_large]="fileTooLargeFor"
    [failed_to_allocate]="failedToAllocate"
    [failed_to_stat]="failedToStat"
    [out_of_memory]="outOfMemory"
    [failed_to_get]="failedToGet"
    [decompression_failed]="decompressionFailed"
    [invalid_value]="invalidValue"
    [checksum_mismatch]="checksumMismatch"
    [exceeds_bounds]="exceedsBounds"
)

# Function to expand errmsg template calls to their full string
# Input: lines containing either "literal string" or errmsg.func("arg") or errmsg.func("arg1", "arg2")
expand_errmsg() {
    while IFS= read -r line; do
        echo "$line"
    done
}

# Extract current error strings from source
# Pattern 1a: literal strings in .invalid(.format, "string") — two-arg form
# Exclude lines containing errmsg. to avoid false positives from template args
rg -v 'errmsg\.' "$PROJECT_DIR/src/core/"*.zig 2>/dev/null | rg -o '\.invalid\([^,]+,\s*"([^"]*)"' --no-filename -r '$1' 2>/dev/null > "$TMPDIR/current_errors_raw.txt" || true
rg -v 'errmsg\.' "$PROJECT_DIR/src/core/"*.zig 2>/dev/null | rg -o '\.invalidWithDepth\([^,]+,\s*"([^"]*)"' --no-filename -r '$1' 2>/dev/null >> "$TMPDIR/current_errors_raw.txt" || true

# Pattern 1b: literal strings in .invalid("string"...) — single-arg or first-string form (custom result types)
rg -v 'errmsg\.' "$PROJECT_DIR/src/core/"*.zig 2>/dev/null | rg -o '\.invalid\("([^"]*)"' --no-filename -r '$1' 2>/dev/null >> "$TMPDIR/current_errors_raw.txt" || true

# Pattern 1c: literal strings in .err("string") — e.g. DicomParseResult.err()
rg -v 'errmsg\.' "$PROJECT_DIR/src/core/"*.zig 2>/dev/null | rg -o '\.err\("([^"]*)"' --no-filename -r '$1' 2>/dev/null >> "$TMPDIR/current_errors_raw.txt" || true

# Pattern 2a: errmsg.func("arg") in .invalid(.format, errmsg) and .invalidWithDepth() — two-arg form
rg -o '\.invalid\([^,]+,\s*errmsg\.(\w+)\("([^"]*)"\)' --no-filename -r '$1|$2' "$PROJECT_DIR/src/core/" 2>/dev/null > "$TMPDIR/current_errors_errmsg.txt" || true
rg -o '\.invalidWithDepth\([^,]+,\s*errmsg\.(\w+)\("([^"]*)"\)' --no-filename -r '$1|$2' "$PROJECT_DIR/src/core/" 2>/dev/null >> "$TMPDIR/current_errors_errmsg.txt" || true

# Pattern 2b: errmsg.func("arg") in .invalid(errmsg) — single-arg form (custom result types)
rg -o '\.invalid\(errmsg\.(\w+)\("([^"]*)"\)' --no-filename -r '$1|$2' "$PROJECT_DIR/src/core/" 2>/dev/null >> "$TMPDIR/current_errors_errmsg.txt" || true

# Pattern 2c: errmsg.func("arg") in .invalid(errmsg, extra) — with trailing numeric arg
rg -o '\.invalid\(errmsg\.(\w+)\("([^"]*)"\),\s*\d+\)' --no-filename -r '$1|$2' "$PROJECT_DIR/src/core/" 2>/dev/null >> "$TMPDIR/current_errors_errmsg.txt" || true

# Pattern 2d: errmsg.func("arg") in .err(errmsg) — e.g. DicomParseResult
rg -o '\.err\(errmsg\.(\w+)\("([^"]*)"\)' --no-filename -r '$1|$2' "$PROJECT_DIR/src/core/" 2>/dev/null >> "$TMPDIR/current_errors_errmsg.txt" || true

# Pattern 3a: errmsg.func("arg1", "arg2") — two-arg templates (invalidSignatureExpected, invalidSignatureNot)
rg -o '\.invalid\([^,]+,\s*errmsg\.(\w+)\("([^"]*)",\s*"([^"]*)"\)' --no-filename -r '$1|$2|$3' "$PROJECT_DIR/src/core/" 2>/dev/null > "$TMPDIR/current_errors_errmsg2.txt" || true
rg -o '\.invalidWithDepth\([^,]+,\s*errmsg\.(\w+)\("([^"]*)",\s*"([^"]*)"\)' --no-filename -r '$1|$2|$3' "$PROJECT_DIR/src/core/" 2>/dev/null >> "$TMPDIR/current_errors_errmsg2.txt" || true

# Pattern 3b: single-arg form for two-arg templates
rg -o '\.invalid\(errmsg\.(\w+)\("([^"]*)",\s*"([^"]*)"\)' --no-filename -r '$1|$2|$3' "$PROJECT_DIR/src/core/" 2>/dev/null >> "$TMPDIR/current_errors_errmsg2.txt" || true

# Pattern 3c: errmsg.func("arg1", "arg2") in .invalidCodeMsg(.fmt, .code, "detail", errmsg.func(...))
rg -o '\.invalidCodeMsg\([^,]+,\s*\.\w+,\s*"[^"]*",\s*errmsg\.(\w+)\("([^"]*)",\s*"([^"]*)"\)' --no-filename -r '$1|$2|$3' "$PROJECT_DIR/src/core/" 2>/dev/null >> "$TMPDIR/current_errors_errmsg2.txt" || true

# Pattern 4c: .invalidCodeMsg(.fmt, .code, "detail", "message") — raw message with code
rg -o '\.invalidCodeMsg\([^,]+,\s*\.\w+,\s*"[^"]*",\s*"([^"]*)"' --no-filename -r '$1' "$PROJECT_DIR/src/core/" 2>/dev/null >> "$TMPDIR/current_errors_raw.txt" || true

# Pattern 4d: .invalidCodeMsgWithDepth(.fmt, .code, "detail", "message", .depth)
rg -o '\.invalidCodeMsgWithDepth\([^,]+,\s*\.\w+,\s*"[^"]*",\s*"([^"]*)"' --no-filename -r '$1' "$PROJECT_DIR/src/core/" 2>/dev/null >> "$TMPDIR/current_errors_raw.txt" || true

# Pattern 4a: .invalidCode(.fmt, .code, "detail") — error code + detail
rg -o '\.invalidCode\([^,]+,\s*\.(\w+),\s*"([^"]*)"' --no-filename -r '$1|$2' "$PROJECT_DIR/src/core/" 2>/dev/null > "$TMPDIR/current_errors_errcode.txt" || true

# Pattern 4b: .invalidCodeWithDepth(.fmt, .code, "detail", .depth)
rg -o '\.invalidCodeWithDepth\([^,]+,\s*\.(\w+),\s*"([^"]*)"' --no-filename -r '$1|$2' "$PROJECT_DIR/src/core/" 2>/dev/null >> "$TMPDIR/current_errors_errcode.txt" || true

# Expand error code + detail to full strings using ERRCODE_TO_FUNC mapping
while IFS='|' read -r code detail; do
    func="${ERRCODE_TO_FUNC[$code]:-}"
    if [ -n "$func" ]; then
        prefix="${ERRMSG_PREFIX[$func]:-}"
        suffix="${ERRMSG_SUFFIX[$func]:-}"
        echo "${prefix}${detail}${suffix}"
    fi
done < "$TMPDIR/current_errors_errcode.txt" >> "$TMPDIR/current_errors_raw.txt"

# Expand single-arg errmsg templates to full strings
while IFS='|' read -r func arg; do
    prefix="${ERRMSG_PREFIX[$func]:-}"
    suffix="${ERRMSG_SUFFIX[$func]:-}"
    echo "${prefix}${arg}${suffix}"
done < "$TMPDIR/current_errors_errmsg.txt" >> "$TMPDIR/current_errors_raw.txt"

# Expand two-arg errmsg templates to full strings
while IFS='|' read -r func arg1 arg2; do
    if [ "$func" = "invalidSignatureExpected" ]; then
        echo "Invalid ${arg1} signature (expected ${arg2})"
    elif [ "$func" = "invalidSignatureNot" ]; then
        echo "Invalid ${arg1} signature (not ${arg2})"
    fi
done < "$TMPDIR/current_errors_errmsg2.txt" >> "$TMPDIR/current_errors_raw.txt"

sort -u "$TMPDIR/current_errors_raw.txt" > "$TMPDIR/current_errors.txt"

# Extract current warning strings
# Exclude lines containing errmsg. to avoid false positives from template args
rg -v 'errmsg\.' "$PROJECT_DIR/src/core/"*.zig 2>/dev/null | rg -o '\.okWithWarning\([^,]+,\s*"([^"]*)"' --no-filename -r '$1' 2>/dev/null > "$TMPDIR/current_warnings_raw.txt" || true
rg -v 'errmsg\.' "$PROJECT_DIR/src/core/"*.zig 2>/dev/null | rg -o '\.okWithDepthAndWarning\([^,]+,\s*[^,]+,\s*"([^"]*)"' --no-filename -r '$1' 2>/dev/null >> "$TMPDIR/current_warnings_raw.txt" || true

# Warning errmsg patterns (single-arg)
rg -o '\.okWithWarning\([^,]+,\s*errmsg\.(\w+)\("([^"]*)"\)' --no-filename -r '$1|$2' "$PROJECT_DIR/src/core/" 2>/dev/null > "$TMPDIR/current_warnings_errmsg.txt" || true
rg -o '\.okWithDepthAndWarning\([^,]+,\s*[^,]+,\s*errmsg\.(\w+)\("([^"]*)"\)' --no-filename -r '$1|$2' "$PROJECT_DIR/src/core/" 2>/dev/null >> "$TMPDIR/current_warnings_errmsg.txt" || true

while IFS='|' read -r func arg; do
    prefix="${ERRMSG_PREFIX[$func]:-}"
    suffix="${ERRMSG_SUFFIX[$func]:-}"
    echo "${prefix}${arg}${suffix}"
done < "$TMPDIR/current_warnings_errmsg.txt" >> "$TMPDIR/current_warnings_raw.txt"

sort -u "$TMPDIR/current_warnings_raw.txt" > "$TMPDIR/current_warnings.txt"

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
