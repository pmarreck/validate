# NEXT_STEPS.md

**Last updated:** 2026-05-20 evening (EST), second HEIC/HEIF session — Bug #1 (silent CABAC skip for NALs > 256 KB) fixed; Bug #2 (CABAC bit under-consumption) diagnosed and characterized but not yet fixed.

This file orients the *next* Claude/Codex/agent session walking into a fresh context window. Assume nothing carries over except what's in this file + the codebase + `MEMORY.md` + `CLAUDE.md`.

---

## Status snapshot

- **Branch:** `yolo`. Both `validate` and sibling repos (`jpegz`, `tiffz`) are in a clean post-integration state. All pin alignments are at fixed-point (see `git log --oneline -10` and each dep's HEAD).
- **`./test` is green** (full nix-sandbox + CLI integration). 2018 pass, 9 skip, 0 fail.
- **`./build` produces a signed binary** via `nix build` (after the `flake.nix` `libjpeg_turbo.out` fix shipped earlier this session).
- **Zig 0.16.0** across the board.

What shipped in the recent run-up:

```
3d2d1b4e9 deps: bump jpegz to 0b01ec9 (cleanroom-only public dispatcher) + tiffz to 2d356040 (matching pin)
df3e3f28f tiffz: switch validate's TIFF deep-validation from zigimg to tiffz
173ce4f5e flake: fix libjpeg_turbo output selector — .out not default
18ef0e7fe 7z: update stale docstring — z7z C FFI is the deep-validation path
394ae5c18 jpeg_validator: retire libjpeg-turbo FFI; keep filename as JPEG validation hub
```

**This session's commits (afternoon/evening 2026-05-20):** added env-flag-gated trace module (`src/core/trace.zig` + categories VALIDATE_TRACE_H265 / VALIDATE_TRACE_H265_CABAC / etc.), instrumented `validateH265Stream` slice-dispatch and `validateH265IntraCabac` CTU loop, then used the trace to discover and fix Bug #1 (NALs > 256 KB were silent-skipping CABAC via a 256 KB stack `large_rbsp_buf` whose `else` branch yielded `null`). Buffer is now heap-allocated via `heap.validateAllocator()`, sized to `nal.data.len`; alloc/de-emulation failure increments `cabac_anomalies` per "no silent skip" policy. The previous "uncommitted dial-turns" from the earlier session of 2026-05-20 had already shipped in `1c8e13cd9`.

---

## Pending tasks (full picture, since the task list may not survive context wipe)

### #62 HEIC/HEIF deep-validation gaps — **active investigation, deeper than initially scoped**

**Empirically:** 0 of 24 corruption attempts caught (1-byte to 1024-byte spans, at offsets 5K/50K/100K/200K/etc. in `autumn_1440x960.heic`). Single-byte and multi-byte corruption deep in H.265 entropy data sails through as `valid=true, depth=full, no warning`.

**Silencing layers — updated 2026-05-20 (evening):**

| Layer | File | Status |
|---|---|---|
| 1. CABAC anomaly criteria | `h265_validator.zig` (CABAC dispatch block) | Tightened to flag overshoot + immediate-fail + mid-slice fail. Net-positive; no false positives on clean files. |
| 2. H.265 verdict policy | `h265_validator.zig` end-of-`validateH265Stream` | Anomalies → `valid=true + warning_message`; caller propagates as depth=structural+warning. |
| 3. HEIC result routing | `heic_validator.zig` (`validateHevcData` + `validateDirectHevcItem` + `validateGridTiles`) | Propagates `warning_message` via `okWithWarning(...)`. |
| 4a. CABAC silent-skip on NAL > 256 KB | `h265_validator.zig` slice dispatch | **FIXED 2026-05-20 evening.** Buffer is heap-allocated to `nal.data.len`. Alloc/de-emulation failure increments `cabac_anomalies` (no silent skip). Empirical: autumn (282 KB NAL) now exercises CABAC instead of returning clean PASS with zero CABAC invocations. |
| 4b. CABAC bit under-consumption — last_sig_coeff bit order | `h265_cabac_decoder.zig` `residualCoding`/`decodeLastSigCoeff` | **PARTIALLY FIXED 2026-05-20 evening.** Spec section 7.3.8.11 reads `last_sig_coeff` as prefix-X, prefix-Y, then suffix-X, then suffix-Y. The previous monolithic `decodeLastSigCoeff(is_x=true)` then `decodeLastSigCoeff(is_x=false)` read prefix-X, suffix-X, prefix-Y, suffix-Y — wrong for any TB where either prefix > 3 (the case for all but tiny / low-frequency TBs). Split into `decodeLastSigCoeffPrefix`, `lastSigCoeffSuffixBits`, `combineLastSigCoeff`; `residualCoding` now interleaves per spec. |
| 4c. CABAC bit under-consumption — spurious firstG1 remaining | (same) | **FIXED 2026-05-20 evening.** Spec section 7.3.8.11 only decodes `coeff_abs_level_remaining` for `firstGreater1ScanPos` when `greater2=1` (baseLevel=3 matches threshold=3). Previous code added `num_greater1` unconditionally to `total_remaining`, reading one extra bypass slice per sub-block whenever the encoder wrote `greater2=0`. Fixed in `residualCoding` by computing `num_g1_remainings = num_greater1` when `has_greater2` else `num_greater1 - 1`. |
| 4d. CABAC bit under-consumption — RESIDUAL | (same) | **STILL OPEN.** Sample tiles improved uniformly (all 14 tile slices now reach 64/64 CTUs — previously tiles 3 and 4 false-terminated at 16 and 1 respectively). The 1440x960 photo slices regressed in CTU count (autumn 113→20, crowd 158→26, winter 41→33, summer 149→53, spring engine_invalid→72 false-terminate). This regression is the desync surfacing earlier as the engine is more spec-honest — there is at least one more bug. Bin counters (`context_bins` / `bypass_bins` / `terminate_bins` / `residual_calls` / `residual_sig_total` / `residual_greater1_total` / `residual_remaining_total` on `CabacDecodeResult`) surface via `VALIDATE_TRACE_H265` `slice_bins` line — use these for the next bisection. Strongly recommend obtaining an ffmpeg `-loglevel trace` reference for `summer_1440x960.heic` CTU 0 to do a per-bin-position comparison; without a reference, further bug hunting is speculative. |

**Latest baseline trace numbers (2026-05-20 evening, AFTER Bug #2c fix):**

```
File                NAL_len  expected_ctus  ctus_decoded  terminated_cleanly  engine_valid  bits_consumed  bits_remaining  rbsp_bits
autumn   1440x960    282KB           345            20    YES (false)        true             14042         2301150    2315192
crowd    1440x960    124KB           345            26    YES (false)        true             38701          973971    1012672
sample   tile1                       64            64         no              true            118505          733095     851600
sample   tile2..tile14               64            64         no              true            (uniformly 64/64 — clear sample-corpus win)
spring   1440x960     49KB           345            72    YES (false)        true             82877          318115     400992
summer   1440x960    192KB           345            53    YES (false)        true            166885         1410003    1576888
winter   1440x960    239KB           345            33    YES (false)        true             49473         1907943    1957416
```

The previous-session observation of "ctus_decoded=64/64, bits_remaining≈30%" was actually `sample.heic` (a 64-CTU tile), not autumn. Autumn under the old buffer-too-small code was producing **no CABAC trace at all** (because the silent-skip path fired before any CABAC was attempted).

**What needs to happen for the sniper test to pass:**

The skipped test `"HEIC corruption: single-byte flip deep in H.265 data must not silent-pass"` (in `heic_validator.zig`, currently `if (true) return error.SkipZigTest;`) will reliably pass once CABAC reaches `decodeTerminate()=1` at all CTUs on CLEAN ground-truth files. At that point, corruption-induced desync becomes visible because the engine *would* hit the terminator at the wrong bit position (or hit `engine_valid=false`, or overshoot).

**Suggested attack plan for the CABAC desync (the next session's main job):**

1. **Add debug tracing first.** Peter's call: gate via env flag (works in ReleaseFast → diagnosing in-the-wild reports). See "Debug tooling" section below.
2. **Take one clean ground-truth tile** (e.g. `autumn_1440x960.heic`'s first tile via `validateGridTiles`'s iteration) and trace the CTU-by-CTU bit position. Compare against a reference HEVC decoder (ffmpeg `-loglevel trace`, libavcodec, or x265). Identify the first CTU where our bit consumption diverges.
3. **Bisect within that CTU.** The desync is most likely in one of: `residualCoding`, `transformTree`, `parseSaoParams`, `decodeLastSigCoeff`. The codebase's H.264 implementation (per `MEMORY.md` achievements log: "100% corruption detection, 451/451 tests") is the precedent for what spec-correct CABAC looks like — port that discipline to H.265.
4. **Verify per-syntax-element.** For each suspect element, write a fixture test with known bin sequence + expected output bins. The achievement log mentions H.264 took ~1 hour after Peter said "let's just do it" — H.265 is more complex but in the same neighborhood.
5. **Tightening dials.** Once `terminated_cleanly=true, bits_remaining≈0` on clean files:
   - Make `!terminated_cleanly` anomaly → FAIL (the layer-2 fix is already wired up — just update the verdict policy comment and confidence assessment).
   - Make `bits_remaining > threshold` (e.g. > 64 bits after alignment) → WARN.
   - The current "overshoot" criterion will then mean what it should.
6. **Un-skip the sniper test** in `heic_validator.zig` by removing `if (true) return error.SkipZigTest;`.
7. **Run the shotgun harness** (see below) against Peter's HEIC and H.264/H.265 movie corpora.

### #64 PDF per-stream decryption — **pending**

**Context:** validate currently emits an INFO-tier skip when it encounters an encrypted PDF stream. The follow-on principled fix lives in `src/core/pdf_stream_validator.zig` and `src/core/pdf_embedded_file_validator.zig`.

**What the principled fix is:**
- Implement RC4 and AES-128/AES-256 per-stream key derivation per PDF spec §7.6
- For each encrypted stream object, derive its individual encryption key from the document encryption key + object number/generation
- Decrypt the stream content **before** running format-detection / sub-validation on the decoded bytes
- Validate the decoded content with the same depth as unencrypted streams
- Cover both encrypted streams in the main body and encrypted embedded files (PDF attachments)

**Why deferred:** non-trivial spec implementation; was scoped after broader cleanups. The existing INFO skip is correct-but-shallow.

**Test corpora needed:**
- A few encrypted PDFs with known passwords (or empty password / "owner password only")
- An encrypted PDF with embedded files
- An encrypted PDF with both RC4 and AES encryption types

### #56 TIFF → tiffz — **completed this session**

Shipped: validate's generic TIFF/DNG/NEF/etc. deep validation now flows through `tiffz_shim.validateTiffDeepBuffer`. tiffz handles structural integrity (IFD walk, tag parsing, codec selection, etc.). LibRaw still handles ARW/CR2/NEF; bespoke decoders still handle ORF/PEF; DNG and 1-bit LZW still take their custom paths.

### Mecha release plan (`inbox/2026-05-08-mecha-release-plan-validate-slice.md`) — **informational, no action yet**

Peter has a multi-product commercial release plan: validate becomes the CLI engine for "Mecha Validate". BSL-Mecha-1.0 license, separate `pmarreck/validate_gui` for the paid GUI. No code action required from the next session — keep the note around as reference for branding / license updates when those come up.

---

## Debug tooling guidance

**Peter's directive:** "Add debug tooling (perhaps gated behind a build mode or env flag) that prints interim state to stderr. Will help with in-the-wild false-positive / false-negative diagnosis after launch."

**Recommendation: env-flag gating, not comptime build-mode gating.** Reasons:

- Users running the published ReleaseFast binary need to be able to enable diagnostics without rebuilding.
- The C CLI inherits process env vars naturally → no special wiring needed.
- Build-mode gating (`if (comptime @import("builtin").mode == .Debug)`) only works in `Debug` builds, which we never ship.

**Existing precedent:** `src/core/format_validation.zig` has `getenvCrossPlatform`; `src/core/runtime.zig` has `hasEnvVar`. Use those. Example pattern already in tree:

```zig
if (format_validation.getenvCrossPlatform("TIFF_DEBUG")) |_| {
    std.debug.print("TIFF decode error: {s}\n", .{@errorName(err)});
}
```

**Suggested env vars to add (a coherent naming scheme):**

| Env var | Scope | What it dumps |
|---|---|---|
| `VALIDATE_TRACE` | global | turns on all VALIDATE_TRACE_* subcategories |
| `VALIDATE_TRACE_HEIC` | HEIC / HEIF | container parse, NAL walk per tile, per-NAL bytes-summary |
| `VALIDATE_TRACE_H265` | h265_validator | NAL-by-NAL summary, VPS/SPS/PPS parse outcome, slice header bits |
| `VALIDATE_TRACE_H265_CABAC` | h265_cabac_decoder | CTU-by-CTU bit position, decode outcome per syntax element |
| `VALIDATE_TRACE_H264` | h264_syntax_validator | matches H265 shape |
| `VALIDATE_TRACE_PDF` | pdf_*_validator | per-stream filter chain, decrypt attempts, content type detection |
| `VALIDATE_TRACE_JPEG` | jpeg_validator | jpegz dispatch path + finding accumulation |
| `VALIDATE_TRACE_TIFF` | image_validators TIFF path + tiffz_shim | already partially covered by `TIFF_DEBUG`; consolidate |

**Hot-path consideration:** for high-frequency traces (per-CTU, per-coefficient), cache the env-check result once per `validateHeicDeepFromBuffer` (or equivalent) call, not on every print. A `const trace_enabled: bool = runtime.hasEnvVar("VALIDATE_TRACE_H265_CABAC");` at function entry is enough.

**Output format suggestion:**
```
[VALIDATE_TRACE_H265_CABAC] tile=3 ctu=12/64 bit_pos=8423 ctus_decoded=12 engine.range=0x1a0 engine.offset=0xcd
```

Easy to grep, prefix-tagged for filtering.

**Implementation tip:** introduce one helper module (e.g. `src/core/trace.zig`) with a single `pub fn trace(category: []const u8, comptime fmt, args)` so call sites stay clean:

```zig
trace.print("H265_CABAC", "tile={d} ctu={d}/{d}", .{tile_idx, ctu_addr, total_ctus});
```

Cache the per-category enable state inside the helper.

---

## Test corpora (for "shotgun" harness)

**In-tree (deterministic, CI-eligible):**
- `ground_truth_examples/heic/` — 6 HEIC files: autumn / crowd / sample / spring / summer / winter (1440×960 mostly + sample.heic which is a grid).

**External (Peter's local-only, used for shotgun fuzzing):**
- **Apple Photos** library — large HEIC corpus. Privacy-sensitive; the harness should **never** copy file content into the repo or commit. Sample-validate in place or copy to `/tmp/`.
- **`/Volumes/Fileserver/Films_And_TV_Episodes/`** — H.264 and H.265 movies. Same privacy/size guidance: process in place, no commits.

**Shotgun harness skeleton (not yet built — suggested location `./fuzz/heic-shotgun`):**

```bash
#!/usr/bin/env bash
# Usage: ./fuzz/heic-shotgun /path/to/heic/dir [--samples N]
# Selects N random HEIC files. For each:
#   1. Baseline-validate with ./zig-out/bin/validate
#   2. Corrupt a random byte deep in the file
#   3. Re-validate
#   4. Report which baseline-pass files now FAIL or WARN (detection)
#   5. Report which baseline-pass files still PASS (silent — the gap)
```

Once CABAC desync is fixed (per #62 plan), the detection rate should rise substantially.

---

## How to start the next session

1. **Read this file first.** Then `MEMORY.md`, then `CLAUDE.md` (project) and `~/.claude/CLAUDE.md` (global).
2. **`git log --oneline -15`** to see what landed.
3. **`git diff`** to see anything I left uncommitted at session end.
4. **Sanity check**: `./test`. Should be green. The pending HEIC sniper test is `error.SkipZigTest`-skipped (search `src/core/heic_validator.zig` for "PENDING").
5. **Decide priority**:
   - **Option A:** Push on the H.265 CABAC desync fix (#62, the big one). Start with debug tooling, then trace one CTU end-to-end. Per the achievements log, this should be ~one focused session.
   - **Option B:** Pivot to #64 PDF per-stream decryption. Cleaner scope; less spelunking required.
   - Peter's preference will likely depend on what's user-visible vs internal: HEIC has a stronger correctness story (the project's founding motivation was a "grey blob" JPEG render); PDF decryption is feature-completeness.

**Heuristic Peter set this session for FAIL vs WARN:**

> If there is a DETECTABLE discrepancy (failed decode, prematurely-ended decode, forbidden sequence, overshoot, etc.) BUT a "normal" encoder would accept it and do a best-effort decode → **WARN**.
>
> If the discrepancy would cause a normal decoder to render visibly wrong (e.g., the founding motivation: "a JPEG that renders 1/3 of the image as a grey blob due to a data discrepancy") → **FAIL**.
>
> We are aiming for **correctness** — not religious zero-tolerance, but credible verification.

Keep that in mind when calibrating the dials on the broadened CABAC.

---

## Sibling repos (for context)

- `pmarreck/jpegz` HEAD: `0b01ec9` — cleanroom-only public dispatcher + CMYK/YCCK cleanroom.
- `pmarreck/tiffz` HEAD: `2d356040` — pinned matching jpegz; M10 callback API in place.
- Both pulled from sibling directories at `../jpegz/` and `../tiffz/` (mirror tmux sessions exist or have existed).

If sibling-project work is needed, the inbox protocol is the `LLMsend` skill (`<recipient>/inbox/YYYY-MM-DD-topic.md` + tmux send-keys ping). Sibling sessions may or may not be running; the file is durable either way.

---

— end —
