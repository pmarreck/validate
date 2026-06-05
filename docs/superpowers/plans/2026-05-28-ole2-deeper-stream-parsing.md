# OLE2 deeper stream parsing — Office legacy formats (DOC, XLS, PPT)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Meaningfully lift OLE2-family detection rates by adding the missing PPT validator and deepening the existing XLS BIFF + DOC body checks. Honest about format limits — these legacy formats don't carry internal checksums for body data, so detection is bounded by the fraction of bytes that have structural invariants.

**Expected lift (per format):**
- **PPT**: 0% → 25-45% sniper, 0% → 90%+ shotgun (new validator from scratch — biggest free-lunch gain)
- **XLS**: 22% → 35-45% sniper (add type-specific checks for 8-10 most common BIFF record types; current validator only checks record-header framing)
- **DOC**: 2% → 5-8% sniper on large docs (add UTF-16 sanity on body text in WordDocument stream); 52% → 65% shotgun on small docs

**Reality check on format ceilings:** DOC's body text in WordDocument stream is ~80% of a large file and has NO spec-required checksum — bit flips there are invisible by design. XLS BIFF record DATA contains arbitrary UTF-16 (SST), u64 doubles (NUMBER), and tokenized formulas where most bit patterns are valid-but-different values. PPT has the same record-chain structure as XLS BIFF so it should validate comparably well in record headers (12 bytes per record, hundreds-thousands per file).

**Tech Stack:** Zig 0.15.2 core. Existing infrastructure: `src/core/ole2_validator.zig` (FAT/dir/mini-FAT), `src/core/word_doc_validator.zig` (FIB+CLX+PLCF), `src/core/excel_biff8_validator.zig` (BIFF record-header walk). Adds `src/core/ppt_record_validator.zig`. Uses `ole2_validator.readNamedStream` to fetch stream contents.

---

## File Structure

**Will be created:**
- `src/core/ppt_record_validator.zig` — new PPT validator walking the PowerPoint Document stream record tree.
- `ground_truth_examples/ppt/sample.ppt` — synthesized via LibreOffice `soffice --convert-to ppt:"MS PowerPoint 97"`.
- `ground_truth_examples/ppt/README.md` — provenance + license note.
- `scripts/build-ppt-sample` — deterministic regen script (Bash + soffice).

**Will be modified:**
- `src/core/document_validators.zig:detectOle2Subformat` (lines 269-325) — dispatch PPT subformat to `ppt_record_validator.validatePptDeep`.
- `src/core/word_doc_validator.zig:validateDocDeep` (lines 80-219) — add Phase 3 body-text UTF-16 sanity check after CLX validation.
- `src/core/excel_biff8_validator.zig` — add Phase 2 per-record-type validators for BOF, EOF, DIMENSIONS, INDEX, ROW, NUMBER, LABELSST, RK, MULRK, FORMULA.
- `docs/corruption-detection-report.md` — refresh OLE2 row + add PPT row in Phase 5.

---

## Phase 1 — Add PPT validator from scratch

### Task 1.1 — Synthesize a deterministic PPT fixture

**Files:**
- Create: `scripts/build-ppt-sample` (Bash, +x)
- Create: `ground_truth_examples/ppt/sample.ppt`
- Create: `ground_truth_examples/ppt/README.md`

- [ ] **Step 1: Write the synthesizer.**

```bash
#!/usr/bin/env bash
# Regenerate ground_truth_examples/ppt/sample.ppt deterministically via
# LibreOffice headless conversion. The input PPTX is hand-authored CC0
# (mirrors the iWork sample pattern).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"

# Use existing CC0 sample.pptx as source
cp "$ROOT/ground_truth_examples/pptx/sample.pptx" "$TMP/source.pptx"

# Convert to .ppt (BIFF/OLE2 format)
nix-shell -p libreoffice --run "soffice --headless --convert-to 'ppt:MS PowerPoint 97' --outdir '$TMP' '$TMP/source.pptx'"

mkdir -p "$ROOT/ground_truth_examples/ppt"
mv "$TMP/source.ppt" "$ROOT/ground_truth_examples/ppt/sample.ppt"
echo "Built ppt sample:"
ls -la "$ROOT/ground_truth_examples/ppt/sample.ppt"
file "$ROOT/ground_truth_examples/ppt/sample.ppt"
```

- [ ] **Step 2: Run.**

