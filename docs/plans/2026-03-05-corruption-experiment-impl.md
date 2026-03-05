# Corruption Detection Experiment — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** LuaJIT script that statistically estimates `validate`'s corruption detection rate via repeated single-bit flips (sniper) or 4KB overwrites (shotgun).

**Architecture:** Single LuaJIT script with embedded PCG32 PRNG. Reads file into memory, corrupts a copy per trial, writes to `$TMPDIR`, shells out to `validate`, records results to TSV. Wilson CI for statistical analysis.

**Tech Stack:** LuaJIT (FFI for binary I/O), PCG32 PRNG, `validate` CLI

---

### Task 1: PCG32 PRNG + CLI Argument Parsing

**Files:**
- Create: `scripts/corruption-experiment`

**Step 1: Write the script skeleton with PCG32 and arg parsing**

```lua
#!/usr/bin/env luajit
--[[
corruption-experiment: Statistical corruption detection estimator for validate.
Modes: sniper (single-bit flip), shotgun (4KB overwrite).
Uses seeded PCG32 for reproducibility. Outputs TSV + human summary.
]]

local ffi = require("ffi")
local bit = require("bit")

-- ===== PCG32 PRNG =====
-- Minimal PCG-XSH-RR-64/32 implementation for reproducible experiments.
local pcg = {}
pcg.__index = pcg

function pcg.new(seed)
	local self = setmetatable({}, pcg)
	-- Use uint64_t for state
	self.state = ffi.new("uint64_t", 0)
	self.inc = ffi.new("uint64_t", 1442695040888963407ULL)
	-- Seed: advance state twice per PCG spec
	self.state = ffi.new("uint64_t", 0)
	self:next_u32()
	self.state = self.state + ffi.new("uint64_t", seed)
	self:next_u32()
	return self
end

function pcg:next_u32()
	local oldstate = self.state
	self.state = oldstate * ffi.new("uint64_t", 6364136223846793005ULL) + self.inc
	-- XSH-RR output function
	local xorshifted = tonumber(bit.band(
		bit.rshift(tonumber(ffi.cast("uint32_t",
			bit.bxor(
				tonumber(ffi.cast("uint32_t", bit.rshift(ffi.cast("uint64_t", oldstate), 18))),
				tonumber(ffi.cast("uint32_t", oldstate))
			)
		)), 27),
		0xFFFFFFFF
	))
	local rot = tonumber(ffi.cast("uint32_t", bit.rshift(ffi.cast("uint64_t", oldstate), 59)))
	return bit.bor(
		bit.band(bit.rshift(xorshifted, rot), 0xFFFFFFFF),
		bit.band(bit.lshift(xorshifted, bit.band((-rot), 31)), 0xFFFFFFFF)
	)
end

--- Return uniform random integer in [0, bound-1]
function pcg:uniform(bound)
	if bound <= 1 then return 0 end
	-- Rejection sampling to avoid modulo bias
	local threshold = (0x100000000 - bound) % bound
	while true do
		local r = self:next_u32()
		if r >= threshold then
			return r % bound
		end
	end
end

--- Return a random byte (0-255)
function pcg:byte()
	return self:next_u32() % 256
end

-- ===== Seed from /dev/urandom =====
local function random_seed()
	local f = io.open("/dev/urandom", "rb")
	if not f then
		-- Fallback: time-based
		return os.time() + tonumber(tostring({}):match("0x(%x+)"), 16)
	end
	local bytes = f:read(8)
	f:close()
	local seed = 0
	for i = 1, #bytes do
		seed = seed * 256 + bytes:byte(i)
	end
	return seed
end

-- ===== CLI Parsing =====
local function parse_args(argv)
	local opts = {
		mode = nil,
		file = nil,
		count = 38416,
		seed = nil,
		no_stop = false,
		output = nil, -- nil = stdout
	}

	local i = 1
	while i <= #argv do
		local a = argv[i]
		if a == "-h" or a == "--help" then
			io.stderr:write([[
Usage: corruption-experiment <mode> <file> [options]

Modes:
  sniper    Single-bit flip at random byte offset
  shotgun   Overwrite 4096 consecutive bytes with random data

Options:
  --count N     Max trials (default: 38416)
  --seed N      PRNG seed (default: from /dev/urandom)
  --no-stop     Disable early stopping, run all N trials
  --output F    TSV output path (default: stdout)
  -h, --help    Show this help
]])
			os.exit(0)
		elseif a == "--count" then
			i = i + 1
			opts.count = tonumber(argv[i]) or error("--count requires a number")
		elseif a == "--seed" then
			i = i + 1
			opts.seed = tonumber(argv[i]) or error("--seed requires a number")
		elseif a == "--no-stop" then
			opts.no_stop = true
		elseif a == "--output" then
			i = i + 1
			opts.output = argv[i] or error("--output requires a path")
		elseif not opts.mode and (a == "sniper" or a == "shotgun") then
			opts.mode = a
		elseif not opts.file then
			opts.file = a
		else
			error("Unknown argument: " .. a)
		end
		i = i + 1
	end

	if not opts.mode then error("Missing mode (sniper or shotgun)") end
	if not opts.file then error("Missing file argument") end
	if not opts.seed then opts.seed = random_seed() end

	return opts
end

-- ===== File I/O =====
local function read_file(path)
	local f, err = io.open(path, "rb")
	if not f then error("Cannot open file: " .. path .. " (" .. (err or "unknown") .. ")") end
	local data = f:read("*a")
	f:close()
	return data
end

local function write_file(path, data)
	local f = io.open(path, "wb")
	if not f then error("Cannot write file: " .. path) end
	f:write(data)
	f:close()
end

-- ===== Corruption =====

--- Sniper: flip one random bit
local function corrupt_sniper(data, rng)
	local off = rng:uniform(#data)       -- 0-indexed byte offset
	local b = rng:uniform(8)             -- bit index 0-7
	local buf = ffi.new("uint8_t[?]", #data)
	ffi.copy(buf, data, #data)
	buf[off] = bit.bxor(buf[off], bit.lshift(1, b))
	return ffi.string(buf, #data), off, b
end

--- Shotgun: overwrite 4096 bytes with random data
local function corrupt_shotgun(data, rng)
	if #data < 4096 then error("File too small for shotgun mode (< 4096 bytes)") end
	local off = rng:uniform(#data - 4096 + 1) -- 0-indexed start
	local buf = ffi.new("uint8_t[?]", #data)
	ffi.copy(buf, data, #data)
	for i = 0, 4095 do
		buf[off + i] = rng:byte()
	end
	return ffi.string(buf, #data), off, nil
end

-- ===== Wilson Confidence Interval =====
local function wilson_ci(k, n)
	if n == 0 then return 0, 0, 0, 1 end
	local z = 1.959963984540054
	local p_hat = k / n
	local z2 = z * z
	local den = 1 + z2 / n
	local center = (p_hat + z2 / (2 * n)) / den
	local radius = (z * math.sqrt(p_hat * (1 - p_hat) / n + z2 / (4 * n * n))) / den
	return p_hat, center - radius, center + radius, radius
end

-- ===== Validate =====
local function validate_file(path)
	-- os.execute returns raw wait status in LuaJIT: 0=success, 256=exit(1)
	local ret = os.execute(string.format(
		'./zig-out/bin/validate "%s" > /dev/null 2>/dev/null', path))
	return ret == 0 -- true = valid (corruption NOT detected), false = detected
end

-- ===== Human-readable summary =====
local function print_summary(opts, filesize, k, n, seed, p_hat, ci_lo, ci_hi, radius)
	local pct = p_hat * 100
	local margin = radius * 100
	local basename = opts.file:match("([^/]+)$") or opts.file

	io.stderr:write(string.format("\n═══ Results: %s on %s (%s bytes) ═══\n",
		opts.mode, basename, tostring(filesize)))
	io.stderr:write(string.format("  Detection rate:  %.1f%% ± %.1f%%  (95%% confidence)\n", pct, margin))
	io.stderr:write(string.format("  CI:              [%.1f%%, %.1f%%]\n", ci_lo * 100, ci_hi * 100))
	io.stderr:write(string.format("  Trials:          %d of %d%s\n",
		n, opts.count, (n < opts.count and not opts.no_stop) and " (early stop)" or ""))
	io.stderr:write(string.format("  Detected:        %d\n", k))
	io.stderr:write(string.format("  Missed:          %d\n", n - k))
	io.stderr:write(string.format("  Seed:            %s\n", tostring(seed)))
	io.stderr:write("\n")

	-- Plain English summary
	local pct_round = math.floor(pct + 0.5)
	if opts.mode == "sniper" then
		io.stderr:write(string.format(
			"  Plain English:   ~%d%% of the file's bytes are covered by\n" ..
			"                   validation. A random single-bit flip has\n" ..
			"                   a %d%% chance of being caught.\n",
			pct_round, pct_round))
	else
		io.stderr:write(string.format(
			"  Plain English:   A random 4KB sector failure has a %.1f%%\n" ..
			"                   chance of being caught by validation.\n",
			pct))
	end
	io.stderr:write("\n")
end

-- ===== Progress =====
local function print_progress(trial, total, k, mode)
	if trial % 100 == 0 and trial > 0 then
		local p_hat = k / trial
		io.stderr:write(string.format(
			"\r  [%d/%d] detected=%d (%.1f%%)   ", trial, total, k, p_hat * 100))
	end
end

-- ===== Main =====
local function main()
	local opts = parse_args(arg)
	local data = read_file(opts.file)
	local filesize = #data
	local rng = pcg.new(opts.seed)
	local basename = opts.file:match("([^/]+)$") or opts.file

	-- Get file extension for temp file
	local ext = opts.file:match("%.([^.]+)$") or "bin"
	local tmpdir = os.getenv("TMPDIR") or "/tmp"
	local tmpfile = tmpdir .. "/corruption_trial." .. ext

	-- Open TSV output
	local tsv_out = io.stdout
	if opts.output then
		tsv_out = io.open(opts.output, "w")
		if not tsv_out then error("Cannot open output file: " .. opts.output) end
	end

	-- TSV header
	tsv_out:write(string.format("# seed=%s mode=%s file=%s filesize=%d\n",
		tostring(opts.seed), opts.mode, basename, filesize))
	tsv_out:write("trial\tmode\tfilesize\toff\tbit\tspan\tdetected\n")

	local corrupt_fn = opts.mode == "sniper" and corrupt_sniper or corrupt_shotgun
	local span = opts.mode == "sniper" and 1 or 4096

	local k = 0 -- detected count
	local n = 0 -- trial count

	io.stderr:write(string.format("Starting %s experiment on %s (%d bytes, seed=%s, max=%d)\n",
		opts.mode, basename, filesize, tostring(opts.seed), opts.count))

	for trial = 0, opts.count - 1 do
		-- Corrupt
		local corrupted, off, b = corrupt_fn(data, rng)

		-- Write to tmpfile
		write_file(tmpfile, corrupted)

		-- Validate
		local valid = validate_file(tmpfile)
		local detected = not valid

		if detected then k = k + 1 end
		n = n + 1

		-- Record TSV
		local bit_col = b and tostring(b) or "-"
		tsv_out:write(string.format("%d\t%s\t%d\t%d\t%s\t%d\t%s\n",
			trial, opts.mode, filesize, off, bit_col, span,
			detected and "true" or "false"))

		-- Progress
		print_progress(n, opts.count, k, opts.mode)

		-- Early stopping check every 100 trials
		if not opts.no_stop and n >= 100 and n % 100 == 0 then
			local _, _, _, radius = wilson_ci(k, n)
			if radius <= 0.005 then
				io.stderr:write(string.format(
					"\r  Early stop at trial %d: CI radius %.4f <= 0.005\n", n, radius))
				break
			end
		end
	end

	io.stderr:write("\r" .. string.rep(" ", 60) .. "\r") -- clear progress line

	-- Cleanup temp file
	os.remove(tmpfile)

	-- Final statistics
	local p_hat, ci_lo, ci_hi, radius = wilson_ci(k, n)
	print_summary(opts, filesize, k, n, opts.seed, p_hat, ci_lo, ci_hi, radius)

	-- Close output if file
	if opts.output then tsv_out:close() end
end

-- Run
local ok, err = pcall(main)
if not ok then
	io.stderr:write("Error: " .. tostring(err) .. "\n")
	os.exit(2)
end
```

