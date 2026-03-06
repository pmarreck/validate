# Corruption Detection Survey

**Date:** 2026-03-05
**Tool:** `scripts/corruption-experiment` (seeded PCG32, seed=42)
**Trials:** 100 per format per mode
**Modes:** sniper (single-bit flip), shotgun (4KB random overwrite)

## Summary Table

| Category | Format | File Size | Sniper (1-bit) | Shotgun (4KB) | Integrity Mechanism |
|----------|--------|-----------|---------------|---------------|---------------------|
| **Image** | PNG | 345 KB | **100%** | **100%** | CRC32 per chunk |
| | TIFF | 194 KB | 0% | 0% | None (IFD structural only) |
| | GIF | 194 KB | 2% | **94%** | LZW decode (4KB likely hits header/LZW) |
| | WebP | 30 KB | 0% | 0% | RIFF structural only |
| | JPEG | 768 KB | 0% | **93%** | libjpeg-turbo full decode (but 1-bit flips survive in DCT) |
| | HEIC | 2.9 MB | 0% | 0% | H.265 NAL structural only (deep decode may not reach all tiles) |
| | PSD | 120 KB | 0% | 7% | Structural only |
| | EXR | 25 KB | 6% | 5% | Some structural/float validation |
| **Video** | ProRes/MOV | 4.4 MB | 7% | **100%** | MP4 box structure + ProRes frame headers |
| | MPEG-4/AVI | 1.2 MB | 0% | 0% | RIFF structural only |
| **Audio** | FLAC | 404 KB | **98%** | **99%** | MD5 checksum + frame CRC (fixed: decoder errors now = corruption) |
| | OGG | 104 KB | **100%** | **100%** | CRC32 per page |
| | MP3 | 48 KB | 0% | 0% | Frame sync only (no checksums) |
| | WAV | 8 KB | 0% | 2% | Structural only |
| | AC3 | 24 KB | **~100%** | **98%** | CRC-16 per syncframe (fixed: was 0%/0% due to CRC enforcement bug) |
| **Document** | DOC | 28 KB | 1% | 12% | FIB + piece table structural cross-validation |
| | XLS | 178 KB | 0% | 6% | BIFF8 record chain, SST parsing |
| | PDF | 1.7 MB | 0% | 0% | Xref table + image structure (no content checksums) |
| **Archive** | TAR | 4 KB | 15% | n/a* | Header checksum (covers ~2% of each 512-byte block) |
| **Scientific** | FITS | 699 KB | 0% | 2% | Header keyword validation only |
| **Financial** | QBW | 15 MB | **100%** | **100%** | CRC32 per 4096-byte page |

*TAR file too small for shotgun (< 4KB usable range). Some other archive formats (gz, bz2, xz, zstd, 7z) had files too small for meaningful testing.

## Key Findings

### Formats with strong corruption detection (>90% sniper)

| Format | Mechanism | Coverage |
|--------|-----------|----------|
| **PNG** | CRC32 per IDAT/ancillary chunk | Every byte in every chunk is checksummed |
| **FLAC** | MD5 of decoded audio + CRC-8 per frame header + CRC-16 per frame | Every byte contributes to at least one checksum |
| **OGG** | CRC32 per Ogg page | Every byte in every page is checksummed |
| **QBW** | CRC32 per 4096-byte database page | Every byte on every page is checksummed |
| **AC3** | CRC-16 per syncframe (MSB-first, poly 0x8005) | Every byte except 2-byte sync word (~99.8% coverage) |

**Common thread:** All use per-block/per-chunk checksums that cover 100% (or near-100%) of payload bytes.

### Formats where shotgun >> sniper

| Format | Sniper | Shotgun | Explanation |
|--------|--------|---------|-------------|
| **JPEG** | 0% | 93% | A single bit flip in DCT coefficients produces wrong-but-valid pixels. 4KB overwrites destroy Huffman sync and marker structure. |
| **GIF** | 2% | 94% | LZW-compressed data tolerates isolated bit flips but 4KB destroys code table state. |
| **ProRes/MOV** | 7% | 100% | Single bit flips in frame data are invisible. 4KB destroys MP4 box headers or entire frame headers. |
| **DOC** | 1% | 12% | 4KB more likely to hit OLE2 FAT/directory or FIB region. |

**Common thread:** These formats use entropy coding or structural framing that can absorb single-bit errors but cannot survive wholesale 4KB destruction.

### Formats with no detection (0% both modes)

| Format | Why | Could we improve? |
|--------|-----|-------------------|
| **TIFF** | IFD tag validation only; pixel data is raw/uncompressed with no checksums | Unlikely without external checksums |
| **WebP** | Full VP8/VP8L decode via libwebp — same JPEG paradox: single-bit DCT flips produce valid pixels | Fundamental limitation of lossy compression |
| **HEIC** | Full H.265 CABAC decode per tile — same JPEG paradox: CABAC arithmetic absorbs bit flips | Fundamental limitation (see "HEIC CABAC paradox" below) |
| **MP3** | Frame sync pattern only; no CRC (optional CRC rarely present) | MP3 CRC is per-frame-header only, not data |
| ~~**AC3**~~ | ~~Frame CRC exists in spec~~ | **FIXED**: CRC now enforced; detection ~100%/98% |
| **AVI** | RIFF structural only; no codec-level validation | Would need codec-specific decode |
| **PDF** | Xref structure + image parsing, but content streams are opaque | Inherently limited — PDF has no content checksums |
| **FITS** | Header keyword checks only; data array is raw numbers | Could validate DATASUM/CHECKSUM keywords if present |

