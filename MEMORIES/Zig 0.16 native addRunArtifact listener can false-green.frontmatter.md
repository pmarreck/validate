---
description: "Zig 0.16 native addRunArtifact listener can false green."
datetime: 2026-07-15T21:42:16-04:00 # America/New_York (EDT)
tags: [zig, ziglang, native, addrunartifact, listener, false, green]
---
On Linux with Zig 0.16, `b.addRunArtifact(core_tests)` invokes the test binary
through the `--listen=-` adapter. A passing direct test executable can then be
reported as `failed command` while `zig build test` still exits zero, allowing
the Nix test derivation to falsely pass. For non-Windows native hosts, run the
emitted test binary through `env` in a `SystemCommand` and pass its lazy path
with `addFileArg`; `SystemCommand` requires a concrete argv[0]. Keep the
existing Wine system-command path for Windows cross-tests and `addRunArtifact`
for native Windows unless that host is independently verified.
