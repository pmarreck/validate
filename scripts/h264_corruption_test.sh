#!/bin/bash
# Targeted H.264 corruption test
# Tests corruption detection at specific bitstream regions:
#   - SPS data
#   - PPS data
#   - Slice header
#   - Slice body (entropy-coded data)
#   - Multiple byte corruptions
#   - Bit flips at various positions within the file

set -e

VALIDATE_BIN="${VALIDATE_BIN:-./zig-out/bin/validate}"
GT_DIR="ground_truth_examples"
CORRUPT_DIR=$(mktemp -d)
trap "rm -rf $CORRUPT_DIR" EXIT

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

total_tests=0
total_detected=0
total_missed=0

# Corrupt a single byte at a specific position
corrupt_byte_at() {
    local src="$1"
    local dst="$2"
    local pos="$3"
    local val="${4:-00}" # default: zero byte

    cp "$src" "$dst"
    printf "\\x${val}" | dd of="$dst" bs=1 seek="$pos" count=1 conv=notrunc 2>/dev/null
}

# Corrupt multiple bytes at a position
corrupt_bytes_at() {
    local src="$1"
    local dst="$2"
    local pos="$3"
    local count="$4"

    cp "$src" "$dst"
    dd if=/dev/zero of="$dst" bs=1 seek="$pos" count="$count" conv=notrunc 2>/dev/null
}

# Flip a specific bit at a byte position
flip_bit_at() {
    local src="$1"
    local dst="$2"
    local pos="$3"
    local bit="$4"  # 0-7

    cp "$src" "$dst"
    # Read original byte, flip bit, write back
    local orig=$(od -An -tx1 -j"$pos" -N1 "$src" | tr -d ' ')
    local mask=$(printf '%02x' $((1 << bit)))
    local flipped=$(printf '%02x' $((0x$orig ^ 0x$mask)))
    printf "\\x${flipped}" | dd of="$dst" bs=1 seek="$pos" count=1 conv=notrunc 2>/dev/null
}