### The JPEG paradox

JPEG achieves **93% shotgun** but **0% sniper** despite doing a full libjpeg-turbo entropy decode. This is because:

1. **Huffman coding is resilient to single-bit errors.** A flipped bit in a VLC codeword may decode to a different-but-valid coefficient. The decoder produces a slightly wrong image but no error.
2. **4KB overwrites destroy synchronization.** The Huffman decoder loses track of codeword boundaries and quickly hits an invalid state.
3. **JPEG has no checksums.** Even a full pixel-level decode cannot distinguish "correct pixels" from "wrong-but-decodable pixels."

This is a fundamental limitation of lossy compression without integrity metadata.

### The HEIC CABAC paradox

HEIC shows **0% sniper, 0% shotgun** despite implementing a full H.265 CABAC arithmetic decoder per tile. Investigation (2026-03-06):

1. **CABAC arithmetic coding is even more resilient than Huffman.** The arithmetic engine maintains a range/offset state that adjusts smoothly to any input. A flipped bit causes the engine to decode different-but-valid syntax elements (different CU splits, different coefficients), producing a different-but-decodable bitstream. The engine never enters an "invalid state" — it just decodes wrong values.
2. **4KB overwrites ALSO survive CABAC.** Unlike JPEG where 4KB destroys Huffman sync (93% shotgun), CABAC's arithmetic range smoothly adapts to any 4KB of data. The engine continues decoding valid bins, just producing different syntax elements. This makes HEIC fundamentally worse than JPEG for shotgun detection.
3. **Structural coverage is ~0.2%.** Each tile has 6 bytes of structural data (4-byte NAL length prefix + 2-byte NAL header) out of 15-106KB total. Corruption in these bytes IS detected (NAL length validation, NAL type check). But random corruption has only 0.2% chance of hitting structure.
4. **No checksums exist in HEIF/ISOBMFF.** The container format provides no integrity mechanism.

**Why HEIC is worse than JPEG for corruption detection:**
- JPEG's Huffman coding uses variable-length codewords aligned to bit boundaries. A 4KB overwrite destroys the decoder's bit-position tracking, causing cascading failures (93% shotgun).
- CABAC's arithmetic coding uses a continuous probability range that adapts to any input. There are no "bit boundaries" to desynchronize — the range/offset state always produces valid decisions.

This is the fundamental limit of arithmetic coding without checksums. Only a spec-perfect decoder consuming 100% of tile data could detect desynchronization at the bitstream end, and even then only for corruption in the consumed portion.

### The FLAC anomaly (FIXED)

FLAC originally showed **98% sniper** but only **78% shotgun**. Root cause: the FLAC decoder catch blocks in `validateFlacDeep` were returning `OK` when the decoder threw errors (truncated frames, invalid sync from corrupted data). A 4KB overwrite would corrupt frame headers, causing the decoder to error out, and the catch block incorrectly said "valid." Fix: only `Unsupported`/`OutOfMemory` errors fall back to structural; all other decoder errors are treated as corruption. After fix: **98% sniper, 99% shotgun**.

## Actionable Gaps

### High priority (formats with existing checksums we may not be verifying)

1. ~~**AC3/E-AC3**~~: **FIXED** (2026-03-05). Three bugs: (a) CRC computed but result silently ignored (never caused rejection), (b) wrong CRC region (was comparing CRC of data-excluding-CRC vs stored CRC; correct algorithm: CRC of data-including-stored-CRC = 0, MSB-first poly 0x8005), (c) only first 1MB read for large files. AC-3 now ~100% sniper / 98% shotgun; E-AC-3 100% sniper.
2. **FITS DATASUM/CHECKSUM**: FITS files can contain HDU-level checksums. If present, we should verify them.

### Medium priority (formats where deeper decode would help)

3. ~~**WebP**~~: Already does full VP8/VP8L decode via libwebp. Same JPEG paradox — lossy DCT, no checksums. 84% shotgun on larger files.
4. ~~**HEIC**~~: Full per-tile H.265 CABAC decode implemented. Same JPEG paradox — arithmetic coding absorbs corruption. **Fundamentally limited.**
5. **AVI/MPEG-4 Part 2**: Codec-level decode would improve detection, but these are legacy formats.

### Low priority (fundamentally limited)

6. **TIFF**: Raw pixel data with no checksums. Only external parity (par2) can protect this.
7. **PDF**: Content streams are deflate-compressed text — no checksums. Structural checks are all we can do.
8. **MP3**: Optional CRC covers frame header only, not audio data. Most MP3s don't even have CRC.

## Methodology

- **sniper**: Flip 1 random bit at a random byte offset. Tests per-byte coverage.
- **shotgun**: Overwrite 4096 random bytes at a random offset. Simulates disk sector failure.
- **PRNG**: PCG32 with seed=42 for reproducibility.
- **Detection**: `validate` returns non-zero exit code.
- **Confidence**: Wilson interval at 95%. With n=100, margin is ±1.8% at extremes (0% or 100%) and up to ±10% near 50%.
- **Limitation**: 100 trials gives ballpark only. For precise measurement, use `--count 38416` (±0.5% margin).
