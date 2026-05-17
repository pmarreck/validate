# zig016-migrator

AST-guided text patcher for migrating Zig 0.15 source code to 0.16 stdlib
patterns. Standalone Zig 0.16 program — no dependencies beyond stdlib.

## Approach

Parse each `.zig` file via `std.zig.Ast`, walk the AST looking for specific
call-site patterns, extract their byte spans, and apply edits to the source
text in **reverse byte order** so positions don't shift. Comments and
formatting outside the edited spans are preserved automatically — only the
exact byte ranges we identify get touched.

This is "AST-guided text patching", not AST roundtripping: the AST tells us
*where* to edit; the source text owns *what* gets preserved. Same model as
`comby`, `ast-grep`, and `tree-sitter`-based refactor tools, but using Zig's
own stdlib parser (no external dependency, ground truth on syntax).

## Patterns currently supported

| Old (0.15)                              | New (0.16)                        |
|-----------------------------------------|-----------------------------------|
| `std.fs.File`                           | `std.Io.File`                     |
| `std.fs.Dir`                            | `std.Io.Dir`                      |
| `std.fs.cwd().openFile(p, opts)`        | `runtime.openFile(p, opts)`       |
| `std.fs.cwd().openDir(p, opts)`         | `runtime.openDir(p, opts)`        |
| `std.fs.cwd().access(p, opts)`          | `runtime.access(p, opts)`         |
| `std.fs.cwd().statFile(p)`              | `runtime.statFile(p)`             |
| `std.fs.cwd().createFile(p, opts)`      | `runtime.createFile(p, opts)`     |
| `std.fs.cwd().readFileAlloc(...)`       | `runtime.readFileAlloc(...)`      |
| `std.time.nanoTimestamp()`              | `runtime.nanoTimestamp()`         |

The "runtime" identifier is configurable via `--runtime IDENT` and refers to
a project-side module exposing the equivalent wrappers (which thread the
`io: std.Io` argument internally). See `validate/src/core/runtime.zig` for
the reference implementation.

## What this tool does NOT handle (yet)

Receiver-method patterns where the receiver's type isn't visible from syntax:

```zig
const f = try std.fs.cwd().openFile("p", .{});  // ← handled
try f.seekTo(N);                                 // ← NOT handled
try f.close();                                   // ← NOT handled
```

These require either threading the type forward through semantic analysis,
or applying a careful regex-with-context follow-up pass. The tool's policy:
**don't touch what you can't verify**. False positives are worse than a
manual sweep for these.

## Usage

```bash
zig build
./zig-out/bin/zig016-migrator --dry-run path/to/file.zig
./zig-out/bin/zig016-migrator path/to/file.zig          # apply edits
./zig-out/bin/zig016-migrator --runtime myproj.io_compat file.zig
```

Multiple files can be passed in one invocation. Each is parsed independently;
files with syntax errors are skipped (the error is reported, not crashed on).

## Tests

```bash
zig build test
```

The test suite covers each pattern as a parse-transform-assert round-trip
against small in-memory fixtures, plus comment-preservation and
false-positive-avoidance cases (string literals, receiver-method calls).

## License

MIT.
