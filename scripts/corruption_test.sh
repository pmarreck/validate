#!/bin/bash
# Corruption test script for format validation
# Creates corrupted copies of files and tests that they are rejected

set -e

VALIDATE_BIN="${VALIDATE_BIN:-./zig-out/bin/validate}"
GT_DIR="ground_truth_examples"
CORRUPT_DIR="$GT_DIR/corrupted"

# Create corrupted copy of a file by replacing a byte at random position with null
create_corrupted() {
    local src="$1"
    local dst="$2"
    local seed="$3"

    local size=$(stat -f%z "$src" 2>/dev/null || stat -c%s "$src")
    # Use seed to generate deterministic position
    local pos=$(( (seed * 31337) % size ))

    # Copy file and corrupt byte at position
    cp "$src" "$dst"
    printf '\x00' | dd of="$dst" bs=1 seek="$pos" count=1 conv=notrunc 2>/dev/null
}

# Test a single format
test_format() {
    local format="$1"
    local src_file="$2"
    local ext="${src_file##*.}"
    local basename=$(basename "$src_file" ".$ext")

    echo "Testing $format: $src_file"

    # Create format-specific corrupted directory
    mkdir -p "$CORRUPT_DIR/$format"

    # Test original validates
    # Strip ANSI codes for grep matching
    local valid_result=$($VALIDATE_BIN "$src_file" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
    if echo "$valid_result" | grep -qE "^(OK|WARN)"; then
        echo "  [x] Valid example passes"
        local valid_pass=1
    else
        echo "  [ ] Valid example FAILED (unexpected)"
        echo "      $valid_result"
        local valid_pass=0
    fi

    # Generate and test 5 corrupted copies
    local corrupt_pass=0
    local corrupt_fail=0
    local needs_inquiry=""

    for i in 1 2 3 4 5; do
        local corrupt_file="$CORRUPT_DIR/$format/${basename}_corrupt_${i}.${ext}"
        create_corrupted "$src_file" "$corrupt_file" "$i"

        local corrupt_result=$($VALIDATE_BIN "$corrupt_file" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
        # Accept FAIL, Invalid, or UNKNOWN as successful corruption detection
        # UNKNOWN means magic bytes were corrupted enough to prevent format identification
        if echo "$corrupt_result" | grep -qE "^FAIL|^UNKNOWN|Invalid"; then
            echo "  [x] Corrupt $i rejected"
            ((corrupt_pass++)) || true
        else
            echo "  [?] Corrupt $i NOT rejected - needs inquiry"
            ((corrupt_fail++)) || true
            needs_inquiry="yes"
        fi
    done

    # Summary
    echo "  Summary: valid=$valid_pass, corrupt_rejected=$corrupt_pass/5"
    if [ -n "$needs_inquiry" ]; then
        echo "  ** NEEDS INQUIRY: format resilient to single-byte corruption **"
    fi
    echo ""

    # Return results for checklist update
    echo "$format|$valid_pass|$corrupt_pass|$needs_inquiry" >> /tmp/corruption_results.txt
}

# Test magic byte corruption specifically
# Corrupts byte 0 and verifies format becomes UNKNOWN
test_magic_corruption() {
    local format="$1"
    local src_file="$2"
    local ext="${src_file##*.}"
    local basename=$(basename "$src_file" ".$ext")

    echo "Testing magic byte corruption for $format: $src_file"

    mkdir -p "$CORRUPT_DIR/$format"
    local magic_file="$CORRUPT_DIR/$format/${basename}_magic_corrupt.${ext}"

    # Corrupt byte 0 (first magic byte)
    cp "$src_file" "$magic_file"
    printf '\x00' | dd of="$magic_file" bs=1 seek=0 count=1 conv=notrunc 2>/dev/null

    local result=$($VALIDATE_BIN "$magic_file" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
    if echo "$result" | grep -qE "^UNKNOWN"; then
        echo "  [x] Magic corruption -> UNKNOWN (expected)"
    elif echo "$result" | grep -qE "^FAIL"; then
        echo "  [x] Magic corruption -> FAIL (also acceptable)"
    else
        echo "  [?] Magic corruption -> unexpected result: $result"
    fi
    echo ""
}

# Main
echo "Format Validation Corruption Tests"
echo "==================================="
echo ""

# Clear previous results
> /tmp/corruption_results.txt

# Test formats with ground truth examples
# Each line: format_name source_file

# Images
test_format "png" "$GT_DIR/png/generated_text.png"
test_format "jpeg" "$GT_DIR/jpeg/generated_gradient.jpg"
test_format "jxl" "$GT_DIR/jxl/bicycles.jxl"
test_format "gif" "$GT_DIR/gif/sample_1.gif"
test_format "bmp" "$GT_DIR/bmp/sample.bmp"
test_format "webp" "$GT_DIR/webp/sample.webp"
test_format "tiff" "$GT_DIR/tiff/rgb-3c-8b.tiff"
test_format "heic" "$GT_DIR/heic/sample.heic"
test_format "avif" "$GT_DIR/avif/butterfly.avif"
test_format "jpeg2k" "$GT_DIR/jpeg2k/balloon.jp2"

# Audio
test_format "mp3" "$GT_DIR/mp3/generated_tone_440hz.mp3"
test_format "flac" "$GT_DIR/flac/generated_tone_440hz.flac"
test_format "wav" "$GT_DIR/wav/sample.wav"
test_format "ogg" "$GT_DIR/ogg/generated_tone_440hz.ogg"
test_format "wavpack" "$GT_DIR/wavpack/sample.wv"
test_format "midi" "$GT_DIR/midi/fur_elise.mid"
test_format "ac3" "$GT_DIR/ac3/sample.ac3"
test_format "eac3" "$GT_DIR/eac3/sample.eac3"
test_format "alac" "$GT_DIR/alac/sample.m4a"

# Tracker
test_format "mod" "$GT_DIR/tracker/otm.mod"
test_format "xm" "$GT_DIR/tracker/agony.xm"
test_format "it" "$GT_DIR/tracker/flitter.it"
test_format "s3m" "$GT_DIR/tracker/twilight_garden.s3m"

# Video
test_format "mp4" "$GT_DIR/mp4/bigbuckbunny_360_10s.mp4"
test_format "mkv" "$GT_DIR/mkv/generated_testsrc.mkv"
test_format "webm" "$GT_DIR/webm/jellyfish_360_10s.webm"
test_format "avi" "$GT_DIR/avi/generated_testsrc.avi"
test_format "prores" "$GT_DIR/prores/prores_422.mov"
test_format "ogv" "$GT_DIR/theora/sample.ogv"

# Archives
test_format "zip" "$GT_DIR/zip/test_archive.zip"
test_format "brotli" "$GT_DIR/brotli/hello.br"
test_format "rar" "$GT_DIR/rar/sample.rar"
test_format "par2" "$GT_DIR/par2/sample.par2"

# Documents
test_format "pdf" "$GT_DIR/pdf/alice_in_wonderland_illustrated.pdf"
test_format "xls" "$GT_DIR/ole2/sample.xls"
test_format "ppt" "$GT_DIR/ole2/sample.ppt"

# Database
test_format "sqlite" "$GT_DIR/sqlite/chinook.sqlite"

# Other
test_format "jbig2" "$GT_DIR/jbig2/annex-h.jbig2"

echo ""
echo "==================================="
echo "Magic Byte Corruption Tests"
echo "==================================="
echo ""

# Test magic byte corruption for key formats
test_magic_corruption "png" "$GT_DIR/png/generated_text.png"
test_magic_corruption "jpeg" "$GT_DIR/jpeg/generated_gradient.jpg"
test_magic_corruption "gif" "$GT_DIR/gif/sample_1.gif"
test_magic_corruption "zip" "$GT_DIR/zip/test_archive.zip"
test_magic_corruption "pdf" "$GT_DIR/pdf/alice_in_wonderland_illustrated.pdf"
test_magic_corruption "sqlite" "$GT_DIR/sqlite/chinook.sqlite"

echo ""
echo "==================================="
echo "Results saved to /tmp/corruption_results.txt"
echo ""
cat /tmp/corruption_results.txt
