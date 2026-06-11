-- Shared page chrome: <head> with hreflang cluster, header nav with the
-- crawlable 50-locale switcher, Accept-Language suggestion banner mount,
-- and footer with the Mecha, LLC credit. All functions are pure
-- (ctx in → string out); the generator does the I/O.

local html = require("html")
local esc = html.esc

local M = {}

M.BASE_URL = "https://validate.pics"
M.BUY_URL = "https://mecha.llc/validate/"
M.MECHA_URL = "https://mecha.llc/"
M.REPO_URL = "https://github.com/pmarreck/validate"

-- Path of a page for a locale: page is "home" or "coverage".
function M.page_path(locale, page)
	local prefix = locale.slug == "" and "/" or ("/" .. locale.slug .. "/")
	if page == "coverage" then
		return prefix .. "coverage/"
	end
	return prefix
end

-- ctx: { locale, t, locales, page }  (page: "home" | "coverage")
function M.head(ctx, title, description)
	local out = {}
	local dir = ctx.locale.rtl and "rtl" or "ltr"
	out[#out + 1] = "<!DOCTYPE html>"
	out[#out + 1] = ('<html lang="%s" dir="%s">'):format(esc(ctx.locale.hreflang), dir)
	out[#out + 1] = "<head>"
	out[#out + 1] = '<meta charset="UTF-8">'
	out[#out + 1] = '<meta name="viewport" content="width=device-width, initial-scale=1.0">'
	out[#out + 1] = ("<title>%s</title>"):format(esc(title))
	out[#out + 1] = ('<meta name="description" content="%s">'):format(esc(description))
	out[#out + 1] = ('<link rel="canonical" href="%s">'):format(esc(M.BASE_URL .. M.page_path(ctx.locale, ctx.page)))
	-- hreflang cluster: every locale + x-default (English at the root).
	for _, l in ipairs(ctx.locales) do
		out[#out + 1] = ('<link rel="alternate" hreflang="%s" href="%s">')
			:format(esc(l.hreflang), esc(M.BASE_URL .. M.page_path(l, ctx.page)))
	end
	out[#out + 1] = ('<link rel="alternate" hreflang="x-default" href="%s">')
		:format(esc(M.BASE_URL .. M.page_path(ctx.locales_by_code.en, ctx.page)))
	out[#out + 1] = '<link rel="stylesheet" href="/assets/site.css">'
	out[#out + 1] = "</head>"
	return table.concat(out, "\n")
end

-- The locale switcher is server-rendered links (crawlable), wrapped in a
-- <details> so it needs no JS to open.
function M.switcher(ctx)
	local out = {}
	out[#out + 1] = '<details class="lang-menu">'
	out[#out + 1] = ('<summary aria-label="%s">🌐 <span class="lang-current">%s</span></summary>')
		:format(esc(ctx.t.lang_label), esc(ctx.locale.native))
	out[#out + 1] = '<ul class="lang-list">'
	for _, l in ipairs(ctx.locales) do
		local cls = l.code == ctx.locale.code and ' class="active"' or ""
		out[#out + 1] = ('<li%s><a href="%s" hreflang="%s">%s</a></li>')
			:format(cls, esc(M.page_path(l, ctx.page)), esc(l.hreflang), esc(l.native))
	end
	out[#out + 1] = "</ul></details>"
	return table.concat(out, "\n")
end

function M.header(ctx)
	local home = M.page_path(ctx.locale, "home")
	local cov = M.page_path(ctx.locale, "coverage")
	return table.concat({
		'<header class="site-header">',
		('<a class="brand" href="%s"><span class="brand-mecha">MECHA</span> Validate</a>'):format(esc(home)),
		'<nav class="site-nav">',
		('<a href="%s">%s</a>'):format(esc(cov), esc(ctx.t.nav_coverage)),
		('<a class="buy-cta" href="%s">%s</a>'):format(esc(M.BUY_URL), esc(ctx.t.nav_buy)),
		M.switcher(ctx),
		"</nav>",
		"</header>",
	}, "\n")
end

-- Accept-Language suggestion banner: empty mount + per-page data for
-- site.js. Suggestion only — site.js never navigates on its own.
function M.banner_mount(ctx)
	local html_mod = require("html")
	local out = {}
	out[#out + 1] = '<div id="lang-banner" hidden></div>'
	out[#out + 1] = "<script>"
	out[#out + 1] = "window.SITE = {"
	out[#out + 1] = ('page: %s,'):format(html_mod.js_str(ctx.page))
	out[#out + 1] = ('lang: %s,'):format(html_mod.js_str(ctx.locale.code))
	out[#out + 1] = ('banner: { available: %s, switchLabel: %s, dismiss: %s },'):format(
		html_mod.js_str(ctx.t.banner_available),
		html_mod.js_str(ctx.t.banner_switch),
		html_mod.js_str(ctx.t.banner_dismiss))
	local entries = {}
	for _, l in ipairs(ctx.locales) do
		entries[#entries + 1] = ('%s:{slug:%s,native:%s}'):format(
			html_mod.js_str(l.code), html_mod.js_str(l.slug), html_mod.js_str(l.native))
	end
	out[#out + 1] = "locales: {" .. table.concat(entries, ",") .. "}"
	out[#out + 1] = "};"
	out[#out + 1] = "</script>"
	return table.concat(out, "\n")
end

function M.footer(ctx)
	return table.concat({
		'<div class="footer">',
		('<a href="%s">%s</a>'):format(esc(M.MECHA_URL), esc(ctx.t.footer_mecha)),
		('<a href="%s" aria-label="GitHub">'):format(esc(M.REPO_URL)),
		'<svg class="gh-icon" viewBox="0 0 16 16"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"/></svg>',
		"</a>",
		('<a href="%s">%s</a>'):format(esc(M.REPO_URL), esc(ctx.t.footer_source)),
		"</div>",
	}, "\n")
end

return M
