# Code Review — validate

**Date:** 2026-07-14 EDT
**Scope:** current `yolo` (`c5f5c7b11`), Zig core, C FFI/CLI, tests, Nix, and
site tooling. Deep validation is a non-negotiable constraint: performance
findings below remove redundant work or backpressure, never decoding or
checking less.

## Method and summary

Thirteen independent, read-only audits inspected current source and tests.
Direct file reads and `rg` were authoritative; the local codescan index was
stale (2026-07-07) and semantic search was unavailable because its configured
local embedding model is absent. No source was changed for this review.

**Critical remediation order**

1. Make active-batch telemetry snapshots lifetime-safe.
2. Reject/fail a short file read without corrupting allocator ownership.
3. Never return successful batch completion with a missing result.
4. Replace quadratic default file-size selection.
5. Move slow completion delivery off validation workers through bounded handoff.

The last two preserve current arbitrary begin/result interleaving. Validation
is parallel; only the C CLI's *result-output handler* serializes itself.

## 1. Functionality and contract completeness

### WARNING — inaccessible directories disappear instead of becoming NOPERM

`cli/main.c:783-790,818-824,3215-3219,3246-3250` drops `lstat`/`opendir`
access failures during discovery. An unprivileged scan of `/root` returns 0
with no NOPERM result, so a scan can look complete while a protected subtree
was omitted. Make discovery emit an `access=NOPERM` result only for
`EACCES`/`EPERM`; preserve other path failures distinctly. Test an inaccessible
root and child during recursion.

### WARNING — empty `--json`/`--ndjson` output is plaintext and invalid

`cli/main.c:2291-2333,3246-3250,3317-3334` returns successful plaintext
`No files found.` before either structured emitter. Emit `[]` for JSON and no
records for NDJSON, with diagnostics only on stderr; test empty and denied
inputs.

### WARNING — documented `validate_git(.git)` input is invalid in practice

`ffi/validate_core.h:540-549` promises a `.git` directory, while
`ffi/c_api.zig:962-977` passes it to `src/core/git_validator.zig:546-552`,
which appends another `/.git`. Normalize that supplied path as the normal
format route already does (`format_validation.zig:6473-6483`), then ABI-test
both repository root and `.git` inputs.

### ADVISORY — scheduler documentation describes the retired throttle

`ffi/validate_core.h:312-334` says RSS wait occurs after admission, but the
implemented gate is pre-dequeue (`ffi/c_api.zig:1080-1118`). Correct the
contract and test that active-task count does not increase during this wait.

## 2. Inadequate test coverage

### WARNING — active scheduler telemetry lacks an end-to-end controlled test

`ffi/c_api.zig:472-535`, `src/core/thread_pool.zig:222-255,528-553`, and
`cli/main.c:1127-1258` have synthetic/unit coverage only. Add a latch-driven
active batch test that polls twice, proves the specific wait reason/event and
monotonic nanoseconds, plus a deterministic `[SCHED]` CLI schema test.

### WARNING — scheduler performance evidence is historical, not a gate

`bench/results/scheduler_backpressure.jsonl` and
`docs/performance/scheduler-backpressure-2026-07-10.md` preserve good data,
but `build.zig:706-725` supplies no `./bm` runner. Add a ReleaseFast,
production-shaped scheduler benchmark recording CPU/wall, RSS, files, exact
result parity, and all wait counters; compare with the last accepted same-host
baseline. Keep it out of `./test`.

### WARNING — deterministic fuzz mutation unit tests never run

`tests/fuzz/mutate.zig:125-199` is imported only by an executable;
`build.zig:774-778,804-854` does not add its `test` blocks to normal tests or
the fuzz CI replay. Register it as a fast unit-test step.

### WARNING — public memory-budget parsing is untested and overly permissive

`cli/main.c:2740-2754,3191-3201` accepts trailing/unsupported suffixes and
does not guard multiplication overflow; `memory_budget.zig:146-159` lacks
full boundary coverage. Test the complete valid/invalid classifier set at CLI
and FFI boundaries, with invalid input exiting 2 before validation.

