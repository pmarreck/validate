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

## FFI (ffi/)
| Path | Purpose |
|------|---------|
| `ffi/c_api.zig` | C ABI surface for validation |
| `ffi/validate_core.h` | C header for the ABI |

## CLI (cli/)
| Path | Purpose |
|------|---------|
| `cli/main.c` | CLI wrapper around the C FFI |

## Tests (tests/)
| Path | Purpose |
|------|---------|
| `tests/fixtures/` | Validation test fixtures |

## Documentation
| File | Purpose |
|------|---------|
| `PLAN.md` | Checkbox-only work list |
| `PROJECT_OVERVIEW.md` | Goals and terminology |
| `RULES.md` | Non-negotiable project rules |
| `DOCUMENTATION_GUIDE.md` | Doc locations and writing rules |
| `ROADMAP.md` | Fairly certain future goals |
| `ZIG_RECENT_API_CHANGES_2025.md` | Zig 0.14–0.15 API quick reference for current code |
