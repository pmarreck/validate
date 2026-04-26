### Format Coverage Chew-Through (2026-04-25, completed 21:50 EST)

Per Peter's dispatch: measure corruption detection for the 125 formats that validate claimed to support but had no sweep data. Reconcile against `FORMAT_VERIFICATIONS.md` (242 enum entries). Verify checksum mechanisms are wired up.

- [x] Mapped 227 ground-truth dirs vs 104 swept formats → 125-format gap.
- [x] Categorized samples by size: 7 ≥ 4 KB (full sweep), 19 in 1-4 KB range (sniper-only), 98 < 1 KB (sniper-only on tiny structural samples). Most are honest 0%/0% structural-only formats.
- [x] Built `/tmp/run-sweep.sh` parallel harness; ran 117 sniper sweeps + 6 shotgun sweeps (where sample ≥ 4 KB) → 123 new TSVs in `docs/corruption-sweep-results/`.
- [x] Generated 117 new master-report rows distributed across 9 sections; appended in-place. Total now ~250 format rows. Hand-curated mechanism descriptions per row (no LLM-only generation).
- [x] Updated `scripts/audit-corruption-report` `slug_to_label` map with 79 new aliases. Audit clean: 110 formats, 0 drift, 0 missing-row.
- [x] Added Action Item #13: APE / WavPack MD5 not verified — partial validation gap. Both formats embed audio-MD5 but validators only see the metadata. Per Peter's instruction, recorded as a deferred multi-session implementation task because full APE entropy decoder + WavPack decorrelator + MD5 over reconstructed PCM is several days each. Tiny existing ground-truth samples (52 B APE, 2 KB WavPack) are also a sample-sourcing dependency.
- [x] Fixed sample mis-pick for KMZ (sweep had selected `sample.3mf` because it was the largest file in the kmz dir — re-swept against the real `sample.kmz`, 95% sniper).
- [x] Fixed sample mis-pick for VP8 (sweep had selected `sample.webm` which validates as Matroska, not raw VP8 — re-swept against `sample.ivf`, 1% sniper).
- [x] format_roundtrip CLI test still green (219/219 pass).
- [x] master_report_drift CLI test still green.
- [x] Updated preamble to note 117-format wave; many new rows are sniper-only because their ground-truth samples are < 4 KB (the shotgun overwrite size).

