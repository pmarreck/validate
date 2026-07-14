-- Homepage prerelease download rendering stays pure: a parsed manifest in,
-- escaped platform links (or no section) out.
package.path = "./?.lua;./lib/?.lua;./templates/?.lua;" .. package.path

local locales = require("locales")
local releases = require("releases")
local home = require("home")

local failed = 0
local function ok(condition, message)
	if not condition then
		failed = failed + 1
		io.stderr:write("not ok: " .. message .. "\n")
	end
end

local function contains(text, needle)
	return text:find(needle, 1, true) ~= nil
end

local by_code = {}
for _, locale in ipairs(locales.list) do by_code[locale.code] = locale end
local t = assert(loadfile("i18n/en.lua"))()
local parsed = assert(releases.parse_toml([[macos-aarch64 = "https://downloads.example.invalid/validate.zip?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Date=20300102T030405Z&X-Amz-Expires=86400&X-Amz-Signature=example"
linux-aarch64 = "https://downloads.example.invalid/validate.AppImage?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Date=20300102T030405Z&X-Amz-Expires=86400&X-Amz-Signature=arm"
windows-aarch64 = "https://downloads.example.invalid/validate-windows-arm64.zip?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Date=20300102T030405Z&X-Amz-Expires=86400&X-Amz-Signature=windowsarm"
]], 1893456000))

local rendered = home.render({
	locale = by_code.en,
	t = t,
	locales = locales.list,
	locales_by_code = by_code,
	page = "home",
	releases = parsed,
})

ok(contains(rendered, 'class="release-downloads"'), "fresh links render a dedicated download section")
ok(contains(rendered, 'class="stat stat-formats" href="#format-list"'), "formats stat is a direct anchor to the full format list")
ok(contains(rendered, 'class="stat stat-try" href="#release-downloads"'), "fresh links render a stat-card anchor to downloads")
ok(contains(rendered, "TRY IT!"), "try-it stat copy is localized through the catalog")
ok(contains(rendered, 'class="format-list" id="format-list"'), "full format list has a stable scroll destination")
ok(not contains(rendered, 'format-tooltip'), "format list replaces the overlapping hover tooltip")
ok(contains(rendered, "Free prerelease downloads"), "download heading is localized through the catalog")
ok(contains(rendered, "macOS (aarch64)"), "macOS architecture is clear")
ok(contains(rendered, "Linux (aarch64)"), "Linux ARM architecture is clear")
ok(contains(rendered, "Windows ARM64"), "Windows ARM64 uses the requested consumer-facing label")
ok(not contains(rendered, "Windows (x86_64)"), "absent platforms do not render")
ok(contains(rendered, "2030-01-03 03:04 UTC"), "expiry is visibly explicit")
ok(contains(rendered, "X-Amz-Algorithm=AWS4-HMAC-SHA256&amp;X-Amz-Date=20300102T030405Z"), "presigned query is HTML escaped")

local hidden = home.render({
	locale = by_code.en,
	t = t,
	locales = locales.list,
	locales_by_code = by_code,
	page = "home",
	releases = { available = {}, expired = {} },
})
ok(not contains(hidden, 'class="release-downloads"'), "no current links means no empty download section")
ok(not contains(hidden, 'class="stat stat-try"'), "no current links means no dead try-it anchor")
ok(contains(hidden, 'class="format-list" id="format-list"'), "format list is useful even without a prerelease")

if failed > 0 then
	io.stderr:write(failed .. " assertion(s) failed\n")
	os.exit(1)
end
print("test_home_releases: all assertions passed")
