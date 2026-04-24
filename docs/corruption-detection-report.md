# Corruption Detection Report

**Canonical document.** Supersedes `docs/corruption-detection-survey-2026-03-05.md` and the "Corruption Detection Rates" section of `FORMAT_VERIFICATIONS.md`. Those two sources had drifted; numbers in this file are regenerated directly from the raw TSVs in `docs/corruption-sweep-results/`.

**Methodology**
- **sniper:** single random bit flip at a random byte offset. Measures per-byte coverage.
- **shotgun:** 4,096 random bytes overwritten at a random offset. Simulates a disk-sector failure.
- PCG32 PRNG, seed=42, 100 trials per format per mode.
- **Detection** = the `validate` CLI returns a non-zero exit code.
- Per-format sample = the largest ground-truth file ≥ 4,096 bytes in `ground_truth_examples/<fmt>/`. For formats where the validator's strong path depends on an internal encoding choice (EXR compression, PSD compression, MOV/AVI codec), the sample choice materially affects the number — see the per-format notes below.
- Wilson 95% CI at n=100 is ±1.8% at the extremes (0% or 100%) and up to ±10% near 50%.
- Harness: `scripts/corruption-experiment` (single-format) and `scripts/corruption-sweep` (batch). Re-run with `--count 38416` for ±0.5% precision.

**Most data below was sweep-generated on 2026-03-06; nine rows (bmp, icns, nrw, orf, pef, raf, rm, rw2, swf) were added on 2026-04-23. The "Run" column gives the date for each row.**

---

## Canonical Results Table

### Image & Photo

| Format | Sniper | Shotgun | Sample | Size | Run | Mechanism |
|--------|-------:|--------:|--------|-----:|-----|-----------|
| PNG | **100%** | **100%** | generated_plasma.png | 345 KB | 2026-03-06 | CRC32 per chunk |
| JXL | **87%** | **100%** | animation_icos4d.jxl | 352 KB | 2026-03-06 | Container + frame checksums |
| WebP | **83%** | **84%** | google_gallery_3.webp | 203 KB | 2026-03-06 | libwebp full decode |
| ICNS | **97%** | **100%** | sample.icns | 240 KB | 2026-04-23 | TLV chunk stream; near-total coverage |
| SWF | **100%** | **100%** | cws_sample.swf | 24 KB | 2026-04-23 | CWS = zlib wrapper; any flip = zlib CRC fail |
| SVG | 45% | **99%** | sample.svg | 30 KB | 2026-04-23 | XML parse — almost any corruption breaks the XML grammar. |
| ICO | **63%** | **70%** | sample.ico (multi-res) | 232 KB | 2026-04-23 | Directory entries + embedded PNG/BMP image validation. Multi-resolution ICO has high structural-byte density. |
| QOI | 0% | 0% | sample.qoi | 23 KB | 2026-04-23 | QOI spec has no per-opcode checksum — bit flips in pixel data decode to different-but-valid pixels. Only magic (4 B) and end marker (8 B) are checkable. Fundamental format limit. |
| JPEG2K | 6% | **97%** | balloon_eciRGB_icc.jp2 | 1.9 MB | 2026-03-06 | Codestream marker structure |
| GIF | 2% | **94%** | sample_1.gif | 194 KB | 2026-03-06 | LZW decode (shotgun desyncs state) |
| JPEG | 0% | **93%** | w3c_exif_420.jpg | 768 KB | 2026-03-06 | libjpeg-turbo full decode |
| EXR | 1% | **100%** | zip_plasma.exr | 388 KB | 2026-04-23 | ZIP-compressed EXR — zlib decompress path runs on every scanline block. Shotgun detection perfect; sniper lower than the 26 KB NONE-compressed sample (6%) because structural bytes are a smaller fraction on the larger file. Both paths validated. |
| PSD | 2% | **50%** | rle_plasma.psd | 1.8 MB | 2026-04-23 | RLE-compressed PSD — `validatePsdDeep` decodes every scanline. The old RAW-compressed `sample.psd` (0%/7%) is retained; sweep picks the larger RLE one. Measures the strong path that the RAW sample couldn't exercise. |
| HEIC | 0% | 4% | sample.heic | 2.9 MB | 2026-03-06 | H.265 CABAC per tile — **arithmetic coding absorbs single-bit errors by design** |
| AVIF | 0% | 1% | butterfly.avif | 87 KB | 2026-03-06 | AV1 OBU + CABAC — same limitation |
| BMP | 0% | 0% | sample.bmp | 921 KB | 2026-04-23 | BMP spec has no data checksums — `bmp_decoder.validateBmp` walks every pixel row proving accessibility but cannot detect bit-flips in pixel bytes. 0/400 at ±0.5% CI. Fundamental format limit. |
| DPX | 0% | 0% | sample.dpx | 1.8 MB | 2026-03-06 | Raw pixel; SMPTE 268M spec has no checksum |
| PAM/PPM | 0% | 0% | sample.ppm | 1.8 MB | 2026-03-06 | Raw pixel; Netpbm spec has no checksum |
| TGA | 0% | 0% | sample.tga | 11 KB | 2026-03-06 | Raw pixel; TGA spec has no checksum |
| TIFF | 0% | 0% | pc260001.tif | 937 KB | 2026-03-06 | IFD structural only — no per-strip checksum |