### WARNING — deep-corruption CLI contracts are neither strict nor CI-gated

`tests/cli/test_coverage_early_stop` and `test_coverage_deep_dispatch` return
success when fixtures are absent and are excluded from
`flake.nix:342-360`. Add small committed/self-generated fixtures, make absence
a loud skip/failure as appropriate, and assert exit status rather than masking
it with `|| true`.

### WARNING — Windows Arm64 is compile-covered only

`build.zig:815-850`, `flake.nix:216-237,240-414`, and `test-windows:55-60`
do not execute the new Windows Arm64 binary. Add an honest Arm64 runtime smoke
lane covering CLI, batch, JSON/NDJSON, valid/corrupt fixtures, and access
denial semantics.

## 3. Futile or deceptive test coverage

### WARNING — local crasher replay can falsely say CLEAN

`tests/fuzz/run-sweep.bash:75` captures `$?` after `! gtimeout`, which is the
inverted zero status. A crasher timeout/signal can therefore pass `./fuzz
--ci`. Capture the original status before classification and regression-test
the runner with an abnormal dispatcher exit.

### WARNING — frontload test does not enter the scatter algorithm

`tests/cli/frontload_test:10-39` creates exactly ten files, while
`scatter_large_files` returns for `<= 10` at `cli/main.c:1960-1964`; it also
does not assert the no-frontload result. Use at least eleven files and assert
documented ordering/membership and both statuses.

### WARNING — WARN_OUT test manufactures its own success

`tests/cli/warn_output_env:16-36` uses `|| true`, never reads output, and
creates the expected output file. Use a deterministic warning fixture and
assert destination/channel contents without creating the evidence.

### WARNING — TUI regression checks can silently skip or warn-pass

`tests/cli/tui_progress_test:37-40,158-192` returns success without `tmux`,
which the declared CLI test shell lacks, and treats missing rendered state as
informational. Install the prerequisite or split an explicit integration tier;
use exit 77 for a real skip and make observed required tokens mandatory.

### WARNING — FFI result tests allow null/non-parseable output

`ffi/c_api.zig:1999-2012,2073-2090` conditionally asserts only when a result
exists and searches substrings instead of parsing the KV-US-RS contract.
Require non-null output and assert complete parsed records/separators.

## 4. Slow or nondeterministic test coverage

### WARNING — required TUI test uses sleeps and a 747 MiB ambient corpus

`tests/cli/tui_progress_test:64-94,140-181` sleeps/polls in fixed increments
and scans the whole `ground_truth_examples` tree (currently 1,175 files / 747
MiB). Replace it with latch/event-driven bounded integration coverage and pure
renderer tests with injected time/terminal size.

### WARNING — the O(1) progress lookup guard is absent from CI

The deterministic operation-count oracle
`tests/cli/progress_size_lookup_scaling:1-52` runs under local `./test`, but
not the fixed Nix CLI list (`flake.nix:342-359`) nor GitHub's native test
matrix. Add it to the hermetic CI check; retain the operation-count oracle
rather than a timing threshold.

### WARNING — no repeatable scheduler benchmark gate

This corroborates section 2's benchmark gap. Historical results and unit
counter tests are valuable, but cannot identify a throughput/RSS regression.

## 5. Superfluous or duplicated functionality

### WARNING — file-backed PDF deep validation copies its mmap'd input

`src/core/pdf_validator.zig:431-735` allocates/copies up to 500 MiB even
though `FileSource` already provides a mapped slice
(`src/core/file_source.zig:91-117,216-224,294-317`). The buffer route repeats
the orchestration (`pdf_validator.zig:739-970`). Extract one common pipeline,
feed it a zero-copy mapped slice when available, and differential-test mapped
and buffer results including depth/findings.

### WARNING — PDF passes repeatedly rediscover streams and re-inflate fonts