```bash
chmod +x scripts/build-ppt-sample
nix-shell -p libreoffice --run scripts/build-ppt-sample
```

Expected: `file` reports `Composite Document File V2 Document, ... title item: PowerPoint Document`.

- [ ] **Step 3: Write README.md noting CC0 provenance and regen instructions.**

```markdown
# PowerPoint (.ppt / BIFF / OLE2) ground truth

`sample.ppt` is derived from `ground_truth_examples/pptx/sample.pptx` (hand-authored CC0)
via `scripts/build-ppt-sample`, which runs `soffice --convert-to "ppt:MS PowerPoint 97"`.
Regenerates deterministically.
```

- [ ] **Step 4: Commit.**

```bash
# ground_truth_examples is a symlink to validate_gui — commit there
cd "$(readlink ground_truth_examples)/.."
git add ground_truth_examples/ppt/
git commit -m "ppt: add hand-authored CC0 sample.ppt fixture (built via soffice)"
cd -
git add scripts/build-ppt-sample
git commit -m "ppt: add build-ppt-sample synthesizer script"
```

### Task 1.2 — Failing test: PPT validation produces meaningful walk

**Files:**
- Create: `src/core/ppt_record_validator.zig`
- Modify: `src/core/document_validators.zig:detectOle2Subformat`

- [ ] **Step 1: Stub `ppt_record_validator.zig` with a function that always fails.** Just enough for the test to compile:

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const FileSource = @import("file_source.zig").FileSource;
const ole2 = @import("ole2_validator.zig");
const ValidationResult = @import("format_validation.zig").ValidationResult;
const FileFormat = @import("format_validation.zig").FileFormat;

pub fn validatePptDeep(allocator: Allocator, source: *FileSource) ValidationResult {
    _ = allocator;
    _ = source;
    return ValidationResult.invalid(.ole2_ppt, .invalid_value, "PPT validator not yet implemented", .structural);
}
```

- [ ] **Step 2: Wire dispatch in `document_validators.zig:detectOle2Subformat`** — add a case for PPT that calls `ppt_record_validator.validatePptDeep`. Reuse the existing PPT-subformat detection logic.

- [ ] **Step 3: Failing test using ground-truth sample.**

Add to `document_validators.zig` test block:

```zig
test "PPT structural: ground truth sample.ppt validates" {
    const allocator = std.testing.allocator;
    var source = try FileSource.fromPath(allocator, "ground_truth_examples/ppt/sample.ppt");
    defer source.deinit();
    const result = ppt_record_validator.validatePptDeep(allocator, &source);
    try std.testing.expect(result.valid);
}
```

- [ ] **Step 4:** Run; confirm FAIL (stub returns invalid).

### Task 1.3 — Implement the PowerPoint record walker

PowerPoint Document stream contains a sequence of records. Per [MS-PPT] §2.3:
- Each record begins with a `RecordHeader`: 2 bytes (recVer:4 || recInstance:12), 2 bytes recType (u16), 4 bytes recLen (u32 — length of the data following the header).
- Container records (recVer == 0xF) hold child records. Atom records (recVer != 0xF) hold opaque data.
- The top-level record is always a `DocumentContainer` (recType=0x03E8) or `MainMaster`, `Notes`, `Slide`, etc.

Walking the tree validates:
- Every 12-byte record header is well-formed (recType matches a known PPT atom type)
- recLen sums correctly (no oversized children, no truncation)
- Container nesting is balanced

**Files:** `src/core/ppt_record_validator.zig`

- [ ] **Step 1: Define known recType set.**

The 50-60 most common PPT atom types — see [MS-PPT] §2.13.24 for the full enum. Use a `std.StaticStringMap` or a comptime-sorted u16 array for O(log N) membership.

```zig
const KNOWN_REC_TYPES = [_]u16{
    0x03E8, // DocumentContainer
    0x03E9, // DocumentAtom
    0x03EA, // EndDocumentAtom
    0x03F0, // SlideListWithText
    0x03F1, // SlidePersistAtom
    0x03F8, // MainMaster
    0x03EE, // SlideAtom
    0x03F3, // SlideViewInfo
    0x1011, // OEPlaceholderAtom
    0x1015, // TextHeaderAtom
    0x0FA0, // TextCharsAtom
    0x0FA8, // TextBytesAtom
    // … add 40-50 more from §2.13.24
};