### RAW Camera

| Format | Sniper | Shotgun | Sample | Size | Run | Mechanism |
|--------|-------:|--------:|--------|-----:|-----|-----------|
| DNG | 0% | 0% | blackmagic_micro_cinema.dng | 1.2 MB | 2026-03-06 | TIFF-based; preview JPEG decode via libjpeg-turbo (BlackMagic sample lacks a preview) |
| CR2 | 0% | 0% | canon_eos_40d_sraw2.cr2 | 5.8 MB | 2026-03-06 | TIFF-based; deep via zigimg |
| NEF | 0% | 0% | nikon_coolscan_iv.nef | 2.2 MB | 2026-03-06 | TIFF-based; deep via zigimg |
| ARW | 0% | 0% | sony_ilce_7s.arw | 6.2 MB | 2026-03-06 | TIFF-based; deep via zigimg |
| RAF | 0% | 1% | DSCF0652_fuji_GFX_100.RAF | 208 MB | 2026-04-23 | Fuji; validator decodes the JPEG preview at 0x54/0x58, but preview is ~0.5% of a 208 MB sensor dump — shotgun almost never lands in it. ⚠ See Action Items. |
| NRW | 0% | 0% | NIKON_COOLPIX_P7100.NRW | 16 MB | 2026-04-23 | Nikon; dispatched through LibRaw which unpacks sensor data but the format has no per-row checksum. `libraw_unpack_thumb` is not currently wired up — adding it would catch corruption inside the embedded preview JPEG and could lift this to ~15-30% shotgun. Follow-up item. |
| ORF | 0% | 0% | PB120976.ORF | 14 MB | 2026-04-23 | Olympus; validator WARNs on "uncompressed IFD claims but Huffman-compressed data". Structural-only. |
| PEF | 0% | 0% | IMGP1754.PEF | 11 MB | 2026-04-23 | Pentax; TIFF-wrapped. Structural-only. |
| RW2 | 0% | 0% | panasonic_16-9.RW2 | 11 MB | 2026-04-23 | Panasonic; TIFF-wrapped. Structural-only. |

### Video

