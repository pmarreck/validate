-- Evidence-led candidate registry for composite format coverage.  A path with
-- `evidence = "candidate"` is an explicit fixture/measurement backlog, never
-- a rate claim.  The renderer will consume this after the base coverage table
-- has its complete three-mode/date schema.
local M = {}

M.sections = {
	{ id = "tiff", paths = {
		{ id = "lzw_palette", evidence = "measured", sniper_pct = 63, bolter_pct = 93, shotgun_pct = 100 },
		{ id = "packbits", evidence = "candidate" },
		{ id = "deflate", evidence = "candidate" },
		{ id = "jpeg_tiles", evidence = "candidate" },
		{ id = "jpeg2000", evidence = "candidate" },
	} },
	{ id = "pdf", paths = {
		{ id = "flate", evidence = "candidate" }, { id = "dct", evidence = "candidate" },
		{ id = "jpx", evidence = "candidate" }, { id = "jbig2", evidence = "candidate" },
		{ id = "ccitt", evidence = "candidate" }, { id = "lzw", evidence = "candidate" },
	} },
	{ id = "iso_bmff", paths = {
		{ id = "heic", evidence = "candidate" }, { id = "avif", evidence = "candidate" },
		{ id = "h264_aac", evidence = "candidate" },
	} },
	{ id = "matroska", paths = {
		{ id = "vp8", evidence = "candidate" }, { id = "vp9_opus", evidence = "candidate" },
	} },
	{ id = "zip_documents", paths = {
		{ id = "docx", evidence = "candidate", container_evidence = "inherits-zip-crc", recursive_semantics = "not-claimed" },
		{ id = "xlsx", evidence = "candidate", container_evidence = "inherits-zip-crc", recursive_semantics = "not-claimed" },
		{ id = "pptx", evidence = "candidate", container_evidence = "inherits-zip-crc", recursive_semantics = "not-claimed" },
		{ id = "odt", evidence = "candidate", container_evidence = "inherits-zip-crc", recursive_semantics = "not-claimed" },
		{ id = "epub", evidence = "candidate", container_evidence = "inherits-zip-crc", recursive_semantics = "not-claimed" },
	} },
	{ id = "dicom", paths = {
		{ id = "native_pixels", evidence = "candidate" }, { id = "encapsulated_jpeg", evidence = "candidate" },
		{ id = "encapsulated_jpeg2000", evidence = "candidate" },
	} },
}

for _, section in ipairs(M.sections) do
	section.paths_by_id = {}
	for _, path in ipairs(section.paths) do section.paths_by_id[path.id] = path end
end

return M
