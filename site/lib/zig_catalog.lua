-- Extracts `.key = "value"` string pairs from the app's Zig i18n catalogs
-- (src/core/i18n/<code>.zig) so the site reuses the app's translated
-- terminology instead of re-translating it. Decodes Zig string escapes:
-- \xNN hex bytes (how most non-ASCII text is stored in the catalogs),
-- \u{...} codepoints, \" \\ \n \r \t.

local M = {}

local function decode_escapes(s)
	local out, i, n = {}, 1, #s
	while i <= n do
		local c = s:sub(i, i)
		if c == "\\" then
			local nxt = s:sub(i + 1, i + 1)
			if nxt == "x" then
				out[#out + 1] = string.char(tonumber(s:sub(i + 2, i + 3), 16))
				i = i + 4
			elseif nxt == "u" then
				local hex, rest = s:match("^\\u{(%x+)}()", i)
				local cp = tonumber(hex, 16)
				-- UTF-8 encode the codepoint
				if cp < 0x80 then
					out[#out + 1] = string.char(cp)
				elseif cp < 0x800 then
					out[#out + 1] = string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
				elseif cp < 0x10000 then
					out[#out + 1] = string.char(0xE0 + math.floor(cp / 0x1000),
						0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
				else
					out[#out + 1] = string.char(0xF0 + math.floor(cp / 0x40000),
						0x80 + math.floor(cp / 0x1000) % 0x40,
						0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
				end
				i = rest
			elseif nxt == "n" then out[#out + 1] = "\n"; i = i + 2
			elseif nxt == "r" then out[#out + 1] = "\r"; i = i + 2
			elseif nxt == "t" then out[#out + 1] = "\t"; i = i + 2
			elseif nxt == '"' then out[#out + 1] = '"'; i = i + 2
			elseif nxt == "\\" then out[#out + 1] = "\\"; i = i + 2
			else out[#out + 1] = nxt; i = i + 2
			end
		else
			out[#out + 1] = c
			i = i + 1
		end
	end
	return table.concat(out)
end

-- Find the source range of `pub const <name> = ...{ ... });`-style block and
-- return its `.key = "raw string"` pairs decoded. Block ends at the first
-- line starting with `pub const` after the opening, or end of source.
function M.extract_block(source, name)
	local start = source:find("pub const " .. name .. "%s*=")
	if not start then return nil end
	local finish = source:find("\npub const ", start + 1) or #source
	local block = source:sub(start, finish)
	local t = {}
	-- Scan for .key = "..." with escaped-quote awareness. Lua patterns can't
	-- express (non-quote | backslash-pair)* so the value is walked manually.
	local pos = 1
	while true do
		-- Keys come in two spellings: .name = "..." and .@"name" = "..."
		-- (Zig @-quoting for identifiers that can't be bare, e.g. digit-leading).
		local kstart, kend, key = block:find('%.([%w_]+)%s*=%s*"', pos)
		local astart, aend, akey = block:find('%.@"([^"]+)"%s*=%s*"', pos)
		if astart and (not kstart or astart < kstart) then
			kstart, kend, key = astart, aend, akey
		end
		if not kstart then break end
		local i = kend + 1
		while i <= #block do
			local c = block:sub(i, i)
			if c == "\\" then
				i = i + 2
			elseif c == '"' then
				break
			else
				i = i + 1
			end
		end
		t[key] = decode_escapes(block:sub(kend + 1, i - 1))
		pos = i + 1
	end
	return t
end

function M.load_format_descriptions(path)
	local f = assert(io.open(path, "r"), "cannot open " .. path)
	local src = f:read("*a")
	f:close()
	return M.extract_block(src, "format_descriptions")
end

return M
