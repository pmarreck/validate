-- Coverage-table data pipeline for the validate.pics site.
-- Row source: docs/corruption-detection-report.md (the canonical, curated
-- sweep report — itself regenerated from the raw TSVs). Raw TSVs are used
-- by the test suite to cross-check the report's percentages (MFIC), and by
-- parse_tsv_string for any caller needing recomputed rates.

local M = {}

-- ── Raw TSV parsing (schema: scripts/corruption-experiment output) ──
-- Header: "# seed=42 mode=sniper file=foo.png filesize=224566"
-- Rows:   trial \t mode \t filesize \t off \t bit \t span \t detected
function M.parse_tsv_string(s)
	local n, k, filesize, file_name, mode = 0, 0, 0, "", ""
	for line in s:gmatch("[^\n]+") do
		if line:sub(1, 1) == "#" then
			file_name = line:match("file=([^%s]+)") or file_name
			filesize = tonumber(line:match("filesize=(%d+)") or "0")
			mode = line:match("mode=(%S+)") or mode
		elseif line:sub(1, 5) ~= "trial" and #line > 0 then
			local det = line:match("([^\t]+)$")
			n = n + 1
			if det == "true" then k = k + 1 end
		end
	end
	return { n = n, k = k, filesize = filesize, file = file_name, mode = mode }
end

-- ── Report markdown parsing ──────────────────────────────────────
local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- A results cell is like "**100%**", "4%", "n/a†", "—". Returns
-- display (bold markers stripped), pct (number or nil), strong (was bold).
local function parse_cell(raw)
	local v = trim(raw)
	local strong = false
	local inner = v:match("^%*%*(.-)%*%*$")
	if inner then
		strong = true
		v = inner
	end
	local pct = tonumber(v:match("^(%d+%.?%d*)%%$"))
	return v, pct, strong
end

