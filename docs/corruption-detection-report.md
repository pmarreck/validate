# Corruption Detection Report

**Canonical document.** Supersedes `docs/corruption-detection-survey-2026-03-05.md` and the "Corruption Detection Rates" section of `FORMAT_VERIFICATIONS.md`. Those two sources had drifted; the table below is **generated** directly from the raw TSVs in `docs/corruption-sweep-results/` by `scripts/generate-corruption-report` — **do not hand-edit the table.** Per-format prose (the Mechanism column, section assignments, the PDF breakout) lives in the sidecar inputs under `docs/corruption-sweep-results/generated/`.

**Methodology** — three mutation modes, ordered by escalating blast radius:
- **sniper:** single random **bit** flip at a random byte offset. Measures per-byte coverage. Reversible (XOR the bit back).
- **bolter:** a single **byte** XOR'd with `0xFF` (all 8 bits flipped). Reversible. The middle tier between sniper and shotgun — in UTF-8-text formats a bolter almost always yields an invalid byte, so detection is near-total there.
- **shotgun:** **4,096** consecutive bytes overwritten with random data at a random offset. Simulates a disk-sector failure / media loss; **not** reversible.
- PCG32 PRNG, seed=42, 100 trials per format per mode.
- **Detection** = the `validate` CLI returns a non-zero exit code (a WARN-only result, e.g. the Latin-1 plain-text fallback, is exit 0 and so counts as *not* detected).
- Per-format sample = the largest ground-truth file ≥ 4,096 bytes in `ground_truth_examples/<fmt>/`. For formats where the validator's strong path depends on an internal encoding choice (EXR compression, PSD compression, MOV/AVI codec), the sample choice materially affects the number — see the per-format notes below.
- Wilson 95% CI at n=100 is ±1.8% at the extremes (0% or 100%) and up to ±10% near 50%.
- `n/a` in a cell means that mode was not measured for that row (shotgun needs a ≥ 4 KB sample; some formats have no bolter sweep yet). It is **never** a measured zero — a blank/0% would misrepresent unmeasured coverage.
- Harness: `scripts/corruption-experiment` (single-format) and `scripts/corruption-sweep` (batch). Re-run with `--count 38416` for ±0.5% precision.

**Run dates vary per row (see the "Run" column).** The bulk was swept 2026-03-06; coverage chew-throughs on 2026-04-23/25 pushed total format rows past 200; the bolter column and the ≥12 KB UTF-8 text-format re-sweep landed 2026-06-22. Rows whose ground-truth sample is < 4 KB are sniper/bolter-only by honest measurement, not by methodology gap.

---

## Canonical Results Table

### Image & Photo

| Format | Sniper | Bolter | Shotgun | Sample | Size | Run | Mechanism |
|--------|-------:|-------:|--------:|--------|-----:|-----|-----------|
| PNG | **100%** | **100%** | **100%** | generated_plasma.png | 336 KB | 2026-03-06 | CRC32 per chunk |
| JXL | **87%** | **97%** | **100%** | animation_icos4d.jxl | 344 KB | 2026-03-06 | Container + frame checksums |
| WebP | **83%** | **82%** | **84%** | google_gallery_3.webp | 198 KB | 2026-03-06 | libwebp full decode |
| ICNS | **97%** | **97%** | **100%** | sample.icns | 234 KB | 2026-04-23 | TLV chunk stream; near-total coverage |
| SWF | **100%** | **100%** | **100%** | cws_sample.swf | 23 KB | 2026-04-23 | CWS = zlib wrapper; any flip = zlib CRC fail |
| SVG | 45% | **98%** | **99%** | sample.svg | 29 KB | 2026-04-23 | XML parse — almost any corruption breaks the XML grammar. |
| ICO | 63% | 54% | 70% | sample.ico | 226 KB | 2026-04-23 | Directory entries + embedded PNG/BMP image validation. Multi-resolution ICO has high structural-byte density. |
| QOI | 0% | 0% | 0% | sample.qoi | 22 KB | 2026-04-23 | QOI spec has no per-opcode checksum — bit flips in pixel data decode to different-but-valid pixels. Only magic (4 B) and end marker (8 B) are checkable. Fundamental format limit. |
| JPEG2K | 6% | 5% | **97%** | balloon_eciRGB_icc.jp2 | 1.8 MB | 2026-03-06 | Codestream marker structure |
| GIF | 9% | 35% | **100%** | animated_sample.gif | 400 KB | 2026-05-27 | LZW decode (shotgun desyncs state); larger animated fixture lifts header-tamper detection |
| JPEG | 4% | 8% | **100%** | w3c_exif_420.jpg | 750 KB | 2026-05-27 | jpegz wrapperDecode (062393f); most single-byte tamper lands in entropy-coded data, which JPEG tolerates by design |
| EXR | 1% | 0% | **100%** | zip_plasma.exr | 388 KB | 2026-04-23 | ZIP-compressed EXR — zlib decompress path runs on every scanline block. Shotgun detection perfect; sniper lower than the 26 KB NONE-compressed sample (6%) because structural bytes are a smaller fraction on the larger file. Both paths validated. |
| PSD | 2% | 2% | 50% | rle_plasma.psd | 1.8 MB | 2026-04-23 | RLE-compressed PSD — `validatePsdDeep` decodes every scanline. The old RAW-compressed `sample.psd` (0%/7%) is retained; sweep picks the larger RLE one. Measures the strong path that the RAW sample couldn't exercise. |
| HEIC | 0% | 0% | 4% | sample.heic | 2.9 MB | 2026-03-06 | H.265 CABAC per tile — **arithmetic coding absorbs single-bit errors by design** |
| AVIF | 0% | 0% | 1% | butterfly.avif | 85 KB | 2026-03-06 | AV1 OBU + CABAC — same limitation |
| BMP | 0% | 0% | 0% | sample.bmp | 900 KB | 2026-04-23 | BMP spec has no data checksums — `bmp_decoder.validateBmp` walks every pixel row proving accessibility but cannot detect bit-flips in pixel bytes. 0/400 at ±0.5% CI. Fundamental format limit. |
| DPX | 0% | 0% | 0% | sample.dpx | 1.8 MB | 2026-03-06 | Raw pixel; SMPTE 268M spec has no checksum |
| PAM/PPM | 0% | 0% | 0% | sample.ppm | 1.8 MB | 2026-03-06 | Raw pixel; Netpbm spec has no checksum |
| TGA | 25% | 27% | **100%** | sample.tga | 11 KB | 2026-05-27 | Header + image-spec validation catches malformed-byte tamper; tiny 11 KB fixture pushes structural-byte density up |
| TIFF | 0% | 0% | 0% | pc260001.tif | 914 KB | 2026-03-06 | IFD structural only — no per-strip checksum |
| JBIG2 | 0% | n/a | n/a | annex-h-truncated.jbig2 | 860 B | 2026-04-25 | Bi-level image stream walk; sniper 0% on truncated sample. Shotgun N/A (sample < 4 KB). |

### RAW Camera

