# Project Overview (validate)

## CRITICAL DESIGN PRINCIPLE: EXHAUSTIVE VALIDATION

**This is an archival-quality validation tool.** The entire purpose is to verify
data integrity BEFORE applying parity protection (in a separate application).
There is no point protecting corrupt data with parity - you'd just be preserving
corruption.

Therefore:
- **NEVER skip frames, samples, or bytes** to improve performance
- **NEVER limit validation to a subset** (e.g., "first 300 frames")
- **ALWAYS decode/verify the ENTIRE file** when full validation is possible
- Performance optimizations must ONLY come from parallelism or faster algorithms,
  NEVER from reducing coverage

If validation is slow, the solutions are:
- Increase decoder thread counts (internal parallelism)
- Use faster libraries (e.g., ffmpeg when available)
- Parallelize across files (thread pool)
- Accept that thorough validation takes time

**DO NOT** propose "validating a sample" or "limiting frames" - this defeats
the entire purpose of the tool.


## Verdict Tiers: OK / WARN / FAIL

Every file gets exactly one of three terminal verdicts, and the
distinction is meaningful:

- **OK** — file is canonically valid and spec-compliant. Re-encoding
  with a strict tool would produce a byte-identical (or equivalently
  clean) result.
- **WARN** — file is an *acceptable deviation*: every major real-world
  tool opens / decodes / validates it fine, but it deviates from the
  applicable specification in some tolerated way. A strict re-export
  would produce a cleaner file. Common WARN cases include Adobe
  InDesign PDFs (zlib streams missing the Adler-32 trailer), bzip2-
  wrapped DMGs, and PNM files with a single-byte tail truncation.
- **FAIL** — actual data corruption: a checksum mismatch, a truncated
  structure, content no tool can decode. Real damage that re-encoding
  cannot losslessly recover from.

WARN is the load-bearing middle tier. If validate emitted plain OK on
deviations, users would lose the signal that a strict re-export would
produce a cleaner file. If validate FAILed them, users would chase
phantom corruption when their files actually work everywhere.

If you're building a downstream tool: treat WARN as "usable but
non-canonical." If your workflow needs strict spec compliance (e.g.,
distributing files to other strict validators), re-encode any WARN
file before shipping.

## Goals
- Provide deterministic, byte-level validation across a wide range of file formats (at least 100 thus far).
- Maximize auditability and reproducibility (same bytes => same result).
- Keep validation strictly non-destructive (read-only).
- Stay portable across platforms with a thin C FFI boundary.

## Terminology
- **Validation (structural)**: Header/structure checks; payload corruption may go undetected. Also used for opaque text formats (JSON, CSV, OBJ, FASTA, etc.) where every byte is parsed but the format has no integrity mechanism — a valid-to-valid mutation is undetectable.
- **Validation (full)**: Every byte is verified via CRC, hash, decompression, or codec decode. A random bit flip WILL be caught.
- **Validation (best_effort)** *(future tier)*: Every byte parsed but no integrity mechanism exists. Distinguishes "we parsed everything" from "we only checked headers." Both are currently reported as `structural`.
- **Deep validation**: Shorthand for full validation when supported.
- **Corruption opacity**: A format's inherent ability to detect corruption. Three tiers:
  - *transparent*: checksums/decode will catch any bit flip (gzip, PNG, FLAC)
  - *mixed*: depends on corruption location (MP4, JPEG, WAV)
  - *opaque*: format has no integrity mechanism; even full parsing can't detect semantic bit flips (plain text, CSV, OBJ)
  See `scripts/corruption_opacity.tsv` for the per-format map.
- **Malformation**: A known, named format defect (e.g., MIME-wrapped content).
- **Warning**: A notable condition that does not invalidate the file.
- **Format validator**: A format-specific validator implementation.
- **FFI**: C ABI boundary used by wrappers/clients (CLI, apps, other languages).

## Non-Goals
- Repair, redundancy/parity, or protection. Those belong to a future for-pay project that I am still working on.
