# Code Review — Mecha Validate (`validate`)

**Date:** 2026-06-22
**Reviewer:** Claude (deep-code-review skill — 7-dimension adversarial, PM launch-readiness lens)
**Scope:** Full codebase audit before the paid Mecha suite goes on Paddle. validate parses **untrusted files**, so adversarial input is the threat model.
**Backing detail:** verified per-dimension reports in `/tmp/review/validate-{1..7}-*.md` (correctness, tests, memory, security, perf, quality, launch/legal).

---

## PM VERDICT: 🚫 DO NOT SHIP YET — but you're ~1 focused session away.

**The foundation is genuinely good** (this is not a rewrite situation):
- Disciplined architecture: exhaustive `comptime` dispatch makes "format with no validator" a *compile error*; a `FileFormat.maxAchievableDepth()` self-oracle; error-template round-trip drift test; a no-magic→ext-map comptime guard.
- **Data-loss posture solid** — verified it never opens user files for write/truncate/delete; no `O_TRUNC`/`rename`/`deleteFile` in the validation path. (Critical for a file-touching tool.)
- **FFI boundary clean** — consistent single-allocator string ownership, exhaustive error-code mapping (single source of truth + regression test), correct NULL handling.
- **No shell-out / command-injection surface** anywhere; defensively-written parsers (no reachable OOB found on the 5 shipped targets); **strong LOCAL test suite (2078/2087)**; launch-quality CLI UX (help/version/json/stdin/i18n, clean streams); the BSL license header is sound.

**But it is not launch-ready**, due to blockers in four categories:

1. **It can call corrupt files VALID** — the cardinal sin for a validation product.
2. **Crafted-file DoS + no runtime safety net** — a 512-byte file can demand 17 GB; a crafted PDF hangs forever; and it ships **ReleaseFast** (overflow/bounds panics OFF), so any missed check is silent UB instead of a clean FAIL verdict.
3. **The green checkmark is a lie** — CI runs neither the CLI tests nor the corruption-drift oracle, ~256 validator tests silently skip for lack of fixtures, and there's no test-count floor.
4. **Legal: you'd ship with zero required third-party attribution.**

None require rearchitecting. Ordered fix list at the bottom.

## Summary
- **CRITICAL 🔥:** 8 issues + 1 framing decision
- **WARNING ‼️:** ~18
- **ADVISORY ⚠️:** ~12

---

## CRITICAL 🔥

### `scientific_validators.zig:2969,2984` — Parquet false-pass on corrupt/truncated files
**Dimension:** Correctness. `validateParquetDeep` `break`s its page-scan on decode/truncation failure (incl. a page that *declares* a CRC but is cut off mid-read), then falls through to `okWithDepth(.parquet, .full)` if any earlier page verified. **A corrupt/truncated Parquet → clean "fully byte-validated" PASS.** Direct "no silent skip" violation. Fix: a truncation/decode break must downgrade depth and emit a warning, never reach `.full`.

### `music_validators.zig:1905`, `cad_3d_validators.zig:908`, `movie_validators.zig:2293`, `archive_validators.zig:896` — `.full` claimed above the format's own `.structural` ceiling
**Dimension:** Correctness. DTS/STL/DV/TAR have no payload-integrity primitive, so `.full` is impossible by the project's own `maxAchievableDepth()`. The FFI (`c_api.zig:264-273`) emits **both** actual `depth_u8` and ceiling `depth_ceiling_u8` with nothing clamping → self-contradictory output (actual > ceiling). Fix: clamp + the MFIC gate below.

### `validateWav:150`, `validateAiffDeep:558`, `validateRiffAudio:720`, `validateWebp:699` — u32 overflow defeats the truncation bounds-check
**Dimension:** Security/Quality (two reviewers). `declared_size + 8 > file_size` computed in **u32** before promotion → crafted `0xFFFFFFFF` wraps (UB in ReleaseFast), guard silently bypassed. Correct sibling `validateWavDeep:196` uses `@as(u64, …) + 8`. The "one of N copy-pasted validators dropped a guard" pattern.

### `ole2_validator.zig:293-295` (+ `readMiniFat`) — ~17 GB unbounded-allocation DoS
**Dimension:** Security. `readFat` allocates `total_fat_sectors * entries_per_sector` u32s from an **unchecked 4-byte header field** → a ~512-byte crafted `.doc/.xls/.msi/Thumbs.db` requests ~17 GB. Fix: bound against file size.

### `pdf_xref_parser.zig:657-691` — crafted PDF hangs at 100% CPU forever
**Dimension:** Security. The xref `/Prev` chain is walked with **no visited-set and no iteration cap** → a self-referential `/Prev` loops forever during deep validation of the flagship format. Fix: visited-set + cap.

