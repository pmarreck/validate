# Corruption Detection Survey

**Date:** 2026-03-05 (updated 2026-03-06 with full 77-format sweep)
**Tool:** `scripts/corruption-experiment` (seeded PCG32, seed=42)
**Trials:** 100 per format per mode
**Modes:** sniper (single-bit flip), shotgun (4KB random overwrite)

## Summary Table

| Category | Format | File Size | Sniper (1-bit) | Shotgun (4KB) | Integrity Mechanism |
|----------|--------|-----------|---------------|---------------|---------------------|
| **Image** | PNG | 345 KB | **100%** | **100%** | CRC32 per chunk |
| | JXL | 352 KB | **87%** | **100%** | Container checksums + frame integrity |
| | WebP | 203 KB | **83%** | **84%** | VP8/VP8L full decode via libwebp |
| | JPEG2K | 1.9 MB | 6% | **97%** | Codestream structure + tile-part validation |
| | GIF | 194 KB | 2% | **94%** | LZW decode (4KB hits header/LZW) |
| | JPEG | 768 KB | 0% | **93%** | libjpeg-turbo full decode (1-bit flips survive DCT) |
| | EXR | 25 KB | 6% | 5% | Some structural/float validation |
| | PSD | 120 KB | 0% | 7% | Structural only |
| | HEIC | 2.9 MB | 0% | 4% | H.265 CABAC per tile (arithmetic absorbs corruption) |
| | AVIF | 87 KB | 0% | 1% | AV1 OBU structural (arithmetic absorbs corruption) |
| | DPX | 1.8 MB | 0% | 0% | Raw pixel data, no checksums |
| | PAM/PPM | 1.8 MB | 0% | 0% | Raw pixel data, no checksums |
| | TGA | 11 KB | 0% | 0% | Raw pixel data, no checksums |
| | TIFF | 936 KB | 0% | 0% | IFD structural only |
| | DNG | 1.2 MB | 0% | 0% | TIFF-based, IFD structural only |
| | ARW | 6.2 MB | 0% | 0% | TIFF-based, IFD structural only |
| | CR2 | 5.8 MB | 0% | 0% | TIFF-based, IFD structural only |
| | NEF | 2.2 MB | 0% | 0% | TIFF-based, IFD structural only |
| **Video** | MKV | 467 KB | **100%** | **100%** | CRC32 per EBML cluster |
| | AV1 | 7.7 KB | 5% | **100%** | OBU frame structure + tile decode |
| | MPEG-TS | 145 KB | 4% | **100%** | CRC32 on PAT/PMT + CC tracking |
| | MIDI | 20 KB | 15% | **100%** | Track chunk framing + delta/event validation |
| | ProRes/MOV | 6.6 MB | 5% | **78%** | MP4 box structure + frame headers |
| | MP4 | 1.0 MB | 0% | **66%** | H.264 CABAC decode + AAC decode |
| | MOV | 469 KB | 1% | 6% | MP4 box structure |
| | WebM | 1.0 MB | 0% | 2% | EBML structural (no per-cluster CRC) |
| | AVI | 201 KB | 0% | 2% | RIFF structural only |
| | DV | 360 KB | 0% | 0% | No structural validation |
| | MPEG-ES | 30 KB | 0% | 0% | Start codes only |
| | MPEG-1/2 | 16 KB | 0% | 0% | Start codes only |
| | MPEG-4 Part 2 | 1.2 MB | 0% | 0% | RIFF structural only |
| **Audio** | AC3 | 3.2 MB | **~100%** | **100%** | CRC-16 per syncframe |
| | OGG | 104 KB | **100%** | **100%** | CRC32 per page |
| | CPT | 19 KB | **100%** | **100%** | CRC per resource fork entry |
| | EAC3 | 1.2 MB | **81%** | **85%** | CRC-16 per syncframe (see note) |
| | FLAC | 44 KB | **80%** | **88%** | MD5 + frame CRC (smaller file = lower %) |
| | ALAC | 18 KB | 1% | **100%** | Lossless decode (4KB destroys frame) |
| | Opus | 56 KB | 1% | 35% | OGG CRC + decode (WebM container) |
| | AAC (M4A) | 15 KB | 4% | 31% | MP4 box + AAC syntax decode |
| | AAC (ADTS) | 9 KB | 6% | 20% | ADTS framing + syntax decode |
| | MP3 | 49 KB | 1% | 1% | Frame sync only (no data CRC) |
| | WAV | 8 KB | 0% | 2% | Structural only |
| | AIFF | 8 KB | 0% | 1% | Structural only |
| | CAF | 8 KB | 0% | 1% | Structural only |
| | AU | 8 KB | 0% | 0% | Structural only |
| | Tracker | 308 KB | 0% | 0% | No integrity mechanism |
| **Document** | XLS | 178 KB | 12% | **90%** | BIFF8 records + SST + formulas + cells |
| | DOC | 603 KB | 1% | 2% | FIB + piece table + PCD + PlcBte |
| | PDF | 22 MB | 0% | 0% | Xref table + image structure (no content CRC) |
| | PDB (Protein) | 49 KB | 16% | 39% | ATOM/HETATM field format validation |
| **Archive** | TAR | 4 KB | 15% | 73% | Header checksum per block |
| **Database** | QBW | 15 MB | **100%** | **100%** | CRC32 per 4096-byte page |
| | SQLite | 1.0 MB | **54%** | **100%** | Page headers + freelist + btree structure |
| | ACCDB | 4 KB | 1% | 73% | Jet engine page structure |
| | MDB | 4 KB | 1% | 73% | Jet engine page structure |
| **Game ROM** | SNES | 524 KB | **100%** | **99%** | Internal checksum + complement |
| | NES | 131 KB | 0% | 0% | iNES header only |
| | GB | 131 KB | 0% | 1% | Header checksum only (tiny coverage) |
| | GBA | 8.3 MB | 0% | 0% | Header checksum only (tiny coverage) |
| | Genesis | 524 KB | 0% | 1% | Header checksum only (tiny coverage) |
| | N64 | 8.3 MB | 0% | 0% | No checksum validation |
| **Disk Image** | DMG | 16 KB | 0% | 10% | Plist + koly trailer structure |
| | ISO | 358 KB | 0% | 0% | PVD structural only |
| **Executable** | COFF | 10 KB | 0% | 1% | Section header structure |
| | Mach-O Fat | 33 KB | 0% | 0% | Architecture header only |
| **Container** | OLE2 (PPT) | 912 KB | 0% | 0% | FAT/directory structural only |
| | InDesign | 4 KB | 1% | 73% | Page structure |
| **Font** | TTF | 621 KB | 0% | 0% | No checksum validation |
| | OTF | 334 KB | 1% | 0% | Minimal structure |
| | WOFF | 260 KB | 0% | 0% | No checksum validation |
| | WOFF2 | 177 KB | 0% | 0% | No checksum validation |
| **Scientific** | FITS | 699 KB | 0% | 2% | Header keyword validation only |
| | DICOM | 39 KB | 5% | 20% | Tag structure + value validation |
| **Financial** | QDF | 5.1 MB | 1% | 0% | OLE2/ZIP container structural |
| **Other** | Blorb | 3.1 MB | 0% | 0% | IFF structural only |
| | DS_Store | 10 KB | 0% | 25% | BTree page structure |
| | ASF | 7 KB | 1% | 0% | GUID/object structural |
| | HDF5 | 6 KB | 4% | 13% | Jenkins lookup3 checksum (small file) |