| Format | Sniper | Bolter | Shotgun | Sample | Size | Run | Mechanism |
|--------|-------:|-------:|--------:|--------|-----:|-----|-----------|
| DNG | 3% | 3% | 3% | L1006922_leica_M11.DNG | 75.2 MB | 2026-05-27 | TIFF-based via tiffz strip+tile decode loop + jpegz preview decode; 77 MB sensor dump dilutes detection density per byte |
| CR2 | 2% | 1% | 6% | canon_eos_40d_sraw2.cr2 | 5.5 MB | 2026-04-25 | TIFF-based; IFD-walked preview JPEG decoded via libjpeg-turbo (sRAW2 lossless strip filtered out so heuristic keeps the real preview) |
| NEF | 0% | 0% | 0% | nikon_coolscan_iv.nef | 2.1 MB | 2026-03-06 | TIFF-based; deep via zigimg |
| ARW | 0% | 4% | 15% | sony_ilce_7s.arw | 5.9 MB | 2026-03-06 | TIFF-based; deep via zigimg |
| RAF | 0% | 0% | 2% | DSCF0652_fuji_GFX_100.RAF | 198.4 MB | 2026-04-23 | Fuji; validator decodes the JPEG preview at 0x54/0x58, but preview is ~0.5% of a 208 MB sensor dump — shotgun almost never lands in it. ⚠ See Action Items. |
| NRW | 0% | 1% | 0% | RAW_NIKON_COOLPIX_P7100.NRW | 15.7 MB | 2026-04-23 | Nikon; dispatched through LibRaw which unpacks sensor data but the format has no per-row checksum. `libraw_unpack_thumb` is not currently wired up — adding it would catch corruption inside the embedded preview JPEG and could lift this to ~15-30% shotgun. Follow-up item. |
| ORF | 0% | 0% | 0% | PB120976.ORF | 13.3 MB | 2026-04-23 | Olympus; validator WARNs on "uncompressed IFD claims but Huffman-compressed data". Structural-only. |
| PEF | 0% | 0% | 0% | IMGP1754.PEF | 10.6 MB | 2026-04-23 | Pentax; TIFF-wrapped. Structural-only. |
| RW2 | 0% | 0% | 0% | panasonic_16-9.RW2 | 10.4 MB | 2026-04-23 | Panasonic; TIFF-wrapped. Structural-only. |
| CR3 (Canon) | 0% | 0% | 0% | sample.CR3 | 15.0 MB | 2026-04-25 | ISOBMFF-based Canon RAW 3; structural box walk. 15 MB sample at 0%/0% confirms no integrity mechanism beyond structure. |

### Video

| Format | Sniper | Bolter | Shotgun | Sample | Size | Run | Mechanism |
|--------|-------:|-------:|--------:|--------|-----:|-----|-----------|
| MKV | **100%** | **100%** | **100%** | generated_testsrc.mkv | 456 KB | 2026-03-06 | CRC32 per EBML cluster — **gold standard** |
| AV1 | 5% | 6% | **100%** | sample.av1 | 7 KB | 2026-03-06 | OBU structure + tile decode |
| MPEG-TS | 4% | 5% | **100%** | mpeg2_aac_latm.ts | 141 KB | 2026-03-06 | PAT/PMT CRC + continuity counters |
| MIDI | 15% | **94%** | **100%** | fur_elise.mid | 20 KB | 2026-03-06 | Track framing + delta/event validation |
| ProRes/MOV | 5% | 7% | 78% | prores_4444_xq.mov | 6.3 MB | 2026-03-06 | ProRes intra-frame DCT decode per frame |
| MP4 | 0% | 0% | 66% | jellyfish_360_10s.mp4 | 1022 KB | 2026-03-06 | H.264 CABAC + AAC decode (sample = `avc1` + AAC) |
| MOV | 1% | 1% | 75% | jellyfish_h264.mov | 1022 KB | 2026-04-23 | H.264 CABAC decode — new sample generated from public-domain jellyfish footage via ffmpeg. Old MPEG-4 Part 2 sample kept in `sample.mov` but sweep now picks the larger H.264 one. |
| WebM (VP9+Opus) | **86%** | 69% | 78% | jellyfish_vp9_opus.webm | 1.7 MB | 2026-04-24 | libvpx 1.14.1 full VP9 decode per frame — every frame entropy + DCT decoded via `vpx_codec_decode`. Opus audio CRC provides additional coverage. |
| WebM (VP8) | **88%** | n/a | **90%** | jellyfish_360_10s.webm | 1.0 MB | 2026-04-24 | libvpx 1.14.1 full VP8 decode. **Critical:** uses `VP8D_GET_FRAME_CORRUPTED` control query after each frame — without it, VP8's built-in error concealment silently patches bit flips. Both sniper and shotgun lift by ~90 points because of this query. |
| AVI | 0% | 20% | **93%** | jellyfish_mjpeg.avi | 8.1 MB | 2026-04-23 | MJPEG per-frame decode via libjpeg-turbo — new sample generated via ffmpeg. Old MPEG-4 Part 2 sample kept in `generated_testsrc.avi` but sweep picks the larger MJPEG one. |
| DV | 0% | 3% | 0% | sample.dv | 351 KB | 2026-03-06 | DV spec has no checksum; relies on tape physical ECC |
| MPEG-ES | 0% | 0% | 0% | sample.m1v | 30 KB | 2026-03-06 | Start codes only |
| MPEG-1/2 | 0% | 0% | 0% | sample.mpg | 16 KB | 2026-03-06 | Start codes only |
| MPEG-4 Part 2 | 0% | 0% | 0% | ubAVIxvid10.avi | 1.2 MB | 2026-03-06 | VOP header parsing tolerates VOP failures |
| RM | 0% | 1% | 2% | sample.rm | 13 KB | 2026-04-23 | RealMedia spec has no checksums; structural chunk walk only |
| FLV | 40% | n/a | n/a | sample.flv | 33 B | 2026-04-25 | Flash Video tag walk; no per-tag CRC. Tiny 33 B sample — sniper hits magic + header bytes. Shotgun N/A (sample < 4 KB). |
| MPEG-PS | 0% | n/a | n/a | sample.mpg | 2 KB | 2026-04-25 | MPEG Program Stream; PES header walk; no CRC. Shotgun N/A (sample < 4 KB). |
| Theora (.ogv) | **100%** | n/a | **100%** | sample.ogv | 50 KB | 2026-04-25 | Theora-in-Ogg; libtheora-encoded testsrc (CC0). Ogg page CRC32 catches every probed bit flip in both modes. |
| VP8 (raw IVF) | 0% | 0% | 0% | sample.ivf | 9 KB | 2026-04-25 | IVF container with VP8 frames; structural-only without libvpx wired into the IVF dispatch path. Hand-authored CC0 sample. Detection is fundamentally low until VP8-in-IVF gets the same `VP8D_GET_FRAME_CORRUPTED` query as VP8-in-WebM. |

### Audio

