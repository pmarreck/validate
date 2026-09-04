# validate.pics site — plan (site agent workspace)

Owner: validate_pics site agent (jj workspace; never moves yolo, never pushes).
Integration: LLMsend `validate` session to integrate+push, CC Einstein.

## Standing rules (from 2026-06-11 kickoff + validate's per-OS note)
- Product name: **Mecha Validate** (purge stale naming site-wide).
- Coverage table = generated from `docs/corruption-detection-report.md` +
  raw TSVs (2026-05-27 sweep wins where present). "Measured, not claimed"
  framing + roadmap line. Localized per locale.
- **Per-OS honesty (Einstein MFIC condition):** measured rates were taken on
  Linux/macOS builds. Windows ships with JPEG-family at structural depth only;
  affected rows' Windows cell must read (localized): "structural validation
  (deep JPEG decode: Linux/macOS only at launch; Windows upgrade in progress)".
  Non-JPEG rows: Windows = same measured rate. Affected set: start with
  {jpeg, jpeg2k}; exact row list to be confirmed by validate session
  (they offered: JPEG, JPEG2000/JPX, JPEG-in-TIFF/Compression=7, JPEG-LS,
  lossless JPEG in DNG/RAW previews). If jpegz vendoring lands in timebox,
  validate pings us to regenerate with measured Windows numbers.
- 50 locales (i18n skill is spec): per-locale URLs `/de/`, `/pt-br/`,
  `/zh-hans/`…; hreflang cluster + x-default; real RTL (`dir="rtl"`) for
  ar/he/fa/ps/ur; terminology reused from app catalogs
  (`src/core/i18n/<code>.zig` format_descriptions); visible switcher +
  Accept-Language JS *suggestion* banner (never hard redirect).
- Timebox: cut polish depth, not locale count. First-class: EN, DE, FR, ES,
  IT, PT-BR, JA, ZH-Hans, KO, NL; remaining 40 LLM-grade.
- Icons "too dark" (Peter): cannot self-judge visuals — render, screenshot,
  show Peter before encoding. Brand tokens requested from mecha_llc_website
  (2026-06-11 note; awaiting reply; proceeding with sky palette placeholder).
- Mechanism-notes column stays English in all locales (polish-depth cut),
  with a localized disclaimer line.

## Architecture
- `site/generate` — LuaJIT static site generator → emits into `docs/`.
- `site/lib/` — pure modules: `locales.lua` (50-locale registry),
  `zig_catalog.lua` (parse app catalogs), `coverage.lua` (TSV+report parse),
  `html.lua` (escape/util).
- `site/i18n/<code>.lua` — site string catalogs ×50; key-parity test vs en
  (Lua enforce mechanism per i18n skill).
- `site/templates/` — render functions (pure; all state injected).
- `site/test` — Bash runner (set -u, NO set -e), accumulates failures.
- Output: `docs/index.html` (en = x-default), `docs/coverage/`,
  `docs/<slug>/{index.html,coverage/}` ×49, shared `docs/assets/`.

## 2026-09-04 release-publication correction

The live site still rendered five MEGA links that expired on 2026-07-22. The
parser correctly classifies them as expired, but static GitHub Pages output
does not regenerate itself when time passes. Regenerate and publish without
those links immediately.

The permanent repair belongs to the Mecha Validate release transaction:

- [ ] Replace the seven-day SigV4-only `current_releases.toml` contract with a
  schema-validated public-release projection derived from the accepted signed
  update manifest.
- [ ] Use permanent per-platform download endpoints; never bake expiring links
  into static pages.
- [ ] Bind the rendered version and capability matrix to exact Validate and GUI
  commits and their common Build ID.
- [ ] Have the release command generate in a clean worktree, run `site/test`,
  show the proposed diff in dry-run mode, publish, and verify the live version
  and platform links.
- [ ] Add a mechanical site-versus-manifest health check that alerts on drift
  but never republishes by itself.

The cross-project architecture and acceptance gates are recorded in
`$HOME/Code/validate_gui/docs/MECHA_VALIDATE_RELEASE_RUNBOOK.md`; commercial
policy remains in the private Obsidian `MECHA_RELEASE_PLAN.md`.

## Checkboxes
- [x] Scaffold site/ + failing tests (locales registry, zig_catalog, coverage) — 2026-06-11 ~15:30 EST
- [x] Coverage data pipeline (report rows + MFIC TSV cross-checks + per-OS flags) — 2026-06-11 ~15:50 EST
- [x] Templates: home (rebrand port) + coverage page + shared chrome/assets — 2026-06-11 ~16:20 EST
- [x] Site catalogs: first-class 10 hand-done (en de fr es it pt_br ja zh_hans ko nl) — 2026-06-11 ~16:40 EST
- [x] Site catalogs: remaining 40 LLM-grade (4 subagents) — 2026-06-11 ~17:10 EST
- [x] Full generate + test_output green (ALL PASS, 100 pages) — 2026-06-11 ~17:15 EST
- [x] Per-OS flag set finalized from validate's jpegz trace: +AVI/CR2/DNG/RAF — 2026-06-11 ~17:25 EST
- [x] Screenshots → Peter (7 shots sent; icons question asked) — 2026-06-11 ~17:35 EST
- [x] LLMsend validate (integration+push request) + Einstein (status CC) — 2026-06-11 ~17:40 EST

## Open / blocked on others
- [ ] Peter's visual sign-off (eyebrow lockup, blue CTAs, RTL, icons-too-dark answer)
- [ ] Deploy timing: validate session integrates + pushes (pushing deploys GitHub Pages)
- [ ] jpegz vendoring lands → validate pings → lift Windows flags / measured numbers
- [ ] mecha_llc_website may send blessed icon set later → apply

## Decisions log
- Brand (mecha_llc_website 2026-06-11): keep sky identity; accent #3b82f6;
  Inter stack, NO webfont fetch (zero-external-deps story); text wordmark;
  footer "A Mecha, LLC product" → mecha.llc; Buy CTA → mecha.llc/validate/
  (commercial page lives there; validate.pics = technical showcase).
- Coverage table row source = canonical report (already incorporates the
  2026-05-27 sweep); tests recompute png/jpeg rates from raw TSVs as MFIC
  drift tripwires. Bolter mode exists only for 44 re-swept formats → not
  shown (polish-depth cut).
- Rows with no honest app i18n key stay English-only: NRW, MPEG-4 Part 2,
  Opus, JSON5 (aliasing would mislabel them).
- PDF breakout sub-table (#### heading) excluded; headline PDF row points
  readers at the full report.