Deferred (out-of-scope per dispatch brief):
- [ ] Source larger ground-truth samples for APE, WavPack, 7z, ZIP, Gzip, Bzip2, XZ, Zstd, RAR, CAB so shotgun mode can run (current samples all < 4 KB).
- [ ] Implement full APE / WavPack MD5 verification (Action Item #13). Requires APE entropy decoder + WavPack decorrelator/range decoder.
- [x] APE structural rigor + sample upgrade (2026-04-26): replaced header-only with descriptor + header + seek-table parsing (monotonicity, audio-region bounds, sample-rate/channels/BPS sanity, version range). Sample upgraded to real luckynight.ape (v3990, 6.5 MB) for the Zig in-tree test. Synthetic 16 KB `corpus_synthetic.ape` added for sweeps (80 short frames giving ~2.4% structural coverage). Sniper 0%→3%, shotgun 0%→5%. Full-decoder-driven CRC32 + MD5 verification still pending — see "Implement full APE / WavPack MD5 verification" above.
- [ ] **APE deep decoder integration (multi-session).** Two viable paths:
  1. **Vendor FFmpeg apedec.c** as `deps/apedec/` with a small C shim that absorbs the AVCodecContext/AVPacket/AVFrame API. Requires extracting subset of `get_bits.h`, `bytestream.h`, `unary.h`, `lossless_audiodsp.h`, `bswapdsp.h`, `crc.{h,c}`, `mem.{h,c}`, `intreadwrite.h`, `bswap.h`, `attributes.h`, `macros.h`, `error.h`, `common.h` — ~7500 LOC of FFmpeg internals. License: LGPL-2.1 (compatible per existing libraw integration).
  2. **Pure Zig port** of apedec.c (~2000 LOC): range coder, predictor IIR (3 versions: 3800/3930/3950), entropy decoder (5 mode-pairs across versions: 0000/3860/3900/3930/3990), four prediction filters per channel layout, `lossless_audiodsp` (vector adds), per-frame CRC32 over decoded PCM. Tests: per-frame CRC verification + descriptor MD5-over-PCM verification; ground-truth dataset of FFmpeg fate-suite luckynight-mac{388,389b1,391b1}-c{2,4}000.ape (decode-clean) + corruption sweeps showing >95% sniper/shotgun.
  - libdemac (Rockbox) is GPL-2-only — incompatible with project's BSL.
- [ ] Directory-format sweep harness for bagit, git_repository, macos_app/bundle/framework, spotlight, band, logicx (single-file `corruption-experiment` can't probe these).
- [ ] Source samples for: ivf, ogv, song, sevenz, sitx, qbb, msi, ppt, dbf, pcap, pcapng, gcode, esd, llvm_diag, llvm_pch, msgpack, br, rpm — 18 enum formats with neither ground truth nor sweep.

### Pre-Launch Corruption Detection Audit (2026-04-23)

Findings from the 6-agent audit captured in `docs/corruption-detection-report.md`. Priority order.

P0 — validator bugs hiding detection:
- [x] PDF: make `toleratedPdfImageFailures` opt-in via `VALIDATE_PDF_TOLERANT=1`; default strict. Landed 2026-04-23 (commit c304f36). Shotgun on NASA sample 0% → 67%, on Alice PDF 0% → 89%. Sniper stays ~0% (intrinsic PDF limit).
- [x] BMP 0%/0% — RECLASSIFIED to docs-only. BMP spec has no data checksums; 0/400 at ±0.5% CI confirmed fundamental. `FORMAT_VERIFICATIONS.md` row corrected from "Full Decode" to "Structure" (2026-04-23).
- [ ] NRW/NEF/CR2/ARW preview-JPEG decode — tried two approaches, both insufficient: (a) `libraw_unpack_thumb` only extracts JPEG bytes without decoding them; (b) DNG-style SOI-scan-and-libjpeg-turbo-decode false-positives on Nikon NRW sensor noise (16 KB threshold insufficient). Third attempt needs to parse the TIFF IFD for the canonical `PreviewImageStart`/`PreviewImageLength` tag (or equivalent MakerNote) and decode only at that offset. Helper `scanAndValidatePreviewJpegs` in image_validators.zig is retained for the IFD-based implementation. Expected lift: 0% → ~15-30% shotgun on NEF/NRW/CR2/ARW. Currently clean + format_roundtrip is green; this is a deferred detection-quality upgrade, not a regression.
- [ ] CLI print bug — DEFERRED to post-launch as architectural. Root cause: `ValidationDepth` enum has only `.structural` / `.full`; needs a third `.bounds_verified` variant + audit of every validator's return. Affects BMP, most RAW, video containers with weak codecs. Interim honesty comes from the master report's per-format detection numbers.

P1 — sample replacements (validator already strong, sample picks a weak codec path):
- [x] Added `ground_truth_examples/mov/jellyfish_h264.mov` (H.264, 1.0 MB). MOV shotgun 6% → **75%** (2026-04-23). Generated via ffmpeg copy-muxing from jellyfish mp4.
- [x] Added `ground_truth_examples/webm/jellyfish_vp9_opus.webm` (VP9 + synthesized Opus, 1.8 MB). WebM shotgun 2% → **55%** (2026-04-23). Opus audio CRC drives detection; full VP9 byte-validation needs MKV validator work (see P2 item 12).
- [x] Added `ground_truth_examples/avi/jellyfish_mjpeg.avi` (MJPEG, 8.5 MB). AVI shotgun 4% → **93%** (2026-04-23). Generated via ffmpeg transcode.
- [x] Added `ground_truth_examples/psd/rle_plasma.psd` (1.8 MB, RLE-compressed via ImageMagick). PSD shotgun 7% → **50%** (2026-04-23). Exercises the RLE scanline-decode path in `validatePsdDeep`.
- [x] Added `ground_truth_examples/exr/zip_plasma.exr` (388 KB, ZIP-compressed via ImageMagick). EXR shotgun stays 100% on the larger sample; zlib decompression path now exercised. Sniper 6% → 1% reflects file-size effect (structural bytes are a smaller fraction of the larger file) — honest, not a regression.

P1 — ground-truth sourcing (all landed 2026-04-23):
- [x] DOCX — Apache Tika `testWORD.docx` (13 KB). Sniper 78% → **87%**, shotgun N/A → **100%**.
- [x] XLSX — Apache Tika `test-columnar.xlsx` (10 KB). New: sniper **82%** / shotgun **100%**.
- [x] PPTX — Apache Tika `testPPT.pptx` (36 KB). New: sniper **93%** / shotgun **100%**.
- [x] ODT — Apache Tika `testODFwithOOo3.odt` (24 KB). New: sniper **96%** / shotgun **100%**.
- [x] ODS — Apache Tika `LibreOfficeCalc_ods_1.3.ods` (8.8 KB). New: sniper **88%** / shotgun **100%**.
- [x] ODP — Apache Tika `LibreOfficeImpress_odp_1.3.odp` (24 KB). New: sniper **97%** / shotgun **100%**.
- [x] RTF — Apache Tika `testRTFEmbeddedFiles.rtf` (1.2 MB). New: sniper 0% / shotgun **92%** (RTF spec has no checksums; shotgun catches brace/control-word breakage).
- [x] EML — Apache Tika `testRFC822-big` (6.6 KB). New: sniper 0% / shotgun 3% (EML has no format-level checksums).
- [x] MBOX — synthesized from 4 concatenated Tika RFC822 samples (17 KB). New: sniper 0% / shotgun 0% (plain-text concat, no integrity).
- [x] QOI — generated locally via ImageMagick plasma (23 KB). New: sniper 0% / shotgun 0% (fundamental: QOI opcodes have no per-opcode checksum).
- [x] ICO — generated locally via ImageMagick multi-res (232 KB). New: sniper **63%** / shotgun **70%**.
- [x] SVG — hand-written + awk-procedural paths (30 KB). New: sniper 45% / shotgun **99%**.
- [ ] Pages — still needs Peter to author locally; no permissive public corpus exists.

P2 — deeper validation where format permits:
- [x] WOFF/WOFF2 origChecksum verification after Flate / Brotli decompress. Already implemented in `font_validator.zig:370` (zlib) / `font_validator.zig:510` (Brotli). Stale sweep data 2026-04-23: WOFF 100%/100%, WOFF2 49%/100%. Master report refreshed.
- [ ] RAF preview-coverage diagnostic: add a smaller Fuji RAF to the sweep alongside the 208 MB one so preview-decode coverage shows up distinctly in the table
- [x] VP9-in-MKV full-decode: libvpx 1.14.1 integrated 2026-04-24 (commit f8c38ec8). WebM VP9+Opus shotgun 55% → 78%, sniper 0% → 86%. Uses `vpx_codec_decode` per frame.
- [x] VP8-in-MKV full-decode: same libvpx integration (f8c38ec8). WebM VP8 shotgun 2% → 90%, sniper 0% → 88%. Required `VP8D_GET_FRAME_CORRUPTED` control query — VP8 decoder runs error concealment that silently patches bit flips and returns VPX_CODEC_OK without that explicit query.
- [x] Theora-in-OGG full-decode: libtheora 1.2.0 integrated 2026-04-23 (commit 8614b97e). MKV codec_private corruption now caught (was tolerated). OGG-Theora unchanged at 100%/100% (already CRC-driven).

P2 — ground-truth samples uncovered as broken by format_roundtrip (2026-04-23):
- [x] AC3: removed malformed `TomorrowNeverDies-2.1-48khz-192kbit.ac3`. Corruption-sweep now picks `Canyon-5.1-48khz-448kbit.ac3` (2.1 MB) — measured 100%/100% against a genuinely-valid clean file. Old number was a false positive from every trial inheriting the already-failing state.
- [x] .band (GarageBand): replaced 128-byte stub with a proper macOS bundle directory containing minimal plist `projectData`, matching what `validateGarageBandBundle` requires. `.band` is a directory format, so format_roundtrip auto-skips the corruption assertion.
- [x] .reason (Reason): replaced with a 96-byte hand-crafted file containing the exact "Propellerheads Reason Song File\x1a" 32-byte magic required by `validateReason`, followed by a minimal IFF FORM chunk.
P2 — regeneration tooling:
- [x] Drift detector landed 2026-04-25 (commits d48128a0 + 68de05cf). `scripts/audit-corruption-report` walks the TSVs and compares against the report's claimed per-format numbers; surfaces any drift > ±2pp. `tests/cli/master_report_drift` wires it into `./test` so any future TSV refresh that doesn't propagate to the prose fails CI. 101/101 formats verified clean. Full regen-from-TSVs script is still future work but the audit detector closes the immediate drift hazard.

P2 — additional fixes from launch-prep audit (2026-04-25):
- [x] CR2 detection: format detector mis-classified CR2 as plain TIFF because `detectTiffSubformat` lacked a CR2 branch (commit 4db099de).
- [ ] CR2 corruption-detection still 0%/0% even with format-detection fix and the IFD preview decode landing in agent 3's a2542f5. Investigation: the canon_eos_40d_sraw2.cr2 sample has only 3 FFD8FFXX SOI sequences in its 5.8 MB body, all marker `c4` (DHT). The IFD preview decoder may either reject FFD8FFC4 (validateJpegBufferForDng's marker whitelist is DB + E0..EF) or accept it but the JPEG is Huffman-resilient at the bit-flip level. Needs targeted instrumentation.
- [x] CLI `--test-coverage` defaults: sniper+shotgun (was all 6), 1000 rounds (was 100). Statistically meaningful at first run; opt back into legacy via `--modes all` or `--modes everything`. Commit b4388f1e.
- [x] README VP8 error-concealment callout (commit 5b131e27) — concrete launch-copy demonstrating the silent-corruption pattern validate exists for.
- [x] Adaptive early-stop on `--test-coverage`: every 100 rounds, compute 95% Wilson CI; if all enabled modes at or under `--early-stop-radius` (default 0.025), break. PNG/BMP early-stop ~700-800 rounds; `--no-early-stop` runs full cap. New CLI flags + FFI param + KV result keys (requested_rounds, early_stopped, early_stop_radius). 2026-04-25, commit (pending).

### Statistical Corruption Detection for Raw Audio/Video Data
For formats without checksums (AU, AMR, CAF, DPX, etc.), use heuristic analysis to detect likely corruption in raw data sections:

- **Temporal discontinuity detection**: sliding-window variance to flag sudden uncorrelated jumps in sample values (real audio has temporal correlation; corruption doesn't)
- **Single-sample outlier with bit-flip diagnosis**: compute statistical unlikelihood of sample[n] given a window of preceding samples. If it exceeds a tolerance AND flipping any single bit in that sample's bytes produces a value that IS statistically probable (fits the local trend), report it as a diagnosed single-bit error with the exact bit identified. This is forensic-grade — not just "something's wrong" but "bit 15 at offset 0x4A02 is flipped."
- **Zero-run analysis**: extended silence in the middle of non-silent audio is suspicious; context-aware detection distinguishing track gaps from corruption
- **Stuck-value detection**: runs of identical non-zero samples (register latch / bus error patterns)
- **Spectral anomaly**: FFT windows to detect unnaturally flat spectra (white noise from bit errors) or DC offsets
- **Sector-aligned weighting**: at known sample rate + bit depth + channels, calculate `corrupted_samples = sector_size / (channels * bytes_per_sample)` for common physical media sector sizes (512B HDD, 2048B DVD, 2352B CD, 4KB/16KB SSD). Statistical anomalies that are approximately sector-width or a multiple (±16 bytes tolerance for header offsets and controller scatter/gather) are weighted as extra-suspect — this is the signature of physical media failure, not encoding artifact.
- **Synthesized audio caveat**: square waves, FM synthesis, and other digital sources CAN have extreme single-sample transitions intentionally. Outlier detection should be weighted by surrounding context (±10 samples smooth = suspicious spike; surrounding samples also extreme = intentional waveform). Sensitivity should be configurable.
- Report as WARN (heuristic, not certain) rather than FAIL
- Applicable to: AU, AMR, CAF, WAV (raw PCM), AIFF, DSD, DPX (raw pixel data), PAM/PBM/PGM/PPM (raw pixel data)
- This would be a genuinely novel validation tier between structural and full
- Module: `src/core/statistical_corruption.zig` with configurable sensitivity
