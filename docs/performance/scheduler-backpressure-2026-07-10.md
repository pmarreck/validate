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

## Nested PDF parallelism continuation

The next measured bottleneck was multiplicative concurrency. Each outer batch
worker validating a PDF could create an inner image pool sized to one third of
all CPUs. With many PDFs in flight, the old policy could therefore create
hundreds of runnable threads even though outer RSS and memory admission already
limited useful concurrency.

The accepted policy communicates the actual batch width to each worker and
balances PDF image fan-out around a square-root CPU contender ceiling. Very
wide auto-sized batches use half that contender count because the RSS gate
empirically admits only a small wave of heavy files. One-file library calls
retain the original CPU/3 inner fan-out, caller-specified `VALIDATE_INNER_JOBS`
remains a lower ceiling, and a batch never creates more outer workers than
queued files. No image parser, decoder, corruption check, or verdict path was
removed.

### Storage-independent 42-file A/B

The fixed 14.446-GiB workload contains the two giant SQLite files and 40
long-lived PDF/EPUB tasks observed in the full-corpus trace. Both runs read
clean copies from `/dev/shm`, had zero major page faults, used 12 outer workers,
and emitted 42 normalized path/verdict/depth records. A sorted differential of
those records was empty.

| ReleaseFast run | Wall | CPU time (user + system) | Peak RSS | Peak threads | Result parity |
|---|---:|---:|---:|---:|---:|
| `d2e6ab05` control | 95.27 s | 5,980.30 s | 14.43 GiB | 401 | reference |
| Balanced nested PDF pools | 82.19 s | 2,827.54 s | 7.37 GiB | 69 | exact |
| Improvement | −13.73% | −52.72% | −48.92% | −82.79% | unchanged |

### Full-corpus fixed-window A/B

The final candidate and contemporary control used the same corpus order and
155-second run + 25-second interrupt-grace protocol. This comparison is more
relevant than the earlier historical run because it was performed minutes
apart against the same storage state.

| ReleaseFast run | Files | Avg CPU | Peak RSS | Peak threads | Physical reads |
|---|---:|---:|---:|---:|---:|
| Contemporary `d2e6ab05` control | 9,308 | 1,557.9% | 9.57 GiB | 216 | 51.48 GiB |
| Tuned nested PDF policy | 11,677 | 1,797.3% | 9.06 GiB | 175 | 45.69 GiB |
| Change | +25.45% | +15.37% | −5.33% | −18.98% | −11.25% |

Files completed per peak GiB improved 32.51% versus the contemporary control
and 53.89% versus the earlier accepted arena-policy run. Aggregate memory wait
rose from 38.77e9 ns to 1.268e12 ns because the faster PDF wave reaches the two
multi-GiB SQLite reservations sooner; throughput, CPU utilization, RSS, and
thread count all improved. This is why wait time is a diagnostic signal rather
than an objective to minimize in isolation.

Rejected alternatives are retained in the experiment notes and raw logs:
format-aware SQLite reservation worsened RSS, static `CPU / outer_jobs`
underutilized wide batches, and both first-claimer and fair shared-token pools
serialized critical-path files. Machine-readable accepted records are appended
to `bench/results/scheduler_backpressure.jsonl`; raw logs remain in
`/home/pmarreck/perf-results/validate/`.
