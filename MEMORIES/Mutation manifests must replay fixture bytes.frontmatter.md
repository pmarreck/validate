---
description: "Mutation manifests must derive byte values from fixture-level diff and hash evidence rather than copied annotations."
datetime: 2026-07-24T06:31:04Z
tags: [mutation, corpus, fixtures, provenance, tiff, coverage, regression]
---

When classifying a mutation, do not trust a hand-transcribed original-byte
value, even if its byte offset and semantic coordinate appear plausible. Bind
the manifest to SHA-256 values and make a regression compare the clean and
mutated bytes directly, asserting both the exact one-byte delta and the stored
old/new values.

The `rgb-3c-8b_corrupt_*` TIFF audit demonstrated why: the supplied offsets
and RGB coordinates were correct, while four recorded old-byte values were
not. `od` and `cmp -l` against the actual fixtures established the authoritative
source bytes `83 A4 8D 02 C7` and replacement bytes `00`.
