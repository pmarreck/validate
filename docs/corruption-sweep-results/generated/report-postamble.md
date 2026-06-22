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