# Test if corruption is detected
test_corruption() {
    local desc="$1"
    local file="$2"

    total_tests=$((total_tests + 1))

    local result=$($VALIDATE_BIN "$file" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
    if echo "$result" | grep -qE "^FAIL|^UNKNOWN|^WARN|Invalid"; then
        echo -e "  ${GREEN}[DETECTED]${NC} $desc"
        total_detected=$((total_detected + 1))
        return 0
    else
        echo -e "  ${RED}[MISSED]${NC}  $desc"
        echo "              Result: $(echo "$result" | head -1)"
        total_missed=$((total_missed + 1))
        return 1
    fi
}

# Test a single H.264 file with many corruption patterns
test_h264_file() {
    local src="$1"
    local name=$(basename "$src")
    local size=$(stat -f%z "$src" 2>/dev/null || stat -c%s "$src")

    echo ""
    echo "============================================"
    echo "Testing: $name ($size bytes)"
    echo "============================================"

    # First verify the original is valid
    local orig_result=$($VALIDATE_BIN "$src" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
    if echo "$orig_result" | grep -qE "^OK"; then
        echo -e "  ${GREEN}[VALID]${NC}    Original file validates OK"
    else
        echo -e "  ${YELLOW}[SKIP]${NC}     Original doesn't validate: $(echo "$orig_result" | head -1)"
        return
    fi

    local detected=0
    local missed=0
    local file_tests=0

    # Strategy 1: Single byte corruption at evenly-spaced positions through the file
    echo ""
    echo "  --- Single byte zeroing (spread across file) ---"
    for pct in 5 10 15 20 25 30 35 40 45 50 55 60 65 70 75 80 85 90 95; do
        local pos=$((size * pct / 100))
        local dst="$CORRUPT_DIR/${name}_zero_${pct}pct"
        corrupt_byte_at "$src" "$dst" "$pos"
        test_corruption "Zero byte at ${pct}% offset ($pos)" "$dst" || true
    done

    # Strategy 2: Bit flips at various positions
    echo ""
    echo "  --- Single bit flips ---"
    for pct in 10 25 40 50 60 75 90; do
        local pos=$((size * pct / 100))
        for bit in 0 3 7; do
            local dst="$CORRUPT_DIR/${name}_flip_${pct}pct_bit${bit}"
            flip_bit_at "$src" "$dst" "$pos" "$bit"
            test_corruption "Bit flip at ${pct}% offset, bit $bit" "$dst" || true
        done
    done

    # Strategy 3: Multi-byte corruption (more severe)
    echo ""
    echo "  --- Multi-byte corruption ---"
    for pct in 10 25 50 75 90; do
        local pos=$((size * pct / 100))
        for count in 2 4 8 16; do
            if [ $((pos + count)) -lt "$size" ]; then
                local dst="$CORRUPT_DIR/${name}_multi_${pct}pct_${count}b"
                corrupt_bytes_at "$src" "$dst" "$pos" "$count"
                test_corruption "Zero ${count} bytes at ${pct}% offset" "$dst" || true
            fi
        done
    done

    # Strategy 4: Corrupt early bytes (likely SPS/PPS region for containers)
    echo ""
    echo "  --- Early region corruption (SPS/PPS/moov) ---"
    for offset in 8 16 32 64 128 256 512 1024 2048 4096; do
        if [ "$offset" -lt "$size" ]; then
            local dst="$CORRUPT_DIR/${name}_early_${offset}"
            corrupt_byte_at "$src" "$dst" "$offset" "FF"
            test_corruption "0xFF byte at offset $offset" "$dst" || true
        fi
    done

    # Strategy 5: Corrupt with specific bad values
    echo ""
    echo "  --- Specific bad values ---"
    for pct in 20 50 80; do
        local pos=$((size * pct / 100))
        for val in "FF" "80" "7F" "01" "FE"; do
            local dst="$CORRUPT_DIR/${name}_val_${pct}pct_${val}"
            corrupt_byte_at "$src" "$dst" "$pos" "$val"
            test_corruption "Value 0x${val} at ${pct}% offset" "$dst" || true
        done
    done

    # Strategy 6: Truncation at various points
    echo ""
    echo "  --- Truncation ---"
    for pct in 25 50 75 90 95 99; do
        local trunc_size=$((size * pct / 100))
        local dst="$CORRUPT_DIR/${name}_trunc_${pct}pct"
        dd if="$src" of="$dst" bs=1 count="$trunc_size" 2>/dev/null
        test_corruption "Truncated at ${pct}% ($trunc_size bytes)" "$dst" || true
    done
}

echo "=========================================="
echo "  H.264 Targeted Corruption Test Suite"
echo "=========================================="

# Test all H.264 ground truth files
for f in \
    "$GT_DIR/mp4/h264_baseline.mp4" \
    "$GT_DIR/mp4/h264_main.mp4" \
    "$GT_DIR/mp4/h264_high10_profile.mp4" \
    "$GT_DIR/mp4/h264_high444_profile.mp4" \
    "$GT_DIR/mkv/h264_aac.mkv" \
; do
    if [ -f "$f" ]; then
        test_h264_file "$f"
    else
        echo "SKIP: $f (not found)"
    fi
done

# Also test TS if available
if [ -f "$GT_DIR/ts/h264_aac.ts" ]; then
    test_h264_file "$GT_DIR/ts/h264_aac.ts"
fi

echo ""
echo "=========================================="
echo "  FINAL RESULTS"
echo "=========================================="
echo ""
echo "  Total tests:    $total_tests"
echo -e "  ${GREEN}Detected:       $total_detected${NC}"
echo -e "  ${RED}Missed:         $total_missed${NC}"
if [ "$total_tests" -gt 0 ]; then
    local_rate=$((total_detected * 100 / total_tests))
    echo "  Detection rate: ${local_rate}%"
fi
echo ""

if [ "$total_missed" -gt 0 ]; then
    echo -e "${YELLOW}Some corruptions were not detected. Review MISSED entries above.${NC}"
    exit 1
else
    echo -e "${GREEN}All corruptions detected!${NC}"
    exit 0
fi
