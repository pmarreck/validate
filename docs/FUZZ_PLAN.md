---
purpose: Comprehensive fuzz-suite design for validate's untrusted-input parsers (build spec; not yet implemented)
audience: both
maintained_by: agent
---

# Fuzz Suite Plan

**Status:** APPROVED design (Peter + Einstein, 2026-06-23/24). Not yet built —
the BUILD happens on a fresh context from this doc. Ship mode stays
**ReleaseFast**; fuzzing runs under **ReleaseSafe/Debug** (bounds checks on) and
"fuzz-running-clean" is the ship gate that REPLACES the rejected ReleaseSafe
blanket. Run toward the bugs; don't pad the walls.

## Why
`validate` parses ~210 untrusted formats. The 8 CODE_REVIEW CRITICALs were
parser bugs on crafted/corrupt input (truncation, u32 size overflow, unbounded
alloc, infinite loop, OOB). Fuzzing under safety checks is the instrument that
finds this whole class at root; a runtime guard is only containment.

## Architecture — two tiers (coverage)

### Tier 1 — whole-surface dispatch fuzzer (highest leverage)
One harness: bytes → `FileSource.fromBuffer(bytes)` → run BOTH the shallow
dispatch (`FormatValidator.validateFile`-equivalent) and the deep dispatch
(`FormatValidator.validateDeepFromSource`, already buffer-capable). Routes every
input through `detectFormat` + the matching validator → exercises **all ~50
validator entry points / ~210 formats** (detection + shallow + deep) from one
harness. GPA allocator for leak/use-after-free detection.

### Tier 2 — targeted deep-decoder harnesses
For the complex in-house bitstream / decompression / structured-parse engines
where Tier-1's coverage is shallow and the CRITICALs lived. Round-trip oracle
(`decode(encode(x)) == x`) where an encoder exists; crash-only oracle otherwise.
Priority (all our code, all untrusted-path):
- Decompressors (round-trip): bzip2 (harness exists), shared LZW (`tiffz.lzwz`
  profiles for PDF, GIF, and TIFF), run-length, ASCII85, ASCII-hex, brotli.
- Bitstream/entropy (crash-only): H.264 + H.265 CABAC, VP8, `codec_utils` bit
  readers, JBIG2 / CCITT-G4, MPEG-1/2 + MPEG-4p2.
- Structured parsers (crash-only): PDF xref/object (`pdf_xref_parser`), OLE2 FAT
  (`ole2_validator`), Thrift/Parquet (`scientific_validators`), MP4/MKV box walk,
  Spotlight 8tsd/IVF, OpenMPT/tracker.

## The ORACLE — two-tier (the key refinement; avoids false positives)

For each fuzzed input assert:

1. **ROBUSTNESS (always sound, primary target):** never crash, hang, OOM, or hit
   UB on ANY input — for ANY format. This is the universal invariant; a blind
   mutation that produces a "valid-but-different" file is CORRECT behavior, not a
   bug, so robustness is the only thing we can always assert.
2. **DETECTION (conditional):** assert `corrupt → INVALID` **only** when BOTH:
   - the format's `maxAchievableDepth() == .full` (reuse the classifier built in
     the depth-gate work — integrity-backed formats only), AND
   - the mutation landed in the integrity-covered region (CRC/checksum/control-
     total bytes), not pixel/PCM-sample/metadata/padding bytes.
   For `.structural`-only formats assert **only** robustness (no-crash). A blind
   mid-file flip does NOT always invalidate (in-range pixel/sample/metadata/pad
   bytes stay valid) — do NOT false-positive on correct tolerance.

## Mutation operators (beyond noise-from-a-point)
Our real CRITICALs were structural, not random noise — so include:
- **Bit/byte flips** (sniper/bolter), single + small clusters.
- **TRUNCATION** — chop the tail at random offsets (the RIFF/AIFF/WebP/Parquet
  truncation-overflow + Parquet-page-cut classes).