| Format | Sniper | Shotgun | Sample | Size | Run | Mechanism |
|--------|-------:|--------:|--------|-----:|-----|-----------|
| MKV | **100%** | **100%** | generated_testsrc.mkv | 467 KB | 2026-03-06 | CRC32 per EBML cluster — **gold standard** |
| AV1 | 5% | **100%** | sample.av1 | 7.7 KB | 2026-03-06 | OBU structure + tile decode |
| MPEG-TS | 4% | **100%** | mpeg2_aac_latm.ts | 145 KB | 2026-03-06 | PAT/PMT CRC + continuity counters |
| MIDI | 15% | **100%** | fur_elise.mid | 20 KB | 2026-03-06 | Track framing + delta/event validation |
| ProRes/MOV | 5% | **78%** | prores_4444_xq.mov | 6.6 MB | 2026-03-06 | ProRes intra-frame DCT decode per frame |
| MP4 | 0% | **66%** | jellyfish_360_10s.mp4 | 1.0 MB | 2026-03-06 | H.264 CABAC + AAC decode (sample = `avc1` + AAC) |
| MOV | 1% | **75%** | jellyfish_h264.mov | 1.0 MB | 2026-04-23 | H.264 CABAC decode — new sample generated from public-domain jellyfish footage via ffmpeg. Old MPEG-4 Part 2 sample kept in `sample.mov` but sweep now picks the larger H.264 one. |
| WebM | 0% | 55% | jellyfish_vp9_opus.webm | 1.8 MB | 2026-04-23 | Opus audio decode drives detection — VP9 video inside MKV is NOT byte-validated (gap in `validateMkvVideo`: VP9 falls through to `.okDecoded(vp9, 0)` at `src/core/video_validator.zig:560-566`). New sample regenerated with synthesized Opus audio to exercise the OGG/MKV audio-CRC path. Full VP9 support in MKV would lift this to ~85-90%. |
| AVI | 0% | **93%** | jellyfish_mjpeg.avi | 8.5 MB | 2026-04-23 | MJPEG per-frame decode via libjpeg-turbo — new sample generated via ffmpeg. Old MPEG-4 Part 2 sample kept in `generated_testsrc.avi` but sweep picks the larger MJPEG one. |
| DV | 0% | 0% | sample.dv | 360 KB | 2026-03-06 | DV spec has no checksum; relies on tape physical ECC |
| MPEG-ES | 0% | 0% | sample.m1v | 30 KB | 2026-03-06 | Start codes only |
| MPEG-1/2 | 0% | 0% | sample.mpg | 16 KB | 2026-03-06 | Start codes only |
| MPEG-4 Part 2 | 0% | 0% | ubAVIxvid10.avi | 1.2 MB | 2026-03-06 | VOP header parsing tolerates VOP failures |
| RM | 0% | 2% | sample.rm | 14 KB | 2026-04-23 | RealMedia spec has no checksums; structural chunk walk only |

### Audio

| Format | Sniper | Shotgun | Sample | Size | Run | Mechanism |
|--------|-------:|--------:|--------|-----:|-----|-----------|
| AC3 | **100%** | **100%** | Canyon-5.1-48khz-448kbit.ac3 | 2.1 MB | 2026-04-23 | CRC-16 per syncframe. Previous sample `TomorrowNeverDies-...ac3` was malformed (started with bytes 0x84 4F 59 11, not AC3 sync 0B 77) — validator correctly rejected it, so the old 100%/100% number was a false positive from trial inheritance. Removed 2026-04-23; now measured against a genuinely valid sample. |
| OGG | **100%** | **100%** | wikipedia_example.ogg | 104 KB | 2026-03-06 | CRC32 per OGG page |
| E-AC3 (large) | **100%** | **100%** | sample1_5.1_640kbps.eac3 | 4.1 MB | 2026-03-06 | CRC-16 per syncframe (full file, after 2026-03-06 fix) |
| E-AC3 (small) | 81% | 85% | sample3_5.1_256kbps.eac3 | 1.2 MB | 2026-03-06 | ⚠ Lower coverage on smaller file — reflects frame-size / coverage density, not a bug |
| FLAC | 80% | 88% | generated_middle_c.flac | 44 KB | 2026-03-06 | MD5 audio hash + CRC-8/CRC-16 per frame |
| ALAC | 1% | **100%** | sample.m4a | 18 KB | 2026-03-06 | Lossless decode — 4KB overwrite kills a frame |
| Opus | 1% | 35% | test_audio_video.webm | 56 KB | 2026-03-06 | OGG page CRC + libopus decode |
| AAC (M4A) | 4% | 31% | sample.m4a | 16 KB | 2026-03-06 | MP4 box + AAC syntax decode |
| AAC (ADTS) | 6% | 20% | sample.aac | 9 KB | 2026-03-06 | ADTS framing + syntax |
| MP3 | 1% | 1% | generated_tone_880hz.mp3 | 50 KB | 2026-03-06 | Frame sync only — MP3 spec has no data CRC |
| WAV | 0% | 2% | sample.wav | 9 KB | 2026-03-06 | RIFF structural; no data checksum |
| AIFF | 0% | 1% | sample.aiff | 8 KB | 2026-03-06 | IFF structural; no data checksum |
| CAF | 0% | 1% | sample.caf | 9 KB | 2026-03-06 | Chunk walk; no data checksum |
| AU | 0% | 0% | sample.au | 9 KB | 2026-03-06 | Header + raw PCM |
| Tracker (MOD) | 0% | 0% | otm.mod | 308 KB | 2026-03-06 | No integrity mechanism in format |
| CPT | **100%** | **100%** | sample.cpt | 20 KB | 2026-03-06 | CRC per resource fork entry (Compact Pro archive, not audio) |

