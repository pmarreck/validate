# Reader-audit gaps — 2026-07-15

This records an evidence-led audit of a private real-world corpus. The public
repository contains neither original paths nor filenames. Reproducible bytes,
their SHA-256 values, and the reader evidence live in the private sibling
`validate_gui` corpus at `ground_truth_examples/audit_20260715/`.

## Classification rule

Strict conformance and reader interoperability are different claims:

- **FAIL** — structural/decode damage that independent readers reject, or an
  unproven discrepancy.
- **WARN** — a named, technically nonconforming defect that independent
  readers demonstrably recover from.
- **PASS** — no detected defect; another reader accepting a file is not by
  itself a reason to erase a detected deviation.

No format-wide string match may downgrade a result. A warning must name its
cause and retain every truthful location available to the caller.

## Evidence-backed false-positive candidates

| Surface | Core pre-remediation | Independent evidence | Direction |
| --- | --- | --- | --- |
| PDF JBIG2Globals segment declaration exceeds stream | FAIL | qpdf structural check and Ghostscript strict render succeed | WARN only for the decoder's structured global-segment overrun, with byte coordinate |
| PDF JBIG2Globals behind `/FlateDecode` | generic JBIG2 FAIL | qpdf and Ghostscript succeed | Decode PDF preprocessing filters first; any remaining declared-length overrun is the same narrow WARN |
| PDF missing `%%EOF` | FAIL | Ghostscript renders; qpdf repairs/reports recovery warnings | Candidate WARN with missing-EOF cause; do not make a missing trailer invisible |
| JPEG missing EOI | FAIL | ImageMagick decodes sampled bytes | Candidate WARN with missing-EOI cause |
| dBASE header terminator absent | FAIL | LibreOffice converts sampled bytes | Candidate WARN with missing-header-terminator cause |
| DICOM VR metadata | FAIL | Candidate samples previously parsed by independent DICOM readers | Hold classification until the exact checksum-bound fixture is re-verified |

Controls that remained correctly strict in the audit include corrupt JPEG
Huffman tables (libjpeg-turbo rejects), malformed ZIP CRC/decompression data
(unzip and 7-Zip reject), truncated PNGs, and unsupported WordPerfect type 17
files that LibreOffice cannot convert.

## JBIG2 diagnostic contract

The existing C FFI KV-US-RS `warn` field is sufficient and ABI-safe; it is
already returned to `validate_gui` with `valid=T`. The warning uses zero-based
coordinates:

- An unfiltered globals stream names `embedded-stream byte 0x…` and the exact
  `PDF byte 0x…`.
- A prefiltered globals stream names `decoded-globals byte 0x…` and explicitly
  says that no exact raw-PDF byte offset exists.

This avoids both an ABI-unsafe output-struct extension and a misleading
compressed-to-uncompressed offset conversion.

## Focused performance sample

On 2026-07-15, the current ReleaseFast CLI was measured with hyperfine (20
runs after three warmups) on the two affected checksum-bound PDFs. The
unfiltered-globals case averaged **757.4 ms** (σ 7.1 ms); the
Flate-preprocessed-globals case averaged **740.3 ms** (σ 5.9 ms). These are
current-path measurements, not a before/after speed claim: the remediation
intentionally performs preprocessing-filter decode only for JBIG2Globals so it
can validate the actual bytes. The existing deep-PDF coverage gates remain the
acceptance control for future performance work.

## Priority false-negative gaps

These require a red regression before implementation. The checksum-bound
candidate bytes live in the private corpus; the regression must retain the
current Sniper/Bolter/Shotgun sensitivity gates as it closes each gap.

1. **MP4/H.264 semantic reference validation:** a container/syntax-valid file
   passed core while ffmpeg rejected an invalid reference-frame relationship.
   The H.264 decoder must preserve its current syntax coverage while validating
   reference-picture constraints.
2. **MP4 external media references:** an earlier sample's ffmpeg error was an
   unavailable source path, not a byte-level oracle result. Do not implement a
   data-reference rule until a self-contained fixture reproduces a defect.
3. **ZIP extra-field length accounting:** a valid-labelled ZIP had an
   extra-field block length that overran the remaining field bytes. 7-Zip
   accepted it while unzip rejected it, making it a candidate WARN—not a
   silent PASS—once the parser reaches the condition consistently.

## Regression discipline

`tests/cli/pdf_jbig2_audit_regressions` verifies fixture SHA-256 values before
asserting the command-line outcome. It skips loudly without the private corpus;
the regular unit suite independently exercises the structured global issue and
the direct `/Length` stream-boundary rule. The two controls together stop a
future validator from either mutating the evidence or regressing to a generic
JBIG2 warning.
