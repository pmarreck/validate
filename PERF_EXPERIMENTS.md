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

## Post-optimization: `~/Documents` (MAX_FILES=80000)
- Date (EST): 2026-01-26
- Path: `~/Documents`
- Env: `MAX_FILES=80000 MEM_TELEMETRY=1 MEM_TELEMETRY_PATH=/tmp/validate_docs_mem_after.log`
- Counts: Valid 72432, Invalid 36, Unknown 7532
- CPU time (user+sys): 30.16s (user 20.13s, sys 10.03s; real 4.19s)
- Max RSS: ~998.3MB; RSS at end ~761.8MB
- Notes: Dramatic speedup vs baseline; likely dominated by page cache + removal of ZIP data-descriptor scan.

## PDF Telemetry: Books (stage breakdown)
- Date (EST): 2026-01-26
- Path: `~/Documents/Books`
- Env: `PDF_TELEMETRY=1 PDF_SLOW_SECONDS=5`
- Counts: Valid 1179, Invalid 4, Unknown 7
- Observations:
  - Most slow PDFs are dominated by **image validation** time.
  - Two extreme outliers are dominated by **font validation** time (thousands of fonts).
- Slowest PDFs (total / images / fonts / embedded):
  - 117.64s / 1.71s / 115.87s / 0.04s — The Ashley Book of Knots (fonts_total=2660, fonts_failed=2660)
  - 79.86s / 3.19s / 76.60s / 0.06s — OPD - Oxford Picture Dictionary 3 ed. (fonts_total=2667)
  - 79.70s / 79.63s / 0.03s / 0.03s — The Last Whole Earth Catalog Access to Tools
  - 37.70s / 37.67s / 0.01s / 0.01s — Science Fiction - Contemporary Mythology (SFWA/SFRA)
  - 31.35s / 31.08s / 0.12s / 0.12s — FIGHTING FANTASY COMPLETE COLLECTION

## Ground Truth Validation (post ZIP optimization)
- Date (EST): 2026-01-26
- Path: `ground_truth_examples`
- Counts: Valid 142, Invalid 3, Unknown 7
- Invalid PDFs (all missing trailer dictionary):
  - `pdf/Jbig2_042_01.pdf`
  - `pdf/Jbig2_042_02.pdf`
  - `pdf/Jbig2_042_03.pdf`

## Memory & Concurrency Notes (Analysis)
- RSS peaks ~1GB and stays elevated after runs; arenas reset but do not return memory to the OS.
- Each worker uses an arena allocator for deep validation; large per-file allocations (PDF full-file buffers, image/font decode buffers) stay resident until file completion, then remain reserved by the arena.
- Concurrency amplifies memory: multiple large PDFs in flight => multiple arenas at peak size, increasing memory pressure and potential paging/compression, which can slow later tasks.
- Most long PDF times are image/font decode heavy (not structural parsing), so allocator pressure is dominated by large decode buffers and many small font allocations.
- GC consideration (Boehm): 
  - Pros: simplifies memory lifetime tracking for complex PDF parsing; could reduce fragmentation from many small allocations.
  - Cons: adds dependency and runtime overhead, non-deterministic pauses, and would fight against existing per-file arena lifetimes; likely worse for CLI determinism and peak memory.
- Practical next steps (if we want to reduce memory pressure without weakening validation):
  - Route *large* buffers (e.g., full PDF `pdf_data`, large decode outputs) through a non-arena allocator so they can be freed back to OS.
  - Add a size threshold to keep per-file arenas small while preserving fast small allocations.
  - Consider streaming validation for image/font streams to avoid full-buffer materialization where possible.

## Experiment D: Dedicated Output Thread with Result Queue
- Date (EST): 2026-01-27
- Change summary: Replace callback_mutex-serialized I/O with dedicated output thread.
  Workers push results to a ResultQueue (brief lock, no I/O under lock).
  A single output thread drains the queue and calls the callback.
- Path: `~/Documents` (MAX_FILES=20000)
- Counts: Valid 16683, Invalid 4, Unknown 3313
- CPU time (user+sys): 23.22s (user 20.26s, sys 2.96s; real 3.34s)
- Comparison to Baseline (MAX_FILES=80000 scaled down ~4x):
  - Baseline: 470.80s total, sys 425.67s (91% of CPU time was kernel/syscalls)
  - After: 23.22s total, sys 2.96s (13% of CPU time is kernel/syscalls)
  - **sys time reduction: ~99% at comparable file counts**
- Notes: The callback_mutex was the primary bottleneck. Workers were spending most time
  waiting for the mutex while the callback did I/O (printf syscalls). Now workers only
  briefly lock the result queue, and all I/O happens on a single dedicated thread.