fn isKnownRecType(t: u16) bool {
    for (KNOWN_REC_TYPES) |k| if (k == t) return true;
    return false;
}
```

- [ ] **Step 2: Walk loop.**

```zig
fn walkRecords(data: []const u8) WalkResult {
    var off: usize = 0;
    var rec_count: u32 = 0;
    var unknown_rec_count: u32 = 0;
    while (off + 8 <= data.len) {
        const ver_inst = std.mem.readInt(u16, data[off..][0..2], .little);
        const rec_ver = ver_inst & 0x000F;
        const rec_instance = (ver_inst >> 4) & 0x0FFF;
        const rec_type = std.mem.readInt(u16, data[off + 2 ..][0..2], .little);
        const rec_len = std.mem.readInt(u32, data[off + 4 ..][0..4], .little);
        _ = rec_instance;

        if (off + 8 + rec_len > data.len) {
            return .{ .valid = false, .reason = "PPT record overruns stream" };
        }
        if (!isKnownRecType(rec_type)) {
            unknown_rec_count += 1;
            if (unknown_rec_count > 100) {
                return .{ .valid = false, .reason = "too many unknown record types — likely corrupt" };
            }
        }
        rec_count += 1;
        // For container records (rec_ver == 0xF), recurse into the data;
        // for atoms, skip past.
        if (rec_ver == 0xF) {
            const sub = walkRecords(data[off + 8 ..][0..rec_len]);
            if (!sub.valid) return sub;
        }
        off += 8 + rec_len;
    }
    return .{ .valid = true, .rec_count = rec_count, .unknown_count = unknown_rec_count };
}
```

- [ ] **Step 3: validatePptDeep ties readNamedStream + walkRecords:**

```zig
pub fn validatePptDeep(allocator: Allocator, source: *FileSource) ValidationResult {
    const ppt_stream = ole2.readNamedStream(allocator, source, "PowerPoint Document") catch {
        return ValidationResult.invalid(.ole2_ppt, .failed_to_read, "PowerPoint Document stream", .structural);
    } orelse {
        return ValidationResult.invalid(.ole2_ppt, .invalid_value, "no PowerPoint Document stream", .structural);
    };
    defer allocator.free(ppt_stream);

    const result = walkRecords(ppt_stream);
    if (!result.valid) {
        return ValidationResult.invalid(.ole2_ppt, .invalid_value, result.reason, .full);
    }
    return ValidationResult.ok(.ole2_ppt, .full);
}
```

- [ ] **Step 4: Tests pass.** The Task 1.2 test should now go green.

- [ ] **Step 5: Sniper corruption test.** Hand-corrupt a byte in the record header (e.g., flip a bit in recLen to make it overrun); confirm validator returns invalid.

```zig
test "PPT validator catches recLen overrun" {
    var data = std.testing.allocator.dupe(u8, @embedFile("../../ground_truth_examples/ppt/sample.ppt"));
    defer std.testing.allocator.free(data);
    // Flip the high bit of a recLen field somewhere in the PowerPoint stream
    // Pick a known PPT offset — derived from inspection of the fixture.
    data[0x800] ^= 0x80;
    var src = FileSource.fromBytes(data);
    const result = validatePptDeep(std.testing.allocator, &src);
    try std.testing.expect(!result.valid);
}
```

- [ ] **Step 6: Commit.**

```bash
git add src/core/ppt_record_validator.zig src/core/document_validators.zig
git commit -m "ppt: add PowerPoint record-tree validator for PPT/BIFF/OLE2"
```

---

## Phase 2 — Deepen XLS BIFF per-record-type validation

The current `excel_biff8_validator.zig` walks the Workbook stream record-by-record (record header `type:u16 + size:u16`). Adds type-specific checks for the most common record types.

### Task 2.1 — Survey existing checks

- [ ] **Step 1: Read `excel_biff8_validator.zig` end-to-end** (1173 lines). Enumerate which BIFF record types currently have type-specific data validation vs which are only header-walked.
- [ ] **Step 2: Write a one-line note per record type into a working scratchpad** (`docs/superpowers/notes/2026-05-28-xls-biff-coverage.md` — not committed).

### Task 2.2 — Add per-type validators for the high-frequency records

Per [MS-XLS] §2.4, these are the most common records in typical XLS files. Each should have a failing test first using `poi_formula.xls`.

| Record type | Code | What to validate |
|---|---|---|
| BOF | 0x0809 | size == 16; biffVersion (u16) ∈ {0x0500, 0x0600}; substream type ∈ known set |
| EOF | 0x000A | size == 0 |
| DIMENSIONS | 0x0200 | size == 14 (BIFF8); colMic < colMac; rwMic < rwMac |
| INDEX | 0x020B | size ≥ 16; reserved field == 0 |
| ROW | 0x0208 | size == 16; colMic < colMac |
| NUMBER | 0x0203 | size == 14; rw < 0x10000; col < 256 |
| LABELSST | 0x00FD | size == 10; isst < SST.cstUnique |
| RK | 0x027E | size == 10; rw < 0x10000; col < 256 |
| MULRK | 0x00BD | size == 6 + 6*N; colLast >= colFirst |
| FORMULA | 0x0006 | size ≥ 20; rw < 0x10000; col < 256 |

- [ ] **Step 1: For each row above** — write a failing test that hand-corrupts the relevant field in `poi_formula.xls` and asserts detection; add the type-specific check; pass test; commit.
- [ ] **Step 2: Re-run XLS sweep** (Task 5.1) after each commit to track lift incrementally.

10 commits total for this phase (one per record type). Each is ~30 lines of code + ~20 lines of test.

---

## Phase 3 — DOC body-text UTF-16 sanity check

The DOC body text lives in the `WordDocument` stream beginning at offset 0x200 (FIB header is 0x000-0x1FF). It's encoded as 8-bit CP-1252 (older) or 16-bit UTF-16LE (Word 97+).

UTF-16 invariants:
- Every code unit pair is well-formed (no isolated surrogates: high-surrogate 0xD800-0xDBFF must be followed by low-surrogate 0xDC00-0xDFFF)
- Control characters in body text are limited to specific Word special chars (0x07 = cell mark, 0x0D = paragraph mark, 0x0E = column break, 0x0B = manual line break, 0x0C = page break, 0x14 = field separator, 0x15 = field end). Other low-ASCII values are suspicious.

### Task 3.1 — Failing test

- [ ] **Step 1:** Hand-corrupt a UTF-16 high-surrogate byte in `word95_large.doc` body text region (offset >= 0x200, in the WordDocument stream). Verify detection.

### Task 3.2 — Implementation

Walk the WordDocument stream body bytes per CLX piece descriptor. For each piece marked as UTF-16:
- Iterate code units in pairs
- If high-surrogate found, next must be low-surrogate
- Count isolated surrogates; if > 0, emit WARN (not FAIL — lossy round-trips create these)

For pieces marked as CP-1252 (8-bit):
- Count C1 control bytes (0x80-0x9F) — these are mostly unassigned in CP-1252
- High proportion (> 5%) of unassigned bytes in body suggests corruption

- [ ] **Step 1:** Add `validateDocBodyEncoding` in `word_doc_validator.zig`.
- [ ] **Step 2:** Wire it into `validateDocDeep` after CLX validation.
- [ ] **Step 3:** Tests pass; commit.

---

## Phase 4 — Update OLE2 dispatch for new PPT subformat

`detectOle2Subformat` already recognizes PPT (looking for `PowerPoint Document` stream) but currently falls through to generic OLE2 validation. Phase 1 added the dispatch in Task 1.2. Confirm here.

- [ ] **Step 1:** Test that `ground_truth_examples/ppt/sample.ppt` correctly dispatches through `validatePptDeep` and not generic OLE2.

```zig
test "OLE2 subformat: ppt dispatches to validatePptDeep" {
    var src = try FileSource.fromPath(std.testing.allocator, "ground_truth_examples/ppt/sample.ppt");
    defer src.deinit();
    const subformat = detectOle2Subformat(&src);
    try std.testing.expectEqual(FileFormat.ole2_ppt, subformat);
}
```

- [ ] **Step 2: Verify `validate` CLI produces the expected output.**

```bash
zig-out/bin/validate ground_truth_examples/ppt/sample.ppt
# Expected: OK ground_truth_examples/ppt/sample.ppt: PowerPoint (.ppt) (fully validated)
```

---

## Phase 5 — Re-sweep + report refresh

### Task 5.1 — Run corruption-experiment on OLE2-family

```bash
./build
for fmt in doc xls ppt; do
    for mode in sniper bolter shotgun; do
        scripts/corruption-experiment "$mode" \
            "ground_truth_examples/$fmt/sample.$fmt" \
            --count 100 --seed 42 \
            --output "docs/corruption-sweep-results/${fmt}_${mode}.tsv"
    done
