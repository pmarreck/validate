# `--cmd "<external> {}"` — benchmark validate against external tools

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the corruption-test-coverage harness invoke an *arbitrary external validator* per corruption trial, so we can benchmark `validate`'s detection rate against third-party tools (ImageMagick `identify`, `jpeginfo`, `ffmpeg -v error`, `qpdf --check`, `pdfinfo`, etc.) using the *exact same* corruption harness and statistics. This produces apples-to-apples comparison tables for marketing ("validate catches X% where jpeginfo catches Y%") and finds gaps where an external tool catches something we miss.

**Why it belongs in the test-coverage subsystem:** the sniper/bolter/shotgun loop already (1) corrupts a copy of a file, (2) runs the in-process validator, (3) records caught/missed, (4) aggregates a rate. `--cmd` swaps step 2 for "spawn external command on the corrupted bytes; exit 0 = missed (validator said OK), non-zero = caught." Everything else — trial count, seeding, Wilson CIs, TSV output — is reused unchanged.

**Semantics:**
- `--cmd "jpeginfo -c {}"` — `{}` is replaced with the path to the corrupted temp file for each trial.
- **Exit code 0** = external tool reported the (corrupted) file as *valid* → **MISS** (it failed to catch the corruption).
- **Non-zero exit** = external tool reported an error → **CAUGHT**.
- If `{}` is absent from the command string, the corrupted bytes are piped to the tool's **stdin** (for tools that read `-`).
- A per-trial **timeout** (default 10s, override `--cmd-timeout <sec>`) guards against hangs; a timeout counts as CAUGHT (the tool choked) but is tallied separately and reported, per the "no silent cap" rule.