`pdf_validator.zig:598-677`, `pdf_image_validator.zig:350-360,624-650`,
`pdf_font_validator.zig:272-337,613-645`,
`pdf_embedded_file_validator.zig:83-151`, and
`pdf_stream_validator.zig:301-344` independently rebuild discovery state.
Residual Flate validation re-inflates successfully validated font streams.
Build one immutable object/stream plan, preserving malformed-xref fallback and
skipping only streams proven covered; measure full parity on normal, malformed,
encrypted, and font-heavy PDFs.

### WARNING — C and Zig bundle classifiers disagree on `.band`

`cli/main.c:727-756,772-866,3232-3235` recurses into GarageBand bundles,
where core classifies them as one unit (`format_validation.zig:320-405`). This
can both skip package validation and inflate a scan. Add exhaustive
classifier-parity tests, make one traversal owner, and fix the live adapter.

### ADVISORY — unused O(n) font-stream helper remains beside indexed path

Private `src/core/pdf_font_validator.zig:407-453` has no callers and
duplicates the indexed helper at `:343-405`. Remove it with focused indexed
lookup coverage.

## 6. Suboptimal, disorganized, or needlessly expensive code

### WARNING — deep mode reopens every structural-only regular file

`src/core/format_validation.zig:5875,5909-5922,6465` performs a second
stat/open before discovering that a format has no deep route. Plain text is a
concrete example. Add a pure `needs_source` / `path_only` / `none` classifier
with exhaustive route tests; skip only this setup for `none`, then measure
syscalls and exact verdict/depth parity on the fixed small-file corpus.

## 7. Algorithmic complexity

### CRITICAL — default P90 selection is quadratic on common size distributions

`cli/main.c:1902-1957` uses recursive Lomuto quickselect with last-element
pivot and `<=`; default scattering reaches it at `:3253-3257`. Equal 100k
files require about 950 million comparisons, while descending sizes approach
quadratic work and deep recursion. Replace it with iterative three-way
introselect; assert linear operation budgets and identical P90/scatter
membership for equal, ascending, descending, and mixed 100k sets.

### CRITICAL — CLI result delivery can park every completed validator worker

`validate_batch` instantiates `ThreadPool(BatchTask, void)`
(`ffi/c_api.zig:1415-1432`), so workers call completion callbacks inline
(`:1285-1338`). The CLI result handler holds `output_lock` through parsing,
count/progress mutation, output, flush, and TUI render
(`cli/main.c:1761-1863`). Starts remain concurrent, but finished workers queue
behind result output. `PERF_EXPERIMENTS.md:136-150` documents a prior result
handoff that greatly reduced comparable system CPU. Restore only a **bounded**
handoff with explicit queue backpressure; prove JSON/result-set/depth parity
and measure callback-wait ns, queue high-water, CPU/wall/RSS for normal,
`@null`, and slow sinks.

### WARNING — JBIG2 globals rescan the full PDF per image

`src/core/pdf_image_validator.zig:837-874,1125-1131,1389-1395` does O(images
× document bytes) lookups. Resolve each distinct globals object once from xref
or an immutable fallback index, and prove identical missing/malformed/global
decode outcomes with probe counts rather than elapsed time.

### WARNING — batch setup re-stats each path twice after enumeration

`ffi/c_api.zig:1273-1278,1290-1305` re-stats for admission then large-file
gating, in addition to C enumeration and the authoritative validator open.
Carry a best-effort immutable discovery size in an additive FFI/task payload;
keep the validator open authoritative for live changes. This is elaborated in
section 9.

### ADVISORY — unconditional `MADV_RANDOM` conflicts with sequential readers

`src/core/file_source.zig:74-125` advises random access globally while PDF and
7z deep paths read sequentially. Make the default neutral and let validators
request access advice only after cold-cache physical-read, wall, CPU, and
result-parity measurements.

## 8. Files without clear purpose

### WARNING — stale CODE_MINIMAP registry contradicts the live dirtree workflow

