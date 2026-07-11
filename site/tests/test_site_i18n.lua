-- Site string catalog enforcement (site is enforce-phase per i18n skill):
-- all 50 locales in the registry must have a site/i18n/<code>.lua whose key
-- set EXACTLY matches English — missing file, missing key, or extra key
-- fails. Values must be non-empty strings; substitution slots must survive.
package.path = "./?.lua;./lib/?.lua;" .. package.path

local locales = require("locales")

local failed = 0
local function ok(cond, msg)
	if not cond then
		failed = failed + 1
		io.stderr:write("not ok: " .. msg .. "\n")
	end
end

local function load_catalog(code)
	local chunk = loadfile("i18n/" .. code .. ".lua")
	if not chunk then return nil end
	return chunk()
end

local en = load_catalog("en")
ok(en ~= nil, "en catalog loads")
if not en then os.exit(1) end

local en_keys = {}
for k, v in pairs(en) do
	ok(type(v) == "string" and #v > 0, "en." .. k .. " is a non-empty string")
	en_keys[#en_keys + 1] = k
end
ok(#en_keys >= 60, "en catalog has a plausible key count, got " .. #en_keys)

for _, l in ipairs(locales.list) do
	local cat = load_catalog(l.code)
	ok(cat ~= nil, l.code .. ": site catalog file missing")
	if cat then
		for k in pairs(en) do
			ok(type(cat[k]) == "string" and #cat[k] > 0,
				l.code .. "." .. k .. " missing or empty")
		end
		for k in pairs(cat) do
			ok(en[k] ~= nil, l.code .. " has extra key not in en: " .. k)
		end
		if cat.banner_available then
			ok(cat.banner_available:find("%%s") ~= nil,
				l.code .. ".banner_available lost its %s slot")
		end
		if cat.release_expires then
			ok(cat.release_expires:find("%%s") ~= nil,
				l.code .. ".release_expires lost its %s slot")
		end
		-- Brand must not be translated away.
		if cat.meta_title then
			ok(cat.meta_title:find("Mecha Validate", 1, true) ~= nil,
				l.code .. ".meta_title must contain 'Mecha Validate'")
		end
	end
end

if failed > 0 then
	io.stderr:write(failed .. " assertion(s) failed\n")
	os.exit(1)
end
print("test_site_i18n: all assertions passed")