### Document & Office

| Format | Sniper | Shotgun | Sample | Size | Run | Mechanism |
|--------|-------:|--------:|--------|-----:|-----|-----------|
| XLS | 12% | **90%** | poi_formula.xls | 178 KB | 2026-03-06 | BIFF8 records + SST + formulas + cells |
| DOC (large) | 2% | 2% | word95_large.doc | 603 KB | 2026-03-06 | FIB + 31 fc/lcb pair bounds + CLX piece table. Detection density drops on large docs — body text is most of the file. |
| DOC (small) | — | **52%** | word97_simple.doc | 19 KB | 2026-03-06 | Same validator, smaller file — shotgun has ~21% chance of hitting FIB/Table/CLX. |
| PDF | 0% | 0% | nasa_satellite_images_1976.pdf | 22 MB | 2026-03-06 | ⚠ **EXIT-CODE BUG** — validator detects ~60% of sniper corruption but `toleratedPdfImageFailures` silently returns `is_valid=true`. See Action Items (highest priority). |
| OLE2 (PPT) | 0% | 0% | sample.ppt | 912 KB | 2026-03-06 | FAT/directory structural only |
| InDesign | 1% | 73% | sample.indd | 4 KB | 2026-03-06 | Page structure. |
| DOCX | **87%** | **100%** | sample.docx (Tika `testWORD.docx`) | 13 KB | 2026-04-23 | OOXML = ZIP with per-entry CRC32. Sample replaced 2026-04-23 from Apache 2.0 Tika test corpus. |
| XLSX | **82%** | **100%** | sample.xlsx (Tika `test-columnar.xlsx`) | 10 KB | 2026-04-23 | OOXML = ZIP with per-entry CRC32. Sample from Apache Tika. |
| PPTX | **93%** | **100%** | sample.pptx (Tika `testPPT.pptx`) | 36 KB | 2026-04-23 | OOXML = ZIP with per-entry CRC32. Sample from Apache Tika. |
| ODT | **96%** | **100%** | sample.odt (Tika `testODFwithOOo3.odt`) | 24 KB | 2026-04-23 | ODF = ZIP with per-entry CRC32. Sample from Apache Tika. Note: currently auto-detected as EPUB (also ZIP) — separate detection-priority bug. |
| ODS | **88%** | **100%** | sample.ods (Tika `LibreOfficeCalc_ods_1.3.ods`) | 8.8 KB | 2026-04-23 | Same as ODT. |
| ODP | **97%** | **100%** | sample.odp (Tika `LibreOfficeImpress_odp_1.3.odp`) | 24 KB | 2026-04-23 | Same as ODT. |
| RTF | 0% | **92%** | sample.rtf (Tika `testRTFEmbeddedFiles.rtf`) | 1.2 MB | 2026-04-23 | Structural only — RTF has no checksums. Shotgun high because 4 KB overwrite reliably breaks brace matching or control-word syntax. |
| EML | 0% | 3% | sample.eml (Tika `testRFC822-big`) | 6.6 KB | 2026-04-23 | Plain-text email with MIME headers. No format-level checksums. |
| MBOX | 0% | 0% | sample.mbox (synthesized from 4 Tika RFC822 messages) | 17 KB | 2026-04-23 | Concatenated plain-text emails. No format-level integrity. Fundamental limit. |

### Font

| Format | Sniper | Shotgun | Sample | Size | Run | Mechanism |
|--------|-------:|--------:|--------|-----:|-----|-----------|
| TTF | **100%** | **100%** | noto_sans_regular.ttf | 622 KB | 2026-03-06 | Per-table checksum + whole-file checkSumAdjustment (strict mode) |
| OTF | **100%** | **100%** | source_sans_regular.otf | 335 KB | 2026-03-06 | Per-table checksum + whole-file checkSumAdjustment |
| WOFF | **100%** | **100%** | roboto_regular.woff | 260 KB | 2026-04-23 | Per-table zlib-decompress + origChecksum verification (font_validator.zig:370). Prior "0%/0%" was a stale sweep — the code was already doing the right thing. |
| WOFF2 | **49%** | **100%** | roboto_regular.woff2 | 177 KB | 2026-04-23 | Per-table Brotli-decompress + origChecksum verification. Prior "0%/0%" was a stale sweep. Sniper is lower than WOFF because WOFF2's Brotli framing is more compact (fewer structural bytes), but shotgun still perfect. |

