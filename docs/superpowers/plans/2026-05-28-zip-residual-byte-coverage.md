# ZIP residual-byte coverage — closing the LFH↔CD cross-check gaps

> **REVISED 2026-05-30 against the LIVE code.** The original draft assumed an
> API that does not exist in this codebase (`RunCtx`, `ctx.findings`,
> `ctx.strict`, a `FindingCode` enum, `validateZip(... &ctx)`). None of that is
> real. This revision is grounded in `archive_validators.zig` as it actually
> stands at commit `ad2668083`. It also documents a **latent bug discovered
> during recon** (misread LFH flags offset) that must be fixed before the flags
> cross-check is even meaningful.

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development
> or superpowers:executing-plans. Steps use checkbox (`- [ ]`) tracking.
> **Hard rule (see MISTAKES.md):** gate EVERY commit on a green
> `nix build .#checks.aarch64-darwin.test` (exit 0) BEFORE `git commit`. Use
> assert-gated exact-match edits (checked `count==1` replacement), not
> multi-substitution one-liners.

---

## Real architecture (verified, not assumed)

- **Entry point for deep cross-checks:** `validateZipDeepWithCentralDirectory(allocator, file, format, telemetry) ?ValidationResult` at `archive_validators.zig:1593`. Returns optional; `null` means "no central directory found, caller falls back". Reached via `validateZipDeep(allocator, source)` (line 1888) — **verify that linkage before writing the test** so the test exercises the cross-check path.
- **No findings sink, no per-call context.** Validators return a single `ValidationResult`. Warnings are a single `warning_message` string carried on the result, produced by `ValidationResult.okWithDepthAndWarning(format, depth, msg)` (used ~12x in this file already — e.g. lines 505, 1347, 2449).
- **`--strict` is a CLI-layer concept.** `cli/main.c` holds `g_global_strict_mode`; at line ~1229 it promotes ANY result carrying a `warning_message` (WARN) to a FAIL exit. Validators do **not** receive a strict flag and must not invent one. **Therefore "WARN by default, FAIL under --strict" is achieved for free**: return `okWithDepthAndWarning(...)` and the existing CLI plumbing does the rest. No new machinery.
- **Tests:** build a source with `file_source.FileSource.fromBuffer(&bytes)` (pattern at line 3094) and call the deep path; or embed a fixture via `@embedFile`. There are already 150 inline tests in this file and it's in the `mod.zig` test aggregator (line 378), so new `test "..."` blocks are discovered automatically.
- **The per-entry loop** (line 1613): `while (entry_count < central.entries and entry_count < max_entries)`. CD header is `[46]u8`; LFH is a 4-byte sig + `[26]u8`. Final success return is `okWithDepth(format, .full)` at line 1882.

### Fields already parsed (do NOT re-read)
CD side (around 1627–1635): `flags = readLe(u16, header[8..10])` ✓ (correct: CD offset 8–9 = general-purpose flags), `compression_method`, `stored_crc`, `compressed_size`, `uncompressed_size`, `filename_len`, `extra_len`, `comment_len`, `local_header_offset`.
LFH side (around 1737–1743): `local_compression`, `local_crc`, `local_compressed_size`, `local_uncompressed_size`, `local_filename_len`, `local_extra_len`, and `local_flags` — **but `local_flags` is MISREAD (see Phase 0).**

---

## Phase 0 — FIX the misread LFH flags offset (NEW — blocks Phase 2)

**Discovery.** Line 1743 reads:
```zig
const local_flags = readLe(u16, local_header[0..2]);
```
`local_header` is read *after* the 4-byte signature, so `local_header[N]` = file offset `4+N`. Thus `local_header[0..2]` = file offsets **4–5 = "version needed to extract"**, NOT the general-purpose flags (offsets **6–7** = `local_header[2..4]`). Confirmed by the sibling reads: `local_compression = local_header[4..6]` correctly lands on offset 8–9.

**Two consequences of the bug:**
1. Any flags cross-check against `local_flags` (Phase 2) would compare CD's real flags (offset 8–9) to the LFH *version* field → mismatch on virtually every real ZIP → universal false positives. The original plan would have bricked ZIP validation.
2. `has_data_descriptor = (local_flags & 0x0008) != 0` (line 1751) currently keys off version-needed. ZIP64 files (version 45 = 0x2D, bit 3 set) spuriously register as "has data descriptor" and SKIP the CRC/size cross-checks — a real, shipping coverage hole.

