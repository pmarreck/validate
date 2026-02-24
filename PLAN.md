# Plan

Checkbox-only list of specific work items. Keep recent completions with EST timestamps; prune older completed items regularly.

## Active

### Depth Honesty Audit
- [x] Fix ~50 validators dishonestly claiming `.full` depth when they only do header/structural checks or parse opaque text with no integrity mechanism (2026-02-23 EST)
- [ ] Future: Add `best_effort` tier to distinguish "parsed every byte, no integrity mechanism" from "only checked headers"

### Codebase Consolidation
- [x] Consolidate duplicated codec utilities (CRC-32 x4, CRC-16, RBSP, start codes, LEB128, endian helpers) into shared `codec_utils.zig`; replaced across 10 files, net -285 lines (2026-02-22 EST)

### Code Review Fixes (2026-02-22)
- [x] P1: Replace thread pool O(n^2) dequeue with O(1) ring buffer (2026-02-22 EST)
- [x] P2: Fix depth-vs-warning asymmetry in FITS/DICOM/MP4/MPEG-1/2 validators (2026-02-22 EST)
- [x] P3: Fix dangerous silent `catch {}` blocks in mpeg_ts_parser + video_audio_validator (2026-02-22 EST)
- [x] P5: Remove dead validateRarDeep wrapper + unused rar_validator import (2026-02-22 EST)
- [x] P6: Deduplicate build.zig linkLibrary calls; fix shared lib missing cj5/libraw/7z deps (2026-02-22 EST)
- [x] P8: Fix ZIP buffer validator depth, document CCITT Group 3 2D approximation (2026-02-22 EST)
- [x] P4: Add 52 tests across 5 previously untested validator files (executable, email, PE, CAD/3D, creative) (2026-02-22 EST)
- [ ] P7: Further extraction of format_validation.zig god file (deferred)

### Strict Format Coverage Closure (Entropy Shield dependency)
- [x] Add deterministic strict coverage harness (`scripts/strict_format_coverage`) using `hasValidator()` as source-of-truth (2026-02-18 22:50 EST)
- [x] Generate strict baseline report artifacts (`inbox/strict_format_coverage.tsv`, `inbox/strict_format_coverage.md`) (2026-02-18 22:50 EST)
- [ ] Add/curate missing ground-truth samples for 57 missing supported formats
- [x] Add new ground-truth samples that validate cleanly for `av1`, `doc`, `exr`, `mpeg_es`, `macho`, `macho_fat`, `fcpxml`, `prproj`, `type1` (2026-02-20 EST)
- [x] Resolve invalid baseline sample in strict audit (`rar` now validates and rejects 5/5 seeded corruptions) (2026-02-20 EST)
- [x] Add `corruption_opacity` map + strict harness categorization (`opaque` / `mixed` allowable statuses) (2026-02-20 EST)
- [x] Improve transparent-format corruption discrimination (PAR2 packet MD5 validation + ZIP-subformat deep routing + opacity review reduced strict hard-fails to 0) (2026-02-20 EST)
- [x] Add pure-Zig BinHex/HQX validation (alphabet decode + RLE + header/data/resource CRC16), fixture coverage (`ground_truth_examples/hqx/sample.hqx`), and strict-harness protected prefix for non-magic corruption mutation (2026-02-20 EST)
- [x] Add Compact Pro (`.cpt`) strict fixture coverage: known-good ground-truth sample + 5 deterministic non-magic corruptions + CLI discrimination test (`tests/cli/cpt_validation`) (2026-02-21 EST)
- [x] Refresh RAR CLI discrimination test and seeded corrupted fixtures for `rarz` backend (remove legacy external-tool gate; assert 5 deterministic corrupted fixtures fail) (2026-02-21 EST)
- [x] Expand i18n locale matrix to 30 locales by adding bootstrap locales (`bn`, `hi`, `pa`, `ps`, `sw`, `ta`, `th`, `ur`) with locale parsing + alias-map integration + compile-time coverage checks (2026-02-20 EST)
- [x] Implement core UI translations (status/summary/progress/help + localized `--lang` alias) for new locales `bn`, `hi`, `pa`, `ps`, `sw`, `ta`, `th`, `ur`; add i18n tests for RTL coverage and localized labels (2026-02-20 EST)
- [x] Carry new locales `bn`, `hi`, `pa`, `ps`, `sw`, `ta`, `th`, `ur` through remaining i18n layers: full `format_descriptions` + `error_translations` + `warning_translations` (machine-assisted), with regression tests for translated format/error/warning output (2026-02-20 EST)

