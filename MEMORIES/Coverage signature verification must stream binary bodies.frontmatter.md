---
description: "Coverage signature verification must stream binary bodies."
datetime: 2026-07-22T14:17:00-04:00 # America/New_York (EDT)
tags: [coverage, performance, provenance, integrity, shell, regression]
---
The corruption-sweep preflight must hash the signed binary body without its
50-byte integrity trailer, but `dd bs=1 count=$body_size` performs one tiny
read per byte. On a 96.9 MB release binary it had not finished after more than
two and a half minutes, preventing the first corpus trial. Stream the body
with `head -c` and extract the fixed trailer with `tail -c`; the same signed
preflight then completed in 517 ms on Thelio. Keep a deterministic test shim
that rejects a body-sized `dd bs=1` read, rather than a timing threshold that
would be host-dependent.