**Step 2: Make executable**

```bash
chmod +x scripts/corruption-experiment
```

**Step 3: Smoke test — help flag**

```bash
scripts/corruption-experiment --help
```

Expected: Usage text printed to stderr, exit 0.

**Step 4: Smoke test — sniper with 10 trials on a small file**

```bash
scripts/corruption-experiment sniper ground_truth_examples/doc/sample.doc --count 10 --seed 42
```

Expected: TSV header + 10 rows to stdout, summary to stderr. No crashes.

**Step 5: Smoke test — shotgun with 10 trials**

```bash
scripts/corruption-experiment shotgun ground_truth_examples/doc/sample.doc --count 10 --seed 42
```

Expected: Same format, 10 rows, no crashes.

**Step 6: Reproducibility test — same seed = same offsets**

```bash
scripts/corruption-experiment sniper ground_truth_examples/doc/sample.doc --count 5 --seed 42 > /tmp/run1.tsv
scripts/corruption-experiment sniper ground_truth_examples/doc/sample.doc --count 5 --seed 42 > /tmp/run2.tsv
diff /tmp/run1.tsv /tmp/run2.tsv
```

Expected: No diff (identical output for same seed).

**Step 7: Commit**

```bash
git add scripts/corruption-experiment
git commit -m "Add corruption detection experiment script (sniper/shotgun modes)"
```

