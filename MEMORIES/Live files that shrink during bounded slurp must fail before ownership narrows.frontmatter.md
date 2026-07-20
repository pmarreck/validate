---
description: "Live files that shrink during bounded slurp must fail before ownership narrows."
datetime: 2026-07-14T16:12:29-04:00 # America/New_York (EDT)
tags: [live, files, shrink, during, bounded, slurp, fail, ownership, narrows]
---
Between a file-size observation and positional read, a live file can shrink.
`FileSource.getMappedOrSlurp` must treat a short read as `UnexpectedEof` and
let its original-length allocation cleanup run; never return a shortened
owning slice. Allocation routers such as `DivertingAllocator` decide the
correct backend from the slice length, so narrowing a large allocation can
misroute its free and leak or corrupt accounting. The regression uses
`FileSource.fromFile` (no mmap), truncates after its captured size, crosses a
low diversion threshold, and verifies zero live large bytes after the error.