`DOCUMENTATION_GUIDE.md:14,25,33` still calls `CODE_MINIMAP.md` canonical,
but that file has false paths/line counts and obsolete module instructions
(`CODE_MINIMAP.md:31,67,138-140`). Retire/archive it and direct new modules to
`dirtree note <path> "purpose"`; repair the remaining false guide links.

### WARNING — mandatory Zig API guide is a broken absolute symlink

Tracked `ZIG_RECENT_API_CHANGES.md` targets a macOS-only `/Users/...` path and
is unreadable on this Linux checkout, despite project rules requiring it.
Replace it with a portable relative vault target or a maintained repository
copy.

## 9. Missed language/runtime capabilities

### WARNING — typed batch task discards known sizes and creates redundant stats

The CLI retains sizes at `cli/main.c:605-709,772-792` but FFI passes only
paths/IDs (`:3322-3329`), leaving `BatchTask` index-only
(`ffi/c_api.zig:1005,1273-1302`). Add a versioned additive sized-batch ABI,
coordinate it with `validate_gui`, and measure syscall trace plus CPU/wall/RSS/
wait-ns and exact results. Do not move the same I/O into a serial Zig prepass.

### WARNING — Windows lacks FileSource mapping and can lose deep coverage

`src/core/file_source.zig:91-124,182-210,294-316` falls back to positional
reads and bounded-slurp `too_large` on Windows. Profile real Windows x64/Arm64
first; if material, add an owned `CreateFileMappingW`/`MapViewOfFile` backing
with fallback and Windows large-file depth-parity tests.

## 10. Memory safety and resource lifetime

### CRITICAL — polling APIs can dereference stack state after batch teardown

`validate_batch` publishes stack-local `MemoryBudget` and
`SchedulerDebugStats` through atomics (`ffi/c_api.zig:1405-1413`); getters
load then dereference without a lifetime claim (`:478-590`). A poller can load
before teardown clears the pointer and call `snapshot()` after scope exit,
contradicting the header's any-thread safety promise
(`ffi/validate_core.h:261-273`). Use stable owned snapshot state or synchronized
reader/reclamation; test a deterministic load→teardown→resume interleaving.

### CRITICAL — short reads return an owning slice with the wrong length

`src/core/file_source.zig:308-316` allocates `file_size` but returns
`buf[0..n]` after a short read. Consumers free that truncated slice; with the
per-task `DivertingAllocator` (`ffi/c_api.zig:1314-1325`,
`src/core/heap.zig:311-348`), a live-file shrink can select the wrong backend
or length for a large allocation. Free the original full slice and return a
truncation/I/O error; test a forced truncate across a low diversion threshold
with allocator cleanliness.

## 11. FFI boundary correctness

### CRITICAL — active-batch monitor lifetime race

This is the same defect reported in section 10, independently confirmed at
`ffi/c_api.zig:478-590,1405-1413`. Fix it once with an ABI-facing concurrent
poll/teardown test for every getter.

### WARNING — null IDs cause out-of-bounds access

`validate_batch` accepts optional `ids` (`ffi/c_api.zig:1348-1354`), replaces
null with an empty slice (`:1394-1400`), then unconditionally indexes it
(`:1285-1292`). Reject null IDs with a documented error or synthesize
positional IDs, and test zero/nonzero batches and multi-worker ID/path pairing.

### WARNING — successful batch completion can omit input results

Null members in an otherwise accepted paths array return without callback
(`ffi/c_api.zig:1279-1292`). Result-builder OOM does likewise and is a critical
case in section 12. Preflight/represent bad paths and track per-task delivery
failure so accepted input implies exactly one result or non-OK batch status.

### WARNING — callback contract/docs conflict with actual concurrency

Callbacks execute on concurrent, unordered workers
(`ffi/c_api.zig:1285-1338`), while the header omits threading and borrowed
path lifetime details (`ffi/validate_core.h:458-515`) and
`ARCHITECTURE.md:179-188` says they are serialized. The C CLI serializes only
its result handler; begin callbacks are not locked. Document the actual
contract and require UI clients to marshal to a UI thread.

