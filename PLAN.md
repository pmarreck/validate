# Plan

Checkbox-only list of specific work items. Keep recent completions with EST timestamps; prune older completed items regularly.

## Active

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
- [ ] **Break out `format_validation.zig` (34,780 lines)** into separate validator files:
  - [ ] Extract PE/Windows executable validator (~205 lines) → `pe_validator.zig`
  - [ ] Extract text format validators (JSON, CSV, TOML, YAML, INI, RTF) → `text_format_validators.zig`
  - [ ] Extract scientific format validators (FITS, DICOM, NetCDF, FASTA, FASTQ) → `scientific_validators.zig`
  - [ ] Extract game ROM validators → consolidate into `game_validator.zig`
  - [ ] Extract DAW project validators → `daw_validators.zig`
  - [ ] Audit remaining large functions (need accurate line counts, not hallucinated ones)
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
- [ ] **Add Mach-O/COFF recognition** — remaining compilation artifacts
- [x] Add missing corruption tests for: json5, mpeg12, mpeg4p2, ole2, opus, theora, mov (2026-02-09)

### Other
- [x] Add flake-provided Wine for Windows tests on Linux (CrossOver still needed on macOS) (2026-02-02)
- [x] Fix last failed CI build (git identity in tests) (2026-02-01 ~20:45 EST)
- [x] Create utility script to check forked dependencies for upstream updates (scripts/check-fork-updates) (2026-02-01 ~21:15 EST)
## Recently Completed
- [x] Add utility script to check forked dependencies (scripts/check-fork-updates) (2026-02-01 ~21:15 EST)
- [x] Deprecate handle-based API with DEPRECATED comments in C header and Zig FFI (2026-02-01 ~21:00 EST)
- [x] Fix CI: configure git identity in git repository tests (2026-02-01 ~20:45 EST)
- [x] Add warning when skipping inaccessible directories (TCC/permissions) (2026-02-01 ~20:30 EST)
- [x] Skip inaccessible directories during enumeration (macOS Photos Library fix) (2026-02-01 ~20:15 EST)
- [x] Add CP437/DOS text encoding detection for demoscene NFO files (2026-01-31 ~15:30 EST)
- [x] Reach 100 format ground truth coverage with full decode + corruption tests (2026-01-28 23:55 EST)
- [x] Add 9 new formats: beam, swf, flv, pe, ape, dsf, dff, wad, hdf5 (2026-01-28 23:50 EST)
- [x] Add corrupted samples for all 10 missing formats (2026-01-28 23:40 EST)
- [x] Fix DICOM detection priority over TIFF (check offset 128 before offset 0 signatures) (2026-01-28 21:15 EST)
- [x] Add glTF format detection (distinguish from generic JSON via asset/version/scenes keys) (2026-01-28 21:12 EST)
- [x] Add OBJ format detection (detect via v/vt/vn/f line patterns instead of plain text) (2026-01-28 21:08 EST)
- [x] Fix concurrency slowdown: dedicated output thread with result queue (2026-01-27 17:03 EST)
- [x] Remove JOBS_DEBUG logging hook after confirming 16-core usage (2026-01-27 00:33 EST)
- [x] Warn on mixed MKV NAL length prefixes (repairable) and add JOBS_DEBUG logging (2026-01-27 00:21 EST)
- [x] Handle mixed NAL length prefixes in MKV H.264/HEVC byte validation (debug frame dump env added) (2026-01-27 00:02 EST)
- [x] Tolerate MKV byte-validation failures (lacing-aware parsing + padding tolerance) to avoid false invalids (2026-01-26 20:13 EST)
- [x] Route UNKNOWN entries via UNKNOWN_OUT and add CLI tests (2026-01-26 19:30 EST)
- [x] Add byte-coverage parsers for H.264/HEVC/AV1 across MP4/MKV/AVI (2026-01-26 19:30 EST)
- [x] Audit FAIL results in ~/Movies and ~/Books and classify parser vs media issues (2026-01-26 15:33 EST)
- [x] Cross-check FAIL items with Preview.app / CLI player and align lenience+warnings (2026-01-26 15:33 EST)
- [x] Use OS logical CPU count for default worker threads and add a sanity test (2026-01-26 04:52 EST)
- [x] Document lenience/repairability rationale (valid-with-warning for potentially repairable malformations) (2026-01-26 04:44 EST)
- [x] Add checksum mismatch fallback parsing for fonts and surface PDF font warnings without failing PDFs (2026-01-26 04:40 EST)
- [x] Add PDF telemetry for slow deep validation and analyze Books outliers (2026-01-26 04:08 EST)
- [x] Run post-optimization perf on ~/Documents (MAX_FILES=80000) and record results (2026-01-26 04:08 EST)
- [x] Validate ground_truth_examples corpus after ZIP optimization (2026-01-26 04:08 EST)
- [x] Optimize ZIP data-descriptor handling (parse central directory for sizes/offsets) (2026-01-26 03:29 EST)
- [x] Run performance experiments (baseline + A/B/C) and record CPU-time results in PERF_EXPERIMENTS.md (2026-01-26 03:29 EST)
- [x] Add memory telemetry (CLI env-gated) and ZIP entry timing telemetry for slow-zip investigation (2026-01-26 02:18 EST)
- [x] Add CrossOver-based Windows test runner (test-windows + build.zig hook) (2026-01-25 17:14 EST)
- [x] Add core parallel path validation + CLI jobs flag (2026-01-25 16:52 EST)
- [x] Fix CI issues: libde265 SSE4.1 gating + Windows tests (bzip2 temp + JPEG structural) (2026-01-25 16:52 EST)
- [x] Audit Zig 0.15 API usage (no mismatches found) (2026-01-25 16:20 EST)
- [x] Add CLI SLOW warning for validations >5s (2026-01-25 16:20 EST)
- [x] Add Zig 0.14–0.15 API reference doc to CODE_MINIMAP (2026-01-25 16:16 EST)
- [x] Pin zigimg URL ref in build.zig.zon for Zig 0.15+ compatibility (2026-01-25 16:11 EST)
- [x] Accumulate sub-test failures in ./test exit code (2026-01-25 16:06 EST)
- [x] Ensure ./test prints Zig output on failure (2026-01-25 16:04 EST)
- [x] Treat .svg as SVG (no extension mismatch warning) (2026-01-25 15:46 EST)
- [x] Flatten ground_truth_examples directory structure (2026-01-25 15:40 EST)
- [x] Remove PAR2/parity references from FORMAT_VERIFICATIONS (2026-01-25 15:35 EST)
- [x] Add ./build wrapper (tests first, ReleaseFast default) (2026-01-25 15:33 EST)
- [x] Add CI workflows for macOS aarch64, Windows x86_64, Linux musl x86_64 (2026-01-25 15:33 EST)
- [x] Tie dependency optimize mode to DEBUG env var (ReleaseFast when unset) (2026-01-25 15:24 EST)
- [x] Add note on future legacy Office deep validation scope in FORMAT_VERIFICATIONS (2026-01-25 15:16 EST)
- [x] Fix legacy Office format wording to structural-only validation in FORMAT_VERIFICATIONS (2026-01-25 15:16 EST)
- [x] Publish `pmarreck/validate` repo to GitHub (2026-01-25 13:16 EST)
- [x] Add core documentation set (PROJECT_OVERVIEW, RULES, DOCUMENTATION_GUIDE, ROADMAP) (2026-01-25 13:14 EST)
- [x] Move validation fixtures from Entropy Shield into validate (2026-01-25 11:55 EST)
