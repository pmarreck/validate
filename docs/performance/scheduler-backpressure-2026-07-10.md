# Scheduler backpressure — Mac Documents corpus, 2026-07-10

## Outcome

The accepted implementation replaces the per-task, post-dequeue 500 ms RSS
sleep with a centralized pre-reservation admission gate. It uses one RSS
sampling leader, 75% low-watermark hysteresis, bounded permits derived from
headroom and already-active tasks, platform allocator pressure relief, and a
single-task escape so retained pages cannot halt forward progress.

For the standalone Linux/glibc CLI only, the default arena count is two unless
`MALLOC_ARENA_MAX` is explicitly set. The public library does not apply this
process-global policy, so embedding it in `validate_gui` does not silently
reconfigure Swift/AppKit allocation.

| ReleaseFast run | Disposition | Files | Peak RSS | Avg CPU | RSS-wait ns | Max RSS waiters |
|---|---:|---:|---:|---:|---:|---:|
| Old per-task timeout | baseline | 12,831 | 26.46 GiB | 4,226% | 5,529,111,924,494 | 69 |
| First centralized gate | rejected | 2,195 | 17.39 GiB | 2,412% | incomplete | 68 |
| Active-aware, 1 GiB permits | rejected | 3,807 | 8.86 GiB | 946% | 13,752,757,604,674 | 84 |
| Recovery batches, default glibc | rejected | 3,533 | 10.43 GiB | 1,117% | 13,528,863,625,745 | 84 |
| Recovery + startup arena env | pilot | 9,664 | 9.41 GiB | 2,269% | 11,957,149,333,437 | 83 |
| Recovery + automatic CLI policy | accepted | 9,958 | 11.89 GiB | 1,976% | 12,276,099,265,966 | 83 |

Against the repeated same-day control, the accepted run traded 22.39% of
completed-file throughput for 55.06% lower peak RSS. Completed files per peak
GiB improved 72.71% (484.9 to 837.5). Queue-empty wait stayed effectively flat
at about 1.16 seconds total, confirming that the limiting signal is memory
pressure rather than lack of queued work.

The larger aggregate RSS-wait value is expected: the old timeout admitted work
after 500 ms even while over budget, whereas the new counter measures workers
that remain safely blocked. It must be interpreted with throughput, RSS, CPU,
and current waiter count—not minimized in isolation.

## Protocol

- Corpus: `/home/pmarreck/perf-corpora/mac-documents`, 595,792 files, about
  220 GiB allocated.
- Command shape: ReleaseFast `validate --jobs 0`, 85 outer workers, default
  8 GiB memory budget, result streams routed to `@null`.
- Diagnostics: `HEAP_FRAG_DEBUG=1`, five-second heap/scheduler reports, and an
  independent five-second `/proc` sampler for RSS, CPU, threads, and I/O.
- Fixed window: 155 seconds normal operation, 25 seconds after SIGINT, then
  SIGTERM. All rows used the same corpus order and protocol.
- Durable machine-readable summary:
  `bench/results/scheduler_backpressure.jsonl`.
- Raw logs remain under `/home/pmarreck/perf-results/validate/` at the paths in
  each JSONL record; they are intentionally not committed because diagnostics
  contain local paths and are megabytes per run.

## Arena finding

The Zig side already uses a per-task `std.heap.ArenaAllocator` plus the
large-allocation diverting allocator. During the rejected active-aware run,
snapshots showed essentially no Zig-live memory while glibc retained roughly
6–10 GiB in free arenas. C codecs allocate through libc and therefore bypass
the Zig arena.

Moving C memory under the task arena is possible only library by library where
allocator callbacks exist. It must preserve alignment, `realloc`, threading,
and lifetime contracts; arena `free` is intentionally deferred and can raise a
task's within-run peak. The safe follow-up is to profile the largest C-codec
owners and adapt clean callback surfaces incrementally, not interpose `malloc`
process-wide from a linkable library.
