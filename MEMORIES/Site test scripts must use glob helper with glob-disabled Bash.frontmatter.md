---
description: "Site test scripts must use glob helper with glob-disabled Bash."
datetime: 2026-07-13T20:01:18-04:00 # America/New_York (EDT)
tags: [site, tests, glob, bash, pathname-expansion, globbing, release-publishing]
---
This development environment disables Bash pathname expansion globally. A
`for test in tests/test_*.lua` loop consequently sees only the literal pattern
and can report a green suite while running no tests. Site and release-publishing
test drivers must discover files through `glob`, and should fail if a required
test class has no discovered files.
