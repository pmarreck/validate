-- Validates one append-only corruption-coverage run record before it can feed
-- the public site.  The fields bind a percentage to immutable raw evidence,
-- the exact signed validator, fixture, source revision, and execution target.
local M = {}

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

function M.validate_record(record)
	if type(record) ~= "table" then error("coverage evidence: record must be a table") end
	if record.status ~= "measured" then error("coverage evidence: only measured records are runs") end
	required_string(record, "series", ".+")
	required_string(record, "run_id", ".+")
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
	local commit = record.source_commit
	if type(commit) ~= "string" or #commit ~= 40 or not commit:match("^[0-9a-f]+$") then
		error("coverage evidence: invalid source_commit")
	end
	required_string(record, "target", ".+")
	required_string(record, "host", ".+")
	return true
end

return M
