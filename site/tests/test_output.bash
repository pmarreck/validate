#!/usr/bin/env bash
# Integration test: run the generator, assert on the emitted docs/ tree.
# NO set -e (assertions handle failures); set -u only.
set -u

SITE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DOCS="$SITE_DIR/../docs"
source "$HOME/dotfiles/bin/src/capture.bash"

failures=0
fail() { echo "not ok: $1"; failures=$((failures + 1)); }
assert_contains() { # file needle label
	if ! grep -qF -- "$2" "$1" 2>/dev/null; then
		fail "$3 (missing: $2 in $1)"
	fi
}
assert_not_contains() {
	if grep -qF -- "$2" "$1" 2>/dev/null; then
		fail "$3 (stale content present: $2 in $1)"
	fi
}

# ── Generator runs clean ─────────────────────────────────────────
declare out err rc
capture "$SITE_DIR/generate"
if [ "$rc" -ne 0 ]; then
	fail "generate exited $rc: $err"
	echo "site output tests: ABORT (generator failed)"
	exit 1
fi

# ── Root (en, x-default) ─────────────────────────────────────────
IDX="$DOCS/index.html"
assert_contains "$IDX" 'Mecha Validate' "root page rebranded"
assert_contains "$IDX" 'hreflang="x-default"' "x-default present"
assert_contains "$IDX" '<html lang="en" dir="ltr">' "root lang/dir"
assert_not_contains "$IDX" 'Validate — File Integrity You Can Trust</title><' "no stale title artifact"
alt_count=$(grep -o 'rel="alternate" hreflang=' "$IDX" | wc -l | tr -d ' ')
if [ "$alt_count" -ne 51 ]; then
	fail "hreflang cluster should be 51 links (50 locales + x-default), got $alt_count"
fi
assert_contains "$IDX" 'rel="canonical" href="https://validate.pics/"' "root canonical"
assert_contains "$IDX" 'id="lang-banner"' "banner mount present"
assert_contains "$IDX" 'https://mecha.llc/validate/' "buy CTA points at mecha.llc/validate/"
assert_contains "$IDX" 'A Mecha, LLC product' "Mecha LLC footer credit"

# ── Every locale emits both pages ────────────────────────────────
slugs=$(luajit -e 'package.path="'"$SITE_DIR"'/lib/?.lua;"..package.path
local L=require("locales") for _,l in ipairs(L.list) do if l.slug~="" then print(l.slug) end end')
n_slugs=0
for slug in $slugs; do
	n_slugs=$((n_slugs + 1))
	[ -f "$DOCS/$slug/index.html" ] || fail "missing $slug/index.html"
	[ -f "$DOCS/$slug/coverage/index.html" ] || fail "missing $slug/coverage/index.html"
done
[ "$n_slugs" -eq 49 ] || fail "expected 49 non-en slugs, got $n_slugs"
[ -f "$DOCS/coverage/index.html" ] || fail "missing en coverage page"

# ── RTL correctness ──────────────────────────────────────────────
for slug in ar he fa ps ur; do
	assert_contains "$DOCS/$slug/index.html" 'dir="rtl"' "$slug is RTL"
done
assert_contains "$DOCS/de/index.html" 'dir="ltr"' "de is LTR"
assert_contains "$DOCS/de/index.html" '<html lang="de"' "de lang attr"

# ── Localized coverage table reuses app terminology ──────────────
DECOV="$DOCS/de/coverage/index.html"
assert_contains "$DECOV" 'PNG-Bild' "de coverage uses app catalog format name"
assert_contains "$DECOV" 'CRC32 per chunk' "mechanism notes stay English"
assert_contains "$DECOV" 'Linux · macOS · Windows' "all-platforms cell present"

# ── Per-OS honesty: JPEG-family Windows phrasing ─────────────────
ENCOV="$DOCS/coverage/index.html"
assert_contains "$ENCOV" 'deep JPEG decode is Linux/macOS-only at launch' "EN windows note"
# the note must appear exactly as many times as flagged rows
# (JPEG, JPEG2K, AVI, CR2, DNG, RAF — per validate's 2026-06-11 trace)
note_count=$(grep -o 'os-partial' "$ENCOV" | wc -l | tr -d ' ')
[ "$note_count" -eq 6 ] || fail "expected 6 os-partial cells, got $note_count"
assert_contains "$ENCOV" 'Measured, not claimed' "candor framing present"

# ── Bolter column (3rd rate column, between Sniper and Shotgun) ───
assert_contains "$ENCOV" '<th>Sniper</th><th>Bolter</th><th>Shotgun</th>' "Bolter column between Sniper and Shotgun"
assert_contains "$ENCOV" '<strong>Bolter</strong>' "Bolter method bullet in intro"
# DE coverage carries the localized bolter method sentence (not English)
assert_contains "$DECOV" '<strong>Bolter</strong>' "de bolter bullet present"

# ── Category correctness: CPT re-homed, no chronological bucket ───
assert_contains "$ENCOV" '<h2 class="cov-section">Archive</h2>' "Archive section present"
assert_contains "$ENCOV" 'Compact Pro Archive' "CPT renders as Compact Pro (localized app name)"
assert_not_contains "$ENCOV" 'Late addition' "no Late additions section"
assert_not_contains "$ENCOV" 'Wave 2026' "no chronological Wave heading leaked"

# ── Suggestion banner is suggestion-only ─────────────────────────
JS="$DOCS/assets/site.js"
[ -f "$JS" ] || fail "site.js not emitted"
[ -f "$DOCS/assets/site.css" ] || fail "site.css not emitted"
if grep -E 'location\.(href|replace|assign)' "$JS" >/dev/null 2>&1; then
	fail "site.js must never navigate on its own (hard redirect found)"
fi

# ── Sitemap ──────────────────────────────────────────────────────
SM="$DOCS/sitemap.xml"
loc_count=$(grep -o '<loc>' "$SM" 2>/dev/null | wc -l | tr -d ' ')
[ "$loc_count" -eq 100 ] || fail "sitemap should list 100 URLs, got $loc_count"
assert_contains "$SM" 'https://validate.pics/de/coverage/' "sitemap has locale coverage URL"

# ── CNAME untouched ──────────────────────────────────────────────
[ "$(cat "$DOCS/CNAME" 2>/dev/null)" = "validate.pics" ] || fail "CNAME must remain validate.pics"

if [ "$failures" -eq 0 ]; then
	echo "test_output: all assertions passed"
	exit 0
else
	echo "test_output: $failures assertion(s) failed"
	exit 1
fi
