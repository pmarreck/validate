# Corruption Detection Experiment — Design

**Date:** 2026-03-05
**Status:** Approved

## Goal

Estimate the probability that `validate` detects file corruption under two models:
- **sniper**: single-bit flip at a random byte offset
- **shotgun**: overwrite 4096 consecutive bytes (sector failure simulation)

Target: ±0.5 percentage points at 95% confidence (Wilson interval).

## Architecture

Single LuaJIT script: `scripts/corruption-experiment`

```
scripts/corruption-experiment sniper ground_truth_examples/doc/sample.doc --count 1000
scripts/corruption-experiment shotgun ground_truth_examples/doc/sample.doc --count 1000
```

### Why LuaJIT

- Fast binary I/O via FFI (no shelling out for corruption)
- Built-in PCG32 PRNG for reproducibility (same algo as `random` utility)
- Single-language solution: corruption, orchestration, statistics, reporting
- `os.execute("validate <file>")` for the validation step (tests the real CLI)

### Why not par2

The pristine file is held in LuaJIT memory. Each trial overwrites a working copy
from the pristine buffer. No repair step needed — just overwrite. Par2 is not
involved at all.

## Hot Loop

1. Read entire file into memory once
2. For each trial:
   a. Copy pristine → working buffer (in-process, ~memcpy)
   b. PCG32 generates random offset (+ bit for sniper, or 4096 bytes for shotgun)
   c. Apply corruption to working buffer
   d. Write corrupted buffer to `$TMPDIR/corruption_trial.<ext>`
   e. `os.execute("validate <tmpfile>")` — check exit code
   f. Append trial record to TSV
3. Early stop check every 100 trials (Wilson CI radius ≤ 0.005)
4. Print human-readable summary

## PRNG

Seeded PCG32 implemented directly in LuaJIT (no external dependency).
- Default seed: 8 bytes from `/dev/urandom`
- Override: `--seed N`
- Seed recorded in TSV header and summary output

## Corruption Models

### sniper
- Random byte offset: uniform in `[0, filesize-1]`
- Random bit index: uniform in `{0..7}`
- XOR that single bit

### shotgun
- Random start offset: uniform in `[0, filesize-4096]`
- Error if `filesize < 4096`
- Overwrite 4096 bytes with PCG32-generated random data

## Output

### TSV file (stdout or `--output`)

```
# seed=42 mode=sniper file=sample.doc filesize=19456
trial	mode	filesize	off	bit	span	detected
0	sniper	19456	7382	3	1	true
1	sniper	19456	102	5	1	false
```

`bit` column is empty (`-`) for shotgun mode.

### Human summary (stderr)

```
═══ Results: sniper on sample.doc (19,456 bytes) ═══
  Detection rate:  82.3% ± 0.5%  (95% confidence)
  Trials:          5,000 of 38,416 (early stop)
  Detected:        4,117
  Missed:          883
  Seed:            42

  Plain English:   ~82% of the file's bytes are protected by
                   validation. A single-bit flip has an 82% chance
                   of being caught.
```

For shotgun, the plain English adjusts to describe sector failure probability.

## Statistics

Wilson confidence interval at 95%:
- z = 1.959963984540054
- center = (p̂ + z²/(2n)) / (1 + z²/n)
- radius = (z × √(p̂(1−p̂)/n + z²/(4n²))) / (1 + z²/n)

## CLI Interface

```
corruption-experiment <mode> <file> [options]
  mode:         sniper | shotgun
  --count N     Max trials (default: 38416)
  --seed N      PRNG seed (default: from /dev/urandom)
  --no-stop     Disable early stopping, run all N trials
  --output F    TSV output path (default: stdout)
  -h, --help    Show help
```

## Default Sample Size

n = 38,416 — guarantees ±0.5% margin at 95% confidence for any true p.
With early stopping (check every 100 trials), most runs finish much sooner.

## File Layout

```
scripts/corruption-experiment    # LuaJIT executable (#!/usr/bin/env luajit)
```