### Task 0.1 — Failing test
- [ ] Build a tiny ZIP whose LFH version-needed has bit 3 set (e.g. 0x2D) but whose general-purpose flags (offset 6–7) are 0. Assert the validator treats `has_data_descriptor == false` (i.e. it DOES run the CRC cross-check). The cleanest observable: a fixture with a deliberately wrong CD-vs-LFH CRC must FAIL — today it wrongly passes because the cross-check is skipped. (If constructing the version-needed fixture is fiddly, an equivalent unit test on a small helper that extracts flags from a known LFH byte buffer is acceptable — extract the offset logic into a testable `fn lfhFlags(local_header) u16` if needed.)

### Task 0.2 — Fix
- [ ] Change `local_header[0..2]` → `local_header[2..4]` so `local_flags` reads file offsets 6–7 (the real general-purpose flag word). Keep the variable name `local_flags`.
- [ ] Re-run the FULL ground-truth ZIP suite (docx/xlsx/pptx/odt/ods/odp/pages/numbers/keynote/epub) — confirm none regress. This is the risky change; a wrong fix here breaks every Office file. Gate commit on green build + clean ground-truth run.
- [ ] Commit: `zip: fix LFH general-purpose-flags offset (was reading version-needed)`.

---

## Phase 1 — Drop the CRC-zero short-circuit

Line 1753 today:
```zig
if (local_crc != 0 and stored_crc != 0 and local_crc != @as(u32, @intCast(stored_crc & 0xFFFFFFFF))) { ... FAIL ... }
```
A corruption that zeros the LFH CRC field bypasses the check. (`local_crc` itself is correctly read at offset 14–17.)

### Task 1.1 — Failing test + fixture
- [ ] Create `tests/fixtures/zip_tamper/build-fixtures.sh` (deterministic, `nix-shell -p zip`). Base: `zip` a one-entry "hello world\n" archive → `clean.zip`. Variant `lfh_crc_zero.zip`: zero the 4-byte LFH CRC at file offset 14 (`dd ... seek=14 count=4`).
- [ ] Commit the built fixtures (binary, ~150 B each) — they are deterministic regression inputs, not fuzz output.
- [ ] Failing test: `lfh_crc_zero.zip` must FAIL with `.checksum_mismatch` via the deep path. Confirm it currently PASSES (bug present).

### Task 1.2 — Fix
- [ ] Replace the short-circuit so a mismatch fails whenever EITHER side is non-zero; the only legal both-zero case is a genuinely empty entry (`compressed_size == 0`):
```zig
const stored_crc_u32 = @as(u32, @intCast(stored_crc & 0xFFFFFFFF));
if (local_crc != stored_crc_u32 and !(local_crc == 0 and stored_crc_u32 == 0 and compressed_size == 0)) {
    return ValidationResult.invalidCodeWithDepth(format, .checksum_mismatch, "ZIP CRC-32 mismatch (central vs local header)", .full);
}
```
  Note: this sits inside the `if (!has_data_descriptor)` block — correct, since data-descriptor entries legitimately carry CRC=0 in the LFH. (Phase 0 makes `has_data_descriptor` trustworthy.)
- [ ] Gate on green build + full ground-truth ZIP suite. Commit.

---

## Pre-flight: real-world divergence survey (RAN 2026-05-28, still valid)

Surveyed all ground-truth ZIP-family fixtures (167 entries) with `/tmp/zip-lfh-cd-divergence.lua`:

| Check | Real-world divergence | Severity decision |
|---|---|---|
| Flags (offset-correct) | 0/167 entries | **FAIL** — data justifies |
| Extra-field length | 38/167 — docx 21/21, xlsx 5/12, pptx 5/41, epub 7/7; LibreOffice+iWork 0 | **WARN** (auto-FAIL under `--strict`) |
| Extra-field content (when lengths match) | meaningful only when lengths match | **WARN** (auto-FAIL under `--strict`) |

