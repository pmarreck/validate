# `--damage-original` / `--undo-damage` — reversible destructive corruption

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user *intentionally damage a real file in place* (sniper / bolter / shotgun) for testing other tools, recovery workflows, or demos — but make the damage **undoable** via a hash-keyed undo file. Because all corruption becomes XOR-based, multiple overlapping corruptions compose and undo in reverse order, each restoring exactly one step.

**Guardrails (Peter's spec — non-negotiable):**
- `--damage-original` **errors without `--confirm`**.
- `--no-undo` (skip writing the undo file) **errors without `--override`**.
- Before any byte is changed, an undo file is written to `$TMPDIR`, **named by the SHA-256 of the pre-corruption file**, establishing a 1:1 undo mapping.
- Damage emits **RED CAPITAL** warnings to stderr with the exact `--undo-damage <path>` command to reverse it.
- `--undo-damage <path>` hashes the *current* (damaged) file, finds the matching undo file in `$TMPDIR`, applies it, restoring the previous state.

**Architecture (Peter's standing rule — logic in Zig, through FFI):**
```
C CLI (flag parse, RED CAPS warnings) ──► FFI ──► Zig core
   Zig owns: corruption (XOR), SHA-256, undo-file write, undo replay, verification
```
The existing `test_coverage.zig` already routes sniper/bolter/shotgun through the FFI. This extends that path: instead of corrupting a copy in memory, it corrupts the real file's bytes and records a reversible undo record.

**Tech Stack:** Zig 0.15.2 — `std.crypto.hash.sha2.Sha256`, `std.fs` for in-place file rewrite, `std.Random` (seedable DPRNG) for offset selection. FFI `ffi/c_api.zig` / `ffi/validate_core.h`; CLI `cli/main.c`.

---

## The undo-file format (Peter's spec, verbatim)

The undo file is keyed by the SHA-256 of the file **as it is right now** (before this corruption is applied). Applying the corruption produces a new file with a new hash; to undo, you hash the damaged file and look up `<that-hash>` — but the *content* of an undo record describes how to get from the damaged state back to the prior state. (See Task 0 for the precise hash-keying resolution.)

**For bolter / shotgun:**
```
offset_bytes=<byte offset>
length_bytes=<length; 1 or 4096>
from_value=<hex, the corrupted value>
to_value=<hex, the original value>
hash=<sha256 of the file before this particular corruption was done>
```

**For sniper:**
```
offset_bytes=<byte offset, 0-n>
offset_bits=<bit offset, 0-7>
length_bits=1
from_value=<0 or 1>
to_value=<inverse of from_value>
hash=<sha256 of pre-corruption file>
```

**Composition:** because every corruption is XOR, undos applied in reverse order each restore one step. The undo file's `hash` field is the pre-corruption hash; that's what lets a chain of undos walk backward deterministically.

---

## Phase 0 — Resolve the hash-keying semantics (design gate, no code)

There's one subtlety to nail down before coding, because the file is named by a hash but corruption *changes* the hash:

- The undo file records `hash = <sha256 of file BEFORE this corruption>` (per spec).
- `--undo-damage <path>` hashes the **current (damaged)** file to find which undo to apply.
- Therefore the undo file must be **findable by the DAMAGED file's hash**, while its `hash=` field stores the PRE-corruption hash (the state we're restoring to, and the key for the *next* undo in the chain).

**Resolution to implement:** the undo file's **filename** = SHA-256 of the **damaged** (post-corruption) file; the **`hash=` field inside** = SHA-256 of the **pre-corruption** file. Then:
1. Damage file (hash H0) → produces file (hash H1). Write `$TMPDIR/H1.undo` containing `hash=H0` + the XOR record.
2. `--undo-damage` on the damaged file: hash it → H1 → open `$TMPDIR/H1.undo` → apply XOR record → file returns to H0 → verify computed hash == the file's `hash=H0` field. ✅
3. Chained: a second damage on H1 → H2 writes `$TMPDIR/H2.undo` (`hash=H1`). Undo H2→H1, then undo H1→H0. Reverse-order chain works.

- [ ] **Step 1:** Confirm this resolution with the test design below (Task 3.x chain test encodes it). Write it into the plan's implementation notes. No code yet.

> If Peter prefers filename = pre-corruption hash instead, the chain lookup changes (you'd hash, then search for an undo whose `hash=` field matches — a scan, not a direct open). The damaged-hash-as-filename approach above gives O(1) direct lookup and is the recommended default. **Flag this to Peter at greenlight.**

---

## Phase 1 — Migrate shotgun to XOR (prerequisite; Peter approved)

Sniper (single-bit flip) and bolter (1-byte XOR 0xFF) are already XOR. Shotgun currently **overwrites** 4096 bytes with random data — not composable/undoable. Migrate it to **XOR-with-random** so the whole family is XOR and the undo chain works uniformly.

### Task 1.1 — Failing test: shotgun is XOR (round-trips)

- [ ] **Step 1 (failing test):** In `test_coverage.zig`, assert that applying shotgun-XOR twice with the same seed/offset/keystream restores the original bytes (`corrupt(corrupt(x)) == x`). The current overwrite implementation fails this.
- [ ] **Step 2:** Change shotgun from overwrite to `buf[off+i] ^= keystream[i]` over the 4096-byte window, where `keystream` comes from the seeded DPRNG. Round-trip test passes; commit.

### Task 1.2 — Re-sweep shotgun, confirm statistical no-op

- [ ] **Step 1:** Re-run the shotgun column of the corruption sweep across the standard format set (the migration should be statistically identical — XOR-with-random vs overwrite-with-random both maximally perturb 4096 bytes).
- [ ] **Step 2:** Regenerate the shotgun TSVs; confirm detection rates are within noise of prior values. Update `docs/corruption-detection-report.md` if any row drifts beyond CI. Run `./tests/cli/master_report_drift` → exit 0.
- [ ] **Step 3:** Commit (the TSV regeneration is expected churn — note it in the commit message).

---

## Phase 2 — Zig core: in-place damage + undo-file write

### Task 2.1 — Failing test: damage writes a correct undo file

- [ ] **Step 1 (failing test):** Call the (not-yet-existing) `damageFileInPlace(path, mode, seed, write_undo=true)`. Assert:
  - The file bytes changed at the expected offset (seeded → deterministic).
  - An undo file exists at `$TMPDIR/<sha256-of-damaged-file>.undo`.
  - Its contents match the spec format for the mode (parse `offset_bytes`, `from_value`, `to_value`, `hash`).
  - `hash=` field == SHA-256 of the **pre-corruption** bytes.
- [ ] **Step 2:** Implement `damageFileInPlace`:
  1. Read file; compute H0 = SHA-256.
  2. Apply XOR corruption (reuse the test_coverage corruption fns) at a seeded offset.
  3. Compute H1 = SHA-256 of damaged bytes.
  4. Write `$TMPDIR/H1.undo` with the spec-format record (`hash=H0`).
  5. Write damaged bytes back to `path` (atomic: write temp + rename, to avoid a torn file on crash).
- [ ] **Step 3:** Tests pass; commit.

### Task 2.2 — `--no-undo` path

- [ ] **Step 1 (failing test):** `damageFileInPlace(..., write_undo=false)` does NOT create an undo file but still damages. (The guardrail that `--no-undo` requires `--override` lives in the CLI layer — Phase 4.)
- [ ] **Step 2:** Implement. Commit.

---

## Phase 3 — Zig core: undo replay + verification

### Task 3.1 — Failing test: single undo restores exactly

- [ ] **Step 1 (failing test):** Damage a file (H0→H1), then `undoDamage(path)`:
  - Hashes current file → H1 → opens `$TMPDIR/H1.undo`.
  - Applies the XOR record.
  - Asserts restored bytes == original, and computed hash == the undo's `hash=H0` field.
  - Asserts the file is byte-identical to the pre-damage original.
- [ ] **Step 2:** Implement `undoDamage(path)`: hash current → find `$TMPDIR/<hash>.undo` → parse → apply XOR (`from`→`to`) → verify post-restore hash matches the `hash=` field → write back atomically. Error clearly if no matching undo file is found. Commit.

### Task 3.2 — Failing test: chained overlapping undos restore in reverse order

This is the composition guarantee Peter called out explicitly.

- [ ] **Step 1 (failing test):** Damage the SAME file three times (H0→H1→H2→H3), with at least two corruptions whose byte ranges **overlap**. Then `undoDamage` three times. Assert:
  - After undo #1: file hash == H2.
  - After undo #2: file hash == H1.
  - After undo #3: file hash == H0 (byte-identical to original).
  - Overlapping XOR corruptions compose correctly (the overlap region is restored exactly, proving XOR composability).
- [ ] **Step 2:** Confirm the implementation already handles this (it should, given XOR + per-step hash chaining). If not, fix. Commit.

### Task 3.3 — FFI surface

- [ ] **Step 1:** Add FFI entries: `validate_damage_original(path, mode, seed, write_undo, ...)` and `validate_undo_damage(path)`. Return structured results (offset, from/to, undo-file path, restored-hash-verified bool).
- [ ] **Step 2 (failing test):** FFI-level test drives damage→undo and checks the returned struct.
- [ ] **Step 3:** Declare in `ffi/validate_core.h`. Build clean. Commit.

---

## Phase 4 — C CLI: flags, guardrails, RED CAPS warnings

### Task 4.1 — Failing CLI test: guardrails

- [ ] **Step 1 (failing CLI test):** `tests/cli/damage_original` asserts:
  - `validate --damage-original sniper <file>` (no `--confirm`) → **errors**, file unchanged.
  - `validate --damage-original sniper --confirm --no-undo <file>` (no `--override`) → **errors**, file unchanged.
  - `validate --damage-original sniper --confirm <file>` → damages, prints RED CAPS warning + the exact `--undo-damage` command, undo file created.
  - `validate --undo-damage <file>` → restores; file byte-identical to original (assert via sha256 compare).
  - Full chain: damage ×3 (overlapping), undo ×3, file restored.
  - Use a **throwaway copy** of a fixture in `$TMPDIR` so no ground-truth file is ever harmed. (Set `-u` only, never `set -euo pipefail`.)
- [ ] **Step 2:** Parse `--damage-original <mode>`, `--confirm`, `--no-undo`, `--override`, `--undo-damage <path>`, optional `--seed`. Enforce guardrails in C before calling the FFI. Route to FFI.
- [ ] **Step 3:** Add to `./test`. Tests pass; commit.

### Task 4.2 — RED CAPS warning UX

- [ ] **Step 1:** On damage, print to stderr (respecting `--no-color`/`--simple`):
  ```
  ⚠️  DAMAGE APPLIED TO ORIGINAL FILE: <path>
      MODE: sniper   OFFSET: <byte>:<bit>
      UNDO FILE: $TMPDIR/<hash>.undo
      TO REVERSE:  validate --undo-damage "<path>"
  ```
  in **bold red** when ANSI is enabled. Capitalized per Peter's spec.
- [ ] **Step 2:** Confirm the warning text is captured & asserted in the CLI test (the "back of the cabinet" rule — expected stderr is verified, not left visible during test runs).
- [ ] **Step 3:** Commit.

### Task 4.3 — Help + about

- [ ] **Step 1:** Document `--damage-original`, `--confirm`, `--no-undo`, `--override`, `--undo-damage` in `-h`/`--help`, with the guardrail requirements spelled out.
- [ ] **Step 2:** Commit.

---

## Out of scope (parked)

- **GUI exposure** — Peter: CLI-only.
- **Undo files surviving reboot** — `$TMPDIR` is RAM-backed and ephemeral; undo is a session-lifetime convenience, not durable backup. Document this (the warning could note "undo file is in TMPDIR and won't survive a reboot").
- **Cross-machine undo** — undo files are local to `$TMPDIR`.
- **Damaging multiple files in one invocation** — start single-file; batch later if wanted.

---

## Risk + rollback

| Risk | Mitigation |
|---|---|
| Accidental irreversible damage | Two-key guardrail (`--confirm` for damage, `--override` for `--no-undo`); undo file written BEFORE bytes change; atomic write-temp-then-rename so a crash can't tear the file. |
| Undo file lost (TMPDIR wiped) | Documented as session-lifetime; `--no-undo` requires explicit `--override` so the safety net is on by default. |
| Hash collision picks wrong undo | SHA-256 — collision is not a practical concern; post-restore hash verification against the `hash=` field catches any mismatch and errors rather than corrupting further. |
| Shotgun XOR migration changes detection stats | Phase 1.2 re-sweeps and confirms statistical no-op before proceeding; report drift test gates it. |
| Tests harming ground-truth files | All CLI tests operate on throwaway copies in `$TMPDIR`; ground-truth files are never written. |

**Rollback path:** Phase 1 (shotgun XOR) is independent and lands first. Phases 2-4 are additive CLI surface; reverting the C-CLI parse disables damage/undo without touching the corruption core.

---

## Self-review checklist

- [x] All corruption is XOR (shotgun migrated in Phase 1) → undo chain composes.
- [x] Hash-keying semantics resolved in Phase 0 (filename = damaged hash; `hash=` field = pre-corruption hash; O(1) lookup) — flagged to Peter at greenlight.
- [x] Guardrails: `--confirm` for damage, `--override` for `--no-undo` — both tested to error without.
- [x] Undo written before damage; atomic file rewrite; post-restore hash verification.
- [x] Overlapping-corruption reverse-order chain explicitly tested (Peter's composition requirement).
- [x] RED CAPS warning printed AND captured/asserted in tests (no stray stderr).
- [x] Logic in Zig core through FFI; C CLI only parses + warns — matches architecture rule.
- [x] Tests operate on throwaway copies; ground-truth never harmed; `set -u` only.

---

**Reproduce + verify:**
```bash
./build
nix develop -c zig build test -- --test-filter "damage"
nix develop -c zig build test -- --test-filter "shotgun xor"
tests/cli/damage_original
# Manual smoke (on a throwaway copy!):
cp ground_truth_examples/jpeg/*.jpg "$TMPDIR/victim.jpg"
zig-out/bin/validate --damage-original sniper --confirm --seed 42 "$TMPDIR/victim.jpg"
zig-out/bin/validate --undo-damage "$TMPDIR/victim.jpg"
# Expected: victim.jpg byte-identical to the original copy.
```
