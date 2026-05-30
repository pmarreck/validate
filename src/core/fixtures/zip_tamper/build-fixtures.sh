#!/usr/bin/env bash
# Deterministic ZIP tamper-fixture builder for LFH<->CD cross-check regression
# tests (validate's archive_validators.zig). NOT fuzz output — each variant
# corrupts ONE known field at a known offset so a specific cross-check can be
# proven. Requires `zip` (nix-shell -p zip). Run from repo root.
set -u
DST="src/core/fixtures/zip_tamper"
mkdir -p "$DST"

TMP="$(mktemp -d)"
printf 'hello world\n' > "$TMP/a.txt"
# -X strips extra fields for a minimal, predictable layout.
( cd "$TMP" && zip -q -X clean.zip a.txt )
cp "$TMP/clean.zip" "$DST/clean.zip"
rm-safe "$TMP" 2>/dev/null || /bin/rm -rf "$TMP"

# clean.zip LFH layout (after 4-byte PK\003\004 signature, file offsets):
#   04-05 version-needed
#   06-07 general-purpose flags
#   08-09 compression method
#   0a-0d mod time/date
#   0e-11 CRC-32 (offset 14)
#   12-15 compressed size
#   16-19 uncompressed size
#   1a-1b filename length
#   1c-1d extra length (offset 28)
#   1e-.. filename

# --- Phase 1: zero the LFH CRC (offset 14). Must FAIL CRC cross-check. ---
cp "$DST/clean.zip" "$DST/lfh_crc_zero.zip"
printf '\x00\x00\x00\x00' | dd of="$DST/lfh_crc_zero.zip" bs=1 seek=14 count=4 conv=notrunc 2>/dev/null

# --- Phase 0: expose the LFH-flags-offset bug. ---
# Set LFH version-needed (offset 4) to 0x2D (45) so bit 3 is set, AND corrupt
# the LFH CRC (offset 14). With the offset BUG, has_data_descriptor reads the
# version field (bit 3 set) -> CRC check skipped -> corrupted file wrongly OK.
# After the fix, flags read offset 6 (=0) -> check runs -> FAIL. Red->green.
cp "$DST/clean.zip" "$DST/lfh_versionbit3_crc_bad.zip"
printf '\x2d' | dd of="$DST/lfh_versionbit3_crc_bad.zip" bs=1 seek=4 count=1 conv=notrunc 2>/dev/null
printf '\xde\xad\xbe\xef' | dd of="$DST/lfh_versionbit3_crc_bad.zip" bs=1 seek=14 count=4 conv=notrunc 2>/dev/null

# --- Phase 2: flip the real LFH general-purpose flags (offset 6). Must FAIL
# flags cross-check (CD flags stay 0). ---
cp "$DST/clean.zip" "$DST/lfh_flag_flip.zip"
printf '\x08\x00' | dd of="$DST/lfh_flag_flip.zip" bs=1 seek=6 count=2 conv=notrunc 2>/dev/null

echo "Built fixtures:"
ls -la "$DST/"*.zip
