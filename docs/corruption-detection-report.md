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
| JPEG2K | 6% | **97%** | balloon_eciRGB_icc.jp2 | 1.9 MB | 2026-03-06 | Codestream marker structure |
| GIF | 2% | **94%** | sample_1.gif | 194 KB | 2026-03-06 | LZW decode (shotgun desyncs state) |
| JPEG | 0% | **93%** | w3c_exif_420.jpg | 768 KB | 2026-03-06 | libjpeg-turbo full decode |
| EXR | 6% | **100%** | sample.exr | 26 KB | 2026-04-23 | Offset table + block header validation (sample uses NONE compression; ZIP/ZIPS samples would expose zlib verification path) |
| PSD | 0% | 7% | sample.psd | 120 KB | 2026-04-23 | RLE/ZIP compression paths fully validate, but this sample uses RAW where ~60 KB of payload is structurally unverifiable; a sample with RLE-compressed layers would score much higher |
| HEIC | 0% | 4% | sample.heic | 2.9 MB | 2026-03-06 | H.265 CABAC per tile — **arithmetic coding absorbs single-bit errors by design** |
| AVIF | 0% | 1% | butterfly.avif | 87 KB | 2026-03-06 | AV1 OBU + CABAC — same limitation |
| BMP | 0% | 0% | sample.bmp | 921 KB | 2026-04-23 | ⚠ **REGRESSION** — `FORMAT_VERIFICATIONS.md` labels this "fully validated via zigimg" but detection is zero. See Action Items. |
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
| NRW | 0% | 0% | NIKON_COOLPIX_P7100.NRW | 16 MB | 2026-04-23 | ⚠ Nikon; labeled "fully validated" but no JPEG-preview decode path (DNG-style) exists for NRW — deep path is effectively TIFF-structural. See Action Items. |
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
| MOV (plain) | 1% | 6% | sample.mov | 470 KB | 2026-03-06 | ⚠ Sample is `mp4v` (MPEG-4 Part 2); validator is VOP-header-only for that codec. Replace sample with H.264. See Action Items. |
| WebM | 0% | 2% | jellyfish_360_10s.webm | 1.0 MB | 2026-03-06 | ⚠ Sample is VP8; `validateVp8Deep` is header-only. VP9 samples in same dir hit ~88%. Replace sample. See Action Items. |
| AVI | 0% | 4% | generated_testsrc.avi | 201 KB | 2026-03-06 | ⚠ Sample is `FMP4` (MPEG-4 Part 2); same header-only path as MOV(plain). MJPEG or H.264 AVI would score ≫. |
| DV | 0% | 0% | sample.dv | 360 KB | 2026-03-06 | DV spec has no checksum; relies on tape physical ECC |
| MPEG-ES | 0% | 0% | sample.m1v | 30 KB | 2026-03-06 | Start codes only |
| MPEG-1/2 | 0% | 0% | sample.mpg | 16 KB | 2026-03-06 | Start codes only |
| MPEG-4 Part 2 | 0% | 0% | ubAVIxvid10.avi | 1.2 MB | 2026-03-06 | VOP header parsing tolerates VOP failures |
| RM | 0% | 2% | sample.rm | 14 KB | 2026-04-23 | RealMedia spec has no checksums; structural chunk walk only |

### Audio

| Format | Sniper | Shotgun | Sample | Size | Run | Mechanism |
|--------|-------:|--------:|--------|-----:|-----|-----------|
| AC3 | **100%** | **100%** | TomorrowNeverDies-2.1-48khz.ac3 | 3.2 MB | 2026-03-06 | CRC-16 per syncframe |
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
| DOCX | 78% | — | sample.docx | 1.3 KB | 2026-04-23 | Sniper only — **sample too small for shotgun**; needs 50KB+ real-world file. See Sample Sourcing. |

### Font

| Format | Sniper | Shotgun | Sample | Size | Run | Mechanism |
|--------|-------:|--------:|--------|-----:|-----|-----------|
| TTF | **100%** | **100%** | noto_sans_regular.ttf | 622 KB | 2026-03-06 | Per-table checksum + whole-file checkSumAdjustment (strict mode) |
| OTF | **100%** | **100%** | source_sans_regular.otf | 335 KB | 2026-03-06 | Per-table checksum + whole-file checkSumAdjustment |
| WOFF | 0% | 0% | roboto_regular.woff | 260 KB | 2026-03-06 | Compressed tables — checksum verification requires decompression (not yet implemented) |
| WOFF2 | 0% | 0% | roboto_regular.woff2 | 177 KB | 2026-03-06 | Brotli-compressed tables — same limitation |

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