### `format_validation.zig:4670` + `image_validators.zig:116` — ungated `/tmp/es_format_debug.log` write in release builds
**Dimension:** Memory/Quality (two reviewers). **Duplicated** `debugLog` unconditionally appends to a fixed world-shared `/tmp` path on **every invalid validation in release**, **logging the validated file path** — contradicts the read-only promise; predictable world-writable path = privacy leak + TOCTOU/symlink-append surface. The project already has an env-gated `trace.zig`. Fix: gate behind an env var or remove.

### `ci.yml` / Garnix — the CI gate is a false-green
**Dimension:** Test integrity. (a) CI runs only `nix build .#checks.test` (sandboxed Zig units) — the **35 CLI tests and the `master_report_drift` corruption-drift MFIC oracle live only in `./test`, never run in CI**. (b) `ground_truth_examples/` is a gitignored symlink; the Nix sandbox has **0 fixtures**, so **~256 validator tests `catch return error.SkipZigTest`** (pass-by-skipping; only 9 skip locally, which hid it). (c) `installPhase` writes "tests passed" with **no test-count floor** — can't tell 2073 tests from 10. Fix: run `./test` (incl. the oracle) in CI; vendor fixtures or add a count-floor; add a real Windows runtime test.

### `flake.nix:159-188`, `build_all:60,113` — third-party NOTICES not shipped with the sold binary
**Dimension:** Legal. Install step copies only the executable; never `LICENSE`/`LICENSES/`/`THIRD_PARTY`. The binary statically merges **~20 libraries** (BSD-2/3, zlib, MIT) that *require* their copyright notice in binary redistributions → selling a binary with zero required attribution. Also: `LICENSES/` is **missing** libtheora, libvpx (+VP8/VP9 PATENTS), libwavpack, libape, uchardetz, z7z/compact_pro; **LibRaw is LGPL-2.1 statically linked** — non-compliant unless you formally **elect its CDDL-1.0 arm** (no election recorded); **Monkey's Audio (libape)** license is asserted in a code comment, not verified against the real SDK.

### ⚙️ FRAMING DECISION — ship the validation core as **ReleaseSafe**
**Dimension:** Security. The shipped binary is **ReleaseFast → Zig's integer-overflow and slice-bounds panics are OFF.** For a malicious-byte parser this inverts the safety model: a missed check becomes silent UB/OOB instead of a clean panic→FAIL (which is *correct* behavior here — a crash on a bad file = "invalid file"). **This single change retroactively covers every OOB nobody has found yet**, including the u32-overflow above. At minimum, run the full suite + fuzz corpus under ReleaseSafe in CI.

---

## WARNING ‼️ (abridged — full detail in the per-dimension reports)

