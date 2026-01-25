# Project Overview (validate)

## Goals
- Provide deterministic, byte-level validation across a wide range of file formats (at least 100 thus far).
- Maximize auditability and reproducibility (same bytes => same result).
- Keep validation strictly non-destructive (read-only).
- Stay portable across platforms with a thin C FFI boundary.

## Terminology
- **Validation (structural)**: Header/structure checks; payload corruption may go undetected.
- **Validation (full)**: Every byte is verified via checksum, decompression, or full decode.
- **Deep validation**: Shorthand for full validation when supported.
- **Malformation**: A known, named format defect (e.g., MIME-wrapped content).
- **Warning**: A notable condition that does not invalidate the file.
- **Format validator**: A format-specific validator implementation.
- **FFI**: C ABI boundary used by wrappers/clients (CLI, apps, other languages).

## Non-Goals
- Repair, redundancy/parity, or protection. Those belong to a future for-pay project that I am still working on.