| Format | Sniper | Bolter | Shotgun | Sample | Size | Run | Mechanism |
|--------|-------:|-------:|--------:|--------|-----:|-----|-----------|
| AC3 | **100%** | **100%** | **100%** | Canyon-5.1-48khz-448kbit.ac3 | 2.0 MB | 2026-04-23 | CRC-16 per syncframe. Previous sample `TomorrowNeverDies-...ac3` was malformed (started with bytes 0x84 4F 59 11, not AC3 sync 0B 77) — validator correctly rejected it, so the old 100%/100% number was a false positive from trial inheritance. Removed 2026-04-23; now measured against a genuinely valid sample. |
| OGG | **100%** | **100%** | **100%** | wikipedia_example.ogg | 102 KB | 2026-03-06 | CRC32 per OGG page |
| E-AC3 (large) | **100%** | n/a | **100%** | sample1_5.1_640kbps.eac3 | 4.0 MB | 2026-03-06 | CRC-16 per syncframe (full file, after 2026-03-06 fix) |
| E-AC3 (small) | **81%** | **100%** | **85%** | sample3_5.1_256kbps.eac3 | 1.2 MB | 2026-03-06 | ⚠ Lower coverage on smaller file — reflects frame-size / coverage density, not a bug |
| FLAC | **80%** | **96%** | **88%** | generated_middle_c.flac | 43 KB | 2026-03-06 | MD5 audio hash + CRC-8/CRC-16 per frame |
| ALAC | 1% | 0% | **100%** | sample.m4a | 17 KB | 2026-03-06 | Lossless decode — 4KB overwrite kills a frame |
| Opus | 1% | 62% | 35% | test_audio_video.webm | 54 KB | 2026-03-06 | OGG page CRC + libopus decode |
| AAC (M4A) | 4% | 3% | 31% | sample.m4a | 15 KB | 2026-03-06 | MP4 box + AAC syntax decode |
| AAC (ADTS) | 6% | 10% | 20% | sample.aac | 9 KB | 2026-03-06 | ADTS framing + syntax |
| MP3 | 1% | 0% | 1% | generated_tone_880hz.mp3 | 48 KB | 2026-03-06 | Frame sync only — MP3 spec has no data CRC |
| WAV | 0% | 0% | 2% | sample.wav | 8 KB | 2026-03-06 | RIFF structural; no data checksum |
| AIFF | 0% | 0% | 1% | sample.aiff | 7 KB | 2026-03-06 | IFF structural; no data checksum |
| CAF | 0% | 0% | 1% | sample.caf | 8 KB | 2026-03-06 | Chunk walk; no data checksum |
| AU | 0% | 0% | 0% | sample.au | 8 KB | 2026-03-06 | Header + raw PCM |
| Tracker (MOD) | 0% | 0% | 0% | otm.mod | 301 KB | 2026-03-06 | No integrity mechanism in format |
| AMR | 14% | n/a | n/a | sample.amr | 38 B | 2026-04-25 | Adaptive Multi-Rate audio; frame-table based, no per-frame CRC. Sniper at 14% reflects sync-byte coverage on a 38 B sample. Shotgun N/A. |
| APE (Monkey's Audio) | **99%** | **100%** | **100%** | corpus_synthetic.ape | 15 KB | 2026-04-26 | MAC header + descriptor + per-frame CRC32. Full deep-decode validation now wired via vendored upstream Monkey's Audio SDK 12.73 (`deps/libape/`, BSD-3 since 2023). The validator runs structural rigor first (descriptor, header, seek-table monotonicity, audio-region bounds, field sanity, version range) then decodes every frame and surfaces per-frame CRC32-over-decoded-PCM mismatches via the C-shim `validate_ape_decode_check`. Truncation is caught either by the structural seek-table walk (modern v3980+ has audio_data_length) or by the decoder's sample-count-mismatch path. Synthetic 16 KB corpus is now a real APE encoded by the SDK from white-noise WAV (\`mac -c2000\`), so it actually decodes; sniper hits 99% (only the descriptor MD5 bytes — which are byte-level metadata not bitstream — escape detection in some random flips), shotgun hits 100%. Tested with the in-tree Zig tests + tests/cli/ape_validation (11 PASS). |
| CD+G (Karaoke) | 0% | 0% | 2% | sample.cdg | 14 KB | 2026-04-25 | 24-byte fixed-size sectors; structural only — no checksum. 0%/2% confirms fundamental format limit. |
| DFF (DSDIFF) | 52% | n/a | n/a | sample.dff | 32 B | 2026-04-25 | DSD audio container; chunk walk only. Tiny 32 B header-only sample. Shotgun N/A. |
| DSF (DSD) | 60% | n/a | n/a | sample.dsf | 88 B | 2026-04-25 | Sony DSD; structural walk. Shotgun N/A. |
| DTS (Digital Surround) | 0% | 0% | 51% | sample.dts | 369 KB | 2026-04-25 | Frame sync + size walk; no per-frame CRC. Shotgun lift from 4 KB overwrite desyncing the frame stream. |
| TTA (True Audio) | **97%** | n/a | n/a | sample.tta | 3 KB | 2026-04-25 | Per-frame CRC32 catches almost every probed bit flip. Shotgun N/A (sample < 4 KB). |
| WavPack | **100%** | **100%** | **100%** | corpus_xorshift.wv | 117 KB | 2026-04-26 | libwavpack 5.9.0 deep decode: every block decoded to PCM, per-block CRC over decoded samples + checksum sub-block + sample-count drift. Block-checksum sub-block (`ID_BLOCK_CHECKSUM`) catches header/bitstream tampering at open-time; post-decode CRC catches arithmetic drift; truncation surfaces as decoded < expected sample count. |

### Document & Office

| Format | Sniper | Bolter | Shotgun | Sample | Size | Run | Mechanism |
|--------|-------:|-------:|--------:|--------|-----:|-----|-----------|
| XLS | 22% | 24% | **96%** | poi_formula.xls | 174 KB | 2026-05-27 | BIFF8 records + SST + formulas + cells |
| DOC (large) | 2% | 2% | 2% | word95_large.doc | 589 KB | 2026-03-06 | FIB + 31 fc/lcb pair bounds + CLX piece table. Detection density drops on large docs — body text is most of the file. |
| DOC (small) | n/a | n/a | 52% | word97_simple.doc | 19 KB | 2026-03-06 | Same validator, smaller file — shotgun has ~21% chance of hitting FIB/Table/CLX. |
| PDF | n/a | n/a | n/a | (varies — see breakout) | n/a | 2026-04-27 | †Headline numbers are misleading for PDF: detection rate is dominated by which compression filters the document uses for its embedded streams (Flate, DCT/JPEG, JPX/JPEG2000, JBIG2, CCITT), not by the validator. See "PDF detection by stream-filter dominance" subsection below for the breakout table. The exit-code bug from 2026-03-06 was fixed in commit `c304f36` (2026-04-23, Action Item #1). |
| OLE2 (PPT) | 0% | 0% | 0% | sample.ppt | 891 KB | 2026-03-06 | FAT/directory structural only |
| InDesign | 1% | 0% | 73% | sample.indd | 4 KB | 2026-03-06 | Page structure. |
| DOCX | **87%** | **82%** | **100%** | sample.docx | 13 KB | 2026-04-23 | OOXML = ZIP with per-entry CRC32. Sample replaced 2026-04-23 from Apache 2.0 Tika test corpus. |
| XLSX | **82%** | **83%** | **100%** | sample.xlsx | 10 KB | 2026-04-23 | OOXML = ZIP with per-entry CRC32. Sample from Apache Tika. |
| PPTX | **93%** | **97%** | **100%** | sample.pptx | 35 KB | 2026-04-23 | OOXML = ZIP with per-entry CRC32. Sample from Apache Tika. |
| ODT | **96%** | **98%** | **100%** | sample.odt | 23 KB | 2026-04-23 | ODF = ZIP with per-entry CRC32. Sample from Apache Tika. Note: currently auto-detected as EPUB (also ZIP) — separate detection-priority bug. |
| ODS | **88%** | **88%** | **100%** | sample.ods | 8 KB | 2026-04-23 | Same as ODT. |
| ODP | **97%** | **98%** | **100%** | sample.odp | 23 KB | 2026-04-23 | Same as ODT. |
| RTF | 0% | 0% | **92%** | sample.rtf | 1.2 MB | 2026-04-23 | Structural only — RTF has no checksums. Shotgun high because 4 KB overwrite reliably breaks brace matching or control-word syntax. |
| EML | 12% | **97%** | **84%** | sample.eml | 6 KB | 2026-04-25 | UTF-8 + NUL-byte integrity check on the raw file before structural parsing. NUL is never legal in a mail message; flipping the high bit of an ASCII byte produces a lone UTF-8 continuation byte. Caught ~50% of single-bit ASCII flips and ~80% of 4 KB shotgun overwrites. |
| MBOX | 13% | **100%** | **100%** | sample.mbox | 16 KB | 2026-04-25 | Same UTF-8 + NUL-byte check as EML, applied to the whole concatenated file. Shotgun catches every 4 KB random overwrite (random bytes almost always include NUL or invalid UTF-8 sequences). Sniper catches roughly half the random bit flips. |
| Pages | **100%** | **99%** | **100%** | sample.pages | 56 KB | 2026-04-25 | iWork bundle = ZIP with per-entry CRC32. Hand-authored from scratch (no Apple software, no permissive corpus exists); `scripts/build-pages-sample` regenerates a deterministic 8-IWA inner `Index.zip` with high-entropy openssl-AES-CTR payloads plus real plist metadata. CRC32 per entry catches every bit flip and every 4 KB shotgun overwrite. |
| Keynote | **99%** | **100%** | **100%** | sample.key | 64 KB | 2026-04-25 | iWork bundle = ZIP with per-entry CRC32. Hand-authored mirroring the Pages sample; `scripts/build-keynote-sample` regenerates a 9-IWA inner `Index.zip` plus an uncompressed `buildVersionHistory.plist` carrying `com.apple.iWork.Keynote` so the format detector keys on it. CRC32 per entry catches every 4 KB shotgun overwrite and ~99% of single-bit flips. |
| Numbers | **100%** | **99%** | **100%** | sample.numbers | 64 KB | 2026-04-25 | Same iWork-bundle template as Keynote with a Tables/-shaped IWA layout. The `com.apple.iWork.Numbers` marker is stored uncompressed at the head of the outer ZIP. CRC32 per entry catches every probed bit flip and every 4 KB shotgun overwrite. |
| AI (Adobe Illustrator) | 6% | n/a | n/a | sample.ai | 372 B | 2026-04-25 | PostScript-derived header + PDF body. Tiny 372 B sample is mostly PDF magic; later bytes are uncovered text. Shotgun N/A. |
| BAI2 (Bank Admin Inst.) | 20% | n/a | n/a | sample.bai2 | 362 B | 2026-04-25 | Fixed-format banking text; structural validation of record-type prefixes. No checksum. Shotgun N/A. |
| CSV | 26% | **100%** | **100%** | large_utf8.csv | 23 KB | 2026-06-22 | Structural CSV + mandatory UTF-8 validation. bolter/shotgun reliably produce invalid UTF-8 -> 100%; sniper 26% = flips landing in a multibyte sequence. (Was 0/0/0 before 2026-06-22: CSV was omitted from the extension-remap dispatch and silently skipped its UTF-8 check; fixed and guarded by tests/cli/utf8_required_formats_reject.) |
| ClarisWorks | 6% | n/a | n/a | sample.cwk | 64 B | 2026-04-25 | Legacy AppleWorks. Structural walk. Shotgun N/A. |
| EDIFACT | 37% | n/a | n/a | sample.edifact | 152 B | 2026-04-25 | Fixed-format trade messages; validator cross-checks UNH/UNT counts. Shotgun N/A. |
| EPS | 4% | n/a | n/a | sample.eps | 430 B | 2026-04-25 | PostScript header + structural walk. Shotgun N/A. |
| EPUB | 69% | n/a | n/a | sample.epub | 1 KB | 2026-04-25 | ZIP container with mimetype check; per-entry CRC32. Shotgun N/A. |
| HTML | 22% | **100%** | **100%** | large_utf8.html | 34 KB | 2026-06-22 | Tag-tree parse + UTF-8 validation gated on a declared charset (<meta charset=utf-8>). bolter/shotgun -> 100%; sniper 22% on the >=12 KB fixture. |
| iCalendar (RFC 5545) | 21% | n/a | n/a | sample.ics | 650 B | 2026-04-25 | Structural; BEGIN/END pairing + property syntax. Shotgun N/A. |
| IDML (InDesign) | 55% | n/a | n/a | sample.idml | 884 B | 2026-04-25 | ZIP+XML markup; per-entry CRC32. Shotgun N/A. |
| INI | 17% | n/a | n/a | sample.ini | 60 B | 2026-04-25 | Plain-text key-value; structural only. Shotgun N/A. |
| JSON | 43% | **100%** | **100%** | large_utf8.json | 33 KB | 2026-06-22 | RFC 8259 mandates UTF-8: the validator rejects invalid UTF-8, then parses structure. On the >=12 KB multibyte fixture, bolter/shotgun almost always corrupt a UTF-8 sequence -> 100%; sniper 43% is the share of single-bit flips that land in a multibyte byte or a JSON token. |
| JSON5 | 30% | n/a | n/a | sample.json5 | 329 B | 2026-04-25 | JSON5 parser; structural only. Shotgun N/A. |
| MT940 (SWIFT) | 11% | n/a | n/a | sample.mt940 | 347 B | 2026-04-25 | Banking text; structural only. Shotgun N/A. |
| MacWrite Document | 0% | n/a | n/a | sample.mwd | 64 B | 2026-04-25 | Legacy word processor; structural only. Tiny sample. Shotgun N/A. |
| NACHA (ACH) | 15% | n/a | n/a | sample.ach | 950 B | 2026-04-25 | Banking fixed-format text; record-type validation. Shotgun N/A. |
| OFX (Open Financial) | 2% | n/a | n/a | sample.ofx | 850 B | 2026-04-25 | Banking SGML/XML; structural only. Shotgun N/A. |
| Plain Text | 0% | 0% | **95%** | large_utf8.txt | 17 KB | 2026-06-22 | UTF-8 + control-char check. Invalid UTF-8 that is still Latin-1-decodable falls back to single-byte decode with a WARN (exit 0, so counted as not-detected) -> sniper/bolter ~0%; shotgun 95% because a random 4 KB overwrite injects NUL or undecodable bytes that hard-fail. |
| PTX (Pro Tools) | 0% | 0% | 0% | sample.ptx | 39 KB | 2026-04-25 | Avid session structural walk. 0%/0% on 40 KB confirms structural-only. |
| QIF (Quicken Interchange) | 3% | n/a | n/a | sample.qif | 218 B | 2026-04-25 | Plain-text; structural only. Shotgun N/A. |
| TOML | 42% | **100%** | **100%** | large_utf8.toml | 33 KB | 2026-06-22 | TOML structural parse + mandatory UTF-8. bolter/shotgun -> 100% (invalid UTF-8); sniper 42% on the >=12 KB multibyte fixture. |
| TXF (Tax Exchange) | 3% | n/a | n/a | sample.txf | 140 B | 2026-04-25 | Plain-text; structural only. Shotgun N/A. |
| vCard (RFC 6350) | 32% | n/a | n/a | sample.vcf | 198 B | 2026-04-25 | Structural BEGIN/END pairing + property syntax. Shotgun N/A. |
| WordPerfect | 2% | n/a | n/a | sample.wpd | 512 B | 2026-04-25 | Header walk; structural only. Shotgun N/A. |
| X12 EDI | 21% | n/a | n/a | sample.edi | 262 B | 2026-04-25 | Fixed-format trade messages; ISA/IEA + GS/GE counts cross-validated. Shotgun N/A. |
| XML | 52% | **100%** | **100%** | large_utf8.xml | 40 KB | 2026-06-22 | XML well-formedness + mandatory UTF-8. bolter/shotgun -> 100%; sniper 52% from tag/quote/multibyte density on the >=12 KB fixture. |
| YAML | 0% | n/a | n/a | sample.yaml | 68 B | 2026-04-25 | Plain-text; structural only. Shotgun N/A. |
| Markdown | 0% | n/a | n/a | sample.md | 525 B | 2026-04-25 | Plain-text; structural only. Shotgun N/A. |

#### PDF detection by stream-filter dominance

A single "PDF detection rate" misleads. PDF is a container; its real bit-flip
detection ceiling depends on which compression filter dominates the file's
byte volume. We deep-validate every embedded stream by running it through
its codec (Flate via zlib, DCT/JPEG via libjpeg-turbo, JPX/JPEG2000 via
OpenJPEG, JBIG2 via our own decoder, CCITT via our G4 reader). What the
validator detects is bounded by what the codec rejects — not by validator
effort.

| PDF byte-mix dominance | Sniper (1-bit flip) | Shotgun (4 KB overwrite) | Why |
|---|---:|---:|---|
| Flate-dominated (text books, code/glyph data) | **~90%** | **~90%** | zlib Adler-32 catches almost every flip in compressed bytes; remaining ~10% are inside structurally-valid Flate output that's still parseable PDF. Sample: 876 KB Vonnegut text PDF, 50 rounds. |
| Mixed Flate + DCT/JPEG (illustrated text) | **~46%** | **~88%** | libjpeg's `emit_message` is now escalated so any negative-level warning ('Premature end of data segment', 'Corrupt JPEG data: bad Huffman code', 'Extraneous bytes before marker') aborts decode rather than silently continuing. Sample: 3 MB book with 296 Flate + 40 DCT streams, 100 rounds. Pre-escalation (jpeg_validator only hooked error_exit, not emit_message): sniper 20%, shotgun 85% — escalation roughly doubled sniper detection. Verified zero false-positives on a 12-PDF random NAS sample. |
| JPX / JPEG2000-dominated (photo books, picture books, archive scans) | **~0%** | **~2%** | OpenJPEG's wavelet decode degrades gracefully into visual artifacts; only flips that hit JPEG2000 markers (SOC, SIZ, COD, SOT, EOC) cause decode failure. Standalone 506 KB JP2 stream extracted from sample: 0/54 sniper, 1/46 shotgun (100 rounds, seed=42). |
| JBIG2-dominated (scanned bilevel pages) | **~0%** (expected, untested standalone) | **~few %** (expected) | Same shape as JPEG2000 — JBIG2's arithmetic coder is corruption-tolerant; only segment-header flips fail decode. Future sample-extraction needed. |
| CCITT G3/G4-dominated (faxed pages, OCR scans) | **~5-10%** (expected, untested standalone) | **medium** (expected) | Run-length coding tends to break sync more readily than JPEG2000/JBIG2 but is still not a checksum. |

**Why this is honest, not a defect.** PDF the spec has no per-stream content
hash. A PDF "fully validated" in our sense means: every stream parsed,
every codec accepted the payload, every cross-reference resolves. It does
not mean every byte's integrity is verified — that proof requires an
external mechanism the format does not carry. For codecs without a
checksum, the only ways a flip CAN fail decode are (a) it lands in a
marker/header byte the codec checks, or (b) the resulting bitstream
violates the codec's structural grammar. Most flips in entropy-coded
payload do neither.

**Where this matters.** If your authoritative copy of a PDF gets
silently flipped on disk (cosmic ray, RAID rebuild error, flash bit-rot)
and that flip lands inside a JPEG2000 page-image stream, validate will
report `OK ... PDF Document (fully validated)`. The image will still
render, just with a few visual glitches. This is the codec's design.
For real-world bit-rot protection of opaque-codec PDFs (and any other
format whose spec lacks integrity fields), pair validate with a
sidecar-parity solution like Entropy Shield (https://entropyshield.app),
which carries a dedicated whole-file or per-block hash and can repair
corruption it detects rather than just reporting it.

**Roadmap.** A future architectural refactor will introduce a
`.bounds_verified` validation depth distinct from `.full`, so
`(fully validated)` only appears when every byte is provably checked.
For PDF, the realistic top tier per filter dominance becomes:
`Flate-dominated → .full`, codec-opaque-dominated → `.bounds_verified`.

### Font

| Format | Sniper | Bolter | Shotgun | Sample | Size | Run | Mechanism |
|--------|-------:|-------:|--------:|--------|-----:|-----|-----------|
| TTF | **100%** | **100%** | **100%** | noto_sans_regular.ttf | 607 KB | 2026-03-06 | Per-table checksum + whole-file checkSumAdjustment (strict mode) |
| OTF | **100%** | **100%** | **100%** | source_sans_regular.otf | 327 KB | 2026-03-06 | Per-table checksum + whole-file checkSumAdjustment |
| WOFF | **100%** | **100%** | **100%** | roboto_regular.woff | 254 KB | 2026-04-23 | Per-table zlib-decompress + origChecksum verification (font_validator.zig:370). Prior "0%/0%" was a stale sweep — the code was already doing the right thing. |
| WOFF2 | 49% | 63% | **100%** | roboto_regular.woff2 | 172 KB | 2026-04-23 | Per-table Brotli-decompress + origChecksum verification. Prior "0%/0%" was a stale sweep. Sniper is lower than WOFF because WOFF2's Brotli framing is more compact (fewer structural bytes), but shotgun still perfect. |

### Scientific

| Format | Sniper | Bolter | Shotgun | Sample | Size | Run | Mechanism |
|--------|-------:|-------:|--------:|--------|-----:|-----|-----------|
| FITS (with CHECKSUM) | **100%** | n/a | **100%** | sample_with_checksum.fits | 5 KB | 2026-03-06 | CHECKSUM/DATASUM per HDU |
| FITS (no CHECKSUM) | 0% | 0% | 2% | sample.fits | 683 KB | 2026-03-06 | Keyword validation only |
| DICOM | 7% | 9% | 20% | CT_small.dcm | 38 KB | 2026-03-06 | Tag structure + value validation |
| HDF5 | 4% | 72% | 13% | sample_v2.h5 | 6 KB | 2026-03-06 | Jenkins lookup3 checksum (small file) |
| PDB (Protein) | 16% | 19% | 39% | 1CRN.pdb | 48 KB | 2026-03-06 | ATOM/HETATM record cross-validation |
| CIF (Crystallographic Info) | 0% | n/a | n/a | sample.cif | 145 B | 2026-04-25 | Plain-text scientific format; structural only. Shotgun N/A. |
| FASTA | 22% | n/a | n/a | sample.fasta | 479 B | 2026-04-25 | Plain-text bioinformatics; structural only. Shotgun N/A. |
| FASTQ | 28% | n/a | n/a | sample.fastq | 447 B | 2026-04-25 | Plain-text bioinformatics; per-record sequence/quality length cross-check. Shotgun N/A. |
| MAT-File | **94%** | n/a | n/a | sample.mat | 1 KB | 2026-04-25 | Element header + flag walk; magic + endian + tag length validation. Shotgun N/A. |
| NetCDF | 39% | n/a | n/a | sample.nc | 84 B | 2026-04-25 | NetCDF classic header walk; HDF5-derived NetCDF-4 reuses HDF5's lookup3 checksums. Tiny sample. Shotgun N/A. |
| NIfTI-1 | 1% | n/a | n/a | sample.nii | 416 B | 2026-04-25 | Header magic + dims; no checksum. Shotgun N/A. |
| Parquet | 2% | n/a | n/a | sample.parquet | 484 B | 2026-04-25 | Footer + page CRC32 (not currently verified by validator beyond header). Shotgun N/A. |
| Shapefile | **89%** | n/a | n/a | sample.shp | 128 B | 2026-04-25 | GIS .shp; record-by-record header check + magic. Shotgun N/A. |

### Database

| Format | Sniper | Bolter | Shotgun | Sample | Size | Run | Mechanism |
|--------|-------:|-------:|--------:|--------|-----:|-----|-----------|
| QBW | **100%** | **100%** | **100%** | B18_Managing_Company_Files.qbw | 14.4 MB | 2026-03-06 | CRC32 per 4096-byte page (v12+) |
| SQLite | 54% | 52% | **100%** | chinook.sqlite | 984 KB | 2026-03-06 | Page headers + btree structure |
| ACCDB | 1% | 0% | 73% | sample.accdb | 4 KB | 2026-03-06 | Jet engine page structure (small file) |
| MDB | 1% | 0% | 73% | sample.mdb | 4 KB | 2026-03-06 | Jet engine page structure (small file) |
| QuickBooks Backup (.qbb) | 8% | 7% | 24% | sample.qbb | 19 KB | 2026-04-25 | OLE2-based; dispatches through document_validators (no per-stream checksum). Sample shared with ole2/sample.doc. |
| dBASE (.dbf) | 0% | 0% | **100%** | sample.dbf | 20 KB | 2026-04-25 | Header version + date + record-length cross-validation; hand-authored CC0 dBASE III. Sniper rate fundamental (no per-record checksum); shotgun lands in tail records past header-declared range. |

### Archive

| Format | Sniper | Bolter | Shotgun | Sample | Size | Run | Mechanism |
|--------|-------:|-------:|--------:|--------|-----:|-----|-----------|
| CPT | **100%** | **100%** | **100%** | sample.cpt | 19 KB | 2026-03-06 | CRC per resource fork entry (Compact Pro archive, not audio) |
| TAR | 15% | 78% | 73% | sample.tar | 4 KB | 2026-03-06 | Header checksum per 512-byte block |
| 7z | **99%** | n/a | **100%** | corpus_xorshift.7z | 16 KB | 2026-04-25 | 7z next-header CRC32 + per-stream CRC32. Hand-authored xorshift corpus (CC0). Both sniper and shotgun catch nearly every flip. |
| AR (Unix archive) | 38% | n/a | n/a | minimal.a | 88 B | 2026-04-25 | `!<arch>\n` magic + 60-byte member headers; no per-entry checksum. Shotgun N/A. |
| BLAR (Blake3 Archive) | **100%** | n/a | n/a | sample.blar | 1 KB | 2026-04-25 | Peter's archive format with Blake3 per-entry hashing. Every probed bit flip detected. Shotgun N/A. |
| Brotli | 47% | 72% | **100%** | realistic_corpus.br | 26 KB | 2026-04-26 | Raw Brotli stream; full streaming decompression via libbrotli. RFC 7932 has no whole-file checksum, but the entropy coder rejects most structurally invalid prefix codes / distance overflows / window-bits errors. ~47% of single-bit flips on dense English-text Huffman streams cascade into decoder failure; the rest decode to wrong-but-valid bytes (silent). 4 KB shotgun overwrites are essentially always rejected. Earlier 0%/0% row used a pathological xorshift random-noise corpus where compressed output is ~8 bits/byte and bit flips are statistically valid Huffman codes; replaced with a deterministic CC0 English-text corpus (scripts/build-brotli-corpus). |
| Bzip2 | **100%** | **100%** | **100%** | corpus_xorshift.bz2 | 16 KB | 2026-04-25 | CRC32 per block + combined CRC. Hand-authored xorshift corpus (CC0). |
| CAB (Microsoft) | **100%** | **100%** | **100%** | corpus_xorshift.cab | 26 KB | 2026-04-25 | Per-folder + per-file CSUM (Adler-like) cross-validated. CC0 sample built via gcab. |
| Gzip | **100%** | **100%** | **100%** | corpus_xorshift.gz | 16 KB | 2026-04-25 | CRC32 + ISIZE in trailer. Hand-authored xorshift corpus (CC0). |
| BinHex (.hqx) | **100%** | **100%** | **100%** | corpus_xorshift.hqx | 13 KB | 2026-04-25 | BinHex 4.0 header + per-fork CRC16. Hand-authored CC0 sample (encoder reverse-engineered from validator). |
| MBLAR (Multi-Blake3) | **100%** | n/a | n/a | sample.mblar | 393 B | 2026-04-25 | Peter's manifest-bundle archive; Blake3 per file. Shotgun N/A. |
| PAR2 | **100%** | **100%** | **100%** | corpus_xorshift.par2 | 33 KB | 2026-04-25 | MD5 of every packet + recovery slice integrity. Built via par2cmdline (BSD-licensed). |
| RAR | **100%** | **100%** | **100%** | corpus_xorshift.rar | 16 KB | 2026-04-25 | Per-entry CRC32 + RAR5 BLAKE2sp option. CC0 corpus (rar -m5). |
| StuffIt | **94%** | n/a | n/a | sample.sit | 140 B | 2026-04-25 | Header + entry walk; sniper 94% on 140 B from header dominance. Shotgun N/A. |
| XZ | **100%** | **100%** | **100%** | corpus_xorshift.xz | 16 KB | 2026-04-25 | CRC32/CRC64/SHA-256 per stream + index integrity. Hand-authored xorshift corpus (CC0). |
| ZIP | **100%** | **100%** | **100%** | corpus_xorshift.zip | 16 KB | 2026-04-25 | Per-entry CRC32 + EOCD record. Hand-authored xorshift corpus (CC0). |
| Zstd | **100%** | **100%** | **100%** | corpus_xorshift.zst | 16 KB | 2026-04-25 | Frame-level XXH64 + frame footer. Hand-authored xorshift corpus (CC0). |
| Studio One Project (.song) | **100%** | **99%** | **100%** | sample.song | 41 KB | 2026-04-25 | ZIP-based; per-entry CRC32 + metainfo.xml integrity. Hand-authored CC0 sample. |
| StuffIt X (.sitx) | 0% | 0% | 0% | sample.sitx | 16 KB | 2026-04-25 | Magic + structural header walk only; no per-entry checksums in current validator. Hand-authored. |

### Game ROM

| Format | Sniper | Bolter | Shotgun | Sample | Size | Run | Mechanism |
|--------|-------:|-------:|--------:|--------|-----:|-----|-----------|
| SNES | **100%** | **100%** | **99%** | F-ZERO.smc | 512 KB | 2026-03-06 | Internal ROM checksum + complement |
| GB | 0% | **100%** | 1% | Addams | 128 KB | 2026-03-06 | Header checksum only (tiny coverage) |
| GBA | 0% | 0% | 0% | Bomberman | 8.0 MB | 2026-03-06 | Header checksum only |
| Genesis | 0% | **100%** | 1% | Aero | 512 KB | 2026-03-06 | Header checksum only |
| NES | 0% | 0% | 0% | 1943 | 128 KB | 2026-03-06 | iNES header only |
| N64 | 0% | 10% | 0% | Super | 8.0 MB | 2026-03-06 | No integrity mechanism |
| CHD (MAME) | 10% | n/a | n/a | synthetic_chd.chd | 124 B | 2026-04-25 | MAME's compressed disc; SHA-1 per hunk + global SHA-1. Tiny synthetic 124 B sample. Shotgun N/A. |
| NDS (Nintendo DS) | 41% | n/a | n/a | synthetic_nds_rom.nds | 1 KB | 2026-04-25 | Header CRC16 (logo + secure area). 41% sniper on 1 KB. Shotgun N/A. |
| WAD (Doom/Wii) | **100%** | n/a | n/a | sample.wad | 12 B | 2026-04-25 | Lump table; structural only. Tiny synthetic sample — header IS most of file. Shotgun N/A. |

### Disk Image / Filesystem / Executable / Other

| Format | Sniper | Bolter | Shotgun | Sample | Size | Run | Mechanism |
|--------|-------:|-------:|--------:|--------|-----:|-----|-----------|
| DMG | 0% | 0% | 10% | sample.dmg | 16 KB | 2026-03-06 | Plist + koly trailer |
| ISO | 0% | 0% | 0% | sample.iso | 350 KB | 2026-03-06 | PVD structural only |
| COFF | 0% | 0% | 1% | sample.o | 10 KB | 2026-03-06 | Section header structure |
| Mach-O Fat | 0% | 0% | 0% | sample | 32 KB | 2026-03-06 | Architecture header only |
| Blorb | 0% | 0% | 0% | Alabaster.gblorb | 3.0 MB | 2026-03-06 | IFF structural only |
| DS_Store | 0% | 0% | 25% | sample.ds_store | 10 KB | 2026-03-06 | BTree page structure |
| ASF | 1% | 4% | 0% | sample.asf | 6 KB | 2026-03-06 | GUID/object structural |
| QDF | 1% | 1% | 0% | LONDON_2018.QDF | 4.9 MB | 2026-03-06 | OLE2/ZIP structural |
| 3MF (3D Manufacturing) | 75% | n/a | n/a | sample.3mf | 1 KB | 2026-04-25 | ZIP-based; per-entry CRC32 + XML manifest. Shotgun N/A (sample < 4 KB). |
| AEP (After Effects Project) | 27% | n/a | n/a | sample.aep | 44 B | 2026-04-25 | RIFX container; structural-only walk. Tiny sample (44 B). Shotgun N/A. |
| ALS (Ableton Live Set) | **90%** | n/a | n/a | sample.als | 82 B | 2026-04-25 | gzip-wrapped XML. Tiny sample — gzip CRC32 + zlib structure catches most bit flips. Shotgun N/A. |
| Apple Media DB | 46% | n/a | n/a | sample.tvdb | 253 B | 2026-04-25 | tvdb/photo SQLite-derived store. Structural walk. Shotgun N/A. |
| GarageBand (.band) | 0% | n/a | n/a | projectData | 512 B | 2026-04-25 | Bundle (directory) format — `projectData` inside is a plist routed to plist validator. Sweep-only on the plist file. Shotgun N/A. |
| BEAM (Erlang) | 36% | n/a | n/a | sample.beam | 736 B | 2026-04-25 | FOR1/IFF chunk container; chunk lengths cross-validated. No CRC. Shotgun N/A. |
| Blender (.blend) | 47% | n/a | n/a | sample.blend | 104 B | 2026-04-25 | DNA-block-based binary. Structural walk; no checksum. Tiny header-only sample. Shotgun N/A. |
| BSP (Quake) | 39% | n/a | n/a | sample.bsp | 1 KB | 2026-04-25 | Lump-table walk; no CRC. Structural only. Shotgun N/A. |
| Bitwig Project | 0% | n/a | n/a | sample.bwproject | 128 B | 2026-04-25 | ZIP-derived but tiny sample (128 B). Sniper 0% — sample is below ZIP minimum. Shotgun N/A. |
| Chromium PAK | 0% | n/a | n/a | sample.pak | 30 B | 2026-04-25 | Resource bundle; index walk only. Tiny synthetic sample. Shotgun N/A. |
| Cubase Project | 49% | n/a | n/a | sample.cpr | 76 B | 2026-04-25 | Steinberg binary. Structural only. Shotgun N/A. |
| DER (ASN.1) | 7% | n/a | n/a | sample.der | 688 B | 2026-04-25 | TLV-walked. Structural; no checksum. Shotgun N/A. |
| DRP (DR Painter) | 60% | n/a | n/a | sample.drp | 263 B | 2026-04-25 | Generic binary — high sniper from header dominance. Shotgun N/A. |
| DWG (AutoCAD) | 1% | n/a | n/a | sample.dwg | 1 KB | 2026-04-25 | Section structure walk. Tiny sample. Shotgun N/A. |
| DXF (AutoCAD) | 5% | n/a | n/a | sample.dxf | 388 B | 2026-04-25 | Plain-text CAD; structural only. Shotgun N/A. |
| Erlang Mix .eex | 0% | n/a | n/a | sample.eex | 378 B | 2026-04-25 | Plain-text template; structural only. Shotgun N/A. |
| ELF | 20% | n/a | n/a | minimal.elf | 64 B | 2026-04-25 | Section header walk; no whole-file checksum. Tiny synthetic 64 B sample. Shotgun N/A. |
| Erlang BERT | 0% | n/a | n/a | sample.app | 281 B | 2026-04-25 | External Term Format walk. Shotgun N/A. |
| FCPXML (Final Cut) | 58% | n/a | n/a | sample.fcpxml | 134 B | 2026-04-25 | XML-based; structural walk. Shotgun N/A. |
| FL Studio | 6% | n/a | n/a | sample.flp | 122 B | 2026-04-25 | Project file structural walk. Tiny sample. Shotgun N/A. |
| GLB (glTF binary) | 32% | n/a | n/a | box.glb | 1 KB | 2026-04-25 | Chunk-based; structural walk. JSON chunk + BIN chunk lengths cross-validated. Shotgun N/A. |
| glTF (JSON) | 20% | n/a | n/a | box.gltf | 2 KB | 2026-04-25 | JSON manifest; structural only. Shotgun N/A. |
| IFF (EA) | 46% | n/a | n/a | sample.iff | 232 B | 2026-04-25 | Chunk walk; no CRC. Shotgun N/A. |
| Java .class | 21% | n/a | n/a | Hello.class | 397 B | 2026-04-25 | ClassFile constant pool walk; magic + version check. Shotgun N/A. |
| KML | 58% | n/a | n/a | sample.kml | 1 KB | 2026-04-25 | GIS XML; structural only. Shotgun N/A. |
| KMZ | **95%** | n/a | n/a | sample.kmz | 538 B | 2026-04-25 | KMZ = zipped KML; per-entry CRC32 catches almost any bit flip on the small sample. Shotgun N/A. |
| Logic Pro X | 71% | n/a | n/a | sample.logicx | 249 B | 2026-04-25 | Bundle format — sample is `ProjectData` plist alone. Shotgun N/A. |
| LSPK (Larian Studios) | 3% | n/a | n/a | sample.lspk | 256 B | 2026-04-25 | Pak file; structural only. Shotgun N/A. |
| Mach-O | 0% | n/a | n/a | sample.o | 536 B | 2026-04-25 | Single-arch sample; load command walk; no checksum. Shotgun N/A. |
| OBJ (Wavefront) | 44% | n/a | n/a | sample.obj | 652 B | 2026-04-25 | Plain-text 3D; vertex/face syntax check. Shotgun N/A. |
| PAK (Quake) | 60% | n/a | n/a | sample.pak | 12 B | 2026-04-25 | Header offset/length cross-check. Tiny synthetic sample (12 B). Shotgun N/A. |
| PE (Windows) | 3% | n/a | n/a | sample.exe | 1 KB | 2026-04-25 | MZ + PE headers; optional checksum (rarely populated). Tiny sample. Shotgun N/A. |
| PEM (RFC 7468) | 51% | n/a | n/a | sample.pem | 989 B | 2026-04-25 | Base64 envelope; structural only. Shotgun N/A. |
| PGP Signed Message | **81%** | n/a | n/a | sample.asc | 370 B | 2026-04-25 | Header/footer detect + Base64 walk. Shotgun N/A. |
| Plist | 52% | n/a | n/a | sample.plist | 830 B | 2026-04-25 | Both XML and binary plist; structural only. Shotgun N/A. |
| PLY (3D) | 51% | n/a | n/a | sample.ply | 447 B | 2026-04-25 | Header + element count; no per-element checksum. Shotgun N/A. |
| Premiere Project | 55% | n/a | n/a | sample.prproj | 112 B | 2026-04-25 | Gzip-wrapped XML. Tiny sample. Shotgun N/A. |
| Reason (Propellerhead) | 33% | n/a | n/a | sample.reason | 96 B | 2026-04-25 | Bundle binary; structural walk. Shotgun N/A. |
| RPP (Reaper) | 50% | n/a | n/a | sample.rpp | 44 B | 2026-04-25 | Plain-text project; structural only. Shotgun N/A. |
| Sketch (.sketch) | 56% | n/a | n/a | sample.sketch | 631 B | 2026-04-25 | ZIP-based; per-entry CRC32. Shotgun N/A. |
| SSH Signature | 64% | n/a | n/a | sample.sig | 294 B | 2026-04-25 | RFC 4880-like wire-format walk. Shotgun N/A. |
| STEP (.step) | 23% | n/a | n/a | sample.stp | 711 B | 2026-04-25 | ISO 10303-21 plain-text CAD. Shotgun N/A. |
| STL (3D) | 73% | n/a | n/a | sample.stl | 518 B | 2026-04-25 | Both ASCII and binary stl; sniper 73% on small ASCII sample. Shotgun N/A. |
| Toast (Roxio) | 0% | 0% | 10% | sample.toast | 36 KB | 2026-04-25 | Apple Toast disc image; structural walk. |
| Type 1 Font | 0% | n/a | n/a | sample.pfa | 174 B | 2026-04-25 | PostScript-derived font; eexec encrypted body walk. Shotgun N/A. |
| VMDK | 0% | 0% | 0% | sample.vmdk | 64 KB | 2026-04-25 | VMware disk descriptor + extent walk. 65 KB sample at 0%/0% — structural-only. |
| VPK (Valve Pak) | **100%** | n/a | n/a | sample.vpk | 28 B | 2026-04-25 | Tiny synthetic 28 B sample; structural walk catches every flip (header IS the file). Shotgun N/A. |
| WARC (Web Archive) | 48% | n/a | n/a | sample.warc | 1 KB | 2026-04-25 | Record header + content-length walk. Shotgun N/A. |
| WebAssembly | 35% | n/a | n/a | minimal.wasm | 24 B | 2026-04-25 | Section LEB128 length walk; magic + version. Tiny sample. Shotgun N/A. |
| WIM (Windows Imaging) | 8% | n/a | n/a | sample.wim | 1 KB | 2026-04-25 | XPRESS/LZX section walk; partial integrity. Shotgun N/A. |
| Microsoft Installer (.msi) | 0% | 0% | 43% | sample.msi | 9 KB | 2026-04-25 | OLE2 compound file (no integrity beyond CFBF FAT structure). Built via wixl. Shotgun catches FAT/dir mismatch. |
| Windows ESD (.esd) | 1% | 0% | 0% | sample.esd | 16 KB | 2026-04-25 | WIM variant with LZMS compression; structural header walk (208-byte WIM header). Hand-authored. |
| LLVM Precompiled Header (.pch) | 0% | 0% | 0% | sample.pch | 16 KB | 2026-04-25 | Magic ("CPCH") + LLVM bitcode signature only. Bitcode contents are version-specific; structural only. |
| LLVM Serialized Diagnostics (.dia) | 0% | 0% | 0% | sample.dia | 16 KB | 2026-04-25 | Magic ("DIAG") + LLVM bitcode signature only. Same limit as .pch. |
| PCAP | 4% | 3% | **100%** | sample.pcap | 13 KB | 2026-04-25 | Hand-authored (no sudo for tcpdump in nix sandbox). Walks every packet record's incl_len/orig_len; shotgun lands in valid trailer bytes that fail length checks. Fixed 64 MiB-stack-overflow bug in `validatePcap` while landing the sample. |
| PCAPNG | 0% | 0% | 0% | sample.pcapng | 9 KB | 2026-04-25 | Section Header Block + IDB + EPBs structural walk; pcapng-validator checks magic and BOM only (no block-level CRC verification yet — pcapng has optional CRC32 per block). |
| G-code | 27% | **99%** | **98%** | sample.gcode | 20 KB | 2026-04-25 | Text format; line-grammar walk catches 27% sniper (most flips break a coordinate or G/M code prefix). Shotgun 98% — large overwrite breaks too many lines to ignore. Hand-authored CC0. |
| MessagePack (.msgpack) | 0% | 0% | 0% | sample.msgpack | 19 KB | 2026-04-25 | Type-tagged binary; validator walks tag stream but spec has no checksum. Most flips land in payload bytes that decode to different-but-valid values. Fundamental limit per RFC. Hand-authored CC0. |
| RPM Package (.rpm) | 3% | 7% | 30% | sample.rpm | 22 KB | 2026-04-25 | RPM v3 lead + signature header + main header. Validator computes SHA-1 over main header (when sig tag 269 present). Shotgun 30% reflects header dominance vs payload mass. Built via rpmbuild (CC0 spec). Fixed 16 MiB-stack-overflow bug in `validateRpm` while landing the sample. |

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

13. **DONE 2026-04-26 — both WavPack AND APE at full deep-decode validation.** WavPack achieves **100%/100%** via libwavpack 5.9.0 deep-decode integration. The CRC field in each WavPack block header (computed over decoded PCM per dbry's `unpack.c` line 508) is verified by decoding every block and querying `WavpackGetNumErrors`. Block-checksum sub-blocks catch header/bitstream tampering at open-time; sample-count drift catches truncation. **APE achieves 99%/100%** via the vendored upstream Monkey's Audio SDK 12.73 (BSD-3 since 2023) at `deps/libape/`. The 32-bit per-frame CRC (computed over decoded PCM per `APEDecompressCore::EndFrame`) is verified by decoding every frame through the C shim `validate_ape_decode_check`; truncation is caught either by the structural seek-table walk or by the decoder's sample-count drift path. The remaining 1% sniper miss reflects bit flips inside the descriptor's stored MD5 bytes — purely metadata, not bitstream content.

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

Source of truth = `docs/corruption-sweep-results/*.tsv` (measured numbers) +
`docs/corruption-sweep-results/generated/` (sidecar: section, display name,
slug, run date, Mechanism prose, frozen fallbacks). To refresh this report:

```bash
./build                                      # fresh release binary
./scripts/corruption-sweep                   # fill/refresh all *_{sniper,bolter,shotgun}.tsv
./scripts/generate-corruption-report         # regenerate THIS file from TSVs + sidecar
```

`generate-corruption-report` writes `docs/corruption-detection-report.md` by
default; override with `--out` / `$VALIDATE_CORRUPTION_REPORT` (and
`--results-dir` / `$VALIDATE_SWEEP_RESULTS_DIR`, `$VALIDATE_GROUND_TRUTH_DIR`)
to run the whole sweep→generate chain against a small fixture corpus — see
`tests/cli/corruption_report_generator`. **Do not hand-edit the table above**:
numbers come from the TSVs, prose from the sidecar.

---

*Report generated from TSV sweep data on 2026-04-23. Raw data and per-trial offsets live in `docs/corruption-sweep-results/`.*