- **SIZE / LENGTH-FIELD max-out** — set declared-size/count fields to
  `0xFFFFFFFF`/huge (the OLE2 ~17 GB alloc + u32-overflow classes). Target the
  bytes the detector/parser reads as lengths.
- **Splice / region-overwrite** (shotgun) — overwrite a 4 KB run with other-file
  or random bytes.
- **Self-reference / cycle injection** where the format has offset chains (the
  PDF `/Prev` infinite-loop class).

## Detector-prefix preservation + re-bucket
Preserve the detector's consumed magic prefix (per-format magic length) so the
mutation keeps reaching the intended decoder; after mutating, re-run
`detectFormat` and **re-bucket** the input under whatever format it now routes to
(a mutation may legitimately change the detected format — follow it, don't assume).

## Hang watchdog
Per-input timeout (the `/Prev` class stalls rather than crashes). A timeout =
FAIL (treated as a found bug → reproduce-first).

## Build + execution
- **ReleaseSafe/Debug** build for the sweep (bounds/overflow/unreachable ON).
  Native `zig build` is blocked here by the macOS-26 libSystem stub issue → build
  the fuzz harnesses via a **nix ReleaseSafe variant** (same mechanism used for
  the ReleaseSafe perf measurement).
- **In-memory via `FileSource.fromBuffer`** for the heavy sweep (RAM-first, fast)
  + a thinner CLI/`@stdin`/tmp-file adapter pass to also cover the real I/O path.
- Harnesses are AFL/honggfuzz-style stdin executables (mirrors
  `fuzz/fuzz_stream_bzip2.zig`) → work with AFL++/honggfuzz AND our own driver.

## Determinism + committed crasher corpus (CI-safe)
- **Seed the RNG** (the project `random` util / a fixed-seed DPRNG) — no
  `/dev/urandom`, no wall-clock. Every crash reproduces from
  `(seed, format, sample, operator, offset)`. Same bytes every run, every host.
- On a crash/hang: **minimize** the input, then **COMMIT** it to a regression
  corpus (`tests/fuzz/corpus/<fmt>/`) + a reproduce-first test
  (`fromBuffer(crasher)` → assert no panic / terminates) → root-cause fix → jj
  commit → push. The committed crashers replay every `./fuzz` run AND in CI.
- **Fixture caveat:** `ground_truth_examples/` is a gitignored symlink (244
  files, private validate_gui) → NOT in the Nix sandbox. So exploratory `./fuzz`
  (which seeds from those samples) runs LOCALLY; the **committed minimized
  crashers** are what guard CI (they're self-contained, no fixtures) — do not
  reintroduce the missing-fixture false-green.

## `./fuzz` runner (bash, per house convention)
Builds the harnesses (nix ReleaseSafe) → runs the deterministic seeded-mutation
sweep over the local corpus + the committed crashers + the `fuzz_smoke`
pathological shapes → accumulates crashes to `tests/fuzz/corpus/` → exits
non-zero on any crash/hang. Stays SEPARATE from `./test` (house rule: `./test`
= unit/integration, `./fuzz` = fuzzing). A bounded `--time N` / `--afl` mode for
coverage-guided runs (AFL++ added to flake.nix) is opt-in. CI later runs a
bounded `./fuzz` over the committed crasher corpus only (the CI-honesty dispatch).

## Sequencing (for the fresh-context build)
1. `./fuzz` + nix ReleaseSafe fuzz build + Tier-1 dispatch harness + the
   deterministic driver + the two-tier oracle → first sweep.
2. Triage/fix each finding reproduce-first; commit minimized crashers.
3. Add Tier-2 harnesses by risk (CABAC, PDF-xref, OLE2, LZW first); fix; repeat.
4. Wire the committed-crasher replay into CI (bounded).

## Coverage estimate
Tier 1: 100% of detection + validation entry points reachable from untrusted
bytes (the full attack surface), shallow + deep. Tier 2: deep coverage of ~12–15
in-house decoder/parser engines (where the CRITICALs lived). Combined ≈ the full
untrusted-input surface with the complex engines fuzzed to depth.
