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
	eq(png.sniper, "100%", "PNG sniper")
	eq(png.shotgun, "100%", "PNG shotgun")
	ok(png.strong_sniper and png.strong_shotgun, "PNG strong flags")
	eq(png.sniper_pct, 100, "PNG sniper_pct")
	eq(png.run, "2026-03-06", "PNG run date")
	ok(png.mechanism:find("CRC32") ~= nil, "PNG mechanism mentions CRC32")
end

local qoi = by["QOI"]
ok(qoi ~= nil, "QOI row present")
if qoi then
	eq(qoi.sniper_pct, 0, "QOI sniper_pct")
	ok(not qoi.strong_sniper, "QOI not strong")
end

local doc_small = by["DOC (small)"]
ok(doc_small ~= nil, "DOC (small) row present")
if doc_small then
	eq(doc_small.sniper, "—", "em-dash sniper cell preserved")
	eq(doc_small.sniper_pct, nil, "em-dash has no pct")
	eq(doc_small.shotgun_pct, 52, "DOC (small) shotgun pct")
end

local pdf = by["PDF"]
ok(pdf ~= nil, "PDF row present")
if pdf then
	eq(pdf.sniper_pct, nil, "PDF n/a sniper has no pct")
end

-- Wave table included; PDF breakout (#### sub-table) excluded.
ok(by["Studio One Project (.song)"] ~= nil, "wave-table row present")
ok(by["G-code"] ~= nil, "wave-table G-code present")

-- JPEG row reflects the 2026-05-27 re-sweep.
local jpeg = by["JPEG"]
ok(jpeg ~= nil, "JPEG row present")
if jpeg then
	eq(jpeg.run, "2026-05-27", "JPEG run date")
end

-- ── MFIC: recompute rates from raw TSVs, compare to report claims ──
local function tsv_pct(path)
	local t = cov.parse_tsv_string(slurp(path))
	return math.floor(t.k / t.n * 100 + 0.5), t
end
local d = "../docs/corruption-sweep-results/2026-05-27/"
eq(tsv_pct(d .. "png_sniper.tsv"), png and png.sniper_pct, "TSV vs report: png sniper")
eq(tsv_pct(d .. "png_shotgun.tsv"), png and png.shotgun_pct, "TSV vs report: png shotgun")
eq(tsv_pct(d .. "jpeg_sniper.tsv"), jpeg and jpeg.sniper_pct, "TSV vs report: jpeg sniper")
eq(tsv_pct(d .. "jpeg_shotgun.tsv"), jpeg and jpeg.shotgun_pct, "TSV vs report: jpeg shotgun")

local _, meta = tsv_pct(d .. "png_sniper.tsv")
eq(meta.mode, "sniper", "TSV mode parsed")
ok(meta.n == 100, "TSV trial count is 100, got " .. tostring(meta.n))

-- ── Per-OS honesty flags (Einstein MFIC condition) ─────────────────
-- JPEG-family rows are structural-only on Windows at launch; everything
-- else applies to all three OSes. Set pending exact list from validate.
ok(cov.windows_structural_only("JPEG"), "JPEG flagged windows-structural")
ok(cov.windows_structural_only("JPEG2K"), "JPEG2K flagged windows-structural")
ok(not cov.windows_structural_only("PNG"), "PNG not flagged")
ok(not cov.windows_structural_only("ZIP"), "ZIP not flagged")

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
