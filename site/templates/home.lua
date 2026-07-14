-- Home page template — port of the original validate.pics single page,
-- rebranded to Mecha Validate and parameterized over locale. The format
-- scroller / "ALL OF THEM!" interaction lives in /assets/site.js and reads
-- its localized strings from window.SITE set up here.

local html = require("html")
local shared = require("shared")
local esc = html.esc

-- Marketing extension list for the scroller. cat values are site-catalog
-- key suffixes (cat_<key>); the badge shows the localized label.
local FORMATS = {
	{ "png", "image" }, { "jpg", "image" }, { "gif", "image" }, { "bmp", "image" },
	{ "webp", "image" }, { "tiff", "image" }, { "heic", "image" }, { "avif", "image" },
	{ "exr", "image" }, { "jxl", "image" }, { "svg", "image" }, { "apng", "image" },
	{ "qoi", "image" }, { "psd", "image" }, { "dng", "image" }, { "ico", "image" },
	{ "icns", "image" }, { "dpx", "image" }, { "tga", "image" }, { "pam", "image" },
	{ "cr2", "image" }, { "nef", "image" }, { "arw", "image" },
	{ "mp4", "video" }, { "mkv", "video" }, { "mov", "video" }, { "avi", "video" },
	{ "webm", "video" }, { "flv", "video" }, { "mpg", "video" }, { "m2ts", "video" },
	{ "ts", "video" }, { "3gp", "video" }, { "wmv", "video" }, { "swf", "video" },
	{ "dv", "video" }, { "ivf", "video" }, { "rm", "video" }, { "asf", "video" },
	{ "vob", "video" },
	{ "mp3", "audio" }, { "flac", "audio" }, { "wav", "audio" }, { "m4a", "audio" },
	{ "aiff", "audio" }, { "ogg", "audio" }, { "opus", "audio" }, { "mid", "audio" },
	{ "ape", "audio" }, { "wv", "audio" }, { "aac", "audio" }, { "ac3", "audio" },
	{ "dts", "audio" }, { "dsf", "audio" }, { "mp2", "audio" }, { "caf", "audio" },
	{ "wma", "audio" }, { "amr", "audio" }, { "mod", "audio" }, { "xm", "audio" },
	{ "s3m", "audio" },
	{ "zip", "archive" }, { "gz", "archive" }, { "bz2", "archive" }, { "xz", "archive" },
	{ "zst", "archive" }, { "7z", "archive" }, { "rar", "archive" }, { "tar", "archive" },
	{ "cab", "archive" }, { "iso", "archive" }, { "dmg", "archive" }, { "rpm", "archive" },
	{ "sit", "archive" }, { "wim", "archive" }, { "vmdk", "archive" }, { "msi", "archive" },
	{ "br", "archive" }, { "kmz", "archive" },
	{ "pdf", "document" }, { "docx", "document" }, { "xlsx", "document" }, { "pptx", "document" },
	{ "doc", "document" }, { "xls", "document" }, { "ppt", "document" }, { "odt", "document" },
	{ "epub", "document" }, { "rtf", "document" }, { "pages", "document" }, { "sqlite", "document" },
	{ "mdb", "document" }, { "dbf", "document" },
	{ "ai", "creative" }, { "eps", "creative" }, { "sketch", "creative" }, { "aep", "creative" },
	{ "prproj", "creative" }, { "indd", "creative" }, { "idml", "creative" },
	{ "fcpxml", "creative" }, { "drp", "creative" },
	{ "flp", "daw" }, { "als", "daw" }, { "rpp", "daw" }, { "cpr", "daw" },
	{ "ptx", "daw" }, { "band", "daw" }, { "reason", "daw" }, { "logicx", "daw" }, { "song", "daw" },
	{ "stl", "3d_cad" }, { "obj", "3d_cad" }, { "glb", "3d_cad" }, { "gltf", "3d_cad" },
	{ "ply", "3d_cad" }, { "3mf", "3d_cad" }, { "blend", "3d_cad" }, { "dwg", "3d_cad" },
	{ "step", "3d_cad" }, { "dxf", "3d_cad" },
	{ "dcm", "medical" }, { "dicom", "medical" }, { "nii", "medical" },
	{ "hdf5", "scientific" }, { "parquet", "scientific" }, { "netcdf", "scientific" },
	{ "fits", "scientific" }, { "fasta", "scientific" }, { "fastq", "scientific" },
	{ "shp", "scientific" }, { "pdb", "scientific" }, { "cif", "scientific" },
	{ "qbw", "financial" }, { "qbb", "financial" }, { "ofx", "financial" },
	{ "qif", "financial" }, { "nacha", "financial" }, { "mt940", "financial" },
	{ "bai2", "financial" },
	{ "ttf", "font" }, { "otf", "font" }, { "woff", "font" }, { "woff2", "font" },
	{ "exe", "executable" }, { "elf", "executable" }, { "wasm", "executable" },
	{ "class", "executable" }, { "dll", "executable" }, { "so", "executable" },
	{ "beam", "executable" },
	{ "pem", "crypto" }, { "der", "crypto" }, { "crt", "crypto" },
	{ "eml", "email" }, { "mbox", "email" },
	{ "json", "text" }, { "xml", "text" }, { "csv", "text" }, { "toml", "text" },
	{ "html", "text" }, { "md", "text" }, { "kml", "text" },
	{ "pcap", "network" }, { "pcapng", "network" },
	{ "nes", "game" }, { "sfc", "game" }, { "n64", "game" }, { "gb", "game" },
	{ "gba", "game" }, { "nds", "game" }, { "gen", "game" }, { "chd", "game" },
	{ "wad", "game" }, { "bsp", "game" }, { "vpk", "game" },
}

