---
description: "Enumeration metadata avoids duplicate batch scheduler stats."
datetime: 2026-07-15T08:29:35-04:00 # America/New_York (EDT)
tags: [enumeration, metadata, avoids, duplicate, batch, scheduler, stats]
---
The C CLI already owns a positional `size_t` size snapshot from directory
enumeration, including its queue reordering. Passing that immutable metadata
through additive ABI v2.3 `validate_batch_sized()` lets batch memory admission,
large-file gating, and heap diagnostics share it rather than each `stat`ing a
path. `SIZE_MAX` / a NULL array retains the conservative unknown-size fallback;
the size is scheduling metadata only and the validator's opened file remains
authoritative for its verdict. On the fixed 512-file fixture this removed
exactly 1,024 metadata syscalls with byte-identical results.
