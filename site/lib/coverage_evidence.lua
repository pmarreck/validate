-- Validates one append-only corruption-coverage run record before it can feed
-- the public site.  The fields bind a percentage to immutable raw evidence,
-- the exact signed validator, fixture, source revision, and execution target.
local M = {}

M.ledger_fields = {
	"timestamp_utc",
	"run_id",
	"series",
	"mode",
	"seed",
	"trials",
	"detected",
	"mutation_policy",
	"fixture_id",
	"fixture_sha256",
	"raw_tsv_relpath",
	"raw_tsv_sha256",
	"signed_binary_id",
	"signed_binary_sha256",
	"source_commit",
	"target",
	"host",
}

M.ledger_header = table.concat(M.ledger_fields, "\t")

local function required_string(record, key, pattern)
	local value = record[key]
	if type(value) ~= "string" or not value:match(pattern) then
		error("coverage evidence: invalid " .. key)
	end
end

local function required_sha256(record, key)
	local value = record[key]
	if type(value) ~= "string" or #value ~= 64 or not value:match("^[0-9a-f]+$") then
		error("coverage evidence: invalid " .. key)
	end
end

local function required_identifier(record, key)
	local value = record[key]
	if type(value) ~= "string" or not value:match("^[%w%._%-%/]+$") then
		error("coverage evidence: invalid " .. key)
	end
end

local function required_raw_tsv_path(record)
	local path = record.raw_tsv_relpath
	if type(path) ~= "string"
		or not path:match("^docs/coverage%-evidence/runs/[%w%._%-%/]+%.tsv$")
		or path:find("..", 1, true)
	then
		error("coverage evidence: invalid raw_tsv_relpath")
	end
end

function M.validate_record(record)
	if type(record) ~= "table" then error("coverage evidence: record must be a table") end
	if record.status ~= "measured" then error("coverage evidence: only measured records are runs") end
	required_string(record, "series", ".+")
	required_string(record, "run_id", ".+")
	if type(record.timestamp_utc) ~= "string"
		or not record.timestamp_utc:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$")
	then
		error("coverage evidence: invalid timestamp_utc")
	end
	if record.mode ~= "sniper" and record.mode ~= "bolter" and record.mode ~= "shotgun" then
		error("coverage evidence: invalid mode")
	end
	for _, key in ipairs({ "seed", "trials", "detected" }) do
		if type(record[key]) ~= "number" or record[key] < 0 or record[key] % 1 ~= 0 then
			error("coverage evidence: invalid " .. key)
		end
	end
	if record.trials == 0 or record.detected > record.trials then
		error("coverage evidence: detected must be within trials")
	end
	for _, key in ipairs({ "fixture_sha256", "raw_tsv_sha256", "signed_binary_sha256" }) do
		required_sha256(record, key)
	end
	required_identifier(record, "mutation_policy")
	required_identifier(record, "fixture_id")
	required_identifier(record, "signed_binary_id")
	required_raw_tsv_path(record)
	local commit = record.source_commit
	if type(commit) ~= "string" or #commit ~= 40 or not commit:match("^[0-9a-f]+$") then
		error("coverage evidence: invalid source_commit")
	end
	required_string(record, "target", ".+")
	required_string(record, "host", ".+")
	return true
end

local function split_tsv(line)
	local cells, start = {}, 1
	while true do
		local separator = line:find("\t", start, true)
		if separator then
			cells[#cells + 1] = line:sub(start, separator - 1)
			start = separator + 1
		else
			cells[#cells + 1] = line:sub(start)
			return cells
		end
	end
end

--- Parses the immutable coverage-run ledger with a deliberately exact schema.
--- Rejecting unknown or reordered columns prevents a changed shell writer from
--- silently reinterpreting provenance in an existing public history.
function M.parse_ledger_tsv_string(tsv)
	if type(tsv) ~= "string" then error("coverage evidence: ledger must be a string") end
	local lines = {}
	for line in (tsv .. "\n"):gmatch("(.-)\n") do
		if #line > 0 then lines[#lines + 1] = line end
	end
	if lines[1] ~= M.ledger_header then
		error("coverage evidence: ledger schema does not match")
	end

	local records = {}
	for line_index = 2, #lines do
		local cells = split_tsv(lines[line_index])
		if #cells ~= #M.ledger_fields then
			error("coverage evidence: wrong column count on ledger line " .. line_index)
		end
		local record = { status = "measured" }
		for index, field in ipairs(M.ledger_fields) do
			local value = cells[index]
			if field == "seed" or field == "trials" or field == "detected" then
				value = tonumber(value)
			end
			record[field] = value
		end
		records[#records + 1] = record
	end
	return records
end

--- Validates the ledger as an append-only set: a run may contain each mode
--- once for a series, so accidental overwrites surface before publication.
function M.validate_ledger(records)
	if type(records) ~= "table" then error("coverage evidence: ledger must be a table") end
	local seen = {}
	for _, record in ipairs(records) do
		M.validate_record(record)
		local key = table.concat({ record.run_id, record.series, record.mode }, "\0")
		if seen[key] then
			error("coverage evidence: duplicate run/series/mode")
		end
		seen[key] = true
	end
	return true
end

return M
