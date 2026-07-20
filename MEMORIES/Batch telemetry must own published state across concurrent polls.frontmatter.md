---
description: "Batch telemetry must own published state across concurrent polls."
datetime: 2026-07-14T14:47:14-04:00 # America/New_York (EDT)
tags: [batch, telemetry, published, state, across, concurrent, polls]
---
An atomic pointer only makes publication itself atomic; it does not keep the
pointed-to object alive after a reader loads it. Public active-batch telemetry
must use state whose lifetime is owned beyond every concurrent poll (for
example, stable copied snapshots or synchronized reader reclamation), never
addresses of stack-local batch state. Test the load→batch-teardown→snapshot
interleaving deterministically whenever telemetry lifecycle code changes.
