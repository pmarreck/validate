# RAW camera formats — close the genuine preview-decode gaps + honest ceilings

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:systematic-debugging (Phase 0 is a diagnosis, not a build) then superpowers:subagent-driven-development / superpowers:executing-plans for the fixes. Steps use checkbox (`- [ ]`) syntax.

> **⚠️ This plan was rewritten 2026-05-28 after live code recon.** The original premise ("wire preview-JPEG decode across the RAW family from scratch") was **wrong**: most of it already exists. This version targets the *actual* gaps found in the code.

## What actually exists today (verified in code, 2026-05-28)

| Format | Deep dispatch (`format_validation.zig:5987`) | Reality |
|---|---|---|
| DNG | `validateDngDeep` | ✅ works (sniper 3/100) — IFD preview scan + RawImageDigest check |
| CR2, NEF, ARW, ORF, PEF | `validateTiffDeep` → `findTiffPreviewLocation` → `validateJpegBufferForDng` (libjpeg-turbo) | ✅ **already wired**; `findTiffPreviewLocation` has passing tests for NRW/CR2/ARW preview discovery |
| RAF | `validateRafDeep` | ✅ decodes embedded preview JPEG via libjpeg-turbo |
| **RW2** | `.rw2, .cr3 => initial_result` | ❌ **NO deep validation at all** — genuine gap |
| **CR3** | `.rw2, .cr3 => initial_result` | ❌ none (ISO-BMFF, separate path — parked) |

**Dead code found:** `src/core/libraw_validator.zig` (`validateRawFile`) is **never called** and **LibRaw is not linked** in `build.zig`/`flake.nix`. It's aspirational. Comments in `format_validation.zig` that say "via LibRaw" are misleading — no LibRaw decode happens. (Decide its fate in Phase 3.)

## Why sniper detection is still ~0% on ARW/NEF/ORF (it's a ceiling, not a bug)

The preview path *works*, but two compounding factors cap sniper detection:
1. **The preview JPEG is a small byte-fraction** of a multi-MB RAW (the raw sensor mosaic dominates).
2. **libjpeg-turbo tolerates single-bit flips** — it decodes slightly-wrong pixels without erroring. This is exactly why *plain* JPEG sniper detection is only ~4% (per the report).

So sniper-on-RAW ≈ (preview fraction) × (~4% JPEG sniper detectability) ≈ near zero. **Shotgun** (4096-byte smear) does better *only when the smear lands in the preview or an IFD*. This ceiling is real and must be stated honestly — chasing it via the preview alone is a dead end. The only lever for materially-higher detection is validating the **raw sensor data itself** (Phase 3 decision).

