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
	timestamp_utc = "2026-07-17T23:35:00Z",
	mode = "sniper",
	seed = 42,
	trials = 100,
	detected = 63,
	mutation_policy = "single-bit-v1",
	fixture_id = "bali.tif",
	fixture_sha256 = string.rep("a", 64),
	raw_tsv_relpath = "docs/coverage-evidence/runs/2026-07-17T233500Z-924075817/tiff_lzw_palette_bali.tif_sniper.tsv",
	raw_tsv_sha256 = string.rep("b", 64),
	signed_binary_id = "validate-linux-x86_64-releasefast",
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

local ledger_tsv = table.concat({
	"timestamp_utc\trun_id\tseries\tmode\tseed\ttrials\tdetected\tmutation_policy\tfixture_id\tfixture_sha256\traw_tsv_relpath\traw_tsv_sha256\tsigned_binary_id\tsigned_binary_sha256\tsource_commit\ttarget\thost",
	"2026-07-18T03:35:00Z\t2026-07-18T033500Z-924075817\ttiff/lzw_palette/bali.tif\tsniper\t42\t100\t63\tsingle-bit-v1\tbali.tif\t" .. string.rep("a", 64) .. "\tdocs/coverage-evidence/runs/2026-07-18T033500Z-924075817/tiff_lzw_palette_bali.tif_sniper.tsv\t" .. string.rep("b", 64) .. "\tvalidate-linux-x86_64-releasefast\t" .. string.rep("c", 64) .. "\t" .. string.rep("d", 40) .. "\tx86_64-linux\tthelio-nixos",
	"2026-07-18T03:35:00Z\t2026-07-18T033500Z-924075817\ttiff/lzw_palette/bali.tif\tbolter\t42\t100\t93\tcontiguous-byte-span-v1\tbali.tif\t" .. string.rep("a", 64) .. "\tdocs/coverage-evidence/runs/2026-07-18T033500Z-924075817/tiff_lzw_palette_bali.tif_bolter.tsv\t" .. string.rep("e", 64) .. "\tvalidate-linux-x86_64-releasefast\t" .. string.rep("c", 64) .. "\t" .. string.rep("d", 40) .. "\tx86_64-linux\tthelio-nixos",
}, "\n") .. "\n"

local ledger = evidence.parse_ledger_tsv_string(ledger_tsv)
assert(#ledger == 2, "ledger parser returns both append-only records")
assert(ledger[1].trials == 100 and ledger[1].detected == 63, "ledger parser converts numerical trial fields")
assert(ledger[1].raw_tsv_relpath:match("^docs/coverage%-evidence/runs/"), "ledger records keep raw evidence path")
assert(evidence.validate_ledger(ledger), "ledger validates each record and uniqueness")

local malformed_schema = ledger_tsv:gsub("\ttarget\thost", "\thost")
assert(not pcall(evidence.parse_ledger_tsv_string, malformed_schema), "ledger requires exact schema")

local duplicate_line = ledger_tsv:match("\n([^\n]+sniper[^\n]+)\n")
local duplicate = evidence.parse_ledger_tsv_string(ledger_tsv .. duplicate_line .. "\n")
assert(not pcall(evidence.validate_ledger, duplicate), "ledger rejects duplicate run series and mode")

print("test_coverage_evidence: all assertions passed")
