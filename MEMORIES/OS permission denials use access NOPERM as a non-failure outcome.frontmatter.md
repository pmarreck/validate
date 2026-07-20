---
description: "OS permission denials use access NOPERM as a non failure outcome."
datetime: 2026-07-12T18:51:05-04:00 # America/New_York (EDT)
tags: [permission, denials, access, noperm, non, failure, outcome]
---
Only normalized `error.AccessDenied` and `error.PermissionDenied` mean a path
was blocked by OS security policy. They set `ValidationResult.access` to
`.no_permission`; missing, broken, and all other file-open failures remain
ordinary invalid outcomes.

The FFI preserves legacy `valid=F` and `unknown=F` for this case while adding
the exact stable token `access=NOPERM`. Consumers must check that token before
legacy boolean/error handling. The CLI renders it grey, counts it separately,
and never makes it a validation-failure exit status. `NOPERM` and
`NOPERM_OUT` are fixed protocol tokens; the accompanying error detail remains
localized.
