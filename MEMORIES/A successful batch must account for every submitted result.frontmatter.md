---
description: "A successful batch must account for every submitted result."
datetime: 2026-07-14T22:57:12-04:00 # America/New_York (EDT)
tags: [successful, batch, account, submitted, result]
---
When result serialization for a C callback fails independently of deep
validation, the worker must atomically record a terminal delivery failure.
After draining workers, `validate_batch` returns a non-success status instead
of claiming a successful batch whose caller received fewer results than it
submitted. Keep serialization allocation injectable in tests so a failing
allocator can prove this contract without weakening the production allocator.