- **`.full` stamped on header-only parses:** `validateMpegPs` (14 bytes), `validateMpegEs` (4-byte start code), `validateAsf` (GUID walk, no decode), `validateSshSignatureDeep` (no crypto verify on a *signature*), PEM/DER TLV-only. (Correctness W3)
- **MIME-wrapped deep validation** `format_validation.zig:5962` falls through to bare OK + magic-only GIF stub → zero integrity check on extracted payload while reporting OK. (Correctness W4)
- **`cli/main.c` directory walker** uses `stat()` (follows symlinks), no cycle/depth guard, `max_files` unlimited → symlink-to-ancestor loop = C stack overflow + growing mallocs, reachable from `validate ~/dir`. Fix: `lstat` + visited-inode + depth cap. (Security W1)
- **u64-overflow length checks defeat the verdict** (7z/WARC/ZIP64) — validation bypass, not memory-unsafe. (Security W3) MATLAB `.mat` allocs from unchecked u32. (Security W4) Unchecked `@intCast(u6, buffer[0x1E])`. (Security W2)
- **`main.c` `warn_pos`** accumulates `snprintf` returns past the 1024 buffer → `size - warn_pos` unsigned-underflow OOB-write risk. (Quality)
- **No-op MP3 CRC stub** — `validateMp3Deep`'s CRC check is empty; the function meant to fill it (`crc16Mpeg`) is dead code. (Quality)
- **Enum-count desync** — Zig `MalformationType` (20) vs hand-maintained C `VALIDATE_MALFORM_COUNT 22`, no comptime guard; `u6`/`u5` index-width split breaks past 32 variants. (Quality)
- **Complexity/scaling gate not wired** — no `./bm`, `bench/` has one (O(n²)-BWT) benchmark `./test` never runs, only 1 `// complexity:` doc-comment across 203 files → linear property unguarded against regression. (Perf W1)
- **Four 1 MB stack buffers** in `scientific_validators.zig` (1743/1851/3476/3720) on a **4 MB worker stack** — 25%/frame, latent stack-exhaustion (echoes the Garnix HEIF history). Should be heap. (Perf W3) EML MIME-boundary scan O(body×marker) → `indexOfPos`. (Perf W2)
- **`racetrack.zig:487-538` load tests have zero assertions** (doesn't-crash) + nondeterministic "Verdict" that flips; **test output not clean** (benchmark/`ORF decode OK` prints + a confusing "failed command" line on a GREEN build). (Tests W1/W2)
- **Windows CI builds but runs no tests** (compile-only) — yet `PLAN.md:17` claims "Windows full-parity DONE." (Tests W3, Launch #3/#6) **Windows-aarch64 has no binary** (upstream nixpkgs bug). **Version `0.1.0`** for a paid v1, and `build.zig.zon` disagrees (`0.16.0`). **No DEBUG-build announcement** (RULES.md violation). (Launch #3/#7/#8)

---

## ADVISORY ⚠️

- **Dead code** (verified def/internal/test-only, zero prod callers): `CrcHashingWriter` (~100 lines), `crc16Mpeg`, `okNoEmbed` (dup of `ok`), `validateThumbsDb`, `extractRawCodecPrivate`, `VideoDecoderGuard`, `isFfprobeAvailable`, four `h264*Profile*`/ffmpeg-era remnants, 8 `if(false)`/commented blocks.
- **Dispatch-table gaps:** 8 magic-detectable formats (jbig2, jpeg2000, nifti, matlab, warc, par2, type1, wpd) have no `ext_format_map` entry → extension-mismatch detection silently off; duplicate `tvdb`/`musicdb` keys; `.alac` unreachable.
- **Dedup wins:** `getMappedOrSlurp` slurp-switch ×17, AVI extractors triplicated *and divergent*, MDB/ACCDB 6 near-clones, FITS checksum dup.
- Test discovery is fragile-but-currently-OK (28 modules re-exported but absent from the explicit `test {}` block; their tests run only via a subtle 0.16 reachability rule — add the 28 `_ = @import` lines). README has no License section. Three stray `.a` files in repo root (gitignored). Verify the Mac integrity-trailer survives codesign/notarization. OLE2 dir re-walked ~31×/doc (constant-factor). Mutable FFI globals make `validate_batch` non-reentrant (note for GUI consumers).

---

## What's genuinely good (credit — this is a strong codebase)
Read-only/data-safe; clean FFI ownership + exhaustive error mapping; no command-injection surface; exhaustive comptime dispatch + `maxAchievableDepth()` oracle + error-template drift test; defensive parsing (u64 math, bounds checks, decompression-bomb guard, mmap, per-task memory budget — no reachable OOB found); strong local test suite; launch-quality CLI UX; sound BSL license + a well-formed Additional Use Grant moat.

---

## Recommended fix order (highest leverage first)
1. **Ship the validation core as ReleaseSafe** (or run suite+fuzz under ReleaseSafe in CI) — covers the entire overflow/OOB class at once.
2. **Fix the false-passes:** Parquet truncation→never-`.full`; add the MFIC gate **`assert validation_depth ≤ format.maxAchievableDepth()`** (an oracle the authors already wrote — independently kills the whole over-claim class + future regressions).
3. **Cap the DoS vectors:** PDF `/Prev` visited-set, OLE2 alloc bound, symlink walker `lstat`+depth.
4. **Make CI honest:** run `./test` (incl. the drift oracle) in CI; vendor fixtures or add a test-count floor; add a real Windows runtime test; reconcile the "Windows full-parity" claim.
5. **Legal:** bundle third-party NOTICES with the binary; complete `LICENSES/`; elect LibRaw's CDDL; verify the libape license.
6. Gate/remove the `/tmp` debug log; fix the u32 overflow casts; reconcile the version.
7. WARNINGs/dead-code/dedup — post-launch or as time allows.

## The recurring theme (MFIC)
Three independent reviewers flagged the same root pattern: **gates that exist on paper but don't bite** — CI that doesn't run the real tests, a complexity gate that's unwired, a `.full` claim with nothing clamping it to the ceiling. Every cheap durable fix above is an *external oracle the producer can't satisfy with wrong work*: the depth≤ceiling assertion, the CI test-count floor + drift oracle, the scaling-ratio gate, the ReleaseSafe panic backstop. Wire those four and the false-greens can't recur.