### WARNING — overlapping batches race shared global state

Shared active-monitor pointers, semaphore, interrupt, and begin callback
(`ffi/c_api.zig:1193-1236,1380-1413`) have no one-batch API restriction. Reject
overlap with a documented busy error or make all state per-batch; add an
overlap-contract test.

### ADVISORY — batch ABI behavior has no direct contract test

`ffi/c_api.zig:1999-2065` does not exercise a real batch callback, ownership,
null boundaries, concurrency, or active polling. Add a C/ABI-facing test using
the public header rather than only Zig helpers.

## 12. Error handling gaps

### CRITICAL — result-builder OOM silently drops a file but returns OK

`ffi/c_api.zig:1331-1339` returns from the worker if result construction
fails, and `validate_batch` returns 0 after joining (`:1448-1450`). This can
report a clean strict subset during high-memory pressure. Record a thread-safe
terminal task failure and return non-OK (or emit explicit unvalidated output);
test injected builder OOM with exact input/callback accounting.

### WARNING — output write/flush errors produce successful missing output

Unchecked `fputs`/`fprintf`/`fflush` in `cli/main.c:1423-1459,1525-1554` leave
the normal exit status independent of sink failure (`:3424-3428`). A verified
`--json /etc/hosts > /dev/full` run exited 0. Centralize error-returning output,
latch the first error, and regression-test JSON and configured destinations
against `/dev/full`.

### WARNING — post-structural reopens can erase NOPERM/I/O and retain PASS

`src/core/format_validation.zig:5392-5396,5677-5818,5913-5922` discards later
open errors or substitutes an empty source after structural success. Map every
reopen through the existing access-error constructor and test a first-open
success/second-open access denial: it must yield NOPERM or explicit
unvalidated I/O, never a clean/deep claim.

## 13. Database access patterns

### WARNING — `.sqlite3` companions miss the SQLite-sidecar classifier

`isSqliteCompanionFile` handles `sqlite-*`/`db-*`
(`src/core/format_validation.zig:2768-2791`) but not the supported `.sqlite3`
parent extension (`:2857-2862`). `.sqlite3-wal`, `-shm`, and `-journal` are
therefore not treated like deliberate structural-only sidecars
(`:5341-5346,5869-5873`). Add all supported parent-extension × sidecar cases,
mixed case, and near misses to a classifier set test. Continue full
`integrity_check` on the parent; sidecars never substitute for it.

### WARNING — structural SQLite read faults can end as clean OK

`src/core/document_validators.zig:567-594,626-631,781` returns/breaks to `ok`
when a root header/page seek/read fails after preflight. A changed/truncated DB
can pass structural validation without covering promised pages. Return precise
read/truncation failure instead; use an injectable source to test root and
later-page failure while retaining full deep integrity checks for stable files.

### WARNING — the purported SQLite deep integration test calls only structural API

`src/core/format_validation.zig:8163-8202` initializes a deep-capable
validator but calls `validateFile`, and its own comment acknowledges that deep
validation was not exercised. The direct `validateSqliteDeep` fixture test is
useful, but it does not prove the public
`validateFileDeep → performDeepValidation → SQLite` path preserves a full
integrity check. Replace it with a temporary SQLite database exercised through
`validateFileDeep`, then corrupt integrity and assert invalid + full depth.

### ADVISORY — busy/locked depth outcome lacks a deterministic contract test

`document_validators.zig:801-844` appropriately returns structural depth plus
warning for SQLite contention rather than false corruption, but tests do not
exercise the path (`:1219-1331`). Add a held-lock and readable-WAL test proving
prompt structural+warning/full-depth behavior without retry sleeps or hidden
backpressure.

There is no general application database/persistence layer. The SQLite
validator's per-task read-only connection, prepared statement, finalization,
and close at `src/core/document_validators.zig:786-845` are appropriate; no
N+1/shared-connection/write-query defect was found.
