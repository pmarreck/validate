---
description: "Queue startup complexity needs an operation count oracle."
datetime: 2026-07-15T01:00:20-04:00 # America/New_York (EDT)
tags: [queue, startup, complexity, operation, count, oracle]
---
File-size distributions are commonly sorted or uniform, so queue-startup
selection must be tested against those shapes at production-sized cardinality.
Wall-clock tests hide the regression under machine load; compiling the actual
CLI translation unit with a test-only comparison counter makes the former
quadratic Lomuto path fail deterministically. Keep the counter test-only, and
retain a separate CLI result-membership test so an algorithmic optimization
cannot silently change what gets validated.
