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
| `src/core/thread_pool.zig` | Thread pool with O(1) ring-buffer work queue (head/len circular buffer with doubling growth), replacing prior O(n) ArrayList dequeue |
| `src/core/format_validation.zig` | Format validation logic incl. bundle detection (`detectBundleType()`, `isBundleDirectory()`), git repository deep validation routing, ZIP deep validation (central-directory parsing), PDF image lenience (JBIG2/DCT warnings), XML undefined-entity tolerance, expanded magic/extension handling (e.g., EXR, MPEG-ES), pure-Zig BinHex/HQX validation (alphabet decode, RLE, CRC16), HDF5 Jenkins lookup3 superblock+OHDR checksum verification (v2/3 → `.full`), Parquet page CRC-32 verification, and telemetry envs (`ZIP_TELEMETRY`, `PDF_TELEMETRY`) |
| `src/core/codec_utils.zig` | Shared codec utilities: `Crc32Normal(init,xorout)` comptime-parameterized MSB-first CRC-32 (instantiated as `Crc32Ogg`/`Crc32Mpeg2`/`Crc32Bzip2`), `crc16Ccitt` (RAR4+BinHex), `removeEmulationPreventionBytes` (H.264/H.265 RBSP), `findAnnexBStartCode`, `readLeb128`, `readLe`/`readBe` endian helpers. Consumed by: ebml_parser, ogg_validator, mpeg_ts_parser, bzip2, archive_validators, format_validation, h264_syntax_validator, h265_validator, av1_obu_validator, video_validator |
| `src/core/i18n/mod.zig` | i18n locale registry/switching, locale detection from env/CLI prefixes, translated string accessors, and cross-locale CLI/env alias maps (30 locales) |
| `src/core/i18n/{bn,hi,pa,ps,sw,ta,th,ur}.zig` | Locale data modules for Bengali/Hindi/Punjabi/Pashto/Swahili/Tamil/Thai/Urdu including core UI strings, full format description catalog, and error/warning translation maps |
| `src/core/git_validator.zig` | Git repository validation using SHA-1 checksums for loose objects, pack files, and index files |
| `src/core/video_validator.zig` | Video container parsing + codec decode validation (MP4/MKV/AVI), MKV byte-coverage with mixed NAL-length handling and debug envs (`MKV_BYTE_DEBUG`, `MKV_BYTE_DEBUG_OUT`, `MKV_BYTE_DEBUG_FRAME_OUT`) |
| `src/core/font_validator.zig` | Standalone font validation (TTF/OTF/CFF/Type1) with checksum fallback to structural parsing for clearer errors |
| `src/core/pdf_font_validator.zig` | Extracts/validates embedded PDF fonts using strict checksums while reporting warnings instead of failing PDFs |
| `src/core/pdf_image_validator.zig` | PDF embedded image extraction and validation (JPEG, JBIG2, JPEG2000, CCITT) |
| `src/core/pdf_xref_parser.zig` | PDF xref table/stream parser for O(M) object lookup (traditional tables + xref streams + /Prev chain) |
| `src/core/mp4_box_parser.zig` | Shared MP4/ISOBMFF box parsing utilities (readMp4BoxHeader, findChildBox) |
| `src/core/video_audio_validator.zig` | MP4/MKV audio+video stream validation (AAC, ALAC, MP3, FLAC, AC-3 in containers) |
| `src/core/archive_validators.zig` | Archive/compression validation (ZIP/Gzip/Bzip2/XZ/Zstd/RAR/CPT/7z/TAR/PAR2/WARC), including deep ZIP CRC checks, PAR2 packet MD5 verification, `rarz` in-memory RAR validation, `compact_pro` C FFI-backed CPT validation, and WARC deep validation with SHA-1 digest verification (Base32 decode + WARC-Block-Digest) |
| `src/core/rar_validator.zig` | Legacy external-tool RAR deep-validation helper (`unrar`/`7z`/`bsdtar`) retained in tree; primary runtime path now uses `rarz` via `archive_validators.zig` |
| `src/core/h264_syntax_validator.zig` | Pure Zig H.264 NAL/SPS/PPS/slice header parser with full VUI and extension support |
| `src/core/h264_cavlc_tables.zig` | H.264 CAVLC entropy decoder (coeff_token, total_zeros, run_before, level VLC) |
| `src/core/h264_cabac_engine.zig` | H.264 CABAC arithmetic engine with context model initialization |
| `src/core/h264_cabac_tables.zig` | H.264 CABAC tables (rangeTabLPS, transIdx, context init values) |
| `src/core/h265_validator.zig` | Pure Zig H.265/HEVC NAL unit parser with VPS/SPS/PPS validation |
| `src/core/av1_obu_validator.zig` | Pure Zig AV1 OBU structural validator (sequence header, frame header, tile group) |
| `src/core/vp9_syntax_validator.zig` | Pure Zig VP9 frame header parser |
| `src/core/heif_container_parser.zig` | HEIF ISOBMFF meta-box parsing (ftyp/hdlr/pitm/iinf/iloc/iprp/iref) for HEIC and AVIF; supports grid images via iref dimg tile reference resolution |
| `src/core/heic_validator.zig` | HEIC validation: HEIF container → hvcC NALs → h265_validator; supports grid (tiled) images by validating each tile's H.265 bitstream via iref dimg references |
| `src/core/avif_validator.zig` | AVIF validation: HEIF container → av1C OBUs → av1_obu_validator; supports grid (tiled) images by validating each tile's AV1 bitstream via iref dimg references |
| `src/core/aac_syntax_validator.zig` | AAC-LC bitstream validator (raw AU, ADTS, LATM/LOAS) with Huffman spectral decode |
| `src/core/aac_huffman_tables.zig` | AAC Huffman trees (scalefactor + 11 spectral codebooks) and SWB offset tables |
| `src/core/mpeg_ts_parser.zig` | MPEG-TS demuxer with PAT/PMT CRC-32, CC tracking, PES assembly + stream dispatch |
| `src/core/mp3_decode_validator.zig` | MP3 frame decoder (file and buffer-based) with Huffman + IMDCT validation |
| `src/core/error_messages.zig` | 25 comptime error message template functions (failedToRead, truncated, invalidSignature, etc.) replacing ~2076 string literals |
| `src/core/text_format_validators.zig` | Text format validation (JSON, CSV, TOML, INI, XML, RTF, HTML, KML, plain text, Unicode) |
| `src/core/scientific_validators.zig` | Scientific format validation (FITS, DICOM, NetCDF, FASTA, FASTQ) with honest depth reporting |
| `src/core/music_validators.zig` | Audio format validation (WAV, FLAC, MP3, OGG, AIFF, WavPack, APE, DSD, AC3, EAC3, MIDI, Tracker); WAV/AIFF float PCM deep validation with IEEE 754 NaN/Inf corruption detection |
| `src/core/movie_validators.zig` | Video container validation (MP4, MKV, AVI, MOV, FLV, WebM, SWF, ASF, DV, IVF) with depth downgrade on unvalidated audio; IVF deep validation via VP9/AV1 codec dispatch; FLV deep validation via H.264 AVCC→Annex B + AAC stream decode |
| `src/core/image_validators.zig` | Image format validation (PNG, JPEG, GIF, BMP, TIFF, WebP, JXL, SVG, EXR, PSD, PAM, DPX, QOI, TGA, DNG, ICO); ICO deep validation dispatches embedded PNG entries to CRC-32 verification |
| `src/core/cad_3d_validators.zig` | 3D/CAD format validation (DWG, DXF, STEP, STL, OBJ, PLY, glTF/GLB, Blender); PLY binary deep validation with float NaN/Inf + face index range checking |
| `src/core/creative_validators.zig` | Creative suite validation (Premiere, InDesign, IDML, FCPXML, DaVinci, Sketch, AI, EPS, AEP) |
| `src/core/email_validators.zig` | Email format validation (EML, MBOX) |
| `src/core/executable_validators.zig` | Binary executable validation (ELF, Mach-O, COFF, Wasm, AR) |
| `src/core/pe_validator.zig` | Windows PE executable validation (DOS header, COFF, optional header, section table) |
| `src/core/daw_validators.zig` | DAW project validation (FLP, ALS, RPP) |
| `src/core/game_validator.zig` | Game ROM validation (NES, SNES, N64, GB, GBA, NDS, Genesis, CHD) |
| `src/core/ebml_parser.zig` | EBML/Matroska container parser with CRC-32 verification (uses `std.hash.Crc32` via codec_utils consolidation) |

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
| `tests/cli/` | CLI integration tests (bash), including archive discrimination checks (`rar_validation`, `cpt_validation`) over valid + 5 deterministic corrupted fixtures |
| `scripts/strict_format_coverage` | Deterministic strict coverage harness: enumerates `hasValidator()` formats, maps ground-truth samples (including extension-aware KMZ mapping), validates valid-path behavior, runs 5 seeded non-magic corruption checks (with per-format protected prefixes, including HQX envelope protection), and classifies failures via `corruption_opacity` policy |

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
| `inbox/strict_format_coverage.tsv` | Machine-readable strict per-format audit output (`format`, sample path, valid result, C1..C5, status, opacity, notes) |
| `inbox/strict_format_coverage.md` | Human-readable strict per-format audit checklist/report generated by harness |
| `scripts/corruption_opacity.tsv` | Source-controlled per-format corruption-opacity policy map consumed by strict harness (`transparent` default, `mixed`, `opaque`) |
