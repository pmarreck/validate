# Documentation Guide

Canonical documentation lives in this repo root.

## Root Docs (Active)
| File | Purpose |
|------|---------|
| `README.md` | User-facing introduction, build/test instructions |
| `PLAN.md` | Checkbox-only work list (keep recent completions with EST timestamps) |
| `PROJECT_OVERVIEW.md` | Project goals + terminology definitions |
| `RULES.md` | Non-negotiable project rules |
| `ROADMAP.md` | Fairly certain future goals |
| `ARCHITECTURE.md` | Hexagonal architecture design, FFI boundary |
| `CODE_MINIMAP.md` | Project structure and file purposes (no issues/TODOs) |
| `FORMAT_VERIFICATIONS.md` | Validation coverage by format |
| `VALIDATE_VERIFICATION.md` | Per-format corruption test checklist |
| `PERF_EXPERIMENTS.md` | Performance optimization results |

## docs/ (Reference & Investigation)
| File | Purpose |
|------|---------|
| `docs/H264_SPECIFICATION.md` | H.264 decoder spec (deferred work) |
| `docs/JPEGXL_ANALYSIS.md` | JPEG-XL performance analysis |
| `docs/Silent_Data_Corruption_at_Scale.md` | Facebook SDC research (project motivation) |
| `docs/HEIF_CRASH_INVESTIGATION.md` | HEIF stack overflow investigation |
| `docs/thread_safety/*.md` | Thread safety analysis per library |

## Where to Put New Information
- **New task?** -> `PLAN.md`
- **New term or goal?** -> `PROJECT_OVERVIEW.md`
- **New rule/policy?** -> `RULES.md`
- **Design decision?** -> `ARCHITECTURE.md`
- **New file/module?** -> `CODE_MINIMAP.md`
- **Investigation notes?** -> `docs/`
