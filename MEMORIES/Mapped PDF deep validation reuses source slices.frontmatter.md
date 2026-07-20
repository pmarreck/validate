---
description: "Mapped PDF deep validation reuses source slices."
datetime: 2026-07-15T10:12:14-04:00 # America/New_York (EDT)
tags: [mapped, pdf, deep, validation, reuses, source, slices]
---
When `FileSource.getMappedSlice()` is available, deep PDF validation must
borrow that slice for the whole validation call instead of allocating and
copying the complete document. The slice is valid for the `FileSource`
lifetime, which already spans all image, font, attachment, and residual Flate
passes; a separate `?[]u8` ownership slot frees data only in the existing
non-mapped fallback.

Keep the preexisting seek, 500 MiB bound, complete-read check, and fallback
verdicts unchanged. Test the optimization with a counting allocator over a
corrupt synthetic Flate PDF: require the corruption to remain invalid and
document-sized allocations to be zero. For performance acceptance, compare
fixed-seed Sniper/Bolter/Shotgun corpus results before and after, not raw
decode timing alone. On the 22.8 MiB NASA PDF (100 strict rounds per mode,
seed 42), detection stayed 21/100, 33/100, and 74/100 while peak RSS fell
about 26–28%; wall time was flat because deep validation was deliberately
unchanged.
