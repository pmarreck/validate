-- Contract for the public composite-format coverage matrix.  This is a
-- capability map, not a fabricated aggregate: only raw-measurement-backed
-- paths may carry rates, and ZIP-derived documents inherit ZIP integrity
-- evidence without claiming recursive document semantics.
package.path = "./?.lua;./lib/?.lua;" .. package.path

local matrix = require("composite_coverage")

local failed = 0
local function ok(condition, message)
	if not condition then
		failed = failed + 1
		io.stderr:write("not ok: " .. message .. "\n")
	end
end

local by_id = {}
for _, section in ipairs(matrix.sections) do
	ok(by_id[section.id] == nil, "unique section id: " .. section.id)
	by_id[section.id] = section
end

for _, id in ipairs({ "tiff", "pdf", "iso_bmff", "matroska", "zip_documents", "dicom" }) do
	ok(by_id[id] ~= nil, "required composite section: " .. id)
end
ok(by_id.email == nil and by_id.web == nil, "email/web containers excluded by scope")

local tiff = assert(by_id.tiff, "TIFF section missing")
local lzw = assert(tiff.paths_by_id.lzw_palette, "TIFF LZW cell missing")
ok(lzw.evidence == "measured", "TIFF LZW is measured")
ok(lzw.sniper_pct == 63 and lzw.bolter_pct == 93 and lzw.shotgun_pct == 100,
	"TIFF LZW rates match signed raw evidence")

local zip_docs = assert(by_id.zip_documents, "ZIP-derived documents missing")
for _, id in ipairs({ "docx", "xlsx", "pptx", "odt", "epub" }) do
	local path = assert(zip_docs.paths_by_id[id], "ZIP-derived path missing: " .. id)
	ok(path.container_evidence == "inherits-zip-crc", id .. " inherits ZIP CRC evidence")
	ok(path.recursive_semantics == "not-claimed", id .. " makes no recursive semantic claim")
end

for _, section in ipairs(matrix.sections) do
	for _, path in ipairs(section.paths) do
		if path.evidence ~= "measured" then
			ok(path.sniper_pct == nil and path.bolter_pct == nil and path.shotgun_pct == nil,
				"unmeasured path has no fabricated rate: " .. section.id .. "/" .. path.id)
		end
	end
end

if failed > 0 then os.exit(1) end
print("test_composite_coverage: all assertions passed")
