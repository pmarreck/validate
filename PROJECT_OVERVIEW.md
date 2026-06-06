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

### Shim implementer guide: routing decoder-library errors

When a format-shim (`tiffz_shim.zig`, `jpegz_shim.zig`, future
format shims) maps an error from the underlying decoder library, the
verdict-tier mapping follows the principle above:

| Underlying-library error | Verdict | Rationale |
|---|---|---|
| Codec rejected input bytes (e.g. `tiffz.Error.Malformed` from `decodeStrip`; jpegz's "huffman_table_corrupt" finding) | **FAIL** | The codec is doing exactly what corruption detection requires: rejecting bits that don't make sense. Cosmic ray / sector failure / network glitch → here. |
| Resource limit / I/O failure (OOM, `LimitExceeded*`, `SourceTooShort`, `SourceShortRead`) | **FAIL** | The validator hit a hard wall. User needs to know it's not just a missing-feature gap. |
| Unsupported format variant (e.g. `tiffz.Error.UnsupportedCompression`, `.UnsupportedPhotometric`) | **WARN** at `structural` depth | The decoder library hasn't implemented this variant yet. The file is probably fine; just don't tell the user it's been fully validated. |
| Decoder library SUCCESSFULLY decoded via a known-quirk fallback (e.g. tiffz's `old_style_lzw_codes` finding fires on libtiff-style legacy LZW) | **WARN** | The tolerated-deviation case from the WARN definition above. File is readable everywhere; just non-canonical. |

The two WARN sub-cases differ in depth: known-quirk fallback returns
`full` depth (the file was fully decoded); unsupported-variant returns
`structural` depth (depth degraded because the codec couldn't run).

If a single error code from the underlying library conflates the
"corruption" and "unsupported variant" cases (no signal to
distinguish), that's an upstream library-design issue worth flagging
— the library should split into distinct error names so shim
implementers can route them differently.

## Caveat: codec-level vs byte-level integrity

Validate's verdict tiers describe what it observes about *structural*
correctness and *codec* acceptance. Several common file format
classes have NO byte-level integrity primitive built into the format
spec, which bounds what any validator (validate or anyone else) can
detect from the bytes alone:

### Uncompressed payload formats

TIFF (Compression=1), BMP, raw PCM audio, raw camera sensor data, and
any other format where the payload bytes ARE the data: a flipped bit
or even a wholesale byte substitution inside the payload produces a
visibly different but structurally valid file. No checksum exists in
the spec to detect this. Validate's claim on such files is bounded
to "structural + codec-level" — not "byte-level integrity."

Detecting bit-level changes in uncompressed payloads would require an
external integrity primitive (sidecar hash, filesystem metadata, ECC
storage, content-addressed retrieval).

### Codecs without per-byte integrity primitives

LZW, PackBits, raw run-length encodings, naive Huffman, and other
"structural-only" codecs fail on logical impossibilities (forward
references, output overruns, EOD-at-wrong-position) but typically
accept individual bit flips silently and emit garbage decoded bytes.
Empirically (TIFF corruption-sweep, 2026-05-21): LZW catches ~7-11%
of single-bit flips in compressed strip data via its
forward-reference check — but the other ~90% land on still-valid
codes that just decode wrong. Same fundamental limit applies wherever
LZW is embedded: TIFF, PDF, GIF, PostScript, TGA, etc.

By contrast, codecs that DO carry per-byte integrity primitives
(Deflate/zlib's CRC32, JPEG entropy-coded markers, ZSTD's xxhash, the
T.4/T.6 EOL line markers) catch most bit-level corruption naturally
and consequently push validate's sniper-detection rates into the
60-100% range on files using those codecs. See
`docs/corruption-sweep-results/tiff_per_fixture.md` for the per-codec
empirical breakdown.

### Shotgun vs sniper

A multi-KB sector failure (shotgun-style corruption) catches in the
~57-100% range across nearly every compressed codec — even
"structural-only" codecs fail when thousands of consecutive codes
get scrambled. Single-bit flips (sniper-style) only catch where the
codec has per-byte integrity. This shape of failure is the
"interesting" case for storage-medium corruption (typically
sector-aligned), and validate's claim against it is genuinely strong.

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

## Internationalization (i18n)
- **i18n phase: enforce.** Every user-facing string lives in a no-default Zig
  struct (`Strings`), so the compiler rejects any incomplete locale at build
  time — a missing translation breaks the build, never silently falls back to
  English.
- **50 locales** supported (the fleet-canonical set; see `docs/I18N.md` for the
  full list and selection rationale). CLI/env alias maps are merged at comptime
  with a same-name→different-arg collision guard (`@compileError`).
- Errors are bilingual: the localized message carries the English original in
  parentheses (`(search for: "...")`) for searchability.

## Non-Goals
- Repair, redundancy/parity, or protection. Those belong to a future for-pay project that I am still working on.