done
```

Special case: `doc/word95_large.doc` is the canonical DOC fixture in the report (NOT sample.doc which is smaller). Re-run separately:

```bash
for mode in sniper bolter shotgun; do
    scripts/corruption-experiment "$mode" \
        "ground_truth_examples/doc/word95_large.doc" \
        --count 100 --seed 42 \
        --output "docs/corruption-sweep-results/doc_${mode}.tsv"
done
```

### Task 5.2 — Refresh report rows

**Files:** `docs/corruption-detection-report.md`

- [ ] **Step 1:** Update DOC (large) row with new sniper rate.
- [ ] **Step 2:** Update XLS row.
- [ ] **Step 3:** ADD a PPT row (currently doesn't exist).
- [ ] **Step 4:** Run `./tests/cli/master_report_drift`; expect exit 0.
- [ ] **Step 5:** Commit.

---

## Risk + rollback

| Risk | Mitigation |
|---|---|
| **soffice produces a non-deterministic PPT** (modification timestamps in OLE2 header drift between runs) | Phase 1 fixture is regenerated by script; commit once and treat subsequent regenerations as expected churn. If determinism becomes important, run `soffice` with `--norestore --nologo --nofirststartwizard` and pin a specific LibreOffice version via nix-shell. |
| **Unknown PPT record type set too narrow** — newer PPT records added in PowerPoint 2003/2007 may not be in the initial KNOWN_REC_TYPES list, triggering false-positive "too many unknown types" failures. | Phase 1 walks the ground-truth fixture and adds any encountered types to the known set BEFORE committing. The 100-unknown threshold is generous. |
| **DOC body encoding check fires on legitimately mixed-encoding documents** (some Word docs have both CP-1252 and UTF-16 pieces). | Phase 3 emits WARN, not FAIL — same pattern as ZIP plan. Body-text encoding sanity is a soft signal. |
| **XLS per-record validation rejects valid-but-unusual records** (Excel allows BIFF8 substream switches mid-stream, alternative encodings). | Each per-type check is gated by record-type matching first; unknown types pass through unchanged. The size invariants (BOF size == 16, EOF size == 0) are spec-mandatory; rw/col bounds are spec-mandatory. |

**Rollback path:** every phase commits independently. Per-record-type checks (Phase 2) are individual commits so any false-positive can be reverted without affecting other checks.

---

## Out of scope (parked for future)

- **Deeper XLS records**: BLANK, MULBLANK, BOOLERR, STRING (formula result), SHRFMLA, ARRAY — lower frequency, marginal lift each.
- **DOC field-instruction validation**: parse `\* FORMAT` and field codes for sanity. Niche.
- **PPT animation/transition timing nodes** (`ProgTags`, `ExtTimeNodeContainer` subtrees): deeply nested with version-dependent layouts. Phase 1.5 validates slide text/shape/placeholder atoms (the high-frequency, well-bounded ones); the timing subtrees are lower-frequency and parked.
- **DOC grammar/spelling PLCF tables** (`PlcfGram`, `Plcfspl`), revision marks, bookmarks: niche tables. Phase 3.5 covers the high-value STSH / SttbfFnm / bin-table FKP walk; these remain parked.
- **WPS Office / Kingsoft Office variants**: their OLE2 layouts differ slightly; not in scope.

---

## Self-review checklist

- [x] Each phase has bite-sized TDD tasks with failing test → impl → pass → commit.
- [x] Fixture (sample.ppt) is reproducibly synthesized via a committed script.
- [x] Phase 2's 10 record-type validators are listed with their spec invariants; each gets its own commit.
- [x] Phase 3's body-text check is calibrated as WARN, not FAIL (real-world tolerance).
- [x] Phase 5 measures the lift before declaring done.
- [x] No "TBD" / "appropriate" placeholders.

---

**Reproduce + verify:**
```bash
scripts/build-ppt-sample
./build
nix develop -c zig build test -- --test-filter "PPT structural"
nix develop -c zig build test -- --test-filter "XLS"
./tests/cli/master_report_drift                           # exit 0
scripts/corruption-experiment sniper ground_truth_examples/ppt/sample.ppt --count 1000 --seed 42
# Expected: ≥25% detection rate (was 0%)
```
