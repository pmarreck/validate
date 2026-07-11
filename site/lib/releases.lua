-- Short-lived GUI release manifest handling. The publisher owns the atomic
-- TOML replacement; this pure module accepts only its four SigV4 HTTPS links,
-- derives their expiry, and keeps stale data out of rendered pages.

local M = {}

M.ORDER = {
	"macos-aarch64",
	"windows-x86_64",
	"linux-x86_64",
	"linux-aarch64",
}

local known = {}
for _, key in ipairs(M.ORDER) do known[key] = true end

local function leap_year(year)
	return year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
end

local function days_in_month(year, month)
	local days = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
	if month == 2 and leap_year(year) then return 29 end
	return days[month]
end

-- Parse AWS's UTC basic timestamp without depending on the host timezone.
local function parse_amz_date(value)
	local year, month, day, hour, minute, second = value:match("^(%d%d%d%d)(%d%d)(%d%d)T(%d%d)(%d%d)(%d%d)Z$")
	year, month, day = tonumber(year), tonumber(month), tonumber(day)
	hour, minute, second = tonumber(hour), tonumber(minute), tonumber(second)
	if not year or year < 1970 or month < 1 or month > 12 or day < 1 or day > days_in_month(year, month)
		or hour > 23 or minute > 59 or second > 59 then
		return nil
	end

	local prior_years = year - 1970
	local leap_days = math.floor((year - 1) / 4) - math.floor(1969 / 4)
		- math.floor((year - 1) / 100) + math.floor(1969 / 100)
		+ math.floor((year - 1) / 400) - math.floor(1969 / 400)
	local days = prior_years * 365 + leap_days
	for m = 1, month - 1 do days = days + days_in_month(year, m) end
	days = days + day - 1
	return days * 86400 + hour * 3600 + minute * 60 + second
end

local function query_value(url, key)
	return url:match("[?&]" .. key .. "=([^&]+)")
end

local function parse_url(key, url, now)
	if not url:match("^https://[^/%s?#]+") or url:find("[%c%s#]") then
		return nil, key .. " must be an HTTPS URL without whitespace or fragments"
	end
	if query_value(url, "X%-Amz%-Algorithm") ~= "AWS4-HMAC-SHA256" then
		return nil, key .. " is not an AWS SigV4 URL"
	end
	if not query_value(url, "X%-Amz%-Signature") then
		return nil, key .. " has no SigV4 signature"
	end
	local issued_at = parse_amz_date(query_value(url, "X%-Amz%-Date") or "")
	if not issued_at then return nil, key .. " has an invalid X-Amz-Date" end
	local expires = tonumber(query_value(url, "X%-Amz%-Expires") or "")
	if not expires or expires <= 0 or expires > 604800 or expires % 1 ~= 0 then
		return nil, key .. " has an invalid X-Amz-Expires (must be 1..604800 seconds)"
	end
	local expires_at = issued_at + expires
	return {
		key = key,
		url = url,
		expires_at = expires_at,
		expires_utc = os.date("!%Y-%m-%d %H:%M UTC", expires_at),
		expired = expires_at <= now,
	}
end

-- Parse the deliberately constrained one-assignment-per-line TOML contract.
-- Missing platform lines are normal; malformed or duplicate data is rejected.
function M.parse_toml(source, now)
	if type(source) ~= "string" then return nil, "release manifest is not text" end
	if source ~= "" and source:sub(-1) ~= "\n" then
		return nil, "release manifest must end with a newline"
	end
	now = now or os.time()
	local by_key = {}
	for line in (source .. "\n"):gmatch("(.-)\n") do
		if not line:match("^%s*$") then
			local key, url = line:match('^%s*([a-z0-9_%-]+)%s*=%s*"([^"\\]*)"%s*$')
			if not key then return nil, "invalid TOML assignment: " .. line end
			if not known[key] then return nil, "unknown release platform: " .. key end
			if by_key[key] then return nil, "duplicate release platform: " .. key end
			local entry, err = parse_url(key, url, now)
			if not entry then return nil, err end
			by_key[key] = entry
		end
	end

	local parsed = { available = {}, expired = {} }
	for _, key in ipairs(M.ORDER) do
		local entry = by_key[key]
		if entry then
			if entry.expired then
				parsed.expired[#parsed.expired + 1] = entry
			else
				parsed.available[#parsed.available + 1] = entry
			end
		end
	end
	return parsed
end

-- Publish only complete-fresh manifest sets (one or more selected platforms).
function M.publishable(parsed)
	return parsed and #parsed.available > 0 and #parsed.expired == 0
end

return M
