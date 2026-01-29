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
test_format "docx" "$GT_DIR/docx/sample.docx"
test_format "xlsx" "$GT_DIR/xlsx/sample.xlsx"
test_format "pptx" "$GT_DIR/pptx/sample.pptx"
test_format "odt" "$GT_DIR/odt/sample.odt"
test_format "ods" "$GT_DIR/ods/sample.ods"
test_format "odp" "$GT_DIR/odp/sample.odp"
test_format "epub" "$GT_DIR/epub/sample.epub"
test_format "rtf" "$GT_DIR/rtf/sample.rtf"

# Compression
test_format "gzip" "$GT_DIR/gzip/sample.gz"
test_format "bzip2" "$GT_DIR/bzip2/sample.bz2"
test_format "xz" "$GT_DIR/xz/sample.xz"
test_format "zstd" "$GT_DIR/zstd/sample.zst"
test_format "tar" "$GT_DIR/tar/sample.tar"
test_format "7z" "$GT_DIR/7z/sample.7z"

# Database
test_format "sqlite" "$GT_DIR/sqlite/chinook.sqlite"

# Fonts
test_format "ttf" "$GT_DIR/ttf/sample.ttf"
test_format "otf" "$GT_DIR/otf/sample.otf"
test_format "woff" "$GT_DIR/woff/sample.woff"
test_format "woff2" "$GT_DIR/woff2/sample.woff2"

# Text/Data formats
test_format "json" "$GT_DIR/json/sample.json"
test_format "xml" "$GT_DIR/xml/sample.xml"
test_format "yaml" "$GT_DIR/yaml/sample.yaml"
test_format "toml" "$GT_DIR/toml/sample.toml"
test_format "csv" "$GT_DIR/csv/sample.csv"
test_format "ini" "$GT_DIR/ini/sample.ini"

# Other
test_format "jbig2" "$GT_DIR/jbig2/minimal_white_page.jbig2"
test_format "ico" "$GT_DIR/ico/sample.ico"
test_format "svg" "$GT_DIR/svg/sample.svg"
test_format "eml" "$GT_DIR/eml/sample.eml"

# Scientific/Bioinformatics
test_format "fasta" "$GT_DIR/fasta/sample.fasta"
test_format "fastq" "$GT_DIR/fastq/sample.fastq"

# 3D/CAD
test_format "stl" "$GT_DIR/stl/sample.stl"
test_format "dxf" "$GT_DIR/dxf/sample.dxf"
# Note: OBJ and glTF currently detected as plain text/JSON - needs format detection fix

# Geographic
test_format "kml" "$GT_DIR/kml/sample.kml"

# Email/Archive
test_format "mbox" "$GT_DIR/mbox/sample.mbox"

# Audio (additional)
test_format "aiff" "$GT_DIR/aiff/sample.aiff"

# Text formats (additional)
test_format "markdown" "$GT_DIR/markdown/sample.md"
test_format "plist" "$GT_DIR/plist/sample.plist"

# 3D formats (additional)
test_format "ply" "$GT_DIR/ply/sample.ply"

# Archive/Preservation formats
test_format "warc" "$GT_DIR/warc/sample.warc"

# CAD formats (additional)
test_format "step" "$GT_DIR/step/sample.stp"

# PostScript
test_format "eps" "$GT_DIR/eps/sample.eps"

# IFF-based formats
test_format "iff" "$GT_DIR/iff/sample.iff"

# Compressed containers
test_format "kmz" "$GT_DIR/kmz/sample.kmz"
test_format "3mf" "$GT_DIR/3mf/sample.3mf"

# 3D formats (binary)
test_format "glb" "$GT_DIR/glb/box.glb"

# Text formats (additional)
test_format "plain_text" "$GT_DIR/plain_text/sample.txt"
test_format "erlang_term" "$GT_DIR/erlang_term/sample.app"
test_format "eex" "$GT_DIR/eex/sample.eex"

# Scientific formats
test_format "fits" "$GT_DIR/fits/sample.fits"

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
