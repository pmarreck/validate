#!/usr/bin/env bash
# Integration test: run the generator, assert on the emitted docs/ tree.
# NO set -e (assertions handle failures); set -u only.
set -u

SITE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DOCS="$SITE_DIR/../docs"
RELEASE_FIXTURE="$SITE_DIR/tests/fixtures/current_releases.toml"
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
export VALIDATE_GUI_RELEASES_FILE="$RELEASE_FIXTURE"
capture "$SITE_DIR/generate"
unset VALIDATE_GUI_RELEASES_FILE
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
assert_not_contains "$IDX" 'buy-cta' "retired purchase CTA is absent"
assert_not_contains "$IDX" 'https://mecha.llc/validate/' "retired purchase URL is absent"
assert_contains "$IDX" 'class="coverage-link main-coverage-link"' "detection coverage link lives in main content"
assert_contains "$IDX" 'A Mecha, LLC product' "Mecha LLC footer credit"
assert_contains "$IDX" 'class="release-downloads"' "current GUI releases render a download section"
assert_contains "$IDX" 'class="stat stat-formats" href="#format-list"' "formats stat links to the full format list"
assert_contains "$IDX" 'class="stat stat-try" href="#release-downloads"' "try-it stat links directly to prerelease downloads"
assert_contains "$IDX" 'TRY IT!' "English try-it copy is rendered"
assert_contains "$IDX" 'class="format-list" id="format-list"' "full format list has a stable scroll destination"
assert_not_contains "$IDX" 'format-tooltip' "overlapping format tooltip is removed"
assert_contains "$IDX" 'Free prerelease downloads' "English prerelease heading"
assert_contains "$IDX" 'class="release-list release-list-count-5"' "five fresh platform links receive a stable layout hook"
assert_contains "$IDX" 'macOS (aarch64)' "macOS platform label is unambiguous"
assert_contains "$IDX" 'Windows ARM64' "Windows ARM64 platform label is explicit"
assert_contains "$IDX" 'Linux (x86_64)' "Linux x86_64 platform label is unambiguous"
assert_contains "$IDX" 'Linux (aarch64)' "Linux aarch64 platform label is unambiguous"
assert_contains "$IDX" 'X-Amz-Algorithm=AWS4-HMAC-SHA256&amp;X-Amz-Date=20400102T030405Z' "presigned release URL is escaped"
assert_contains "$DOCS/de/index.html" 'Kostenlose Vorabversionen' "German prerelease copy is localized"
assert_contains "$DOCS/ar/index.html" 'تنزيلات تجريبية مجانية' "Arabic prerelease copy is localized"

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

# ── Suggestion banner is suggestion-only ─────────────────────────
JS="$DOCS/assets/site.js"
[ -f "$JS" ] || fail "site.js not emitted"
CSS="$DOCS/assets/site.css"
[ -f "$CSS" ] || fail "site.css not emitted"
assert_contains "$CSS" 'scroll-behavior: smooth;' "download anchor scrolls smoothly"
assert_contains "$CSS" '@media (prefers-reduced-motion: reduce)' "reduced-motion users can opt out of smooth scrolling"
assert_contains "$CSS" '.format-grid' "full format list is laid out wider than the former tooltip"
if grep -E 'location\.(href|replace|assign)' "$JS" >/dev/null 2>&1; then
	fail "site.js must never navigate on its own (hard redirect found)"
fi
assert_not_contains "$JS" 'format-tooltip' "format tooltip behavior is removed"

format_line=$(grep -nF 'id="format-list"' "$IDX" | cut -d: -f1)
release_line=$(grep -nF 'id="release-downloads"' "$IDX" | cut -d: -f1)
if [ -z "$format_line" ] || [ -z "$release_line" ] || [ "$format_line" -ge "$release_line" ]; then
	fail "the full format list must precede prerelease downloads"
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
