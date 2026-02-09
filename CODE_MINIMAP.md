# validate Code Minimap

Purpose: quick map of project structure and file purposes. This file should only describe structure and purpose (no issues/TODOs).

## Repository Layout
```
./
├── .github/workflows/  CI workflows (cross-platform builds)
├── src/                Zig validation core
├── ffi/                C ABI exports + header
├── cli/                C CLI wrapper (validate)
├── tests/              Test assets and integration tests
├── bench/              Benchmarks
├── fuzz/               Fuzz targets
├── deps/               Zig dependency build helpers
├── build               Build+test wrapper (nix develop aware)
├── test-windows         Windows test runner via CrossOver/Wine
├── build.zig           Zig build configuration
├── build.zig.zon       Zig dependency lock
├── flake.nix           Nix dev shell
└── *.md                Project documentation
```

## Core (src/)
| Path | Purpose |
|------|---------|
| `src/core/` | Validation logic and format support |
| `src/build/` | Zig build helpers (libtool bundling) |
| `src/core/path_validation.zig` | Parallel path validation with bundle-aware enumeration (.git directories validated as units, not recursed into); honors `MAX_FILES` |
| `src/core/format_validation.zig` | Format validation logic incl. bundle detection (`detectBundleType()`, `isBundleDirectory()`), git repository deep validation routing, ZIP deep validation (central-directory parsing), PDF image lenience (JBIG2/DCT warnings), XML undefined-entity tolerance, and telemetry envs (`ZIP_TELEMETRY`, `PDF_TELEMETRY`) |
| `src/core/git_validator.zig` | Git repository validation using SHA-1 checksums for loose objects, pack files, and index files |
| `src/core/video_validator.zig` | Video container parsing + codec decode validation (MP4/MKV/AVI), MKV byte-coverage with mixed NAL-length handling and debug envs (`MKV_BYTE_DEBUG`, `MKV_BYTE_DEBUG_OUT`, `MKV_BYTE_DEBUG_FRAME_OUT`) |
| `src/core/font_validator.zig` | Standalone font validation (TTF/OTF/CFF/Type1) with checksum fallback to structural parsing for clearer errors |
| `src/core/pdf_font_validator.zig` | Extracts/validates embedded PDF fonts using strict checksums while reporting warnings instead of failing PDFs |
| `src/core/pdf_image_validator.zig` | PDF embedded image extraction and validation (JPEG, JBIG2, JPEG2000, CCITT) |
| `src/core/pdf_xref_parser.zig` | PDF xref table/stream parser for O(M) object lookup (traditional tables + xref streams + /Prev chain) |
| `src/core/mp4_box_parser.zig` | Shared MP4/ISOBMFF box parsing utilities (readMp4BoxHeader, findChildBox) |
| `src/core/video_audio_validator.zig` | MP4/MKV audio+video stream validation (AAC, ALAC, MP3, FLAC, AC-3 in containers) |
| `src/core/h264_syntax_validator.zig` | Pure Zig H.264 NAL/SPS/PPS/slice header parser with full VUI and extension support |
| `src/core/h264_cavlc_tables.zig` | H.264 CAVLC entropy decoder (coeff_token, total_zeros, run_before, level VLC) |
| `src/core/h264_cabac_engine.zig` | H.264 CABAC arithmetic engine with context model initialization |
| `src/core/h264_cabac_tables.zig` | H.264 CABAC tables (rangeTabLPS, transIdx, context init values) |
| `src/core/h265_validator.zig` | Pure Zig H.265/HEVC NAL unit parser with VPS/SPS/PPS validation |
| `src/core/av1_obu_validator.zig` | Pure Zig AV1 OBU structural validator (sequence header, frame header, tile group) |
| `src/core/vp9_syntax_validator.zig` | Pure Zig VP9 frame header parser |
| `src/core/heif_container_parser.zig` | HEIF ISOBMFF meta-box parsing (ftyp/hdlr/pitm/iinf/iloc/iprp) for HEIC and AVIF |
| `src/core/heic_validator.zig` | HEIC validation: HEIF container → hvcC NALs → h265_validator |
| `src/core/avif_validator.zig` | AVIF validation: HEIF container → av1C OBUs → av1_obu_validator |
| `src/core/aac_syntax_validator.zig` | AAC-LC bitstream validator (raw AU, ADTS, LATM/LOAS) with Huffman spectral decode |
| `src/core/aac_huffman_tables.zig` | AAC Huffman trees (scalefactor + 11 spectral codebooks) and SWB offset tables |
| `src/core/mpeg_ts_parser.zig` | MPEG-TS demuxer with PAT/PMT CRC-32, CC tracking, PES assembly + stream dispatch |
| `src/core/mp3_decode_validator.zig` | MP3 frame decoder (file and buffer-based) with Huffman + IMDCT validation |
| `src/core/ebml_parser.zig` | EBML/Matroska container parser with CRC-32 verification |

## FFI (ffi/)
| Path | Purpose |
|------|---------|
| `ffi/c_api.zig` | C ABI surface for validation |
| `ffi/validate_core.h` | C header for the ABI |

## CLI (cli/)
| Path | Purpose |
|------|---------|
| `cli/main.c` | CLI wrapper around the C FFI, SLOW warnings, and memory telemetry (env `MEM_TELEMETRY`) |

## Tests (tests/)
| Path | Purpose |
|------|---------|
| `tests/fixtures/` | Validation test fixtures |
| `tests/cli/` | CLI integration tests (bash) |

## Documentation
| File | Purpose |
|------|---------|
| `PLAN.md` | Checkbox-only work list |
| `PROJECT_OVERVIEW.md` | Goals and terminology |
| `RULES.md` | Non-negotiable project rules |
| `DOCUMENTATION_GUIDE.md` | Doc locations and writing rules |
| `ROADMAP.md` | Fairly certain future goals |
| `PERF_EXPERIMENTS.md` | Performance experiment log and results |
| `ZIG_RECENT_API_CHANGES_2025.md` | Zig 0.14–0.15 API quick reference for current code |
