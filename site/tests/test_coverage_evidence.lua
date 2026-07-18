-- An evidence record is publishable only when a raw, reproducible run proves
-- its provenance.  This prevents a hand-edited percentage or an overwritten
-- latest TSV from becoming a public coverage claim.
package.path = "./?.lua;./lib/?.lua;" .. package.path

local evidence = require("coverage_evidence")

local function expect_error(record, label)
	local ok = pcall(evidence.validate_record, record)
	if ok then error("expected invalid record: " .. label) end
end

local valid = {
	series = "tiff/lzw_palette/bali.tif",
	run_id = "2026-07-17T19:35:00-04:00-924075817",
	status = "measured",
	mode = "sniper",
	seed = 42,
	trials = 100,
	detected = 63,
	fixture_sha256 = string.rep("a", 64),
	raw_tsv_sha256 = string.rep("b", 64),
	signed_binary_sha256 = string.rep("c", 64),
	source_commit = string.rep("d", 40),
	target = "x86_64-linux",
	host = "thelio",
}

assert(evidence.validate_record(valid))
expect_error({ status = "candidate", series = valid.series }, "candidate lacking rates is not a run")

local missing = {}
for k, v in pairs(valid) do missing[k] = v end
missing.signed_binary_sha256 = nil
expect_error(missing, "unsigned binary")

local impossible = {}
for k, v in pairs(valid) do impossible[k] = v end
impossible.detected = 101
expect_error(impossible, "detected above trials")

print("test_coverage_evidence: all assertions passed")