**Honest expected lift from this plan:**
- **RW2**: 0% → matches the other TIFF-RAW formats once a deep path exists (sniper low single digits, shotgun materially up) — the one clear win.
- **ARW/NEF/ORF/CR2**: marginal sniper lift at best; the value here is *honesty* (Phase 2: stop silently claiming `.structural` / `.full` when we didn't really check the bulk of the file) + confirming the preview is actually being found per-fixture.
- **Real detection ceiling break** requires Phase 3 (raw-sensor decode) — a strategic decision for Peter, not a free lunch.

**Tech Stack:** Zig 0.15.2. `src/core/image_validators.zig` (`validateTiffDeep` @2691, `findTiffPreviewLocation` @3391, `scanAndValidatePreviewJpegs` @3317, `validateRw2` @2837, `validateRafDeep` @877). Dispatch in `format_validation.zig` @5987. tiffz/jpegz already linked.

---

## Phase 0 — Diagnose (systematic-debugging; NO code changes)

Establish ground truth per fixture before changing anything. The Iron Law: no fixes without root-cause first.

- [ ] **Step 1:** For each fixture (CR2, ARW, NEF, ORF, RW2, RAF, NRW), instrument or one-off-probe: does `findTiffPreviewLocation` (or RAF/RW2 equivalent) return a preview offset/length? Record offset, length, and length-as-%-of-file.
  - If a preview IS found: the format's ~0% sniper is the JPEG-tolerance ceiling (expected). Shotgun should show hits proportional to preview fraction.
  - If a preview is NOT found: the format silently falls to `.structural` — that's a discoverable IFD-walk gap (real fix) AND a no-silent-skip violation (Phase 2).
- [ ] **Step 2:** For the formats whose sweep showed 0% shotgun too, confirm whether shotgun corruption is even landing in the preview region (preview fraction × 100 trials). If preview fraction is <1%, 0/100 shotgun is statistically expected — note it, don't "fix" a non-bug.
- [ ] **Step 3:** Write findings to a scratch note (`docs/superpowers/notes/2026-05-28-raw-diagnosis.md`, not committed). This note decides which of Phases 1-3 are worth doing and in what order.

**Gate:** Phase 0 output may reveal that ARW/NEF/ORF are already at their honest ceiling (preview found, JPEG-tolerant) — in which case the only real code work is RW2 (Phase 1) + honesty (Phase 2), and Phase 3 becomes the strategic conversation. Report this to Peter before grinding.

---

## Phase 1 — RW2 deep validation (the one clear win)

RW2 (Panasonic, TIFF-variant magic `II\x55\x00`) currently returns `initial_result` — structural only. Give it a deep path like its TIFF-RAW siblings.

### Task 1.1 — Failing test

- [ ] **Step 1 (failing test):** Corrupt a byte inside the RW2 fixture's preview-JPEG region (offset from Phase 0); assert detection. It fails today because RW2 never deep-validates.
- [ ] **Step 2:** Determine whether `findTiffPreviewLocation` already handles RW2's non-standard magic (0x55 instead of 0x2A). If it bails on the magic, add an RW2 branch (RW2 IFDs are otherwise standard; the preview is typically in IFD0 or a SubIFD as a JPEG).

### Task 1.2 — Implementation

- [ ] **Step 1:** Add a `validateRw2Deep(allocator, source)` that mirrors `validateTiffDeep`'s preview path (or route `.rw2` through `validateTiffDeep` directly if the magic shim makes it work). Change the dispatch at `format_validation.zig:6007` from `.rw2, .cr3 => initial_result` to `.rw2 => <deep>`, leaving `.cr3 => initial_result`.
- [ ] **Step 2:** Preview decode failure → FAIL `.full`; preview found + decodes → `.full`; no preview found → `.structural` **with the Phase-2 WARN** (no silent skip).
- [ ] **Step 3:** Confirm clean RW2 fixture still validates; corruption test passes. Commit.

---

## Phase 2 — Honesty: no silent structural fallback (no-silent-skip rule)

`validateTiffDeep` currently does this **silently**:
- `readAllAlloc(..., max_tiff_size)` fails (file too big — RAF is 208 MB!) → `return okWithDepth(.structural)` with no message.
- `findTiffPreviewLocation` returns null → `return okWithDepth(.structural)` with no message.

Both claim a clean-ish result while having skipped the deep check. That violates the byte-complete-validation invariant ("every 'I can't deeply validate this' path MUST surface").

### Task 2.1 — Surface the fallback

- [ ] **Step 1 (failing test):** Assert that a RAW file with no discoverable preview (or one too large to buffer) returns a result carrying an INFO/WARN message like `"preview JPEG not located; raw sensor data not validated"` — NOT a bare `.structural` OK.
- [ ] **Step 2:** Add the message at both fallback sites. Use INFO (min) per the no-silent-skip policy; the depth stays `.structural` so the report harness can distinguish it from `.full`.
- [ ] **Step 3:** Check `max_tiff_size` against the RAF (208 MB) / DNG (77 MB) fixtures — if it's smaller, either stream the preview slice instead of `readAllAlloc` (preferred — we only need the preview bytes, located via IFD offsets without buffering the whole file) or raise the cap with a documented rationale. Streaming is the right fix: `findTiffPreviewLocation` only needs the IFD region, and the preview can be read by offset.
- [ ] **Step 4:** Tests pass; commit.

---

## Phase 3 — Wire LibRaw for raw sensor-data validation (DECIDED: Option B, Peter 2026-05-28)

**Decision (Peter):** Wire LibRaw to decode the actual raw sensor data — the only lever for detection materially above the preview ceiling. Ship native binaries on the platforms where LibRaw builds; **`--warn`/graceful-degrade on platforms where it doesn't** (fall back to preview+structural with an explicit message, never silently). `libraw_validator.zig` already exists as a starting point.

**HARD CONSTRAINT — NO PYTHON.** LibRaw's default build pulls Python in (some codegen / build tooling). We do **not** adopt Python tooling under any circumstances. Find LibRaw's no-Python build path; **fork LibRaw if necessary** to strip the Python build dependency (use `find_github_forks_with_file` to look for an existing fork with a clean `flake.nix`/`build.zig`/`CMakeLists` that already builds Python-free; check Peter's sibling dirs first per memory). Document the build recipe.

**This Phase warrants its own dedicated plan** (build wiring + cross-target CI is substantial). Outline of the work:

- [ ] **Step 1 — No-Python LibRaw build:** Establish a LibRaw build (vendored fork or patched derivation) with the Python build-time dependency removed. Add to `flake.nix`. Verify it builds in Nix's sandbox (no network) per the project's Zig+Nix+Garnix dep strategy.
- [ ] **Step 2 — Link + per-target gating:** Link LibRaw into the native build. For the 5 OS/arch targets, gate availability at comptime/build-time: targets where LibRaw links get the deep raw-decode path; targets where it doesn't compile a stub that returns a "raw sensor validation unavailable on this platform — preview+structure only" message (no-silent-skip honesty).
- [ ] **Step 3 — Revive `validateRawFile`:** Wire `libraw_validator.validateRawFile` into the deep dispatch for CR2/NEF/ARW/ORF/RW2 (after the preview check). LibRaw decode failure on a structurally-valid file = corruption in the sensor data → FAIL `.full`. Fix the previously-misleading "via LibRaw" comments to now be accurate.
- [ ] **Step 4 — TDD per format:** Failing test — corrupt the raw sensor region (NOT the preview) of each fixture; assert LibRaw decode catches it. This is where the real detection lift comes from. Confirm clean fixtures still pass (LibRaw must accept all ground-truth files).
- [ ] **Step 5 — Re-sweep + honest report:** Measure the lift (should be substantial — raw mosaic is the bulk of the file). Update the report; distinguish LibRaw-validated targets from preview-only targets.

> Until this dedicated plan runs, Phases 1-2 (RW2 deep path + no-silent-skip honesty) stand alone and ship the incremental wins. Phase 3 is the big swing.

---

## Phase 4 — Re-sweep + report refresh

- [ ] **Step 1:** `./build`, then re-sweep the formats that changed (at minimum RW2; others if Phase 0/3 produced changes):
```bash
for fmt in rw2 cr2 arw nef orf raf nrw; do
    for mode in sniper bolter shotgun; do
        scripts/corruption-experiment "$mode" \
            "$(glob ground_truth_examples/$fmt/*)" \
            --count 100 --seed 42 \
            --output "docs/corruption-sweep-results/${fmt}_${mode}.tsv"
    done
done
```
- [ ] **Step 2:** Update RAW rows in `docs/corruption-detection-report.md` with measured rates + an honest "preview-validated; raw sensor data not checked" annotation where applicable.
- [ ] **Step 3:** `./tests/cli/master_report_drift` → exit 0. Commit.

---

## Out of scope (parked)

- **CR3 (Canon)**: ISO-BMFF, not TIFF; preview in `PRVW`/`THMB` boxes — different code path (closer to HEIC/MP4 box walker). Note the gap honestly; separate follow-up.
- **PEF (Pentax)**: no fixture — SKIP with a report note until one is provided.
- **MakerNote secondary previews**: marginal; parked.

---

## Risk + rollback

| Risk | Mitigation |
|---|---|
| "Fixing" a non-bug (0% that's actually the honest ceiling) | Phase 0 diagnosis gates all code work; we only fix confirmed gaps (RW2, silent fallback). |
| RW2 magic shim breaks standard TIFF path | RW2 gets its own dispatch branch; TIFF path untouched; its own commit. |
| `readAllAlloc` OOM on 208 MB RAF | Phase 2 streams the preview by offset instead of buffering the whole file. |
| LibRaw cross-target breakage | Phase 3 keeps LibRaw as a *separate* gated decision, not bundled into this plan. |

**Rollback path:** RW2 deep path and the honesty messages are independent commits, each revertable without touching the working DNG/CR2/NEF/ARW/ORF paths.

---

## Self-review checklist

- [x] Rewritten against **actual code**, not the stale RESUME premise.
- [x] Distinguishes genuine gaps (RW2, silent fallback) from honest ceilings (JPEG-tolerance) — no fixing non-bugs.
- [x] Phase 0 is a systematic-debugging diagnosis gate.
- [x] No-silent-skip violation (Phase 2) surfaced and fixed.
- [x] Dead LibRaw code + unlinked dep flagged; fate decided in Phase 3, not assumed.
- [x] The real detection-ceiling lever (raw sensor decode) is a labeled decision for Peter (A/B/C), not a silent assumption.
- [x] Large fixtures handled by offset-streaming, not whole-file reads.

---

**Reproduce + verify:**
```bash
./build
nix develop -c zig build test -- --test-filter "rw2"
nix develop -c zig build test -- --test-filter "findTiffPreviewLocation"
scripts/corruption-experiment shotgun "$(glob ground_truth_examples/rw2/*)" --count 1000 --seed 42
# Expected: RW2 shotgun materially above the pre-wiring 0%.
./tests/cli/master_report_drift   # exit 0
```
