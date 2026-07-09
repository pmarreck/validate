---
purpose: Durable technical learnings discovered while working on validate — env quirks, ABI gotchas, tooling insights worth not re-discovering.
audience: agent
maintained_by: agent
---

# LEARNINGS.md

## 2026-07-07 — Zig `export fn ... bool` + C header `int` = garbage-true across the FFI

**Symptom:** `validate` prepended a U+200F RIGHT-TO-LEFT MARK to *every* `OK`/`FAIL`
status line, under *every* locale — including `en_US`, `LANG=C`, and explicit
`--lang en`/`--lang ja` (both LTR, and whose translated strings rendered
correctly as English/Japanese). `NO_BIDI=1` suppressed it. Every downstream tool
or test that anchored a grep on `^OK` / `^FAIL` broke (cpt/git_repository/iwork/
rar/webm CLI tests all "failed" even though `validate`'s verdicts were correct).

**Root cause:** a Zig↔C return-type ABI mismatch.
- Zig: `export fn validate_is_rtl() bool { ... }` — a Zig `bool` return only
  writes the low byte (`al`) of the return register; the upper bytes of `eax`
  are left **undefined**.
- Header: `int validate_is_rtl(void);` — the C caller reads a full 4-byte `int`.
- The C CLI computed `g_rtl_enabled = validate_is_rtl() && !getenv("NO_BIDI")`.
  With stale nonzero garbage in the high bytes, the `int` was nonzero → "true"
  for every locale, so the RLM prefix always fired.

**Fingerprint / how it was confirmed:** the behavior was *garbage-dependent, not
locale-dependent* — e.g. on the buggy binary `--lang zh_hans` happened to pass
(register garbage was zero on that code path) while `--lang en/de/ja/fr/es`
failed. Non-deterministic per-code-path truthiness is the tell of an undefined
upper-register read, NOT of real conditional logic. The Zig core was provably
correct: `isRtl(.en) == false`, `setLocale` sets `g_locale` consistently with
`g_strings`, and translations worked — so the divergence had to be at the C ABI
boundary, not in the logic.

**Fix:** return `c_int` (via `@intFromBool(...)`) from any `export fn` whose C
header prototype is `int`. This writes the whole int register. Applied to both
`validate_is_rtl` and `validate_is_interrupted` (same latent bug — the latter
could have spuriously reported interruption). See `ffi/c_api.zig`.

**General rule (fleet-wide):** an `export fn` returning Zig `bool` MUST be
prototyped as `bool` (with `#include <stdbool.h>`, 1-byte `_Bool`) in the C
header — OR return `c_int`/`u8` explicitly. Never let a Zig `bool` return face a
C `int` prototype. Audit: `rg 'export fn \w+\([^)]*\) bool'` and cross-check each
against its header prototype. (In this repo only these two existed; both fixed.)

**Regression test:** `tests/cli/rtl_directional_mark` — a classifier-over-sets
test that asserts the RLM is ABSENT for a set of LTR locales (incl. env-detected
default) and PRESENT for all five RTL baseline locales (`ar he fa ps ur`), with
`NO_BIDI` overriding. Exercises the real C-FFI boundary via the CLI.

## 2026-07-07 — Keep undeclared tools out of repo workflows

Two CLI tests (`tests/cli/ape_validation`, `tests/cli/wavpack_validation`) shell
out to an undeclared interpreter for byte-level corruption (`write_u16_le`/
`write_u32_le`, version parse, single-byte XOR bit-flips, block-offset reads).
That tool is not installed here and should not be part of this repo workflow.
When it is missing, the "corrupt" copy is written *unchanged*, so `validate`
accepts it and the test reports "bogus X accepted" — a false failure that looks
like a detection regression.

Fix applied: the APE/WavPack corruption helpers now use `od`/`printf`/`dd`
only. The remaining active corpus generator (`scripts/build-brotli-corpus`) was
ported to LuaJIT, the active binary scan in `tests/cli/theora_validation`
was ported to LuaJIT, and their external tools are declared in `flake.nix`'s dev
shell (`brotli`, `luajit`, `coreutils`). Rule: repo workflows should use tools
provided by the flake; if a script needs a tool, add it to the flake instead of
telling people to reach into ambient PATH or `nix shell nixpkgs#...`.

On the Thelio migration, the desired seal is stricter than "flake tools first in
PATH": `./test` now runs CLI tests under `nix develop --ignore-env`, keeping only
`VALIDATE_BIN` and `TMPDIR`. The sole expected local filesystem exception is the
`ground_truth_examples -> ../validate_gui/ground_truth_examples` symlink.