### HIGH PRIORITY: Hexagonal Architecture FFI Refactor
- [x] Add validate(), validate_batch(), free_result(), get_default_threads() to C FFI (2026-01-30)
- [x] Verify new FFI functions compile and basic tests pass (2026-01-30)
- [x] Refactor cli/main.c to use new validate_batch() instead of direct Zig imports (2026-01-30)
- [x] Add directory enumeration to CLI (CLI enumerates, passes paths to validate_batch) (2026-01-30)
- [x] Make CLI format-agnostic (removed git-specific logic, CLI is now a dumb pipe) (2026-01-30)
- [x] Parallel PDF image validation using thread pool (36% faster on ~/Documents/Books) (2026-01-30)
- [x] Remove es_* prefix from all FFI functions (project is validate, not entropy_shield) (2026-01-31)
- [x] Deprecate old handle-based API (format_validator_create, etc.) - add DEPRECATED comments (2026-02-01 ~21:00 EST)
- [x] Remove deprecated handle-based API and implement KV-US-RS format (2026-02-02)

### Bundle Validation (directories as single validation units)
- [x] Add BundleType enum and detectBundleType() to format_validation.zig (2026-01-31)
- [x] Add bundle patterns API to C FFI (validate_get_bundle_patterns) (2026-01-31)
- [x] Route .git directories to existing git_validator.zig via validateGitRepositoryDeep() (2026-01-31)
- [x] Add bundle-aware enumeration to path_validation.zig (enumerateWithBundles) (2026-01-31)
- [x] Add bundle detection to CLI enumerate_path() and main loop (2026-01-31)
- [x] Add TDD tests for bundle validation (Zig unit tests + CLI bash tests) (2026-01-31)
- [x] Add macOS bundle validation (.app, .framework, .bundle) (2026-02-02)
- [x] Return continuable error for unknown directory types (2026-02-02)
- [x] Bundle validation complete (see ARCHITECTURE.md)

### HEIC/Intel Crash Investigation — RESOLVED via pure-Zig
- [x] Replaced libheif/libde265 with pure-Zig heif_container_parser + h265_validator (2026-02-07)
- Note: Original crash was SIGABRT in C library on Intel. Moot now that C deps are removed.

### Codebase Refactoring (from 2026-02-09 review)
- [x] **Break out `format_validation.zig`** into separate validator files:
  - [x] Extract PE/Windows executable validator → `pe_validator.zig` (2026-02-09)
  - [x] Extract text format validators (JSON, CSV, TOML, INI, XML, RTF, HTML, KML, plain text, Unicode) → `text_format_validators.zig` (2026-02-09)
  - [x] Extract scientific format validators (FITS, DICOM, NetCDF, FASTA, FASTQ) → `scientific_validators.zig` (2026-02-09)
  - [x] Extract game ROM validators → `game_validator.zig` (2026-02-09)
  - [x] Extract DAW project validators → `daw_validators.zig` (2026-02-09)
  - [x] Extract video/movie format validators → `movie_validators.zig` (MP4, MKV, AVI, MOV, FLV, WebM, SWF, MPEG-TS/PS/ES, IVF) (2026-02-09)
  - [x] Extract music/audio format validators → `music_validators.zig` (WAV, FLAC, MP3, OGG, AIFF, WavPack, APE, DSD, AC3, EAC3, MIDI, Tracker) (2026-02-09)
  - [x] Extract photography/image format validators → `image_validators.zig` (PNG, JPEG, GIF, BMP, TIFF, WebP, JXL, SVG, EXR, PSD, JPEG2000, JBIG2, HEIC, AVIF, ICO, QOI, TGA, DNG) (2026-02-09)
  - [x] Audit remaining large functions — see session audit (2026-02-09)
  - [x] Extract archive/compression validators → `archive_validators.zig` (ZIP, Gzip, Bzip2, XZ, Zstd, RAR, 7z, Tar, PAR2, WARC) (2026-02-10)
  - [x] Extract 3D/CAD validators → `cad_3d_validators.zig` (DWG, DXF, STEP, STL, OBJ, PLY, glTF/GLB, Blender) (2026-02-10)
  - [x] Extract creative suite validators → `creative_validators.zig` (Premiere, InDesign, IDML, FCPXML, DaVinci, Sketch, AI, EPS, AEP) (2026-02-10)
  - [x] Extract email validators → `email_validators.zig` (EML, MBOX) (2026-02-10)
  - [x] Extract executable/binary validators → `executable_validators.zig` (ELF, Mach-O, COFF, Wasm, AR) (2026-02-10)
