# MISTAKES.md

## 2026-06-05 — A cached Nix FOD masks dependency-hash changes; local green != CI green

**What happened:** A dep (`sqlite3`) drifted (pinned to a moving `heads/main`
branch; upstream 3.51.0->3.53.2), breaking Garnix on every platform. I pinned
it to a commit SHA + updated `build.zig.zon` `.hash`, ran
`nix build .#checks.aarch64-darwin.test` -> GREEN, pushed. Garnix STILL failed
on every platform with the same dep-tree FOD hash mismatch. Root cause: the
`flake.nix` `zigDepsHash` (whole-dep-tree fixed-output-derivation hash) ALSO
changes when a dep moves, but my machine reused the CACHED FOD output, so the
local build never re-derived it and never saw the mismatch. Garnix, building
clean, did. Cost a whole extra fix+push+CI cycle.

**How to apply (the rule):** When ANY Zig dependency changes (`build.zig.zon`
url/hash), the `flake.nix` `zigDepsHash` is almost certainly stale too. Do NOT
trust a local `nix build` green — it can be cache-masked. Force the FOD to
re-derive: set `zigDepsHash` to `sha256-AAAA...A=` (fakeHash), `nix build`,
copy the printed `got:` hash back in, rebuild. Commit `build.zig.zon` AND
`flake.nix` together. (Same class of trap as the jj/watchman "local snapshot
masks reality" bug: a cached local layer hid the true state.)

**Bonus rule:** never pin a dep to `refs/heads/main|master` (a moving branch)
— it silently drifts and breaks CI later. Pin to an immutable commit SHA or
tag. (zlib + openmpt in this repo still violate this — flagged for follow-up.)


## 2026-06-02 — jj + stale Watchman fsmonitor silently drops files from commits

**What happened:** While committing the animated-WebP fix, the
`deps/libwebp/build.zig` change (adding demux.c to the build) was on disk
(4876 bytes, demux present) but jj's working-copy `@` kept the OLD content
(4291 bytes). `jj commit <paths>` and `jj squash` both said "Nothing
changed"; `jj file show -r <commit>` confirmed the committed build.zig was
the original. The validator commit thus referenced demux.h that the lib
never built — broken on fresh checkout — and I pushed it before noticing.

**Root cause:** this repo had `fsmonitor.backend = "watchman"` in jj config.
Watchman's view was stale (same Watchman gremlin from the May-30 crisis), so
it never reported `deps/libwebp/build.zig` as changed, and jj trusted
Watchman and skipped snapshotting it — even after `touch` and appending real
bytes. The `.git-old` tracked-then-gitignored flood made `jj status` noisy,
which masked the problem.

**How to apply (the rule):**
1. Proved the file content actually landed in the COMMIT, not just on disk:
   `jj file show -r <change> <path> | grep <marker>` (or compare byte sizes
   of `jj file show -r @ <path>` vs the on-disk file). A green `nix build`
   does NOT prove this — nix reads the working tree (disk), so it builds the
   correct bytes even when jj/the commit has the stale ones.
2. If jj refuses to snapshot a known-changed file, run with the fsmonitor
   disabled: `jj --config fsmonitor.backend=none status` (forces a direct
   filesystem scan). That immediately surfaced the real diff.
3. Fixed permanently for this repo: `jj config set --repo fsmonitor.backend none`.
4. Don't leave large dirs (.git-old) tracked-but-gitignored; untrack them
   (`jj file untrack .git-old`) so `jj status` stays readable.


A running log of mistakes made while working on `validate`, so future sessions
(and future me) don't repeat them. Newest first.

## 2026-05-30 — Never trust `git commit` exit code as proof of correctness

**What happened:** While wiring V=5 AES-256 decryption into the PDF font and
image deep validators, I edited the files with fragile multi-substitution
one-liners (an unbalanced heredoc terminator for the font file; another edit
with 9 chained substitutions where only 3 matched). Both **silently corrupted**
the source — the font file was emptied to 0 lines, the image file truncated to
13 — yet `git commit` returned **exit 0** for both, because git will happily
commit a broken/empty file. I saw `commit=0`, assumed success, and moved on.
The breakage only surfaced on the next `nix build`:
`pdf_font_validator has no member validatePdfFonts`,
`pdf_image_validator has no member ImageValidationResult`.

**Why it matters:** a green `commit=0` means *git recorded the change*, NOT
*the change is correct or even compiles*. Trusting it shipped two
non-compiling commits to `yolo`.

**How to apply (the rule):**
1. **Gate EVERY commit on a green build first.** Run
   `nix build .#checks.<system>.test` (e.g. `aarch64-darwin`) and confirm exit
   0 *before* `git add`/`git commit`. If the build fails, do not commit.
2. For TDD steps, also red-proof: break the new assertion, confirm the build
   FAILS, restore, confirm it passes — *then* commit.
3. **Prefer single-purpose, checked edits over multi-substitution one-liners.** Use
   `apply_patch` for manual changes, or a flake-provided lightweight tool with
   an explicit "exactly one match" guard for mechanical edits. The guard should
   abort before writing if the anchor isn't unique. One edit → one build → one
   commit.
4. Avoid shell heredocs embedded inside ad-hoc edit programs; quoting/terminator
   errors there fail in ways that still produce output and a zero-ish exit.

**Recovery that worked:** `git reset --hard <last-known-good-commit>` (the two
broken commits were the two HEAD commits, nothing good above them), verify the
build is green at that commit, then redo each edit with the assert-gated
exact-match approach above, building green before each commit.

## Environment notes that bit me (see also LEARNINGS.md)

- The codescan Read hook intercepts `Read` on `.zig` files (and even some
  `/tmp` paths) — copy to a `.txt`/`.view` name or use `cat`/`sed` via Bash to
  read source when the MCP read is inconvenient.
- codescan `replace_lines` requires a FRESH `read_file` immediately before the
  write; any intervening edit invalidates the version hash and the write is
  (correctly) rejected as stale. Read → write back-to-back, no batching.
- Bash tool output intermittently drops when several calls are batched in one
  message — use sequential single calls and write results to `/tmp` files when
  it matters.

## 2026-06-11 (site agent, validate_pics workspace)
- Wrote a PCRE non-capturing group `(?:...)` inside a Lua pattern (zig_catalog.lua). Lua patterns are not regex; escaped-quote string scanning needs a manual walker. Caught by the first red test run.
- Byte-truncated a localized string for a meta description (`s:sub(1,120)`) — would have emitted invalid UTF-8 on ja/zh pages. Caught in review before ship. Rule: never byte-slice translated text; pass full strings and let consumers truncate at display time.
- Misused `capture` (dotfiles capture.bash): it populates `out`/`err`/`rc` and requires them declared in caller scope — not `STDOUT`/`RETURN_CODE`. Read the helper's header before first use.

## 2026-06-11 — #32 cross-platform CI marathon (validate side)

- **Empty-FOD-from-broken-sandbox masquerades as a "platform-divergent hash."**
  framework-nixos's nix *sandbox* couldn't fetch, so the zigDeps FOD produced
  an EMPTY `p/o/tmp` tree — whose sha256 is stable and real-looking, so
  `nix build` kept reporting it as "linux's hash" ≠ darwin's. No real
  divergence existed. **Tell:** the suspicious `got:` hash equals
  `mktemp -d; mkdir p o tmp; nix hash path --sri`. Trust darwin/Garnix
  (working sandboxes) for FOD hashes; distrust framework-nixos-sourced ones.
- **One "test SEGV" was FIVE bugs, each masking the next.** Once the compiler
  stopped crashing (use_llvm), real errors surfaced one at a time. Re-run after
  each fix; read the NEW top error, don't assume one symptom = one cause.
- **Zig 0.16 self-hosted x86_64 Debug backend SEGVs on large test binaries** →
  `compile.use_llvm = true` on the test step, gated by a comptime `zig_version`
  tripwire that `@compileError`s on >0.16 so the workaround self-expires.
- **pthread stack minimum is TLS-inflated.** ~827KB static TLS (libjxl/libvpx/
  openmpt) lives inside each thread stack → `Thread.spawn(.stack_size=256KB)`
  EINVALs → Zig `unreachable` → abort. Measure `readelf -lW <bin> | grep TLS`.
- **Duplicate module from transitive+direct shared dep** (validate + tiffz both
  `b.dependency("jpegz")`) → Zig 0.16 `file exists in modules 'jpegz'/'jpegz0'`,
  sandbox SEGVs. Fix: one owner re-exports (`tiffz pub const jpegz`), consumers
  reach it transitively. Single instance, no dual-pin drift.
- **jpegz `linkSystemLibrary("jpeg"/"openjp2")` is unconditional** → blocks
  mingw `-static` cross. Real fix = Zig-vendor the C libs (option A), not nix
  static-mingw overrides.

## 2026-06-13 — `rg -rn` ≠ `grep -rn` (self-inflicted "mangling")
Typed `rg -rn "pat" file` out of grep muscle memory. In ripgrep `-r` is
`--replace REPLACEMENT` (NOT recursive — rg recurses by default), so `-rn`
parsed as `--replace=n`: every match was substituted with the literal "n".
Spent real cycles misattributing this to codescan, then to Claude Code's
Bash parser, before a hexdump of redirected output proved rg itself wrote
the "n" — and `rg --help` showed `-r REPLACEMENT`. Lesson: for ripgrep use
`rg -n` (or `--no-filename`/`-l` etc.); NEVER `-r` unless you actually want
match replacement. When output looks corrupted, hexdump the bytes before
blaming a tool — and check your own flags first.

## 2026-06-22 — Edited a Bash script while it was running in the background

While a long `scripts/corruption-sweep` ran in the background, I edited that
same script (added env-var lines near the top, changed the `find` line). Bash
reads scripts from disk by **byte offset** as it executes; inserting lines
shifted every subsequent offset, so when the running instance finally re-read
near the file's end it desynced and aborted with a bogus `line 68: syntax
error near unexpected token 'then'` — even though the on-disk file was
syntactically perfect (`bash -n` clean). The sweep had already buffered its
main `for` loop (a compound command bash reads whole), so 145/145 TSVs landed
before the tail aborted — I got lucky. **Lesson:** never edit a script (or any
file) that a running process is reading. Wait for it to finish, copy it to a
new path and edit the copy, or stop the process first. The on-disk file being
valid does NOT mean a mid-flight interpreter is reading valid bytes.

## 2026-07-07 — Dispatched a port agent on an unverified "which decoder" claim
An analysis subagent reported validate's `validateTiffDeep` "decodes TIFF via
zigimg" and lacked CCITT-G4. I dispatched a second agent to port a G4 decoder
into zigimg (branch `tiff-ccitt-g4`, ~17 min) BEFORE verifying the claim.
Reality: `validateTiffDeep` → `tiffz_shim.validateTiffDeepBuffer` → **tiffz**
(zigimg is used only for BMP V4/V5, `bmp_decoder.zig` — the sole
`zigimg.Image.fromMemory` call). validate's pinned tiffz (9a2c18e, 2026-07-02)
already has `src/compressions/ccitt_t6.zig` (16.7 KB, more complete than the
263-line zigimg port) wired via `compression_ccitt_t6 = 4`. The zigimg bump was
a no-op for validate.
**Lesson:** before dispatching implementation work that hinges on "component X
uses library Y", VERIFY the actual call path (grep the dispatch, don't trust a
subagent's one-line characterization). A 30-second `rg`/codescan on
`validateTiffDeep` would have caught it. The zigimg branch remains a valid
upstream contribution to Peter's fork, just irrelevant to validate.

## 2026-07-10 — Started a second flake formatting check while the first was evaluating

`nix develop -c zig fmt --check ...` was still materializing the dev shell and
had detached from the short tool-output window. I mistook the lack of output for
completion and launched it again, creating two competing Nix evaluations and a
busy eval-cache warning. I stopped both processes; neither reached `zig fmt` or
modified source. **Lesson:** after an apparently incomplete long Nix command,
check its PID before retrying. For a formatting-only check, prefer the already
realized project toolchain or rely on the successful sandboxed Zig compilation
until the dev shell is known ready.

## 2026-07-10 — Put a fixture directory inside an executable-test directory

I initially placed a C fixture under `tests/cli/fixtures/`. The master runner
iterates every `tests/cli/*` entry and uses `-x`; directories satisfy `-x`, so it
tried to execute the fixture directory and reported `FAIL: fixtures`. I stopped
the run and moved the source to the existing `tests/fixtures/` tree. **Lesson:**
inspect a directory-driven test runner's entry contract before adding any new
subdirectory; executable-only filtering does not exclude directories.

## 2026-07-10 — Lost track of yielded long-running build sessions

I treated a short tool yield as command completion and launched duplicate Nix /
Wine work while the original processes were still alive. I stopped only the
processes I had launched, but the duplicate work wasted time and muddied status
reporting. **Lesson:** start long commands with a short yield, retain the
returned session identifier, and poll that exact session until it reports an
exit code. Before retrying any apparently silent build, check the owning PID.