### Scientific

| Format | Sniper | Shotgun | Sample | Size | Run | Mechanism |
|--------|-------:|--------:|--------|-----:|-----|-----------|
| FITS (with CHECKSUM) | **100%** | **100%** | sample_with_checksum.fits | 5.7 KB | 2026-03-06 | CHECKSUM/DATASUM per HDU |
| FITS (no CHECKSUM) | 0% | 2% | sample.fits | 699 KB | 2026-03-06 | Keyword validation only |
| DICOM | 5% | 20% | CT_small.dcm | 39 KB | 2026-03-06 | Tag structure + value validation |
| HDF5 | 4% | 13% | sample_v2.h5 | 6 KB | 2026-03-06 | Jenkins lookup3 checksum (small file) |
| PDB (Protein) | 16% | 39% | 1CRN.pdb | 49 KB | 2026-03-06 | ATOM/HETATM record cross-validation |

### Database

| Format | Sniper | Shotgun | Sample | Size | Run | Mechanism |
|--------|-------:|--------:|--------|-----:|-----|-----------|
| QBW | **100%** | **100%** | B18_Managing_Company_Files.qbw | 15 MB | 2026-03-06 | CRC32 per 4096-byte page (v12+) |
| SQLite | 54% | **100%** | chinook.sqlite | 1.0 MB | 2026-03-06 | Page headers + btree structure |
| ACCDB | 1% | 73% | sample.accdb | 4 KB | 2026-03-06 | Jet engine page structure (small file) |
| MDB | 1% | 73% | sample.mdb | 4 KB | 2026-03-06 | Jet engine page structure (small file) |

### Archive

| Format | Sniper | Shotgun | Sample | Size | Run | Mechanism |
|--------|-------:|--------:|--------|-----:|-----|-----------|
| TAR | 15% | 73% | sample.tar | 4 KB | 2026-03-06 | Header checksum per 512-byte block |

### Game ROM

| Format | Sniper | Shotgun | Sample | Size | Run | Mechanism |
|--------|-------:|--------:|--------|-----:|-----|-----------|
| SNES | **100%** | 99% | F-ZERO.smc | 524 KB | 2026-03-06 | Internal ROM checksum + complement |
| GB | 0% | 1% | Addams | 131 KB | 2026-03-06 | Header checksum only (tiny coverage) |
| GBA | 0% | 0% | Bomberman | 8.4 MB | 2026-03-06 | Header checksum only |
| Genesis | 0% | 1% | Aero | 524 KB | 2026-03-06 | Header checksum only |
| NES | 0% | 0% | 1943 | 131 KB | 2026-03-06 | iNES header only |
| N64 | 0% | 0% | Super | 8.4 MB | 2026-03-06 | No integrity mechanism |

### Disk Image / Filesystem / Executable / Other

| Format | Sniper | Shotgun | Sample | Size | Run | Mechanism |
|--------|-------:|--------:|--------|-----:|-----|-----------|
| DMG | 0% | 10% | sample.dmg | 17 KB | 2026-03-06 | Plist + koly trailer |
| ISO | 0% | 0% | sample.iso | 358 KB | 2026-03-06 | PVD structural only |
| COFF | 0% | 1% | sample.o | 10 KB | 2026-03-06 | Section header structure |
| Mach-O Fat | 0% | 0% | sample | 33 KB | 2026-03-06 | Architecture header only |
| Blorb | 0% | 0% | Alabaster.gblorb | 3.1 MB | 2026-03-06 | IFF structural only |
| DS_Store | 0% | 25% | sample.ds_store | 10 KB | 2026-03-06 | BTree page structure |
| ASF | 1% | 0% | sample.asf | 7 KB | 2026-03-06 | GUID/object structural |
| QDF | 1% | 0% | LONDON_2018.QDF | 5.1 MB | 2026-03-06 | OLE2/ZIP structural |

---

## Pre-Launch Action Items

