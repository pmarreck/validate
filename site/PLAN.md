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

## WIND-DOWN STATE (2026-07-07, fleet → Thelio)
- **Green + pushed.** Commit `ztkprsqu` (bc2ba32) = "site: 8-col Bolter column
  + reconcile categories to source-of-truth report". `site/test` ALL PASS
  (5 suites, 100 pages regenerated). Pushed to origin on bookmark
  **`site/bolter-column`** (NOT yolo — validate owns integration/deploy).
- Parented on yolo `48da779d` (txrkuxkw = validate's generated 8-col report).
- **NEXT STEP (resume on Thelio):** validate rebases `site/bolter-column`
  onto current yolo → `bash site/test` green → push (redeploys validate.pics).
  Integration request already in validate's inbox
  (`2026-06-22-bolter-column-shipped-integrate.md`). If validate already
  integrated, this bookmark can be abandoned.
- **Outstanding (not blocking):**
  1. Peter's visual sign-off on the 3-column table density (screenshots were
     at /private/tmp/validate-pics-bolter/ — regenerate via `site/screenshot`
     on the Thelio; the inline file-send tool was disabled last session).
     Open Q: is the 6-col table too cramped at desktop width? tighten meters /
     drop bars on mobile?
  2. When jpegz vendoring lands + Windows re-swept, validate pings to flip the
     6 per-OS flags (JPEG/JPEG2K/AVI/CR2/DNG/RAF) from structural-only to
     measured numbers — 6-line set in site/lib/coverage.lua + 1 test count.
  3. mecha_llc_website may send a blessed icon set → apply.
  4. Peter's original "icons too dark" target never identified (only site icon
     is the footer GitHub mark; visuals were approved overall on 2026-06-11).

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
- Coverage table row source = canonical report (now GENERATED by validate's
  scripts/generate-corruption-report, 8-col incl. Bolter); tests recompute
  png/jpeg sniper+bolter+shotgun from raw TSVs as MFIC drift tripwires.
- 2026-06-22: Bolter is now a published column (Sniper · Bolter · Shotgun =
  escalating 1 bit / 1 byte / 4 KB). Parse contract locked w/ validate:
  `| Format | Sniper | Bolter | Shotgun | Sample | Size | Run | Mechanism |`,
  n/a never blank; parser asserts 8-col count. cov_col_bolter = "Bolter"
  verbatim ×50; cov_method_bolter translated ×50.
- 2026-06-22: validate fixed categories AT SOURCE (CPT→Archive, Wave heading
  dissolved). Site-side CATEGORY_OVERRIDE DROPPED — report is single source
  of truth; set-classifier test (every row in 11 semantic sections) is the
  permanent guard. sec_late_additions key removed ×50.
- Rows with no honest app i18n key stay English-only: NRW, MPEG-4 Part 2,
  Opus, JSON5 (aliasing would mislabel them).
- PDF breakout sub-table (#### heading) excluded; headline PDF row points
  readers at the full report.
