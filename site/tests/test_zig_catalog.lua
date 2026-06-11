-- Tests for site/lib/zig_catalog.lua — extracts `.key = "value"` pairs from
-- the app's Zig locale catalogs (src/core/i18n/<code>.zig), decoding Zig
-- string escapes (\xNN hex bytes, \", \\, \n, \t, \u{...}).
package.path = "./?.lua;./lib/?.lua;" .. package.path

local zc = require("zig_catalog")

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

-- Unit: escape decoding on synthetic source (one entry per line and packed).
local synth = [[
pub const format_descriptions = i18n.FormatDescriptions.init(.{
    .alpha = "Hex \xc3\xbc here",
    .beta = "Quote \" and backslash \\ and tab \t",
    .gamma = "A", .delta = "B (packed, same line)",
    .uni = "U \u{1F600} done",
    .@"3mf" = "At-quoted key (digit-leading)",
});
pub const other = Strings{
    .alpha = "should not leak across blocks",
};
]]
local t = zc.extract_block(synth, "format_descriptions")
eq(t.alpha, "Hex \195\188 here", "hex escape")
eq(t.beta, "Quote \" and backslash \\ and tab \t", "quote/backslash/tab escapes")
eq(t.gamma, "A", "packed entry 1")
eq(t.delta, "B (packed, same line)", "packed entry 2")
eq(t.uni, "U \240\159\152\128 done", "unicode codepoint escape")
eq(t["3mf"], "At-quoted key (digit-leading)", '@"..." key syntax')
ok(t.other == nil, "no cross-block leak")

-- Real catalog: the only @"..." format key in the app today.
local en_keys = zc.load_format_descriptions("../src/core/i18n/en.zig")
eq(en_keys["3mf"], "3MF 3D Manufacturing", "en 3mf via @-quoted key")

-- Integration: real catalogs on disk.
local en = zc.load_format_descriptions("../src/core/i18n/en.zig")
eq(en.png, "PNG Image", "en png")
eq(en.jpeg, "JPEG Image", "en jpeg")

local de = zc.load_format_descriptions("../src/core/i18n/de.zig")
eq(de.png, "PNG-Bild", "de png")

local ja = zc.load_format_descriptions("../src/core/i18n/ja.zig")
eq(ja.png, "PNG\231\148\187\229\131\143", "ja png (PNG画像)")

if failed > 0 then
	io.stderr:write(failed .. " assertion(s) failed\n")
	os.exit(1)
end
print("test_zig_catalog: all assertions passed")
