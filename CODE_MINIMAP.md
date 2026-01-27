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
| `src/core/path_validation.zig` | Parallel path validation and per-file callback reporting (honors `MAX_FILES`) |
| `src/core/format_validation.zig` | Format validation logic incl. ZIP deep validation (central-directory parsing to avoid data-descriptor scans), PDF image lenience (JBIG2/DCT warnings), XML undefined-entity tolerance (after DOCTYPE stripping), and ZIP/PDF telemetry (env `ZIP_TELEMETRY`, `PDF_TELEMETRY`) |
| `src/core/video_validator.zig` | Video container parsing + codec decode validation (MP4/MKV/AVI), MKV byte-coverage with mixed NAL-length handling and debug envs (`MKV_BYTE_DEBUG`, `MKV_BYTE_DEBUG_OUT`, `MKV_BYTE_DEBUG_FRAME_OUT`) |
| `src/core/font_validator.zig` | Standalone font validation (TTF/OTF/CFF/Type1) with checksum fallback to structural parsing for clearer errors |
| `src/core/pdf_font_validator.zig` | Extracts/validates embedded PDF fonts using strict checksums while reporting warnings instead of failing PDFs |

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
