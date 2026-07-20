---
description: "Reusing validation file descriptors requires explicit borrowed ownership."
datetime: 2026-07-15T02:10:34-04:00 # America/New_York (EDT)
tags: [reusing, validation, file, descriptors, explicit, borrowed, ownership]
---
Structural and deep validation can share a regular-file descriptor, but the
source wrapper must explicitly distinguish borrowed and owning handle lifetime.

`FileSource.fromFile` previously documented borrowed ownership but its generic
`close()` closed the copied descriptor, risking a caller-side double close. The
new `borrowed_file` backing makes close a no-op for that path, while
`fromFilePreferMapped` maps the caller-owned descriptor on POSIX and unmaps
without closing it. This safely removes the second deep `stat`/open without
downgrading mapped deep validation; a 512-file RAM fixture eliminated 1,024
path syscalls (28.6%).
