# i18n: expand validate from 30 → 50 locales (dirtree lockstep)

**Date:** 2026-06-08
**Driver:** dirtree inbox (2026-06-08-full-locale-list-50.md), Peter: full native translations, parallel agents.
**Skill:** `i18n` (canonical 50-locale set; validate is in ENFORCE phase — no-default Zig structs already give compile-time completeness).

## Target

Canonical 50 (skill): `am ar az bg bn bs da de el en es fa fi fil fr ha he hi hr hu id ig is it ja km ko mk nb nl pa pl ps pt_br ro ru sl sq sr sv sw ta th tr uk ur vi yo zh_hans zh_hant`

**Delta vs current 30 → +20:** `am bg bs da fi fil ha hr id ig is mk nb nl sl sq sr sv yo zh_hant`
Zero removals (clean superset). **No new RTL** (ar/he/fa/ps/ur already present) — no new bidi work.

## Per-locale file shape (template = `ro.zig`, ~330 lines)
- `pub const strings = Strings{ ... }` — 43 fields (no defaults → compiler enforces completeness)
- `pub const cli_aliases = cli.CliAliases{ ... }` — localized arg-name aliases
- `pub const env_aliases = cli.EnvAliases{ ... }`
- `pub const format_descriptions = i18n.FormatDescriptions.init(.{ ... })` — the big table (~240 lines)
- `pub const error_translations = i18n.ErrorMap.initComptime(.{})` / `warning_translations` — often empty
- Scripts: Cyrillic for `bg mk sr`; Latin for the rest. Bilingual errors `<localized> (search for: "<english>")`.
- Low-resource (`ha am yo ig`): English-loanword fallback for CLI terms (regex/TTY) is acceptable/idiomatic.

## Shared-file wiring (SEQUENTIAL — I do these, NOT the agents, to avoid mod.zig collisions)

1. **Parser rewrite** `mod.zig fromString` — currently `s[0..2]` prefix chain.
   BUGS it fixes: `fil`→wrongly `fi`; `zh`→always `zh_hans` so `zh_hant` unreachable.
   New: longest-match over known codes, case-insensitive, require separator boundary (`_`/`-`/`.`) or end,
   fold region/script suffixes (`de_DE`, `en-GB`, `zh_hant`, `pt_br`). TDD: parser-sanity tests
   (`fil`!=`fi`, `pt_br`, `zh_hant`, `zh_hans`, longest-match).
2. **`Locale` enum** — add 20 variants (note `tr` uses `@"tr"`; check `is`/`id` etc. aren't keywords → `id` is fine, `is`/`fn`-like? `is` is not a Zig keyword as enum field but verify).
3. **mod.zig dispatch** — 4 switches (strings/format_descriptions/error_translations/warning_translations) + the `g_*` setters + env-prefix detector: 20 new arms each.
4. **cli_aliases merge + collision guard** — comptime same-name→diff-arg = `@compileError`
   (skill: real Indonesian `--hanya` vs Hausa `--hanya` collision). Same-name→same-arg dedupes.

## Parallel phase (AGENTS — one per locale, ×20)
Each agent: produce ONLY `src/core/i18n/<code>.zig`, full native-script translation mirroring `ro.zig`'s
structure/field set, all 43 strings + format_descriptions table + cli/env aliases + (empty) error/warning maps.
Reference dirtree's MIT locale files for script/alias/bilingual choices where the language overlaps (fleet
consistency). Agents do NOT touch mod.zig/cli_aliases/parser (I wire those).

## Integration + verify
- Register all 20 in mod.zig; build green (`nix build .#checks.aarch64-darwin.test`) — the no-default structs
  fail the build on any missing field (enforce-phase guarantee).
- Skill tests: parser-sanity, alias-collision (comptime), completeness (compiler), env precedence.
- `./test` green; commit (likely: 1 infra commit + the 20 locale files; or grouped). Push yolo.
- Update docs/I18N.md (50 list + rationale) + PROJECT_OVERVIEW.md i18n phase. Reply to dirtree with validate's rev.

## Sequencing
Infra (1-4) first as its own green commit (real bug fix, independently valuable) → then fan out 20 agents →
integrate → verify → commit/push. Request dirtree's files before/at agent fan-out.

## EXECUTION STATE (2026-06-08 checkpoint)
DONE (uncommitted in @, NOT yet building — exhaustive switches need the 20 arms+files):
- Locale enum: 30 → 50 variants added.
- fromString: rewritten to table-driven longest-match (50-entry code_table); fixes fil≠fi,
  zh_hant selectable, pt_br; boundary-aware, case-insensitive. Parser tests extended (red-proof pending build).
REFERENCE SECURED: dirtree's ../dirtree/src/i18n/<code>.zig has all 20 needed locales with
high-quality native-script translations (dirtree-specific strings, but gold for script/terminology/tone).
Read directly — no need to wait on inbox reply.
REMAINING:
1. Fan out 20 agents (one per locale am bg bs da fi fil ha hr id ig is mk nb nl sl sq sr sv yo zh_hant):
   each writes src/core/i18n/<code>.zig mirroring ro.zig (41 Strings fields + format_descriptions table
   + cli_aliases + env_aliases + empty error/warning maps), translating validate's strings using
   dirtree's ../dirtree/src/i18n/<code>.zig as the language/script reference.
2. Wire 20 arms into each of the 4 mod.zig dispatch switches + g_* setters (+ register imports).
3. Add comptime alias-collision guard in cli_aliases (same-name→diff-arg = @compileError).
4. Build green (no-default structs enforce completeness), ./test, commit, push, reply to dirtree.