## Key Findings

### Formats with strong corruption detection (>80% sniper)

| Format | Mechanism | Coverage |
|--------|-----------|----------|
| **PNG** | CRC32 per IDAT/ancillary chunk | Every byte in every chunk is checksummed |
| **MKV** | CRC32 per EBML cluster | Every byte in every cluster is checksummed |
| **SNES** | Internal checksum + complement | Every byte of ROM data is summed |
| **QBW** | CRC32 per 4096-byte database page | Every byte on every page is checksummed |
| **AC3** | CRC-16 per syncframe (MSB-first, poly 0x8005) | Every byte except 2-byte sync word (~99.8% coverage) |
| **OGG** | CRC32 per Ogg page | Every byte in every page is checksummed |
| **CPT** | CRC per resource fork entry | Full file coverage |
| **JXL** | Container-level checksums + frame integrity | High structural + data coverage |
| **WebP** | VP8/VP8L full decode via libwebp | Frame-level decode catches most corruption |
| **EAC3** | CRC-16 per syncframe | ~81% sniper with 1.2MB file (see E-AC3 note) |
| **FLAC** | MD5 of decoded audio + CRC-8/CRC-16 per frame | Full coverage (80% sniper on small file) |

**Common thread:** All use per-block/per-chunk checksums or full-stream decode that covers most payload bytes.

### Formats where shotgun >> sniper