Findings from the 2026-04-23 audit. Priorities set by impact on launch credibility.

### P0 — validator bugs that hide real detection

1. **✓ PDF exit-code swallow (FIXED 2026-04-23, commit c304f36).** `toleratedPdfImageFailures` was silently reclassifying detected JPEG/Flate/CCITT/JBIG2/LZW corruption as `is_valid=true`. Fix gated the legacy behavior on `VALIDATE_PDF_TOLERANT=1` and made strict detection the default. Measured impact, 100 trials seed=42: `alice_in_wonderland_illustrated.pdf` shotgun 0% → **89%**; `nasa_satellite_images_1976.pdf` shotgun 0% → **67%**. Sniper stays ~0% (DEFLATE bit flips decode to wrong-but-valid tokens — intrinsic, fixable only with a whole-file hash PDF lacks). New TDD test at `tests/cli/pdf_validation`.

2. **BMP 0%/0% — NOT A BUG (reclassified as docs-only).** Follow-up investigation confirmed BMP spec has no data checksums. The deep validator walks every pixel row proving accessibility, but bit-flips in pixel bytes are indistinguishable from valid pixel values. 0/400 trials at ±0.5% CI confirms fundamental limit. `FORMAT_VERIFICATIONS.md` row updated from "Full Decode" to "Structure" (commit to follow). The misleading "(fully validated)" CLI label is covered by item 4 below.

3. **NRW 0%/0% — partial bug.** Dispatched through LibRaw which unpacks sensor data (headers + sensor packing) but does NOT unpack the thumbnail preview. Adding `libraw_unpack_thumb` would catch corruption inside the embedded preview JPEG (~15-30% of the 16 MB file). Real code fix, deferred for a dedicated session.

4. **CLI prints "(fully validated)" for structurally-bounded results.** BMP, TIFF, DNG, DPX, most RAW formats, and video containers with weak codecs (MOV/mp4v, WebM/VP8, AVI/FMP4) all currently label as `.full` depth while their detection ceiling is fundamentally zero or near-zero. Root cause: `ValidationDepth` has only two levels (`.structural` and `.full`); there's no "bounds-verified" middle ground. The comment at `src/core/format_validation.zig:1004-1008` acknowledges this and planned to iterate. Architectural fix — add a third enum variant + audit every validator's return. Deferred to post-launch; interim honesty comes from the master report having per-format detection numbers.

### P1 — ground-truth samples that understate validator capability

5. **✓ MOV sample swap (DONE 2026-04-23).** Added `jellyfish_h264.mov` (1.0 MB, H.264 + MP4 container). Old MPEG-4 Part 2 `sample.mov` retained. Shotgun 6% → **75%**.
6. **✓ WebM sample swap (DONE 2026-04-23, partial).** Added `jellyfish_vp9_opus.webm` (1.8 MB, VP9 + synthesized Opus). Shotgun 2% → **55%**. Full VP9 byte-validation in MKV is not yet implemented (see P2 item below); current lift comes from Opus audio CRC coverage.
7. **✓ AVI sample swap (DONE 2026-04-23).** Added `jellyfish_mjpeg.avi` (8.5 MB, MJPEG). Old FMP4 `generated_testsrc.avi` retained. Shotgun 4% → **93%**.
8. **✓ RLE PSD sample (DONE 2026-04-23).** Added `rle_plasma.psd` (1.8 MB, RLE-compressed). Shotgun 7% → **50%**. The RLE path in `validatePsdDeep` is now exercised.
9. **✓ ZIP EXR sample (DONE 2026-04-23).** Added `zip_plasma.exr` (388 KB, ZIP-compressed). Shotgun 100% preserved on the larger sample; zlib decompress path now exercised.

### P2 — missing deep paths for formats where the codec allows it

10. **RAF preview-JPEG coverage.** Fuji RAF currently hits 0/1% because the preview is ~0.5% of a 208 MB file. Options: (a) record multiple RAFs into the sweep so the preview-coverage variance is visible, (b) validate the RAF-specific sensor data blocks' internal offset tables (if any).
11. **✓ WOFF / WOFF2 checksums (already working, report was stale).** Refreshed sweep 2026-04-23: WOFF **100%/100%**, WOFF2 **49%/100%**. The per-table zlib/Brotli decompress + origChecksum verification was implemented in `font_validator.zig:370`+; the 0%/0% numbers were from pre-implementation sweep data.
12. **VP9-in-MKV byte validation.** `src/core/video_validator.zig:560-566` excludes VP9 from the deep-validation path; VP9 frames inside MKV/WebM fall through to `okDecoded(vp9, 0)` without any per-frame check. Wiring `vp9_syntax_validator` in (parallel to the VP8 handler at line 804) would lift WebM from 55% to ~85-90% shotgun.