---

### Task 2: Validate Against Multiple Formats

After Task 1 works, run against several format types to verify broad compatibility:

**Step 1: Quick runs across formats**

```bash
for f in ground_truth_examples/doc/sample.doc \
         ground_truth_examples/xls/sample.xls \
         ground_truth_examples/png/sample.png \
         ground_truth_examples/pdf/sample.pdf; do
    echo "=== $(basename $f) ==="
    scripts/corruption-experiment sniper "$f" --count 100 --seed 42 > /dev/null
done
```

Expected: Summaries for each format, no crashes.

**Step 2: Fix any issues discovered**

**Step 3: Commit fixes if any**

---

### Task 3: Documentation

**Files:**
- Modify: `CODE_MINIMAP.md`
- Modify: `PLAN.md`

**Step 1: Add entry to CODE_MINIMAP.md**

Add to scripts section:
```
| `scripts/corruption-experiment` | LuaJIT statistical corruption detection estimator — sniper (single-bit flip) and shotgun (4KB overwrite) modes with seeded PCG32, Wilson CI, early stopping, TSV output |
```

**Step 2: Update PLAN.md**

Check off the corruption experiment item.

**Step 3: Commit**

```bash
git add CODE_MINIMAP.md PLAN.md
git commit -m "Add corruption-experiment to docs"
```
