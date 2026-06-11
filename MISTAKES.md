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
image deep validators, I edited the files with fragile multi-substitution perl
(a heredoc with an unbalanced `}` terminator for the font file; a perl with 9
chained `s///` for the image file where only 3 matched). Both **silently
corrupted** the source — the font file was emptied to 0 lines, the image file
truncated to 13 — yet `git commit` returned **exit 0** for both, because git
will happily commit a broken/empty file. I saw `commit=0`, assumed success,
and moved on. The breakage only surfaced on the next `nix build`:
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
3. **Prefer `python3` exact-string replace with a `count == 1` assertion** over
   multi-substitution perl. The assertion aborts the write if the anchor isn't
   uniquely present, so a bad anchor leaves the file untouched instead of
   silently mangling it. One edit → one build → one commit.
4. Avoid bash heredocs embedded in perl `-e`; quoting/terminator errors there
   fail in ways that still produce output and a zero-ish exit.

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
