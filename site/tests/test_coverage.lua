-- Tests for site/lib/coverage.lua — the coverage-table data pipeline.
-- Sources: docs/corruption-detection-report.md (curated rows) + raw TSVs.
-- MFIC: report percentages are cross-checked against rates recomputed from
-- the raw 2026-05-27 TSVs — an oracle the report's author didn't hand us.
package.path = "./?.lua;./lib/?.lua;" .. package.path

local cov = require("coverage")

local failed = 0
local function ok(cond, msg)
	if not cond then
		failed = failed + 1
		io.stderr:write("not ok: " .. msg .. "\n")
	end
end
local function eq(got, want, msg)
	ok(got == want, msg .. ": got " .. tostring(got) .. ", want " .. tostring(want))
end

local function slurp(path)
	local f = assert(io.open(path, "r"))
	local s = f:read("*a")
	f:close()
	return s
end

-- ── Report parsing ────────────────────────────────────────────────
local rows = cov.parse_report_string(slurp("../docs/corruption-detection-report.md"))

ok(#rows >= 180 and #rows <= 260, "row count sane, got " .. #rows)

local by = {}
for _, r in ipairs(rows) do
	ok(by[r.name] == nil, "duplicate row name: " .. tostring(r.name))
	by[r.name] = r
end

-- Spot oracles against known report rows.
local png = by["PNG"]
ok(png ~= nil, "PNG row present")
if png then
	eq(png.category, "Image & Photo", "PNG category")
	eq(png.sniper_pct, 100, "PNG sniper_pct")
	eq(png.bolter_pct, 100, "PNG bolter_pct")
	eq(png.shotgun_pct, 100, "PNG shotgun_pct")
	ok(png.strong_sniper and png.strong_bolter and png.strong_shotgun, "PNG all three strong")
	eq(png.run, "2026-03-06", "PNG run date")
	ok(png.mechanism:find("CRC32") ~= nil, "PNG mechanism mentions CRC32")
end

local qoi = by["QOI"]
ok(qoi ~= nil, "QOI row present")
if qoi then
	eq(qoi.sniper_pct, 0, "QOI sniper_pct")
	eq(qoi.bolter_pct, 0, "QOI bolter_pct")
	eq(qoi.shotgun_pct, 0, "QOI shotgun_pct")
	ok(not (qoi.strong_sniper or qoi.strong_bolter or qoi.strong_shotgun), "QOI none strong")
end

-- n/a cells must parse to nil pct (never a misleading 0), display preserved.
local doc_small = by["DOC (small)"]
ok(doc_small ~= nil, "DOC (small) row present")
if doc_small then
	eq(doc_small.sniper, "n/a", "DOC (small) sniper is n/a")
	eq(doc_small.sniper_pct, nil, "n/a sniper has no pct")
	eq(doc_small.bolter_pct, nil, "n/a bolter has no pct")
	eq(doc_small.shotgun_pct, 52, "DOC (small) shotgun pct")
end

local amr = by["AMR"]
ok(amr ~= nil, "AMR row present")
if amr then
	eq(amr.sniper_pct, 14, "AMR sniper pct")
	eq(amr.bolter, "n/a", "AMR bolter n/a display")
	eq(amr.bolter_pct, nil, "AMR bolter no pct")
	eq(amr.shotgun_pct, nil, "AMR shotgun no pct")
end

local pdf = by["PDF"]
ok(pdf ~= nil, "PDF row present")
if pdf then
	eq(pdf.sniper_pct, nil, "PDF n/a sniper has no pct")
end

-- JPEG re-sweep: sniper/bolter/shotgun = 4/8/100.
local jpeg = by["JPEG"]
ok(jpeg ~= nil, "JPEG row present")
if jpeg then
	eq(jpeg.sniper_pct, 4, "JPEG sniper")
	eq(jpeg.bolter_pct, 8, "JPEG bolter")
	eq(jpeg.shotgun_pct, 100, "JPEG shotgun")
	eq(jpeg.run, "2026-05-27", "JPEG run date")
end

-- The CSV silent-pass fix (validate, 2026-06-22): 0/0/0 → 26/100/100.
local csv = by["CSV"]
ok(csv ~= nil, "CSV row present")
if csv then
	eq(csv.sniper_pct, 26, "CSV sniper")
	eq(csv.bolter_pct, 100, "CSV bolter")
	eq(csv.shotgun_pct, 100, "CSV shotgun")
end

-- ── Category: report is the single source of truth ────────────────
-- validate fixed CPT→Archive and dissolved the chronological "Wave" heading
-- AT SOURCE (2026-06-22), so no site-side category override is needed; the
-- report's ### headings are authoritative. These rows formerly misfiled:
eq(by["CPT"].category, "Archive", "CPT → Archive (was Audio)")
eq(by["dBASE (.dbf)"].category, "Database", "dBASE → Database")
eq(by["RPM Package (.rpm)"].category, "Disk Image / Filesystem / Executable / Other", "RPM → Other")
eq(by["Studio One Project (.song)"].category, "Archive", "Studio One → Archive")
ok(by["G-code"] ~= nil, "ex-Wave G-code still present")

-- Classifier over the WHOLE set: every row resolves to a real semantic
-- section. No chronological/unknown bucket (e.g. "Late additions") survives.
local SEMANTIC = {}
for _, c in ipairs({
	"Image & Photo", "RAW Camera", "Video", "Audio", "Document & Office",
	"Font", "Scientific", "Database", "Archive", "Game ROM",
	"Disk Image / Filesystem / Executable / Other",
}) do SEMANTIC[c] = true end
local stray = {}
for _, r in ipairs(rows) do
	if not SEMANTIC[r.category] then stray[#stray + 1] = r.name .. " → " .. r.category end
end
ok(#stray == 0, "rows left in a non-semantic category: " .. table.concat(stray, " | "))

-- ── MFIC: recompute rates from raw TSVs, compare to report claims ──
local function tsv_pct(path)
	local t = cov.parse_tsv_string(slurp(path))
	return math.floor(t.k / t.n * 100 + 0.5), t
end
local d = "../docs/corruption-sweep-results/2026-05-27/"
eq(tsv_pct(d .. "png_sniper.tsv"), png and png.sniper_pct, "TSV vs report: png sniper")
eq(tsv_pct(d .. "png_bolter.tsv"), png and png.bolter_pct, "TSV vs report: png bolter")
eq(tsv_pct(d .. "png_shotgun.tsv"), png and png.shotgun_pct, "TSV vs report: png shotgun")
eq(tsv_pct(d .. "jpeg_sniper.tsv"), jpeg and jpeg.sniper_pct, "TSV vs report: jpeg sniper")
eq(tsv_pct(d .. "jpeg_bolter.tsv"), jpeg and jpeg.bolter_pct, "TSV vs report: jpeg bolter")
eq(tsv_pct(d .. "jpeg_shotgun.tsv"), jpeg and jpeg.shotgun_pct, "TSV vs report: jpeg shotgun")

local _, meta = tsv_pct(d .. "png_bolter.tsv")
eq(meta.mode, "bolter", "TSV bolter mode parsed")
ok(meta.n == 100, "TSV trial count is 100, got " .. tostring(meta.n))

-- ── Per-OS honesty flags (Einstein MFIC condition) ─────────────────
-- Exact set confirmed by the validate session 2026-06-11 (call-site trace):
-- every deep JPEG/JPEG2000 path routes through jpegz/openjp2, which the
-- launch Windows build cannot link — these rows' measured numbers drop to
-- structural on Windows. Everything else is pure-Zig and identical per OS.
for _, name in ipairs({ "JPEG", "JPEG2K", "AVI", "CR2", "DNG", "RAF" }) do
	ok(cov.windows_structural_only(name), name .. " flagged windows-structural")
end
-- Explicit do-NOT-flag set (numbers identical on Windows): over-flagging
-- under-claims Windows coverage, which is its own form of dishonesty.
for _, name in ipairs({ "PNG", "ZIP", "TIFF", "NEF", "ARW", "PDF" }) do
	ok(not cov.windows_structural_only(name), name .. " must NOT be flagged")
end
-- The flagged set must never name a row absent from the report (typo guard).
for _, name in ipairs(cov.windows_flagged_names()) do
	ok(by[name] ~= nil, "flagged row not in report: " .. name)
end

-- ── Localized-name join: classifier over the WHOLE row set ─────────
-- Every report row must either resolve to an app i18n format key (so its
-- name localizes) or be explicitly acknowledged as English-only. No silent
-- third bucket.
local zc = require("zig_catalog")
local en = zc.load_format_descriptions("../src/core/i18n/en.zig")
local unresolved = {}
for _, r in ipairs(rows) do
	local key = cov.app_key_for(r.name)
	if key then
		ok(en[key] ~= nil, "app_key_for(" .. r.name .. ") = " .. key .. " not in app catalog")
	elseif not cov.english_only(r.name) then
		unresolved[#unresolved + 1] = r.name
	end
end
ok(#unresolved == 0, "rows neither app-keyed nor english-only allowlisted: " ..
	table.concat(unresolved, " | "))

if failed > 0 then
	io.stderr:write(failed .. " assertion(s) failed\n")
	os.exit(1)
end
print("test_coverage: all assertions passed")