local CAT_ORDER = {
	"image", "video", "audio", "archive", "document", "creative", "daw",
	"3d_cad", "medical", "scientific", "financial", "font",
	"executable", "crypto", "email", "text", "network", "game",
}

-- The publisher manifest uses machine-oriented keys. These identifiers are
-- industry-standard platform names (not natural-language copy); keeping the
-- architecture literal prevents ARM Linux from looking like x86_64 Linux.
local RELEASE_LABELS = {
	["macos-aarch64"] = "macOS (aarch64)",
	["windows-x86_64"] = "Windows (x86_64)",
	["windows-aarch64"] = "Windows ARM64",
	["linux-x86_64"] = "Linux (x86_64)",
	["linux-aarch64"] = "Linux (aarch64)",
}

local M = {}

function M.render(ctx)
	local t = ctx.t
	local out = {}

	out[#out + 1] = shared.head(ctx, t.meta_title, t.meta_description)
	out[#out + 1] = "<body>"
	out[#out + 1] = shared.banner_mount(ctx)

	-- localized data for site.js
	local fmt_entries = {}
	local formats_by_category = {}
	for _, f in ipairs(FORMATS) do
		fmt_entries[#fmt_entries + 1] = ('["%s","%s"]'):format(f[1], f[2])
		local category = formats_by_category[f[2]] or {}
		category[#category + 1] = f[1]
		formats_by_category[f[2]] = category
	end
	local cat_entries = {}
	for _, c in ipairs(CAT_ORDER) do
		cat_entries[#cat_entries + 1] = ('%s:%s'):format(html.js_str(c), html.js_str(t["cat_" .. c]))
	end
	out[#out + 1] = "<script>"
	out[#out + 1] = "SITE.formats = [" .. table.concat(fmt_entries, ",") .. "];"
	out[#out + 1] = "SITE.cats = {" .. table.concat(cat_entries, ",") .. "};"
	out[#out + 1] = ("SITE.impact = { allOfThem: %s, goal: %s };"):format(
		html.js_str(t.all_of_them), html.js_str(t.goal_subtext))
	out[#out + 1] = "</script>"

	out[#out + 1] = '<div class="clouds"><div class="cloud cloud-1"></div><div class="cloud cloud-2"></div><div class="cloud cloud-3"></div><div class="cloud cloud-4"></div></div>'
	out[#out + 1] = shared.header(ctx)

	out[#out + 1] = '<div class="content">'
	out[#out + 1] = '<h1><span class="eyebrow">MECHA</span>Validate.</h1>'
	out[#out + 1] = '<div class="tagline" id="tagline-area">'
	out[#out + 1] = ("<span>%s</span>"):format(esc(t.tagline_prefix))
	out[#out + 1] = ('<button class="how-many-btn" id="how-many-btn">%s</button>'):format(esc(t.how_many_btn))
	out[#out + 1] = "</div>"

	out[#out + 1] = '<div class="scroller-container">'
	out[#out + 1] = ("<span>%s</span>"):format(esc(t.validates_your))
	out[#out + 1] = '<div class="scroller-box"><div class="scroller-track" id="scroller-track"><div class="ext-item" id="ext-current"></div><div class="ext-item" id="ext-next"></div></div></div>'
	out[#out + 1] = '<span class="category-badge" id="category-badge"></span>'
	out[#out + 1] = ("<span> %s</span>"):format(esc(t.files_suffix))
	out[#out + 1] = "</div>"

	local available_releases = ctx.releases and ctx.releases.available or {}
	out[#out + 1] = '<div class="stats">'
	out[#out + 1] = ('<div class="stat"><div class="stat-number">0</div><div class="stat-label">%s</div></div>'):format(esc(t.stat_deps))
	out[#out + 1] = ('<a class="stat stat-formats" href="#format-list"><div class="stat-number" id="format-count">240+</div><div class="stat-label">%s</div></a>'):format(esc(t.stat_formats))
	out[#out + 1] = ('<div class="stat"><div class="stat-number">50</div><div class="stat-label">%s</div></div>'):format(esc(t.stat_languages))
	if #available_releases > 0 then
		out[#out + 1] = ('<a class="stat stat-try" href="#release-downloads"><div class="stat-number">%s</div></a>'):format(esc(t.try_it))
	end
	out[#out + 1] = "</div>"

	out[#out + 1] = ('<a class="coverage-link main-coverage-link" href="%s"><span class="coverage-link-title">%s</span><span class="coverage-link-note">%s →</span></a>'):format(
		esc(shared.page_path(ctx.locale, "coverage")), esc(t.nav_coverage), esc(t.cov_subtitle))

	out[#out + 1] = '<section class="format-list" id="format-list" aria-labelledby="format-list-title">'
	out[#out + 1] = ('<h2 id="format-list-title">%s</h2>'):format(esc(t.stat_formats))
	out[#out + 1] = ('<p class="format-list-note">%s</p>'):format(esc(t.tooltip_note))
	out[#out + 1] = '<div class="format-grid">'
	for _, category in ipairs(CAT_ORDER) do
		local formats = formats_by_category[category]
		if formats then
			out[#out + 1] = '<div class="format-category">'
			out[#out + 1] = ('<h3>%s</h3>'):format(esc(t["cat_" .. category]))
			out[#out + 1] = '<div class="format-extensions">'
			for _, extension in ipairs(formats) do
				out[#out + 1] = ('<span class="format-extension">.%s</span>'):format(esc(extension))
			end
			out[#out + 1] = '</div></div>'
		end
	end
	out[#out + 1] = '</div></section>'

	if #available_releases > 0 then
		out[#out + 1] = '<section class="release-downloads" id="release-downloads" aria-labelledby="release-downloads-title">'
		out[#out + 1] = ('<h2 id="release-downloads-title">%s</h2>'):format(esc(t.release_title))
		out[#out + 1] = ('<p class="release-intro">%s</p>'):format(esc(t.release_intro))
		out[#out + 1] = ('<ul class="release-list release-list-count-%d">'):format(#available_releases)
		for _, release in ipairs(available_releases) do
			local label = assert(RELEASE_LABELS[release.key], "unknown release platform: " .. release.key)
			out[#out + 1] = '<li class="release-item">'
			out[#out + 1] = ('<a class="release-link" href="%s" rel="noopener noreferrer">%s <span aria-hidden="true">↓</span></a>')
				:format(esc(release.url), esc(label))
			out[#out + 1] = ('<span class="release-expiry">%s</span>'):format(esc(t.release_expires:format(release.expires_utc)))
			out[#out + 1] = '</li>'
		end
		out[#out + 1] = '</ul>'
		out[#out + 1] = '</section>'
	end
	out[#out + 1] = "</div>"

	out[#out + 1] = shared.footer(ctx)
	out[#out + 1] = '<script src="/assets/site.js"></script>'
	out[#out + 1] = "</body>"
	out[#out + 1] = "</html>"
	return table.concat(out, "\n")
end

return M