OOXML writes extended-timestamp extras in LFH but not CD (LFH=28, CD=24) — legal per APPNOTE.TXT, widely considered sloppy. WARN keeps real files valid while surfacing it; `--strict` fails loud for archival/forensic use.

> ⚠️ Re-run this survey AFTER Phase 0, because the flags column was computed by the
> Lua tool (which reads the correct offset) — confirm the Zig validator now agrees
> with the tool's 0/167 once the offset bug is fixed.

---

## Phase 2 — Cross-check LFH flags vs CD flags (FAIL) — REQUIRES Phase 0

Both fields now exist and are correctly read (`local_flags` post-Phase-0, `flags` from CD line 1627).

- [ ] Failing test: `lfh_flag_flip.zip` (flip a byte at file offset 6, the real LFH flags) must FAIL with `.invalid_value`.
- [ ] Add after the existing compression cross-check (~line 1748):
```zig
if (local_flags != flags) {
    return ValidationResult.invalidCodeWithDepth(format, .invalid_value, "ZIP general-purpose-flag mismatch (central vs local)", .full);
}
```
  (CD flags variable is named `flags` at line 1627. Confirm the name in scope at the LFH cross-check point; capture it if shadowed.)
- [ ] **Critical regression gate:** run ALL ground-truth ZIP fixtures. The survey says 0/167 diverge, but this is the check most likely to surface a real-world counter-example — if any Office/iWork/EPUB fixture fails, DOWNGRADE to WARN (`okWithDepthAndWarning`) per the extra-field pattern and record the counter-example. Commit only when green.

---

## Phase 3 — LFH extra-field LENGTH cross-check (WARN)

Real data: OOXML/EPUB routinely differ. Emit WARN (auto-FAIL under `--strict`).

**Mechanism (adapted to real code — no findings sink):** the function early-returns
on hard errors and ends with `okWithDepth(format, .full)`. To carry a WARN to the
end, introduce a local `var deferred_warning: ?[]const u8 = null;` near the loop top;
set it (first-wins to keep the earliest signal) when a soft divergence is seen; at the
final return, if it's non-null return
`okWithDepthAndWarning(format, .full, deferred_warning.?)` instead of `okWithDepth`.

- [ ] Fixture `lfh_extra_len_bump.zip`: clone clean.zip, increment the LFH extra-len byte (file offset 28) by 1. (Note: this also shifts where the parser thinks data begins — verify the fixture still parses far enough to reach the cross-check; if not, instead craft a fixture whose CD extra-len differs from a valid LFH extra-len.)
- [ ] Failing test (default mode): result is `.valid == true` AND carries a `warning_message`.
- [ ] Add after Phase 2's flag check:
```zig
if (local_extra_len != extra_len and deferred_warning == null) {
    deferred_warning = "ZIP extra-field length mismatch (central vs local)";
}
```
- [ ] Wire `deferred_warning` into the final return (the `okWithDepth` at line 1882, plus any other success exits — audit them).
- [ ] Test default-mode WARN + (optional) a CLI-level test that `--strict` turns it into a non-zero exit (`tests/cli/`, exercising `g_global_strict_mode`).
- [ ] Ground-truth: docx/xlsx/pptx/epub must stay `.valid` (WARN only). Commit.

---

## Phase 4 — LFH extra-field CONTENT cross-check (WARN)

Only when lengths match (length mismatch already covered by Phase 3). Compare the
actual LFH extra bytes to the CD extra bytes.

- [ ] Locate where the loop currently skips the LFH extra (search for the `seekBy`/skip of `local_extra_len`). Replace with: read `local_extra_len` LFH bytes into a stack buffer (cap ~256; fall back to skip if larger), compare to the CD extra bytes (capture CD extra into a buffer when the CD entry is parsed — verify whether CD extra is currently read or skipped; it may need capturing).
- [ ] On mismatch (lengths equal, bytes differ): set `deferred_warning` (same mechanism as Phase 3) with `"ZIP extra-field content mismatch (central vs local)"`.
- [ ] Fixture `lfh_extra_byte_flip.zip`: needs an entry WITH an extra field present in both LFH and CD of equal length (for example, `zip` with a UID/GID `0x7875` extra), then flip one byte inside the LFH extra only.
- [ ] Default-mode WARN test + ground-truth no-regress. Commit.

