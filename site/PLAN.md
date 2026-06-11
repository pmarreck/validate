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
- [ ] Scaffold site/ + failing tests (locales registry, zig_catalog, coverage)
- [ ] Coverage data pipeline (TSV latest-run-wins + report mechanism notes + per-OS flags)
- [ ] EN templates: home (rebrand port) + coverage page
- [ ] 50-locale emit: hreflang/x-default, RTL, switcher, banner
- [ ] Site catalogs: first-class 10 hand-done
- [ ] Site catalogs: remaining 40 LLM-grade (subagent fan-out)
- [ ] Screenshots → Peter (icons judgment + general look)
- [ ] LLMsend validate: confirm JPEG-family row set; integration+push request when ready
