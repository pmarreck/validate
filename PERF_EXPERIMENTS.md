# Performance Experiments

Goal: Reduce validation slowdown over long concurrent runs by minimizing allocator contention,
queue growth, and memory retention. Track outcomes using CPU time (user+sys).

## Measurement Method
- Command: `/usr/bin/time -p <command>`
- Metric: CPU time = `user` + `sys` (ignore `real` if machine is busy/gaming).
- Build: ReleaseFast (`./build`), `DEBUG=0`.
- Run: `./zig-out/bin/validate <path> --jobs 0`
- Limit: `MAX_FILES` env var to keep runs under ~10 minutes.

## Baseline (current yolo)
- Commit: 07980947
- Date (EST): 2026-01-26
- Path: `~/Documents/Books`
- MAX_FILES: 0
- Counts: Valid 1179, Invalid 4, Unknown 7
- CPU time (user+sys): 1437.77s (user 1007.57s, sys 430.20s; real 376.44s)
- Notes: SLOW `The Hobbit (J. R. R. Tolkien).epub` at 169.73s
- Path: `~/Documents` (MAX_FILES=80000)
- Counts: Valid 72432, Invalid 36, Unknown 7532
- CPU time (user+sys): 470.80s (user 45.13s, sys 425.67s; real 105.40s)
- Notes: many SLOW ZIPs (70s–105s); ps/top CPU sampling not available (permission limits)

## Experiment A: Relative-path queue + per-thread full-path scratch
- Branch/bookmark: perf-relpath (conflict)
- Change summary: queue stores only relative path; full path built per worker
- Path: `~/Documents/Books`
- MAX_FILES: 0
- Counts: Valid 1179, Invalid 4, Unknown 7
- CPU time (user+sys): 1464.41s (user 1021.09s, sys 443.32s; real 384.04s)
- Notes: log contained multiple SLOW entries; no improvement vs baseline
- Path: `~/Documents` (MAX_FILES=80000)
- Counts: Valid 72432, Invalid 36, Unknown 7532
- CPU time (user+sys): 453.56s (user 44.79s, sys 408.77s; real 100.18s)
- Notes: no improvement vs baseline

## Experiment B: Bounded work queue (backpressure)
- Branch/bookmark: perf-bounded
- Change summary: queue capped to max(256, job_count*128)
- Path: `~/Documents/Books`
- MAX_FILES: 0
- Counts: Valid 1179, Invalid 4, Unknown 7
- CPU time (user+sys): 1465.45s (user 1023.22s, sys 442.23s; real 386.50s)
- Notes: no improvement vs baseline
- Path: `~/Documents` (MAX_FILES=80000)
- Counts: Valid 72432, Invalid 36, Unknown 7532
- CPU time (user+sys): 462.56s (user 44.54s, sys 418.02s; real 102.08s)
- Notes: no improvement vs baseline

## Experiment C: Per-thread allocator isolation
- Branch/bookmark: perf-allocator
- Change summary: worker uses PageAllocator-backed arena for per-file allocations
- Path: `~/Documents` (MAX_FILES=80000)
- Counts: Valid 72432, Invalid 36, Unknown 7532
- CPU time (user+sys): 460.49s (user 44.99s, sys 415.50s; real 102.27s)
- Notes: no improvement vs baseline

## Winner / Merge Decision
- Selected approach:
- Rationale:
- Follow-ups:

## Telemetry: Books (memory + ZIP)
- Date (EST): 2026-01-26
- Path: `~/Documents/Books`
- Env: `MEM_TELEMETRY=1 MEM_TELEMETRY_PATH=/tmp/validate_books_mem.log ZIP_TELEMETRY=1 ZIP_SLOW_SECONDS=0.5`
- Counts: Valid 1179, Invalid 4, Unknown 7
- CPU time (user+sys): 1461.80s (user 1017.48s, sys 444.32s; real 379.91s)
- Max RSS: ~951.9MB; RSS later fell to ~376.8MB by end
- ZIP_SLOW top entries (elapsed):
  - EPUB: `META-INF/container.xml` entry with data descriptor scanning ~177,092,340 reads (~175.85s)
  - ZIP (CBZ): `page000.png` entry with data descriptor scanning ~2,872,707 reads (~6.86s)
  - EPUB: `mimetype` entry with data descriptor scanning ~2,074,244 reads (~6.62s)
- Observation: slow ZIPs are overwhelmingly entries with general-purpose bit 3 set (data descriptor).
  Local header sizes are zero, forcing byte-by-byte scanning for the descriptor and causing huge read loops.
  This likely dominates slow ZIP/EPUB/CBZ validation time.

## Telemetry: Books (post ZIP central directory parsing)
- Date (EST): 2026-01-26
- Path: `~/Documents/Books`
- Env: `MEM_TELEMETRY=1 MEM_TELEMETRY_PATH=/tmp/validate_books_mem_after.log ZIP_TELEMETRY=1 ZIP_SLOW_SECONDS=0.5`
- Counts: Valid 1179, Invalid 4, Unknown 7
- CPU time (user+sys): 936.38s (user 923.24s, sys 13.14s; real 133.97s)
- Max RSS: ~999.7MB; RSS at end ~673.3MB
- ZIP_SLOW: none observed (0 lines)
- Notes: CLI SLOW warnings now point to large PDFs (not ZIP/EPUB/CBZ).