---

## Phase 5 — EOCD entry-count consistency (FAIL) — narrowed

**Reality nuance:** the loop is *bounded by* `central.entries` (the EOCD-claimed count),
so a too-HIGH claim already makes the loop attempt to read a non-existent CD record and
fail with `.invalid_signature` (good — already covered). A too-LOW claim leaves trailing
real CD records un-iterated and is currently silent. So the genuinely-new check is:

- [ ] After the loop, verify the bytes immediately following the last-iterated CD record are the EOCD signature `PK\x05\x06` (i.e. there are no extra un-counted CD records). If a `PK\x01\x02` appears where EOCD was expected, the EOCD undercounts → FAIL `.invalid_value` "ZIP entry count mismatch (EOCD undercounts central directory)".
- [ ] Confirm the ZIP64 path (`needs_zip64`, sentinel 0xFFFF) is excluded from this check or uses the resolved count.
- [ ] Fixture `eocd_entry_count_low.zip`: a 2-entry archive with EOCD total_entries forced to 1. Failing test → FAIL. Commit.

---

## Phase 6 — Re-sweep + report refresh

- [ ] Add a `--validate-args` passthrough to `scripts/corruption-experiment` (~10 lines) so it can run `validate --strict`.
- [ ] Re-sweep docx/xlsx/pptx/odt/ods/odp/pages/numbers/keynote, default + `--strict`, 100 trials seed 42, into `docs/corruption-sweep-results/` (strict into a `2026-05-30-strict/` subdir).
- [ ] Expect: default rates hold or rise marginally (Phase 0/1/2/5); strict rates jump on OOXML/EPUB (Phase 3/4). **If any DEFAULT rate DROPS, a new check has a false-positive bug — investigate before committing.**
- [ ] Update `docs/corruption-detection-report.md`; `./tests/cli/master_report_drift` → exit 0. Commit.

---

## Risk + rollback

| Risk | Mitigation |
|---|---|
| **Phase 0 flags-offset fix breaks every Office file.** | Highest-risk change; gate on full ground-truth ZIP suite before commit. It is also a correctness fix (current code is wrong), so the suite passing is strong evidence. |
| **Flags cross-check (Phase 2) hits a real divergent file** despite 0/167 survey. | Downgrade Phase 2 to WARN+strict; record counter-example. |
| **Extra-field checks break OOXML/EPUB.** | Phases 3 & 4 are WARN-by-default via `okWithDepthAndWarning`; `--strict` (CLI `g_global_strict_mode`) escalates. Real files stay valid. |
| **Deferred-warning mechanism misses a success-exit path.** | Audit ALL `okWithDepth`/`ok*` returns in `validateZipDeepWithCentralDirectory`; route each through the deferred warning. |
| **EOCD check rejects multi-disk/ZIP64.** | Phase 5 excludes the ZIP64/sentinel path. |

**Rollback:** every phase commits independently; revert any single phase if false positives surface.

---

## Out of scope (parked)
- EOCD comment content (legitimately user data).
- CRC of the central directory itself (non-standard; ZIP spec doesn't define it).
- APK/JAR signature blocks (not Office/iWork).

---

## Self-review checklist
- [x] Grounded in the LIVE API (`validateZipDeepWithCentralDirectory`, `okWithDepthAndWarning`, CLI `g_global_strict_mode`) — no invented `RunCtx`/findings.
- [x] **Phase 0 captures the real latent bug** (LFH flags read version-needed) that the original plan would have tripped over.
- [x] WARN/strict achieved via the existing single-`warning_message` + CLI-strict plumbing, not a new findings sink.
- [x] Phase 5 narrowed to the genuinely-uncovered case (EOCD undercount).
- [x] Every phase: failing test → fix → green build gate → ground-truth no-regress → commit.

---

**Reproduce + verify:**
```bash
nix build .#checks.aarch64-darwin.test       # green before every commit
nix develop -c zig build test -- --test-filter ZIP
./tests/cli/master_report_drift               # exit 0
scripts/corruption-experiment sniper ground_truth_examples/docx/sample.docx --count 1000 --seed 42
```