| Format | Sniper | Shotgun | Explanation |
|--------|--------|---------|-------------|
| **ALAC** | 1% | 100% | Lossless decode: single bit → wrong-but-decodable sample; 4KB → frame boundary destruction |
| **AV1** | 5% | 100% | OBU framing: single bit → valid arithmetic; 4KB → destroys OBU headers/tile structure |
| **MPEG-TS** | 4% | 100% | PAT/PMT CRC: sniper rarely hits control tables; 4KB always destroys at least one |
| **MIDI** | 15% | 100% | Track framing: 4KB destroys delta-time + event structure |
| **JPEG2K** | 6% | 97% | Codestream markers: 4KB destroys tile-part headers |
| **GIF** | 2% | 94% | LZW: tolerates isolated flips but 4KB destroys code table state |
| **JPEG** | 0% | 93% | Huffman: 1-bit → wrong-but-valid DCT; 4KB → Huffman desync |
| **XLS** | 12% | 90% | BIFF8 record chain: 4KB destroys record boundaries |
| **SQLite** | 54% | 100% | Page headers: sniper sometimes hits; 4KB always destroys a page |
| **MP4** | 0% | 66% | H.264 CABAC: sniper absorbed; 4KB can hit box headers or codec structure |
| **TAR** | 15% | 73% | Header checksum: covers ~2% of each 512-byte block; 4KB hits multiple |
| **ACCDB/MDB** | 1% | 73% | Page structure: 4KB overwrites entire page (file is only 4KB) |

**Common thread:** These formats use entropy coding or structural framing that absorbs single-bit errors but cannot survive 4KB destruction.

### Formats with no detection (0% both modes)

| Format | Why | Could we improve? |
|--------|-----|-------------------|
| **TIFF/DNG/ARW/CR2/NEF** | IFD tag validation only; pixel/raw data has no checksums | Unlikely without external checksums |
| **DPX/PAM/TGA** | Raw pixel data with no integrity mechanism | Fundamental — no checksums in spec |
| **HEIC** | Full H.265 CABAC decode per tile — arithmetic absorbs corruption | Fundamental (see "HEIC CABAC paradox") |
| **MP3** | Frame sync only; optional CRC covers header not data | MP3 CRC spec is header-only |
| **AVI/MPEG-4 Part 2** | RIFF structural only; no codec-level validation | Would need codec-specific decode |
| **PDF** | Xref structure + image parsing, but content streams opaque | No content checksums in spec |
| **TTF/OTF/WOFF/WOFF2** | No checksum validation implemented | TTF has table checksums — actionable |
| **N64/NES/GBA** | Header-only or no checksum | ROM checksums vary by game |
| **OLE2 (PPT)** | FAT/directory structure only | Would need PowerPoint stream parsing |
| **Blorb** | IFF structural only | Would need chunk-level CRC |
| **Tracker** | No integrity mechanism | Fundamental |
| **AU** | Header + raw PCM, no checksums | Fundamental |
| **DV** | No structural validation beyond container | Would need DIF block parsing |
| **ISO** | PVD structural only | Would need path table/directory cross-validation |

### The JPEG paradox

JPEG achieves **93% shotgun** but **0% sniper** despite doing a full libjpeg-turbo entropy decode. This is because:

1. **Huffman coding is resilient to single-bit errors.** A flipped bit in a VLC codeword may decode to a different-but-valid coefficient. The decoder produces a slightly wrong image but no error.
2. **4KB overwrites destroy synchronization.** The Huffman decoder loses track of codeword boundaries and quickly hits an invalid state.
3. **JPEG has no checksums.** Even a full pixel-level decode cannot distinguish "correct pixels" from "wrong-but-decodable pixels."

This is a fundamental limitation of lossy compression without integrity metadata.

### The HEIC CABAC paradox

HEIC shows **0% sniper, 4% shotgun** despite implementing a full H.265 CABAC arithmetic decoder per tile. Investigation (2026-03-06):

1. **CABAC arithmetic coding is even more resilient than Huffman.** The arithmetic engine maintains a range/offset state that adjusts smoothly to any input. A flipped bit causes the engine to decode different-but-valid syntax elements (different CU splits, different coefficients), producing a different-but-decodable bitstream. The engine never enters an "invalid state" — it just decodes wrong values.
2. **4KB overwrites mostly survive CABAC.** Unlike JPEG where 4KB destroys Huffman sync (93% shotgun), CABAC's arithmetic range smoothly adapts to any 4KB of data. The 4% shotgun detection comes from corruption hitting NAL length prefixes or NAL type headers — structural bytes, not CABAC data.
3. **Structural coverage is ~0.2%.** Each tile has 6 bytes of structural data (4-byte NAL length prefix + 2-byte NAL header) out of 15-106KB total. Corruption in these bytes IS detected. Random corruption has only 0.2% chance of hitting structure.
4. **No checksums exist in HEIF/ISOBMFF.** The container format provides no integrity mechanism.