**Architecture (per Peter's standing rule — logic in Zig, through the FFI):**
```
C CLI (--cmd parse) ──► FFI entry ──► Zig core test_coverage
                                          └─ corrupt copy → spawn child → map exit code → tally
```
The Zig core owns child-process spawning (`std.process.Child`), the `{}` substitution, stdin piping, and the timeout. The C CLI only parses the flag and passes the command string + timeout through the FFI.

**Tech Stack:** Zig 0.15.2 (`std.process.Child` — note PascalCase `.Pipe`/`.Inherit`/`.Ignore` per ZIG_RECENT_API_CHANGES.md). Existing `src/core/test_coverage.zig` corruption loop. FFI in `ffi/c_api.zig`, header `ffi/validate_core.h`, CLI `cli/main.c`.

---

## File Structure

**Will be modified:**
- `src/core/test_coverage.zig` — add an "external command" validation backend alongside the in-process one; substitution + spawn + timeout + exit-code mapping.
- `ffi/c_api.zig` — extend the test-coverage FFI entry with `cmd` (nullable C string) + `cmd_timeout_sec` (u32) params, OR add a sibling `validate_test_coverage_cmd` entry.
- `ffi/validate_core.h` — declare the new param(s)/entry.
- `cli/main.c` — parse `--cmd "<str>"` and `--cmd-timeout <sec>`; route to the FFI.
- `docs/` — a short "benchmarking against external tools" doc + example invocations.

**Will be created:**
- `tests/cli/cmd_external_validator` — Bash CLI test (part of `./test`).

---

## Phase 1 — Zig core: external-command backend

### Task 1.1 — Failing test: substitution + exit-code mapping (pure, no spawn)

The `{}` substitution and exit→verdict mapping are pure functions — test them without spawning anything.

- [ ] **Step 1 (failing test):** In `test_coverage.zig` test block, assert `substituteCmd("jpeginfo -c {}", "/tmp/x")` → `{"jpeginfo", "-c", "/tmp/x"}` (argv split). Assert `substituteCmd("foo bar", path)` (no `{}`) signals "pipe to stdin". Assert `verdictFromExit(0) == .missed`, `verdictFromExit(1) == .caught`.
- [ ] **Step 2:** Implement `substituteCmd` (split on spaces — quoting handled in Task 1.4) and `verdictFromExit`. Tests pass; commit.

### Task 1.2 — Failing test: spawn a real, deterministic child

Use `/usr/bin/false` (always exit 1 = CAUGHT) and `/usr/bin/true` (always exit 0 = MISS) as deterministic stand-ins — no external tool dependency, fully reproducible.

- [ ] **Step 1 (failing test):** A coverage run with `cmd = "true {}"` against a corrupted file must record **0% detection** (true always says "valid" → every trial missed). A run with `cmd = "false {}"` must record **100% detection**.
- [ ] **Step 2:** Implement the spawn path: write the corrupted bytes to a temp file (RAM-backed `$TMPDIR`), substitute `{}`, spawn via `std.process.Child`, capture exit code, map to verdict. Reuse the existing corruption + tally loop. Tests pass; commit.

### Task 1.3 — Timeout handling

- [ ] **Step 1 (failing test):** `cmd = "sleep 30"` with `cmd_timeout_sec = 1` must terminate the child and count it as CAUGHT-via-timeout, tallied separately. (Test must NOT actually wait 30s — the timeout fires at ~1s. This is condition-based, not a sleep hack: we're asserting the timeout *mechanism* kills the child, using a child that would otherwise outlive it.)
- [ ] **Step 2:** Implement timeout: spawn, poll for completion with a deadline, kill on expiry (`child.kill()`), record timeout tally. Tests pass; commit.

### Task 1.4 — stdin piping + quoted-arg handling

- [ ] **Step 1 (failing test):** `cmd = "cat"` (no `{}`) must pipe corrupted bytes to stdin; with a trivial wrapper that exits non-zero on certain content, assert the verdict maps correctly. Also assert a quoted arg with spaces (`--label "a b"`) survives argv splitting.
- [ ] **Step 2:** Implement stdin piping (`.stdin_behavior = .Pipe`, write bytes, close) when `{}` absent; implement minimal shell-like quote handling in `substituteCmd` (respect `"..."` so paths/labels with spaces work — Peter's CLI convention). Tests pass; commit.

---

## Phase 2 — FFI surface

### Task 2.1 — Extend the FFI entry

- [ ] **Step 1:** Decide: add params to the existing `validate_test_coverage` entry vs. a sibling `validate_test_coverage_cmd`. Prefer extending (nullable `cmd` = NULL means "use in-process validator"; non-NULL = external).
- [ ] **Step 2 (failing test):** A C-level FFI test (or Zig test calling through the FFI boundary) passing `cmd = "false {}"` returns a 100% detection result struct.
- [ ] **Step 3:** Implement; declare in `ffi/validate_core.h` (`const char *cmd`, `uint32_t cmd_timeout_sec`). Build clean. Commit.

---

## Phase 3 — C CLI parsing

### Task 3.1 — Parse `--cmd` / `--cmd-timeout`

- [ ] **Step 1 (failing CLI test):** `tests/cli/cmd_external_validator` asserts:
  - `validate --test-coverage sniper --cmd "false {}" --count 20 <file>` reports ~100% detection.
  - `validate --test-coverage sniper --cmd "true {}" --count 20 <file>` reports ~0% detection.
  - `--cmd-timeout 1 --cmd "sleep 30"` returns promptly (well under 30s) with timeout-tallied results.
  - `--cmd "tool with \"spaced arg\" {}"` parses without error.
- [ ] **Step 2:** Parse the flags in `cli/main.c` (non-positional, any-order, later-overrides-earlier per CLI conventions); route through the FFI. Emit the external-tool name in the stderr summary header.
- [ ] **Step 3:** Add the test to the `./test` runner. Tests pass; commit.

### Task 3.2 — Help + JSON output

- [ ] **Step 1:** Add `--cmd` and `--cmd-timeout` to `-h`/`--help`.
- [ ] **Step 2:** Ensure the comparison result (detection rate, timeout count, trial count, tool name) is available in the existing `--json` output mode so it pipes into tooling.
- [ ] **Step 3:** Commit.

---

## Phase 4 — Benchmark doc + example matrix

- [ ] **Step 1:** Write `docs/benchmarking-against-external-tools.md` with copy-paste invocations comparing validate vs. jpeginfo (JPEG), qpdf --check (PDF), ffmpeg -v error (video). Use `--seed` for reproducibility.
- [ ] **Step 2:** (Optional, not in `./test`) a `bm`-style script that runs validate-vs-external across a few formats and emits a comparison table. Document that these need the external tools installed (note them in `flake.nix` if we want CI to have them).
- [ ] **Step 3:** Commit.

---

## Out of scope (parked)

- **Parallel trials across cores** for `--cmd` runs (external spawn is slower than in-process; could parallelize later). Keep sequential first for deterministic tallying.
- **Capturing/diffing external tool stderr** for richer reports — exit code is the contract for now.
- **GUI exposure** — Peter: CLI-only feature.

---

## Risk + rollback

| Risk | Mitigation |
|---|---|
| External tool hangs | Per-trial timeout (default 10s) kills the child; tallied separately and reported (no silent cap). |
| Shell-injection via `--cmd` | We do NOT invoke a shell — argv is split in Zig and passed directly to `execve`-equivalent. `{}` is replaced with a path we control. Document that `--cmd` runs the user's own command with their privileges (same trust as any CLI they type). |
| Temp-file churn | Corrupted bytes written to RAM-backed `$TMPDIR`; cleaned each trial. |
| Quoting edge cases | Task 1.4 + 3.1 test spaced/quoted args explicitly. |

**Rollback path:** the external backend is additive (NULL `cmd` = old in-process behavior). Reverting the C-CLI parse alone disables the feature without touching the core.

---

## Self-review checklist

- [x] Logic in Zig core, routed through FFI, C CLI only parses — matches Peter's architecture rule.
- [x] Exit-code contract explicit (0 = miss, non-zero = caught; timeout = caught-tallied-separately).
- [x] Deterministic tests use `/usr/bin/true` / `false` / `sleep` — no dependency on external validators being installed, no sleep-as-timing-hack (timeout test asserts the mechanism).
- [x] No shell invocation — argv split in Zig (injection-safe).
- [x] Quoted/spaced args tested per CLI conventions.
- [x] JSON output + help updated.
- [x] CLI test added to `./test`.

---

**Reproduce + verify:**
```bash
./build
nix develop -c zig build test -- --test-filter "cmd"
tests/cli/cmd_external_validator
zig-out/bin/validate --test-coverage sniper --cmd "false {}" --count 20 ground_truth_examples/jpeg/*.jpg
# Expected: ~100% (false always exits non-zero = always "caught")
```