-- Parse every 7-column table row under ###-level sections, skipping
-- #### sub-tables (e.g. the PDF stream-filter breakout) and non-results
-- tables (they have different column counts).
function M.parse_report_string(md)
	local rows = {}
	local category = nil
	local in_subtable = false
	for line in md:gmatch("[^\n]*") do
		local h3 = line:match("^### (.+)$")
		local h4 = line:match("^#### ")
		local h2 = line:match("^## ")
		if h3 then
			category = trim(h3)
			in_subtable = false
		elseif h4 then
			in_subtable = true
		elseif h2 then
			category = nil
			in_subtable = false
		elseif not in_subtable and category and line:sub(1, 1) == "|" then
			local cells = {}
			-- split on | ; first and last are empty edges
			for cell in line:gmatch("|([^|]*)") do
				cells[#cells + 1] = trim(cell)
			end
			-- drop trailing empty edge cell if present
			if #cells > 0 and cells[#cells] == "" then cells[#cells] = nil end
			if #cells == 7 and cells[1] ~= "Format" and not cells[1]:match("^[-: ]*$") then
				local sniper, sniper_pct, strong_sniper = parse_cell(cells[2])
				local shotgun, shotgun_pct, strong_shotgun = parse_cell(cells[3])
				rows[#rows + 1] = {
					name = cells[1],
					sniper = sniper, sniper_pct = sniper_pct, strong_sniper = strong_sniper,
					shotgun = shotgun, shotgun_pct = shotgun_pct, strong_shotgun = strong_shotgun,
					sample = cells[4],
					size = cells[5],
					run = cells[6],
					mechanism = cells[7],
					category = category,
				}
			end
		end
	end
	return rows
end

-- ── Per-OS honesty (Einstein MFIC condition, 2026-06-11) ─────────
-- Measured rates were taken on Linux/macOS builds. Windows ships with the
-- JPEG family at structural depth only; these rows must NOT claim measured
-- Windows numbers. Exact row list pending confirmation from the validate
-- session (JPEG, JPEG2000/JPX, JPEG-in-TIFF, JPEG-LS, RAW JPEG previews).
local WINDOWS_STRUCTURAL_ONLY = {
	["JPEG"] = true,
	["JPEG2K"] = true,
}

function M.windows_structural_only(name)
	return WINDOWS_STRUCTURAL_ONLY[name] == true
end

-- ── Localized-name join against the app's i18n format keys ────────
-- Display name in the report → key in src/core/i18n/<code>.zig
-- format_descriptions. Rows that don't localize are explicitly English-only.
local APP_KEY_ALIASES = {
	["JPEG2K"] = "jpeg2000",
	["PAM/PPM"] = "pam",
	["ProRes/MOV"] = "prores",
	["MPEG-1/2"] = "mpeg_ps", -- sample.mpg = program stream
	["Theora (.ogv)"] = "ogv",
	["VP8 (raw IVF)"] = "ivf",
	["AAC (M4A)"] = "m4a",
	["AAC (ADTS)"] = "aac_adts",
	["Tracker (MOD)"] = "mod",
	["OLE2 (PPT)"] = "ppt",
	["InDesign"] = "indd",
	["ClarisWorks"] = "cwk",
	["MacWrite Document"] = "mwd",
	["WordPerfect"] = "wpd",
	["PDB (Protein)"] = "pdb_struct",
	["MAT-File"] = "matlab",
	["NIfTI-1"] = "nifti",
	["7z"] = "sevenz",
	["Brotli"] = "br",
	["BinHex (.hqx)"] = "hqx",
	["StuffIt"] = "sit",
	["GarageBand (.band)"] = "band",
	["Blender (.blend)"] = "blend",
	["Bitwig Project"] = "bwproject",
	["Cubase Project"] = "cpr",
	["Erlang Mix .eex"] = "eex",
	["Erlang BERT"] = "erlang_term",
	["FL Studio"] = "flp",
	["Logic Pro X"] = "logicx",
	["PGP Signed Message"] = "pgp_signed",
	["Premiere Project"] = "prproj",
	["Type 1 Font"] = "type1",
	["WebAssembly"] = "wasm",
	["Studio One Project (.song)"] = "song",
	["StuffIt X (.sitx)"] = "sitx",
	["Microsoft Installer (.msi)"] = "msi",
	["Windows ESD (.esd)"] = "esd",
	["LLVM Precompiled Header (.pch)"] = "llvm_pch",
	["LLVM Serialized Diagnostics (.dia)"] = "llvm_diag",
	["QuickBooks Backup (.qbb)"] = "qbb",
	["dBASE (.dbf)"] = "dbf",
	["MessagePack (.msgpack)"] = "msgpack",
	["RPM Package (.rpm)"] = "rpm",
}

-- Report rows with no honest app i18n format key. Aliasing these to a
-- nearby key would mislabel them (e.g. "MPEG-4 Part 2" is a codec measured
-- inside an AVI sample; "Opus" was measured in a WebM; NRW/JSON5 simply
-- have no catalog entry). They render with their English report name.
local ENGLISH_ONLY = {
	["NRW"] = true,
	["MPEG-4 Part 2"] = true,
	["Opus"] = true,
	["JSON5"] = true,
}

local function normalize(s)
	return (s:lower():gsub("%b()", ""):gsub("[^%w]", ""))
end

function M.app_key_for(name, en_catalog)
	if APP_KEY_ALIASES[name] then return APP_KEY_ALIASES[name] end
	-- lazy-build normalized index of app keys on first use
	if not M._key_index then
		local zc = require("zig_catalog")
		local en = en_catalog or zc.load_format_descriptions("../src/core/i18n/en.zig")
		local idx = {}
		for key in pairs(en) do
			idx[normalize(key)] = key
		end
		M._key_index = idx
	end
	return M._key_index[normalize(name)]
end

function M.english_only(name)
	return ENGLISH_ONLY[name] == true
end

return M