**Why HEIC is worse than JPEG for corruption detection:**
- JPEG's Huffman coding uses variable-length codewords aligned to bit boundaries. A 4KB overwrite destroys the decoder's bit-position tracking, causing cascading failures (93% shotgun).
- CABAC's arithmetic coding uses a continuous probability range that adapts to any input. There are no "bit boundaries" to desynchronize — the range/offset state always produces valid decisions.

This is the fundamental limit of arithmetic coding without checksums.

### The FLAC anomaly (FIXED)

FLAC originally showed **98% sniper** but only **78% shotgun**. Root cause: the FLAC decoder catch blocks in `validateFlacDeep` were returning `OK` when the decoder threw errors (truncated frames, invalid sync from corrupted data). A 4KB overwrite would corrupt frame headers, causing the decoder to error out, and the catch block incorrectly said "valid." Fix: only `Unsupported`/`OutOfMemory` errors fall back to structural; all other decoder errors are treated as corruption. After fix: **98% sniper, 99% shotgun** (on 404KB file). Note: the 44KB file in the sweep shows 80%/88% — smaller files have proportionally less CRC coverage.

### The MKV surprise

MKV achieves **100% sniper, 100% shotgun** — the only video container with per-cluster CRC32. This is because MKV's EBML format includes optional CRC-32 elements at the cluster level, and our MKV samples have these enabled. This makes MKV the gold standard for video integrity detection.

### E-AC3 file size dependency

E-AC3 detection varies significantly with file size:
- 1.2 MB file: **81% sniper, 85% shotgun**
- 4.1 MB file: **33% sniper, 36% shotgun**

This suggests we may only be validating a portion of larger E-AC3 files (likely first 1MB). Investigate and fix for full-file CRC coverage.

## Actionable Gaps

### High priority (formats with existing checksums we should be verifying)

1. **TTF/OTF table checksums**: TrueType and OpenType fonts have per-table CRC32 checksums in their table directory. Currently showing 0%/0%. Implementing table checksum verification would likely achieve near-100% detection.
2. **WOFF/WOFF2 checksums**: WOFF has per-table checksums inherited from the underlying OTF/TTF. WOFF2 has a Brotli-compressed payload with inherent integrity.
3. **E-AC3 full-file CRC**: Detection drops from 81% to 33% on larger files, suggesting partial validation. Fix to process entire file.
4. **FITS DATASUM/CHECKSUM**: FITS files can contain HDU-level checksums. If present, we should verify them.

### Medium priority (formats where deeper decode could help)

5. **HDF5 full checksum traversal**: Currently only checking superblock + root OHDR. Walking the full object tree would improve from 4%/13%.
6. **SQLite page checksums**: 54% sniper is good but not great. WAL mode files or journal checksums could improve.
7. **ISO path table cross-validation**: Currently 0%/0%. Path table + directory record validation could detect structural corruption.

### Low priority (fundamentally limited)

8. **TIFF/DNG/ARW/CR2/NEF**: Raw pixel data with no checksums. Only external parity (par2) can protect these.
9. **PDF**: Content streams are deflate-compressed text — no checksums. Structural checks are all we can do.
10. **MP3**: Optional CRC covers frame header only, not audio data. Most MP3s don't even have CRC.
11. **HEIC/AVIF**: Arithmetic coding absorbs corruption. Fundamental limitation.

## Methodology

- **sniper**: Flip 1 random bit at a random byte offset. Tests per-byte coverage.
- **shotgun**: Overwrite 4096 random bytes at a random offset. Simulates disk sector failure.
- **PRNG**: PCG32 with seed=42 for reproducibility.
- **Detection**: `validate` returns non-zero exit code.
- **Confidence**: Wilson interval at 95%. With n=100, margin is ±1.8% at extremes (0% or 100%) and up to ±10% near 50%.
- **Limitation**: 100 trials gives ballpark only. For precise measurement, use `--count 38416` (±0.5% margin).
- **Sweep tool**: `scripts/corruption-sweep` runs all formats with `--batch`/`--batches` for parallel execution.
- **Result data**: TSV files in `docs/corruption-sweep-results/` (one per format per mode).
