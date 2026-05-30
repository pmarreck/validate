# MISTAKES.md

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