- [x] **Extract shared MP4 box parser** — `mp4_box_parser.zig` with `Mp4Box`/`readMp4BoxHeader`/`findChildBox` (2026-02-09)
- [x] **Remove VideoToolbox dead code** — removed field, function, CLI branch, FFI key across 6 files (2026-02-09)
- [x] **Remove ~995 MB of orphaned deps**: libheif, libde265, dav1d, openh264, libvpx, libfdk-aac + src mirrors (2026-02-09)
- [x] **Remove stale docs**: 5 thread safety MDs for removed C libs, `tools/heif_stress_test.c` (2026-02-09)
- [x] **Remove `check_lzma`** — unreferenced ad-hoc debug binary, no source, no docs (2026-02-09)
- N/A **`result/` symlinks** — checked, all valid (Nix store paths still exist)
- [x] **PDF validation O(N²) fix** — xref table parser with O(M) lookup, falls back to linear scan (2026-02-09)
- [x] **`detectFormat()` lookup table** — comptime first-byte index for O(1) bucket lookup instead of linear scan (2026-02-09)

### Documentation Updates (from 2026-02-09 review)
- [x] **Update `FORMAT_VERIFICATIONS.md`** — replace C library refs with "Pure Zig" (2026-02-09)
- [x] **Update `VALIDATE_VERIFICATION.md`** — updated summary with current counts (2026-02-09)
- [x] **Update `CODE_MINIMAP.md`** — added 20 new pure-Zig validator files (2026-02-09)
- [x] **Fix `ARCHITECTURE.md`** — marked FFI "Current Violation" as RESOLVED (2026-02-09)
- [x] **Complete `PERF_EXPERIMENTS.md`** "Winner / Merge Decision" section (2026-02-09)

### New Format Support
- [x] **Add HTML format detection + well-formedness validation** (`.html`, `.htm`, `.xhtml`) (2026-02-09)
- [x] **Add ELF executable recognition + structural validation** (`.o`, `.so`, `.elf`, `.ko`) (2026-02-09)
- [x] **Add WebAssembly module validation** (`.wasm`) with section ordering + size checks (2026-02-09)
- [x] **Add `ar` archive recognition** (`.a` files, magic `!<arch>\n`) with member header validation (2026-02-09)
- [x] **Add Mach-O/COFF recognition** — single-arch, fat binary, COFF .obj detection + validation (2026-02-09)
- [x] Add missing corruption tests for: json5, mpeg12, mpeg4p2, ole2, opus, theora, mov (2026-02-09)

### Future Investigation: Kaitai Struct as Reference Library
- [ ] Use .ksy specs (https://github.com/kaitai-io/kaitai_struct_formats) as reference when writing new validators
  - 170-200+ format specs in YAML covering archives, images, media, executables, filesystems, etc.
  - Format gallery: https://formats.kaitai.io/
  - **No Zig or C target** — closest are C++/STL and Rust, impractical for pure-Zig FFI
  - **Parsing != validation**: lacks checksum verification, bitstream entropy decoding, semantic cross-field validation
  - **Best use: .ksy YAML as machine-readable format documentation** (field offsets, types, enums, valid ranges)
  - Not worth integrating as a dependency (GPLv3 compiler, code-gen build step, structural-only parsing)

### Other
- [x] Add flake-provided Wine for Windows tests on Linux (CrossOver still needed on macOS) (2026-02-02)
- [x] Fix last failed CI build (git identity in tests) (2026-02-01 ~20:45 EST)
- [x] Create utility script to check forked dependencies for upstream updates (scripts/check-fork-updates) (2026-02-01 ~21:15 EST)
## Recently Completed
- [x] Code review fixes: ring buffer, depth honesty, catch blocks, build.zig dedup, 52 new tests (2026-02-22 EST)
- [x] Consolidate duplicated codec utilities into `codec_utils.zig` (2026-02-22 EST)
- [x] Add Compact Pro (`.cpt`) strict fixture coverage (2026-02-21 EST)
- [x] Refresh RAR CLI discrimination test for `rarz` backend (2026-02-21 EST)
- [x] Strict format coverage: ground-truth samples, corruption opacity, BinHex validation (2026-02-20 EST)
- [x] i18n: 30 locales with full format/error/warning translations (2026-02-20 EST)
- [x] Error message template consolidation (25 templates, 2076 literals replaced) (2026-02-10 EST)
- [x] Archive/creative/email/executable validator extraction (2026-02-10 EST)
- [x] Codebase refactoring: 12 domain-specific validator files extracted (2026-02-09 EST)
- [x] PDF xref parser, Unicode warnings, i18n Phase 1 (2026-02-09 EST)
- [x] H.264 deep bitstream validation (CAVLC + CABAC) (2026-02-08 EST)
- [x] Pure-Zig video/image validators, C library removal (2026-02-07 EST)
- [x] MPEG-TS full validation, H.265/HEVC validator (2026-02-07 EST)
