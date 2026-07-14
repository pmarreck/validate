-- Current GUI prerelease manifest parser. The publisher's TOML is intentionally
-- tiny, but its short-lived URLs must be validated before they reach HTML.
package.path = "./?.lua;./lib/?.lua;./templates/?.lua;" .. package.path

local releases = require("releases")

local failed = 0
local function ok(condition, message)
	if not condition then
		failed = failed + 1
		io.stderr:write("not ok: " .. message .. "\n")
	end
end

local now = 1893456000 -- 2030-01-01 00:00:00 UTC
local manifest = [[
linux-x86_64 = "https://downloads.example.invalid/validate-x86_64.AppImage?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Date=20300102T030405Z&X-Amz-Expires=86400&X-Amz-Signature=one"
windows-x86_64 = "https://downloads.example.invalid/validate-x86_64.zip?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Date=20300102T030405Z&X-Amz-Expires=86400&X-Amz-Signature=two"
windows-aarch64 = "https://downloads.example.invalid/validate-windows-arm64.zip?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Date=20300102T030405Z&X-Amz-Expires=86400&X-Amz-Signature=windowsarm"
macos-aarch64 = "https://downloads.example.invalid/validate-aarch64.zip?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Date=20300102T030405Z&X-Amz-Expires=86400&X-Amz-Signature=three"
linux-aarch64 = "https://downloads.example.invalid/validate-aarch64.AppImage?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Date=20300102T030405Z&X-Amz-Expires=86400&X-Amz-Signature=four"
]]

local parsed, err = releases.parse_toml(manifest, now)
ok(parsed ~= nil, "valid five-platform manifest parses: " .. tostring(err))
if parsed then
	ok(#parsed.available == 5, "all five fresh platforms are available")
	ok(parsed.available[1].key == "macos-aarch64", "platforms use stable display order")
	ok(parsed.available[4].key == "linux-aarch64", "Linux ARM64 stays distinct from Linux x86_64")
	ok(parsed.available[5].key == "windows-aarch64", "Windows ARM64 is a distinct fifth platform")
	ok(parsed.available[1].expires_utc == "2030-01-03 03:04 UTC", "expiry renders in explicit UTC")
	ok(#parsed.expired == 0, "fresh manifest has no expired entries")
	ok(releases.publishable(parsed), "manifest with fresh links is publishable")
end

local partial, partial_err = releases.parse_toml([[windows-x86_64 = "https://downloads.example.invalid/validate.zip?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Date=20300102T030405Z&X-Amz-Expires=86400&X-Amz-Signature=partial"
]], now)
ok(partial ~= nil, "an absent platform is permitted: " .. tostring(partial_err))
if partial then
	ok(#partial.available == 1 and partial.available[1].key == "windows-x86_64", "only supplied platform renders")
end

local stale, stale_err = releases.parse_toml([[windows-x86_64 = "https://downloads.example.invalid/validate.zip?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Date=20200102T030405Z&X-Amz-Expires=60&X-Amz-Signature=stale"
]], now)
ok(stale ~= nil, "expired link remains parseable so generation can omit it: " .. tostring(stale_err))
if stale then
	ok(#stale.available == 0 and #stale.expired == 1, "expired links fail closed and do not render")
	ok(not releases.publishable(stale), "expired-only manifest is not publishable")
end

local _, malformed_err = releases.parse_toml([[windows-x86_64 = "javascript:alert(1)"
]], now)
ok(malformed_err ~= nil, "non-HTTPS URL is rejected")

local _, unknown_err = releases.parse_toml([[macos-x86_64 = "https://downloads.example.invalid/nope?X-Amz-Date=20300102T030405Z&X-Amz-Expires=60"
]], now)
ok(unknown_err ~= nil, "unknown platform key is rejected")

local _, duplicate_err = releases.parse_toml(manifest .. [[macos-aarch64 = "https://downloads.example.invalid/duplicate?X-Amz-Date=20300102T030405Z&X-Amz-Expires=60"
]], now)
ok(duplicate_err ~= nil, "duplicate platform key is rejected")

if failed > 0 then
	io.stderr:write(failed .. " assertion(s) failed\n")
	os.exit(1)
end
print("test_releases: all assertions passed")
