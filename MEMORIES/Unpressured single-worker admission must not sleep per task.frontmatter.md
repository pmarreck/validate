---
description: "Unpressured single worker admission must not sleep per task."
datetime: 2026-07-15T08:41:31-04:00 # America/New_York (EDT)
tags: [unpressured, single, worker, admission, sleep, task]
---
The RSS admission gate's 50ms sampling cadence prevents concurrent workers
from busy-polling and remains necessary once pressure is observed. Applying it
to an unpressured one-worker batch instead adds a deterministic sleep after
every task: 512 tiny files accumulated about 25 seconds of false
`rss_pressure_wait_ns` while consuming under a second of CPU. The policy must
sample immediately in precisely that lone-unpressured state, retaining the
cadence for pressure and multi-worker batches. This preserves centralized
admission without turning sequential validation into a 20-files-per-second
ceiling.
