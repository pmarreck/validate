-- Tests for site/lib/locales.lua — the 50-locale registry.
-- MFIC: the registry is cross-checked against the app's actual catalog
-- files on disk (src/core/i18n/*.zig), an oracle this module didn't write.
package.path = "./?.lua;./lib/?.lua;" .. package.path

local locales = require("locales")

local failed = 0
local function ok(cond, msg)
	if not cond then
		failed = failed + 1
		io.stderr:write("not ok: " .. msg .. "\n")
	end
end

-- 1. Exactly 50 locales.
ok(#locales.list == 50, "expected 50 locales, got " .. #locales.list)

-- 2. Registry codes match the app catalog files on disk exactly (set equality).
local disk = {}
local p = io.popen("ls ../src/core/i18n/*.zig")
for line in p:lines() do
	local code = line:match("([%w_]+)%.zig$")
	if code ~= "mod" and code ~= "strings" and code ~= "cli_aliases" then
		disk[code] = true
	end
end
p:close()
local reg = {}
for _, l in ipairs(locales.list) do
	ok(disk[l.code], "registry code not on disk: " .. tostring(l.code))
	reg[l.code] = true
end
for code in pairs(disk) do
	ok(reg[code], "app catalog missing from registry: " .. code)
end

-- 3. RTL set is exactly {ar, he, fa, ps, ur}.
local rtl = {}
for _, l in ipairs(locales.list) do
	if l.rtl then rtl[#rtl + 1] = l.code end
end
table.sort(rtl)
ok(table.concat(rtl, ",") == "ar,fa,he,ps,ur",
	"RTL set wrong: " .. table.concat(rtl, ","))

-- 4. Every locale has slug, hreflang, native name; en is special-cased to
--    site root (slug ""), all others slugged lowercase-hyphen.
for _, l in ipairs(locales.list) do
	ok(type(l.hreflang) == "string" and #l.hreflang > 0, l.code .. ": hreflang missing")
	ok(type(l.native) == "string" and #l.native > 0, l.code .. ": native name missing")
	if l.code == "en" then
		ok(l.slug == "", "en slug must be empty (site root)")
	else
		ok(l.slug:match("^[a-z][a-z0-9%-]*$") ~= nil, l.code .. ": bad slug " .. tostring(l.slug))
	end
end

-- 5. Multi-segment mappings: BCP-47 hreflang + URL slugs.
local by = {}
for _, l in ipairs(locales.list) do by[l.code] = l end
ok(by.pt_br and by.pt_br.slug == "pt-br" and by.pt_br.hreflang == "pt-BR", "pt_br mapping")
ok(by.zh_hans and by.zh_hans.slug == "zh-hans" and by.zh_hans.hreflang == "zh-Hans", "zh_hans mapping")
ok(by.zh_hant and by.zh_hant.slug == "zh-hant" and by.zh_hant.hreflang == "zh-Hant", "zh_hant mapping")
ok(by.fil and by.fil.slug == "fil" and by.fil.hreflang == "fil", "fil mapping")
ok(by.nb and by.nb.hreflang == "nb", "nb hreflang")

-- 6. Slug uniqueness.
local seen = {}
for _, l in ipairs(locales.list) do
	if l.slug ~= "" then
		ok(not seen[l.slug], "duplicate slug: " .. l.slug)
		seen[l.slug] = true
	end
end

if failed > 0 then
	io.stderr:write(failed .. " assertion(s) failed\n")
	os.exit(1)
end
print("test_locales: all assertions passed")
