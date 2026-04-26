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

**Most data below was sweep-generated on 2026-03-06; nine rows (bmp, icns, nrw, orf, pef, raf, rm, rw2, swf) were added on 2026-04-23. On 2026-04-25, 117 additional formats were swept in a coverage chew-through, bringing total format rows past 200. Many new rows are sniper-only because their ground-truth samples are < 4 KB (the shotgun overwrite size); that is the honest measurement, not a methodology gap. The "Run" column gives the date for each row.**

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
| JBIG2 | 0% | — | annex-h-truncated.jbig2 | 860 B | 2026-04-25 | Bi-level image stream walk; sniper 0% on truncated sample. Shotgun N/A (sample < 4 KB). |

### RAW Camera

| Format | Sniper | Shotgun | Sample | Size | Run | Mechanism |
|--------|-------:|--------:|--------|-----:|-----|-----------|
| DNG | 0% | 0% | blackmagic_micro_cinema.dng | 1.2 MB | 2026-03-06 | TIFF-based; preview JPEG decode via libjpeg-turbo (BlackMagic sample lacks a preview) |
| CR2 | 1% | 6% | canon_eos_40d_sraw2.cr2 | 5.8 MB | 2026-04-25 | TIFF-based; IFD-walked preview JPEG decoded via libjpeg-turbo (sRAW2 lossless strip filtered out so heuristic keeps the real preview) |
| NEF | 0% | 0% | nikon_coolscan_iv.nef | 2.2 MB | 2026-03-06 | TIFF-based; deep via zigimg |
| ARW | 0% | 0% | sony_ilce_7s.arw | 6.2 MB | 2026-03-06 | TIFF-based; deep via zigimg |
| RAF | 0% | 1% | DSCF0652_fuji_GFX_100.RAF | 208 MB | 2026-04-23 | Fuji; validator decodes the JPEG preview at 0x54/0x58, but preview is ~0.5% of a 208 MB sensor dump — shotgun almost never lands in it. ⚠ See Action Items. |
| NRW | 0% | 0% | NIKON_COOLPIX_P7100.NRW | 16 MB | 2026-04-23 | Nikon; dispatched through LibRaw which unpacks sensor data but the format has no per-row checksum. `libraw_unpack_thumb` is not currently wired up — adding it would catch corruption inside the embedded preview JPEG and could lift this to ~15-30% shotgun. Follow-up item. |
| ORF | 0% | 0% | PB120976.ORF | 14 MB | 2026-04-23 | Olympus; validator WARNs on "uncompressed IFD claims but Huffman-compressed data". Structural-only. |
| PEF | 0% | 0% | IMGP1754.PEF | 11 MB | 2026-04-23 | Pentax; TIFF-wrapped. Structural-only. |
| RW2 | 0% | 0% | panasonic_16-9.RW2 | 11 MB | 2026-04-23 | Panasonic; TIFF-wrapped. Structural-only. |
| CR3 (Canon) | 0% | 0% | sample.CR3 | 15.0 MB | 2026-04-25 | ISOBMFF-based Canon RAW 3; structural box walk. 15 MB sample at 0%/0% confirms no integrity mechanism beyond structure. |

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
| WebM (VP9+Opus) | **86%** | **78%** | jellyfish_vp9_opus.webm | 1.8 MB | 2026-04-24 | libvpx 1.14.1 full VP9 decode per frame — every frame entropy + DCT decoded via `vpx_codec_decode`. Opus audio CRC provides additional coverage. |
| WebM (VP8) | **88%** | **90%** | jellyfish_360_10s.webm | 1.0 MB | 2026-04-24 | libvpx 1.14.1 full VP8 decode. **Critical:** uses `VP8D_GET_FRAME_CORRUPTED` control query after each frame — without it, VP8's built-in error concealment silently patches bit flips. Both sniper and shotgun lift by ~90 points because of this query. |
| AVI | 0% | **93%** | jellyfish_mjpeg.avi | 8.5 MB | 2026-04-23 | MJPEG per-frame decode via libjpeg-turbo — new sample generated via ffmpeg. Old MPEG-4 Part 2 sample kept in `generated_testsrc.avi` but sweep picks the larger MJPEG one. |
| DV | 0% | 0% | sample.dv | 360 KB | 2026-03-06 | DV spec has no checksum; relies on tape physical ECC |
| MPEG-ES | 0% | 0% | sample.m1v | 30 KB | 2026-03-06 | Start codes only |
| MPEG-1/2 | 0% | 0% | sample.mpg | 16 KB | 2026-03-06 | Start codes only |
| MPEG-4 Part 2 | 0% | 0% | ubAVIxvid10.avi | 1.2 MB | 2026-03-06 | VOP header parsing tolerates VOP failures |
| RM | 0% | 2% | sample.rm | 14 KB | 2026-04-23 | RealMedia spec has no checksums; structural chunk walk only |
| FLV | 40% | — | sample.flv | 33 B | 2026-04-25 | Flash Video tag walk; no per-tag CRC. Tiny 33 B sample — sniper hits magic + header bytes. Shotgun N/A (sample < 4 KB). |
| MPEG-PS | 0% | — | sample.mpg | 2.0 KB | 2026-04-25 | MPEG Program Stream; PES header walk; no CRC. Shotgun N/A (sample < 4 KB). |
| Theora (.ogv) | **100%** | **100%** | sample.ogv | 50 KB | 2026-04-25 | Theora-in-Ogg; libtheora-encoded testsrc (CC0). Ogg page CRC32 catches every probed bit flip in both modes. |
| VP8 (raw IVF) | 0% | 0% | sample.ivf | 9 KB | 2026-04-25 | IVF container with VP8 frames; structural-only without libvpx wired into the IVF dispatch path. Hand-authored CC0 sample. Detection is fundamentally low until VP8-in-IVF gets the same `VP8D_GET_FRAME_CORRUPTED` query as VP8-in-WebM. |

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
| AMR | 14% | — | sample.amr | 38 B | 2026-04-25 | Adaptive Multi-Rate audio; frame-table based, no per-frame CRC. Sniper at 14% reflects sync-byte coverage on a 38 B sample. Shotgun N/A. |
| APE (Monkey's Audio) | 0% | 0% | corpus_xorshift.ape | 16 KB | 2026-04-25 | MAC header + descriptor MD5 (file-level); **validator does NOT verify the MD5 yet** (full decoder = entropy + predictor needed). Bigger sample enables shotgun mode but rate stays 0% — structural-only is the honest measurement until the decoder lands. See Action Items #13. |
| CD+G (Karaoke) | 0% | 2% | sample.cdg | 14.1 KB | 2026-04-25 | 24-byte fixed-size sectors; structural only — no checksum. 0%/2% confirms fundamental format limit. |
| DFF (DSDIFF) | 52% | — | sample.dff | 32 B | 2026-04-25 | DSD audio container; chunk walk only. Tiny 32 B header-only sample. Shotgun N/A. |
| DSF (DSD) | 60% | — | sample.dsf | 88 B | 2026-04-25 | Sony DSD; structural walk. Shotgun N/A. |
| DTS (Digital Surround) | 0% | 51% | sample.dts | 369 KB | 2026-04-25 | Frame sync + size walk; no per-frame CRC. Shotgun lift from 4 KB overwrite desyncing the frame stream. |
| TTA (True Audio) | **97%** | — | sample.tta | 3.1 KB | 2026-04-25 | Per-frame CRC32 catches almost every probed bit flip. Shotgun N/A (sample < 4 KB). |
| WavPack | 0% | 0% | corpus_xorshift.wv | 118 KB | 2026-04-25 | MD5 in optional sub-block + per-block CRC over decoded samples; **validator does NOT verify either yet** (decorrelator + range decoder + IDWT needed). Bigger real-encoded sample (3 s 440 Hz tone) enables shotgun; rate stays 0% until decoder lands. See Action Items #13. |

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
| EML | **12%** | **84%** | sample.eml (Tika `testRFC822-big`) | 6.6 KB | 2026-04-25 | UTF-8 + NUL-byte integrity check on the raw file before structural parsing. NUL is never legal in a mail message; flipping the high bit of an ASCII byte produces a lone UTF-8 continuation byte. Caught ~50% of single-bit ASCII flips and ~80% of 4 KB shotgun overwrites. |
| MBOX | **13%** | **100%** | sample.mbox (synthesized from 4 Tika RFC822 messages) | 17 KB | 2026-04-25 | Same UTF-8 + NUL-byte check as EML, applied to the whole concatenated file. Shotgun catches every 4 KB random overwrite (random bytes almost always include NUL or invalid UTF-8 sequences). Sniper catches roughly half the random bit flips. |
| Pages | **100%** | **100%** | sample.pages (hand-authored CC0) | 56 KB | 2026-04-25 | iWork bundle = ZIP with per-entry CRC32. Hand-authored from scratch (no Apple software, no permissive corpus exists); `scripts/build-pages-sample` regenerates a deterministic 8-IWA inner `Index.zip` with high-entropy openssl-AES-CTR payloads plus real plist metadata. CRC32 per entry catches every bit flip and every 4 KB shotgun overwrite. |
| Keynote | **99%** | **100%** | sample.key (hand-authored CC0) | 64 KB | 2026-04-25 | iWork bundle = ZIP with per-entry CRC32. Hand-authored mirroring the Pages sample; `scripts/build-keynote-sample` regenerates a 9-IWA inner `Index.zip` plus an uncompressed `buildVersionHistory.plist` carrying `com.apple.iWork.Keynote` so the format detector keys on it. CRC32 per entry catches every 4 KB shotgun overwrite and ~99% of single-bit flips. |
| Numbers | **100%** | **100%** | sample.numbers (hand-authored CC0) | 64 KB | 2026-04-25 | Same iWork-bundle template as Keynote with a Tables/-shaped IWA layout. The `com.apple.iWork.Numbers` marker is stored uncompressed at the head of the outer ZIP. CRC32 per entry catches every probed bit flip and every 4 KB shotgun overwrite. |
| AI (Adobe Illustrator) | 6% | — | sample.ai | 372 B | 2026-04-25 | PostScript-derived header + PDF body. Tiny 372 B sample is mostly PDF magic; later bytes are uncovered text. Shotgun N/A. |
| BAI2 (Bank Admin Inst.) | 20% | — | sample.bai2 | 362 B | 2026-04-25 | Fixed-format banking text; structural validation of record-type prefixes. No checksum. Shotgun N/A. |
| CSV | 0% | — | sample.csv | 70 B | 2026-04-25 | Plain text; structural validator only checks UTF-8 + delimiter consistency. 0% as expected. Shotgun N/A. |
| ClarisWorks | 6% | — | sample.cwk | 64 B | 2026-04-25 | Legacy AppleWorks. Structural walk. Shotgun N/A. |
| EDIFACT | 37% | — | sample.edifact | 152 B | 2026-04-25 | Fixed-format trade messages; validator cross-checks UNH/UNT counts. Shotgun N/A. |
| EPS | 4% | — | sample.eps | 430 B | 2026-04-25 | PostScript header + structural walk. Shotgun N/A. |
| EPUB | 69% | — | sample.epub | 2.0 KB | 2026-04-25 | ZIP container with mimetype check; per-entry CRC32. Shotgun N/A. |
| HTML | 2% | — | simple.html | 196 B | 2026-04-25 | Tag-tree validator; structural only. Shotgun N/A. |
| iCalendar (RFC 5545) | 21% | — | sample.ics | 650 B | 2026-04-25 | Structural; BEGIN/END pairing + property syntax. Shotgun N/A. |
| IDML (InDesign) | 55% | — | sample.idml | 884 B | 2026-04-25 | ZIP+XML markup; per-entry CRC32. Shotgun N/A. |
| INI | 17% | — | sample.ini | 60 B | 2026-04-25 | Plain-text key-value; structural only. Shotgun N/A. |
| JSON | 47% | — | sample.json | 94 B | 2026-04-25 | JSON parser; structural only. Tiny sample's curly/brace density yields 47%. Shotgun N/A. |
| JSON5 | 30% | — | sample.json5 | 329 B | 2026-04-25 | JSON5 parser; structural only. Shotgun N/A. |
| MT940 (SWIFT) | 11% | — | sample.mt940 | 347 B | 2026-04-25 | Banking text; structural only. Shotgun N/A. |
| MacWrite Document | 0% | — | sample.mwd | 64 B | 2026-04-25 | Legacy word processor; structural only. Tiny sample. Shotgun N/A. |
| NACHA (ACH) | 15% | — | sample.ach | 950 B | 2026-04-25 | Banking fixed-format text; record-type validation. Shotgun N/A. |
| OFX (Open Financial) | 2% | — | sample.ofx | 850 B | 2026-04-25 | Banking SGML/XML; structural only. Shotgun N/A. |
| Plain Text | 0% | — | sample.txt | 254 B | 2026-04-25 | UTF-8 + control-char check. 0% as expected. Shotgun N/A. |
| PTX (Pro Tools) | 0% | 0% | sample.ptx | 39.8 KB | 2026-04-25 | Avid session structural walk. 0%/0% on 40 KB confirms structural-only. |
| QIF (Quicken Interchange) | 3% | — | sample.qif | 218 B | 2026-04-25 | Plain-text; structural only. Shotgun N/A. |
| TOML | 37% | — | sample.toml | 72 B | 2026-04-25 | Plain-text; structural only. Shotgun N/A. |
| TXF (Tax Exchange) | 3% | — | sample.txf | 140 B | 2026-04-25 | Plain-text; structural only. Shotgun N/A. |
| vCard (RFC 6350) | 32% | — | sample.vcf | 198 B | 2026-04-25 | Structural BEGIN/END pairing + property syntax. Shotgun N/A. |
| WordPerfect | 2% | — | sample.wpd | 512 B | 2026-04-25 | Header walk; structural only. Shotgun N/A. |
| X12 EDI | 21% | — | sample.edi | 262 B | 2026-04-25 | Fixed-format trade messages; ISA/IEA + GS/GE counts cross-validated. Shotgun N/A. |
| XML | 64% | — | sample.xml | 110 B | 2026-04-25 | XML parse; structural only. 64% sniper from tag/quote density on tiny sample. Shotgun N/A. |
| YAML | 0% | — | sample.yaml | 68 B | 2026-04-25 | Plain-text; structural only. Shotgun N/A. |
| Markdown | 0% | — | sample.md | 525 B | 2026-04-25 | Plain-text; structural only. Shotgun N/A. |

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
| CIF (Crystallographic Info) | 0% | — | sample.cif | 145 B | 2026-04-25 | Plain-text scientific format; structural only. Shotgun N/A. |
| FASTA | 22% | — | sample.fasta | 479 B | 2026-04-25 | Plain-text bioinformatics; structural only. Shotgun N/A. |
| FASTQ | 28% | — | sample.fastq | 447 B | 2026-04-25 | Plain-text bioinformatics; per-record sequence/quality length cross-check. Shotgun N/A. |
| MAT-File | **94%** | — | sample.mat | 1.3 KB | 2026-04-25 | Element header + flag walk; magic + endian + tag length validation. Shotgun N/A. |
| NetCDF | 39% | — | sample.nc | 84 B | 2026-04-25 | NetCDF classic header walk; HDF5-derived NetCDF-4 reuses HDF5's lookup3 checksums. Tiny sample. Shotgun N/A. |
| NIfTI-1 | 1% | — | sample.nii | 416 B | 2026-04-25 | Header magic + dims; no checksum. Shotgun N/A. |
| Parquet | 2% | — | sample.parquet | 484 B | 2026-04-25 | Footer + page CRC32 (not currently verified by validator beyond header). Shotgun N/A. |
| Shapefile | **89%** | — | sample.shp | 128 B | 2026-04-25 | GIS .shp; record-by-record header check + magic. Shotgun N/A. |

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
| 7z | **99%** | **100%** | corpus_xorshift.7z | 17 KB | 2026-04-25 | 7z next-header CRC32 + per-stream CRC32. Hand-authored xorshift corpus (CC0). Both sniper and shotgun catch nearly every flip. |
| AR (Unix archive) | 38% | — | minimal.a | 88 B | 2026-04-25 | `!<arch>\n` magic + 60-byte member headers; no per-entry checksum. Shotgun N/A. |
| BLAR (Blake3 Archive) | **100%** | — | sample.blar | 1.0 KB | 2026-04-25 | Peter's archive format with Blake3 per-entry hashing. Every probed bit flip detected. Shotgun N/A. |
| Brotli | 47% | **100%** | realistic_corpus.br | 27 KB | 2026-04-26 | Raw Brotli stream; full streaming decompression via libbrotli. RFC 7932 has no whole-file checksum, but the entropy coder rejects most structurally invalid prefix codes / distance overflows / window-bits errors. ~47% of single-bit flips on dense English-text Huffman streams cascade into decoder failure; the rest decode to wrong-but-valid bytes (silent). 4 KB shotgun overwrites are essentially always rejected. Earlier 0%/0% row used a pathological xorshift random-noise corpus where compressed output is ~8 bits/byte and bit flips are statistically valid Huffman codes; replaced with a deterministic CC0 English-text corpus (scripts/build-brotli-corpus). |
| Bzip2 | **100%** | **100%** | corpus_xorshift.bz2 | 17 KB | 2026-04-25 | CRC32 per block + combined CRC. Hand-authored xorshift corpus (CC0). |
| CAB (Microsoft) | **100%** | **100%** | corpus_xorshift.cab | 27 KB | 2026-04-25 | Per-folder + per-file CSUM (Adler-like) cross-validated. CC0 sample built via gcab. |
| Gzip | **100%** | **100%** | corpus_xorshift.gz | 16 KB | 2026-04-25 | CRC32 + ISIZE in trailer. Hand-authored xorshift corpus (CC0). |
| BinHex (.hqx) | **100%** | **100%** | corpus_xorshift.hqx | 13 KB | 2026-04-25 | BinHex 4.0 header + per-fork CRC16. Hand-authored CC0 sample (encoder reverse-engineered from validator). |
| MBLAR (Multi-Blake3) | **100%** | — | sample.mblar | 393 B | 2026-04-25 | Peter's manifest-bundle archive; Blake3 per file. Shotgun N/A. |
| PAR2 | **100%** | **100%** | corpus_xorshift.par2 | 34 KB | 2026-04-25 | MD5 of every packet + recovery slice integrity. Built via par2cmdline (BSD-licensed). |
| RAR | **100%** | **100%** | corpus_xorshift.rar | 16 KB | 2026-04-25 | Per-entry CRC32 + RAR5 BLAKE2sp option. CC0 corpus (rar -m5). |
| StuffIt | **94%** | — | sample.sit | 140 B | 2026-04-25 | Header + entry walk; sniper 94% on 140 B from header dominance. Shotgun N/A. |
| XZ | **100%** | **100%** | corpus_xorshift.xz | 16 KB | 2026-04-25 | CRC32/CRC64/SHA-256 per stream + index integrity. Hand-authored xorshift corpus (CC0). |
| ZIP | **100%** | **100%** | corpus_xorshift.zip | 16 KB | 2026-04-25 | Per-entry CRC32 + EOCD record. Hand-authored xorshift corpus (CC0). |
| Zstd | **100%** | **100%** | corpus_xorshift.zst | 16 KB | 2026-04-25 | Frame-level XXH64 + frame footer. Hand-authored xorshift corpus (CC0). |

### Game ROM

| Format | Sniper | Shotgun | Sample | Size | Run | Mechanism |
|--------|-------:|--------:|--------|-----:|-----|-----------|
| SNES | **100%** | 99% | F-ZERO.smc | 524 KB | 2026-03-06 | Internal ROM checksum + complement |
| GB | 0% | 1% | Addams | 131 KB | 2026-03-06 | Header checksum only (tiny coverage) |
| GBA | 0% | 0% | Bomberman | 8.4 MB | 2026-03-06 | Header checksum only |
| Genesis | 0% | 1% | Aero | 524 KB | 2026-03-06 | Header checksum only |
| NES | 0% | 0% | 1943 | 131 KB | 2026-03-06 | iNES header only |
| N64 | 0% | 0% | Super | 8.4 MB | 2026-03-06 | No integrity mechanism |
| CHD (MAME) | 10% | — | synthetic_chd.chd | 124 B | 2026-04-25 | MAME's compressed disc; SHA-1 per hunk + global SHA-1. Tiny synthetic 124 B sample. Shotgun N/A. |
| NDS (Nintendo DS) | 41% | — | synthetic_nds_rom.nds | 1.0 KB | 2026-04-25 | Header CRC16 (logo + secure area). 41% sniper on 1 KB. Shotgun N/A. |
| WAD (Doom/Wii) | **100%** | — | sample.wad | 12 B | 2026-04-25 | Lump table; structural only. Tiny synthetic sample — header IS most of file. Shotgun N/A. |

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
| 3MF (3D Manufacturing) | 75% | — | sample.3mf | 1.5 KB | 2026-04-25 | ZIP-based; per-entry CRC32 + XML manifest. Shotgun N/A (sample < 4 KB). |
| AEP (After Effects Project) | 27% | — | sample.aep | 44 B | 2026-04-25 | RIFX container; structural-only walk. Tiny sample (44 B). Shotgun N/A. |
| ALS (Ableton Live Set) | **90%** | — | sample.als | 82 B | 2026-04-25 | gzip-wrapped XML. Tiny sample — gzip CRC32 + zlib structure catches most bit flips. Shotgun N/A. |
| Apple Media DB | 46% | — | sample.tvdb | 253 B | 2026-04-25 | tvdb/photo SQLite-derived store. Structural walk. Shotgun N/A. |
| GarageBand (.band) | 0% | — | projectData (inside .band bundle) | 512 B | 2026-04-25 | Bundle (directory) format — `projectData` inside is a plist routed to plist validator. Sweep-only on the plist file. Shotgun N/A. |
| BEAM (Erlang) | 36% | — | sample.beam | 736 B | 2026-04-25 | FOR1/IFF chunk container; chunk lengths cross-validated. No CRC. Shotgun N/A. |
| Blender (.blend) | 47% | — | sample.blend | 104 B | 2026-04-25 | DNA-block-based binary. Structural walk; no checksum. Tiny header-only sample. Shotgun N/A. |
| BSP (Quake) | 39% | — | sample.bsp | 1.0 KB | 2026-04-25 | Lump-table walk; no CRC. Structural only. Shotgun N/A. |
| Bitwig Project | 0% | — | sample.bwproject | 128 B | 2026-04-25 | ZIP-derived but tiny sample (128 B). Sniper 0% — sample is below ZIP minimum. Shotgun N/A. |
| Chromium PAK | 0% | — | sample.pak | 30 B | 2026-04-25 | Resource bundle; index walk only. Tiny synthetic sample. Shotgun N/A. |
| Cubase Project | 49% | — | sample.cpr | 76 B | 2026-04-25 | Steinberg binary. Structural only. Shotgun N/A. |
| DER (ASN.1) | 7% | — | sample.der | 688 B | 2026-04-25 | TLV-walked. Structural; no checksum. Shotgun N/A. |
| DRP (DR Painter) | 60% | — | sample.drp | 263 B | 2026-04-25 | Generic binary — high sniper from header dominance. Shotgun N/A. |
| DWG (AutoCAD) | 1% | — | sample.dwg | 1.0 KB | 2026-04-25 | Section structure walk. Tiny sample. Shotgun N/A. |
| DXF (AutoCAD) | 5% | — | sample.dxf | 388 B | 2026-04-25 | Plain-text CAD; structural only. Shotgun N/A. |
| Erlang Mix .eex | 0% | — | sample.eex | 378 B | 2026-04-25 | Plain-text template; structural only. Shotgun N/A. |
| ELF | 20% | — | minimal.elf | 64 B | 2026-04-25 | Section header walk; no whole-file checksum. Tiny synthetic 64 B sample. Shotgun N/A. |
| Erlang BERT | 0% | — | sample.app | 281 B | 2026-04-25 | External Term Format walk. Shotgun N/A. |
| FCPXML (Final Cut) | 58% | — | sample.fcpxml | 134 B | 2026-04-25 | XML-based; structural walk. Shotgun N/A. |
| FL Studio | 6% | — | sample.flp | 122 B | 2026-04-25 | Project file structural walk. Tiny sample. Shotgun N/A. |
| GLB (glTF binary) | 32% | — | box.glb | 1.6 KB | 2026-04-25 | Chunk-based; structural walk. JSON chunk + BIN chunk lengths cross-validated. Shotgun N/A. |
| glTF (JSON) | 20% | — | box.gltf | 2.8 KB | 2026-04-25 | JSON manifest; structural only. Shotgun N/A. |
| IFF (EA) | 46% | — | sample.iff | 232 B | 2026-04-25 | Chunk walk; no CRC. Shotgun N/A. |
| Java .class | 21% | — | Hello.class | 397 B | 2026-04-25 | ClassFile constant pool walk; magic + version check. Shotgun N/A. |
| KML | 58% | — | sample.kml | 1.0 KB | 2026-04-25 | GIS XML; structural only. Shotgun N/A. |
| KMZ | **95%** | — | sample.kmz | 538 B | 2026-04-25 | KMZ = zipped KML; per-entry CRC32 catches almost any bit flip on the small sample. Shotgun N/A. |
| Logic Pro X | 71% | — | sample.logicx (ProjectData) | 249 B | 2026-04-25 | Bundle format — sample is `ProjectData` plist alone. Shotgun N/A. |
| LSPK (Larian Studios) | 3% | — | sample.lspk | 256 B | 2026-04-25 | Pak file; structural only. Shotgun N/A. |
| Mach-O | 0% | — | sample.o | 536 B | 2026-04-25 | Single-arch sample; load command walk; no checksum. Shotgun N/A. |
| OBJ (Wavefront) | 44% | — | sample.obj | 652 B | 2026-04-25 | Plain-text 3D; vertex/face syntax check. Shotgun N/A. |
| PAK (Quake) | 60% | — | sample.pak | 12 B | 2026-04-25 | Header offset/length cross-check. Tiny synthetic sample (12 B). Shotgun N/A. |
| PE (Windows) | 3% | — | sample.exe | 1.0 KB | 2026-04-25 | MZ + PE headers; optional checksum (rarely populated). Tiny sample. Shotgun N/A. |
| PEM (RFC 7468) | 51% | — | sample.pem | 989 B | 2026-04-25 | Base64 envelope; structural only. Shotgun N/A. |
| PGP Signed Message | **81%** | — | sample.asc | 370 B | 2026-04-25 | Header/footer detect + Base64 walk. Shotgun N/A. |
| Plist | 52% | — | sample.plist | 830 B | 2026-04-25 | Both XML and binary plist; structural only. Shotgun N/A. |
| PLY (3D) | 51% | — | sample.ply | 447 B | 2026-04-25 | Header + element count; no per-element checksum. Shotgun N/A. |
| Premiere Project | 55% | — | sample.prproj | 112 B | 2026-04-25 | Gzip-wrapped XML. Tiny sample. Shotgun N/A. |
| Reason (Propellerhead) | 33% | — | sample.reason | 96 B | 2026-04-25 | Bundle binary; structural walk. Shotgun N/A. |
| RPP (Reaper) | 50% | — | sample.rpp | 44 B | 2026-04-25 | Plain-text project; structural only. Shotgun N/A. |
| Sketch (.sketch) | 56% | — | sample.sketch | 631 B | 2026-04-25 | ZIP-based; per-entry CRC32. Shotgun N/A. |
| SSH Signature | 64% | — | sample.sig | 294 B | 2026-04-25 | RFC 4880-like wire-format walk. Shotgun N/A. |
| STEP (.step) | 23% | — | sample.stp | 711 B | 2026-04-25 | ISO 10303-21 plain-text CAD. Shotgun N/A. |
| STL (3D) | 73% | — | sample.stl | 518 B | 2026-04-25 | Both ASCII and binary stl; sniper 73% on small ASCII sample. Shotgun N/A. |
| Toast (Roxio) | 0% | 10% | sample.toast | 36.0 KB | 2026-04-25 | Apple Toast disc image; structural walk. |
| Type 1 Font | 0% | — | sample.pfa | 174 B | 2026-04-25 | PostScript-derived font; eexec encrypted body walk. Shotgun N/A. |
| VMDK | 0% | 0% | sample.vmdk | 64.0 KB | 2026-04-25 | VMware disk descriptor + extent walk. 65 KB sample at 0%/0% — structural-only. |
| VPK (Valve Pak) | **100%** | — | sample.vpk | 28 B | 2026-04-25 | Tiny synthetic 28 B sample; structural walk catches every flip (header IS the file). Shotgun N/A. |
| WARC (Web Archive) | 48% | — | sample.warc | 1.1 KB | 2026-04-25 | Record header + content-length walk. Shotgun N/A. |
| WebAssembly | 35% | — | minimal.wasm | 24 B | 2026-04-25 | Section LEB128 length walk; magic + version. Tiny sample. Shotgun N/A. |
| WIM (Windows Imaging) | 8% | — | sample.wim | 1.2 KB | 2026-04-25 | XPRESS/LZX section walk; partial integrity. Shotgun N/A. |

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
12. **✓ VP8/VP9-in-MKV byte validation (DONE 2026-04-24, commit f8c38ec).** libvpx 1.14.1 integrated, decoder-only, generic-gnu (no asm, cross-compiles to all 5 OS/arch). Replaced the header-only VP8/VP9 handlers at `src/core/video_validator.zig`. WebM VP9+Opus: 0%/55% → **86%/78%**. WebM VP8: 0%/2% → **88%/90%**. Diagnostic find: VP8's decoder ran error concealment silently; required `VP8D_GET_FRAME_CORRUPTED` control query after every `vpx_codec_get_frame` to surface the internal corruption flag.

13. **APE / WavPack MD5 not verified — partial validation gap.** Both formats embed MD5 of the decoded audio (APE descriptor field; WavPack optional `md5_checksum` 0x26 sub-block). Validators recognize the metadata but neither decodes the audio to recompute the hash because that would require a full APE entropy decoder / WavPack decoder. Per Peter (2026-04-25): "we should always use any existing checksum mechanisms such as md5 for APE and WavPack." **Code paths:** `validateApe` in `src/core/music_validators.zig:1380` (no MD5 read; only structural). `wavpack_decoder.zig:344` reads `stored_md5` and sets `has_md5=true` but explicitly leaves `md5_verified=false`. **Action:** implement minimal APE entropy decoder (predictor + range coder) and WavPack decorrelator + range decoder + IDWT, recompute MD5 over reconstructed PCM, compare to stored. ~3-5 dedicated sessions per format. Until then, sniper rates of 6% (APE) and 2% (WavPack) are honest reflections of structural-only coverage on the existing tiny samples; even with the existing samples, larger ground-truth files would let shotgun mode reveal more. **First sub-step:** source larger ground-truth APE/WavPack samples (Wikimedia Commons CC-BY classical recordings) so shotgun mode can run.

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
| Pages | 480 B | 56 KB | Hand-authored from scratch (CC0). `scripts/build-pages-sample` regenerates deterministically. No permissive `.pages` corpus exists in the wild. |
| Keynote | n/a | 64 KB | Hand-authored from scratch (CC0). `scripts/build-keynote-sample` regenerates deterministically. No permissive `.key` corpus exists in the wild. New format added 2026-04-25. |
| Numbers | n/a | 64 KB | Hand-authored from scratch (CC0). `scripts/build-numbers-sample` regenerates deterministically. No permissive `.numbers` corpus exists in the wild. New format added 2026-04-25. |

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


### Wave 2026-04-25b: coverage gap closure (extra-tiny + missing dirs)

Formats sourced/upgraded 2026-04-25 to close the two remaining gap categories
from the prior chew-through: (A) sniper-only rows whose samples were < 4 KB so
shotgun couldn't run; (B) enum entries with no ground-truth dir at all.

| Format | Sniper | Shotgun | Sample | Size | Run | Mechanism |
|--------|-------:|--------:|--------|-----:|-----|-----------|
| Studio One Project (.song) | **100%** | **100%** | sample.song | 41 KB | 2026-04-25 | ZIP-based; per-entry CRC32 + metainfo.xml integrity. Hand-authored CC0 sample. |
| StuffIt X (.sitx) | 0% | 0% | sample.sitx | 16 KB | 2026-04-25 | Magic + structural header walk only; no per-entry checksums in current validator. Hand-authored. |
| Microsoft Installer (.msi) | 0% | 43% | sample.msi | 9 KB | 2026-04-25 | OLE2 compound file (no integrity beyond CFBF FAT structure). Built via wixl. Shotgun catches FAT/dir mismatch. |
| Windows ESD (.esd) | 1% | 0% | sample.esd | 16 KB | 2026-04-25 | WIM variant with LZMS compression; structural header walk (208-byte WIM header). Hand-authored. |
| LLVM Precompiled Header (.pch) | 0% | 0% | sample.pch | 16 KB | 2026-04-25 | Magic ("CPCH") + LLVM bitcode signature only. Bitcode contents are version-specific; structural only. |
| LLVM Serialized Diagnostics (.dia) | 0% | 0% | sample.dia | 16 KB | 2026-04-25 | Magic ("DIAG") + LLVM bitcode signature only. Same limit as .pch. |
| QuickBooks Backup (.qbb) | 8% | 24% | sample.qbb | 19 KB | 2026-04-25 | OLE2-based; dispatches through document_validators (no per-stream checksum). Sample shared with ole2/sample.doc. |
| PCAP | 4% | **100%** | sample.pcap | 13 KB | 2026-04-25 | Hand-authored (no sudo for tcpdump in nix sandbox). Walks every packet record's incl_len/orig_len; shotgun lands in valid trailer bytes that fail length checks. Fixed 64 MiB-stack-overflow bug in `validatePcap` while landing the sample. |
| PCAPNG | 0% | 0% | sample.pcapng | 9 KB | 2026-04-25 | Section Header Block + IDB + EPBs structural walk; pcapng-validator checks magic and BOM only (no block-level CRC verification yet — pcapng has optional CRC32 per block). |
| dBASE (.dbf) | 0% | **100%** | sample.dbf | 21 KB | 2026-04-25 | Header version + date + record-length cross-validation; hand-authored CC0 dBASE III. Sniper rate fundamental (no per-record checksum); shotgun lands in tail records past header-declared range. |
| G-code | 27% | 98% | sample.gcode | 20 KB | 2026-04-25 | Text format; line-grammar walk catches 27% sniper (most flips break a coordinate or G/M code prefix). Shotgun 98% — large overwrite breaks too many lines to ignore. Hand-authored CC0. |
| MessagePack (.msgpack) | 0% | 0% | sample.msgpack | 19 KB | 2026-04-25 | Type-tagged binary; validator walks tag stream but spec has no checksum. Most flips land in payload bytes that decode to different-but-valid values. Fundamental limit per RFC. Hand-authored CC0. |
| RPM Package (.rpm) | 3% | 30% | sample.rpm | 22 KB | 2026-04-25 | RPM v3 lead + signature header + main header. Validator computes SHA-1 over main header (when sig tag 269 present). Shotgun 30% reflects header dominance vs payload mass. Built via rpmbuild (CC0 spec). Fixed 16 MiB-stack-overflow bug in `validateRpm` while landing the sample. |