1. **PDF exit-code swallow.** `src/core/pdf_validator.zig:43-128` (`toleratedPdfImageFailures`), called from `:491` and `:670`, reclassifies every detected `pdf_*_decode_failed` corruption as `is_valid=true`. The CLI exits 0 so the corruption-experiment harness records zero detection. On `nasa_satellite_images_1976.pdf` the deep validator actually catches corruption in ~55–70% of sniper trials — all of it is thrown away. **Fix:** make tolerance opt-in via `--repair-mode` (or treat non-empty `malformations` as non-zero exit in the CLI). Expected lift: 0% → ~55–70% sniper / ~60–80% shotgun.

2. **BMP "fully validated" produces 0%/0%.** `sample.bmp` is 921 KB, labeled fully-validated via zigimg, but detection is zero on both modes. Either the dispatcher returns OK before the decoder runs or zigimg's BMP path doesn't propagate decode errors. Needs tracing in `src/core/image_validators.zig` (find `validateBmp*`).

3. **NRW missing preview-JPEG decode.** Labeled "fully validated" but behaves identically to TIFF-structural (0%/0%). The DNG/RAF path locates and libjpeg-turbo-decodes the embedded preview; NRW does not. Replicate the DNG pattern in NRW dispatch.

4. **CLI prints "(fully validated)" for structural-only results.** Flagged while investigating video containers: webm/avi/mov corrupted files print `OK ... (fully validated)` even when the internal result has `validation_depth=.structural`. The render path at `src/core/video_validator.zig:800-826` (or downstream) is dropping the depth distinction.

### P1 — ground-truth samples that understate validator capability

5. **Swap MOV plain sample** for an H.264 (`avc1`) or HEVC (`hvc1`) `.mov`. Current sample is MPEG-4 Part 2 — deliberately the weakest supported codec path. Expected: 6% → ~65–70% shotgun.
6. **Swap WebM sample** for VP9+Opus. Current sample is VP8 (header-only validator). Expected: 2% → ~88% shotgun.
7. **Swap AVI sample** for MJPEG or H.264 AVI. Current sample is FMP4 (MPEG-4 Part 2). Expected: 4% → ~60–90% shotgun.
8. **Add RLE-compressed PSD sample** alongside the current RAW one; the RLE path is fully instrumented but never exercised by the corpus today.
9. **Add compressed EXR sample** (ZIP/ZIPS). The NONE-compressed sample undersells the validator — it already hits 100% shotgun but sniper would also rise with a compressed sample exposing zlib CRCs.

### P2 — missing deep paths for formats where the codec allows it

10. **RAF preview-JPEG coverage.** Fuji RAF currently hits 0/1% because the preview is ~0.5% of a 208 MB file. Options: (a) record multiple RAFs into the sweep so the preview-coverage variance is visible, (b) validate the RAF-specific sensor data blocks' internal offset tables (if any).
11. **WOFF / WOFF2 checksums.** Both are 0%/0% because compressed tables aren't decompressed to verify `origChecksum`. Doable; needs Flate / Brotli in the deep path.

### Sample sourcing (all under permissive licenses)

See `/tmp/corruption-audit/06-sample-sourcing.md` for full details. Summary:

| Format | Current | Needed | Source |
|--------|--------:|-------:|--------|
| DOCX | 1.3 KB | 50 KB+ | Apache Tika `testWORD_various.docx` (Apache 2.0) |
| XLSX | 2.4 KB | 50 KB+ | Apache Tika `testEXCEL.xlsx` |
| PPTX | 2.5 KB | 50 KB+ | Apache Tika `testPPT_various.pptx` |
| ODT/ODS/ODP | ~1 KB | 50 KB+ | Regenerate via `libreoffice --headless --convert-to ...` from the Tika files (keeps Apache 2.0 provenance) |
| RTF | 75 B | 10 KB+ | Apache Tika `testRTFVarious.rtf` |
| EML | 439 B | 10 KB+ | Apache Tika `testRFC822_multipart` |
| MBOX | 883 B | 20 KB+ | Enron CALO excerpt (public domain) or Apache James |
| QOI | 38 B | 10 KB+ | phoboslab/qoi `dice.qoi` (MIT) |
| ICO | 112 B | 10 KB+ | Wikimedia Commons multi-resolution favicon (CC0) |
| SVG | 480 B | 10 KB+ | W3C SVG 1.1 Test Suite |
| Pages | 480 B | 50 KB+ | No public corpus; author locally, mark CC0 |

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
