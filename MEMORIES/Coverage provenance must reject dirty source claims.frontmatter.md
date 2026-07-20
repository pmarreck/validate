---
description: "Coverage provenance must reject dirty source claims."
datetime: 2026-07-19T12:23:59-04:00 # America/New_York (EDT)
tags: [coverage, provenance, reject, dirty, source, claims]
---
An integrity-trailered binary hash identifies the executable used for a
corruption sweep, but `git rev-parse HEAD` identifies source only when tracked
source is clean.  In-tree sweep defaults must reject staged and unstaged
tracked changes before writing a HEAD provenance row.  An external signed
release or isolated test may supply its source identity explicitly; that
override must never be mistaken for a clean-worktree guarantee.
