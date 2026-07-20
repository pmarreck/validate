---
description: "Additive FFI diagnostics must not extend caller owned snapshots."
datetime: 2026-07-15T01:30:56-04:00 # America/New_York (EDT)
tags: [additive, ffi, diagnostics, extend, caller, owned, snapshots]
---
When a stable C ABI needs new optional telemetry, introduce a sibling struct
and getter rather than appending fields to a caller-owned output struct.

Callers may compile against an older header and allocate only the old struct;
writing newly appended fields would corrupt their memory despite an otherwise
compatible implementation. `validate_get_completion_queue_debug_snapshot()`
therefore returns a new 4×u64 struct with the existing 0/1/2 active-snapshot
status contract, while `validate_scheduler_debug_snapshot_t` retains its
original binary layout. Bump the ABI minor version and document the additive
contract for GUI consumers.