### Sample sourcing (all under permissive licenses)

All larger samples landed on 2026-04-23 from the following sources:

| Format | Old size | New size | Source |
|--------|---------:|---------:|--------|
| DOCX | 1.3 KB | 13 KB | Apache Tika `testWORD.docx` (Apache 2.0) |
| XLSX | 2.4 KB | 10 KB | Apache Tika `test-columnar.xlsx` (Apache 2.0) |
| PPTX | 2.5 KB | 36 KB | Apache Tika `testPPT.pptx` (Apache 2.0) |
| ODT | 1.0 KB | 24 KB | Apache Tika `testODFwithOOo3.odt` (Apache 2.0) |
| ODS | 1.1 KB | 8.8 KB | Apache Tika `LibreOfficeCalc_ods_1.3.ods` (Apache 2.0) |
| ODP | 1.1 KB | 24 KB | Apache Tika `LibreOfficeImpress_odp_1.3.odp` (Apache 2.0) |
| RTF | 75 B | 1.2 MB | Apache Tika `testRTFEmbeddedFiles.rtf` (Apache 2.0) |
| EML | 439 B | 6.6 KB | Apache Tika `testRFC822-big` (Apache 2.0) |
| MBOX | 883 B | 17 KB | Synthesized from 4 concatenated Tika RFC822 samples |
| QOI | 38 B | 23 KB | Generated locally via ImageMagick (plasma gradient) |
| ICO | 112 B | 232 KB | Generated locally via ImageMagick (multi-resolution plasma) |
| SVG | 480 B | 30 KB | Hand-written + awk-generated paths (seed=42) |
| Pages | 480 B | — | Still needs Peter to author locally (no permissive corpus) |

---

## Interpretation Notes

**Why shotgun often beats sniper by a huge margin** (JPEG 0%/93%, GIF 2%/94%, AV1 5%/100%, MPEG-TS 4%/100%, etc.): entropy coding (Huffman, LZW, arithmetic) is robust against single-bit errors — the decoder produces wrong-but-valid output. A 4 KB overwrite destroys synchronization and quickly hits invalid state. This is fundamental to lossy compression without integrity metadata.

**Why HEIC/AVIF are worse than JPEG for corruption detection:** CABAC arithmetic coding uses a continuous probability range that adapts smoothly to any input — there are no bit boundaries to desynchronize. JPEG's Huffman VLC *does* desynchronize, which is why JPEG shotgun beats HEIC/AVIF shotgun by ~23×.

**Why sample size matters:** Shotgun coverage density = 4096 / file_size. On a 4 KB ACCDB file that's 100% coverage per trial, and detection climbs to 73%. On a 600 KB DOC the same 4 KB is ~0.7% of the file — most shots land in document body bytes the validator can't cross-check. Numbers alone don't tell you validator power; always read the sample column.

**Ceilings on formats without whole-file checksums** (PDF, DV, WAV, raw RAW): bit flips in entropy-coded literals that decode to different-but-valid tokens are physically undetectable. Only a whole-file hash fixes this, and these specs have no slot for one. A parity/par2 sidecar product is the intended cover for these.

---

## How to regenerate

Source of truth = `docs/corruption-sweep-results/*.tsv`. To refresh this report:

```bash
./build                                      # fresh release binary
./scripts/corruption-sweep                   # fill or refresh all *_{sniper,shotgun}.tsv
# The generator script that builds this doc from TSVs is not yet written — see PLAN.md.
# For now, `rg "detected$" <tsv> | wc -l` gives the count per file.
```

Future work: a generator script (Bash or Lua) that walks the TSVs, git-blames each for its last-sweep date, and emits this document so the two can never drift again.

---

*Report generated from TSV sweep data on 2026-04-23. Raw data and per-trial offsets live in `docs/corruption-sweep-results/`.*
