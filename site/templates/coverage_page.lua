-- Detection-coverage page ("measured, not claimed"). One section per report
-- category, one row per measured format. Format names localize via the app's
-- own i18n catalogs; mechanism notes stay English by design (deep technical
-- prose kept verbatim from the measurement report) with a localized
-- disclaimer. Per-OS column carries the Einstein MFIC condition: Windows
-- cells never claim numbers that were only measured on Linux/macOS.

local html = require("html")
local shared = require("shared")
local coverage = require("coverage")
local esc = html.esc

local M = {}

-- Report ### heading → site-catalog section key. Unknown headings are a
-- hard error so report restructures surface here instead of dropping rows.
local SECTION_KEYS = {
	["Image & Photo"] = "sec_image_photo",
	["RAW Camera"] = "sec_raw_camera",
	["Video"] = "sec_video",
	["Audio"] = "sec_audio",
	["Document & Office"] = "sec_document_office",
	["Font"] = "sec_font",
	["Scientific"] = "sec_scientific",
	["Database"] = "sec_database",
	["Archive"] = "sec_archive",
	["Game ROM"] = "sec_game_rom",
	["Disk Image / Filesystem / Executable / Other"] = "sec_disk_other",
	-- (No "Wave …" entry: validate dissolved that chronological heading at
	-- source — every row now sits under a real section. A row that somehow
	-- still carried it would hit the error() below, loudly.)
}

local function rate_cell(display, pct, strong)
	if pct == nil then
		return ('<td class="rate rate-na"><bdi dir="ltr">%s</bdi></td>'):format(esc(display))
	end
	local cls = strong and "rate rate-strong" or (pct == 0 and "rate rate-zero" or "rate")
	return ('<td class="%s"><span class="meter" aria-hidden="true"><span class="meter-fill" style="width:%d%%"></span></span><bdi dir="ltr">%s</bdi></td>')
		:format(cls, pct, esc(display))
end

-- ctx additionally carries: rows (parsed report), names (locale's app
-- format_descriptions table).
function M.render(ctx)
	local t = ctx.t
	local out = {}

	local title = t.cov_title .. " — Mecha Validate"
	out[#out + 1] = shared.head(ctx, title, t.cov_subtitle .. " " .. t.cov_intro)
	out[#out + 1] = "<body class=\"coverage-page\">"
	out[#out + 1] = shared.banner_mount(ctx)
	out[#out + 1] = '<div class="clouds"><div class="cloud cloud-1"></div><div class="cloud cloud-2"></div><div class="cloud cloud-3"></div><div class="cloud cloud-4"></div></div>'
	out[#out + 1] = shared.header(ctx)

	out[#out + 1] = '<main class="cov-main">'
	out[#out + 1] = ('<h1 class="cov-title">%s</h1>'):format(esc(t.cov_title))
	out[#out + 1] = ('<p class="cov-subtitle">%s</p>'):format(esc(t.cov_subtitle))
	out[#out + 1] = '<div class="cov-card cov-intro">'
	out[#out + 1] = ("<p>%s</p>"):format(esc(t.cov_intro))
	out[#out + 1] = "<ul>"
	out[#out + 1] = ('<li><strong>Sniper</strong> — %s</li>'):format(esc(t.cov_method_sniper))
	out[#out + 1] = ('<li><strong>Bolter</strong> — %s</li>'):format(esc(t.cov_method_bolter))
	out[#out + 1] = ('<li><strong>Shotgun</strong> — %s</li>'):format(esc(t.cov_method_shotgun))
	out[#out + 1] = "</ul>"
	out[#out + 1] = ("<p>%s</p>"):format(esc(t.cov_roadmap))
	if ctx.locale.code ~= "en" then
		out[#out + 1] = ('<p class="cov-note">%s</p>'):format(esc(t.cov_mech_english_note))
	end
	out[#out + 1] = "</div>"

	-- group rows by category, preserving first-appearance order
	local sections, index = {}, {}
	for _, r in ipairs(ctx.rows) do
		local sec = index[r.category]
		if not sec then
			sec = { category = r.category, rows = {} }
			index[r.category] = sec
			sections[#sections + 1] = sec
		end
		sec.rows[#sec.rows + 1] = r
	end

	for _, sec in ipairs(sections) do
		local key = SECTION_KEYS[sec.category]
		if not key then
			error("coverage.lua: unmapped report section heading: " .. sec.category)
		end
		out[#out + 1] = ('<h2 class="cov-section">%s</h2>'):format(esc(t[key]))
		out[#out + 1] = '<div class="cov-card cov-table-wrap"><table class="cov-table">'
		out[#out + 1] = ('<thead><tr><th>%s</th><th>%s</th><th>%s</th><th>%s</th><th>%s</th><th>%s</th></tr></thead><tbody>')
			:format(esc(t.cov_col_format), esc(t.cov_col_sniper), esc(t.cov_col_bolter),
				esc(t.cov_col_shotgun), esc(t.cov_col_platforms), esc(t.cov_col_mechanism))
		for _, r in ipairs(sec.rows) do
			local app_key = coverage.app_key_for(r.name)
			local display = app_key and ctx.names[app_key] or r.name
			local name_cell
			if display ~= r.name then
				name_cell = ('<th scope="row">%s<span class="fmt-en">%s</span></th>'):format(esc(display), esc(r.name))
			else
				name_cell = ('<th scope="row">%s</th>'):format(esc(display))
			end
			local platforms
			if coverage.windows_structural_only(r.name) then
				platforms = ('<td class="os os-partial">%s</td>'):format(esc(t.cov_os_windows_note))
			else
				platforms = ('<td class="os"><bdi dir="ltr">%s</bdi></td>'):format(esc(t.cov_os_all))
			end
			local mech = ('<td class="mech"><span class="mech-note" lang="en" dir="ltr">%s</span><span class="mech-meta"><bdi dir="ltr">%s · %s</bdi> · %s <bdi dir="ltr">%s</bdi></span></td>')
				:format(esc(r.mechanism), esc(r.sample), esc(r.size), esc(t.cov_measured), esc(r.run))
			out[#out + 1] = "<tr>" .. name_cell
				.. rate_cell(r.sniper, r.sniper_pct, r.strong_sniper)
				.. rate_cell(r.bolter, r.bolter_pct, r.strong_bolter)
				.. rate_cell(r.shotgun, r.shotgun_pct, r.strong_shotgun)
				.. platforms .. mech .. "</tr>"
		end
		out[#out + 1] = "</tbody></table></div>"
	end

	out[#out + 1] = "</main>"
	out[#out + 1] = shared.footer(ctx)
	out[#out + 1] = '<script src="/assets/site.js"></script>'
	out[#out + 1] = "</body>"
	out[#out + 1] = "</html>"
	return table.concat(out, "\n")
end

return M
