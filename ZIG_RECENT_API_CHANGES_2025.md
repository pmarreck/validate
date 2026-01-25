# Zig API Reference for 2025 (0.14.0 - 0.15.x)

> **Purpose**: Quick reference for LLMs and developers writing fresh Zig code in 2025.
> Focus on "how to do things correctly now" rather than migration from old APIs.
>
> **Current Version**: Zig 0.15.x (as of late 2025)
>
> **Sources**:
> - [Zig 0.15.1 Release Notes](https://ziglang.org/download/0.15.1/release-notes.html)
> - [Zig 0.14.0 Release Notes](https://ziglang.org/download/0.14.0/release-notes.html)
> - [Ziggit ArrayList Discussion](https://ziggit.dev/t/arraylist-and-allocator-updating-code-to-0-15/12167)

---

## Table of Contents

1. [ArrayList (Unmanaged by Default)](#1-arraylist-unmanaged-by-default)
2. [I/O: Writers and Readers](#2-io-writers-and-readers)
3. [Build System](#3-build-system)
4. [Type Reflection](#4-type-reflection)
5. [Language Features](#5-language-features)
6. [Standard Library Changes](#6-standard-library-changes)
7. [Allocator API](#7-allocator-api)
8. [Format Strings](#8-format-strings)
9. [Containers](#9-containers)
10. [Quick Reference Table](#10-quick-reference-table)
11. [Signal Handling (POSIX)](#11-signal-handling-posix)

---

## 1. ArrayList (Unmanaged by Default)

**Key Change**: `std.ArrayList` is now unmanaged. Pass the allocator to each method call.

### Correct Pattern (Zig 0.15+)

```zig
const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize with empty struct literal
    var list: std.ArrayListUnmanaged(i32) = .{};
    defer list.deinit(allocator);

    // Pass allocator to every mutating operation
    try list.append(allocator, 42);
    try list.append(allocator, 100);
    try list.appendSlice(allocator, &[_]i32{ 1, 2, 3 });

    // Non-mutating operations don't need allocator
    for (list.items) |item| {
        std.debug.print("{d}\n", .{item});
    }

    // toOwnedSlice needs allocator
    const owned = try list.toOwnedSlice(allocator);
    defer allocator.free(owned);
}
```

### Common Operations

```zig
// Initialization
var list: std.ArrayListUnmanaged(T) = .{};

// Cleanup
list.deinit(allocator);

// Adding items
try list.append(allocator, item);
try list.appendSlice(allocator, slice);
try list.insert(allocator, index, item);

// Removing items (no allocator needed)
_ = list.pop();
_ = list.popOrNull();
_ = list.orderedRemove(index);
_ = list.swapRemove(index);

// Capacity management
try list.ensureTotalCapacity(allocator, n);
try list.ensureUnusedCapacity(allocator, n);
list.clearRetainingCapacity();
list.shrinkRetainingCapacity(new_len);

// Conversion
const slice = try list.toOwnedSlice(allocator);
```

### Storing in Structs

```zig
const MyStruct = struct {
    items: std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MyStruct {
        return .{
            .items = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MyStruct) void {
        self.items.deinit(self.allocator);
    }

    pub fn add(self: *MyStruct, item: u8) !void {
        try self.items.append(self.allocator, item);
    }
};
```

---

## 2. I/O: Writers and Readers

**Key Change**: Complete overhaul in 0.15. Buffers are now in the interface, not the implementation.

### stdout/stderr (Zig 0.15+)

```zig
const std = @import("std");

pub fn main() !void {
    // Create buffer for writer
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;

    // Use the writer
    try stdout.print("Hello, {s}!\n", .{"world"});
    try stderr.print("Error: {s}\n", .{"something went wrong"});

    // IMPORTANT: Flush before exit!
    try stdout.flush();
    try stderr.flush();
}
```

### File Reading

```zig
pub fn readFile(path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    // Read entire file into allocated memory
    return try file.readToEndAlloc(allocator, max_size);
}
```

### File Writing

```zig
pub fn writeFile(path: []const u8, data: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    try file.writeAll(data);
}
```

---

## 3. Build System

### Executable Creation (Zig 0.14+)

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create module first, then executable
    const exe = b.addExecutable(.{
        .name = "myapp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);
}
```

### Adding Dependencies

```zig
const exe = b.addExecutable(.{
    .name = "myapp",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "mylib", .module = mylib_module },
        },
    }),
});
```

### Tests

```zig
const unit_tests = b.addTest(.{
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }),
});

const run_unit_tests = b.addRunArtifact(unit_tests);
const test_step = b.step("test", "Run unit tests");
test_step.dependOn(&run_unit_tests.step);
```

---

## 4. Type Reflection

**Key Change**: All `std.builtin.Type` tags are now lowercase. Keywords need `@""` syntax.

```zig
fn inspectType(comptime T: type) void {
    switch (@typeInfo(T)) {
        .int => |info| {
            std.debug.print("Int: {d} bits, signed={}\n", .{ info.bits, info.signedness == .signed });
        },
        .float => |info| {
            std.debug.print("Float: {d} bits\n", .{info.bits});
        },
        .pointer => |info| {
            std.debug.print("Pointer size: {}\n", .{info.size});
        },
        .@"struct" => |info| {  // Note: @"struct" for keyword
            std.debug.print("Struct with {d} fields\n", .{info.fields.len});
        },
        .@"enum" => |info| {
            std.debug.print("Enum with {d} fields\n", .{info.fields.len});
        },
        .@"union" => |info| {
            std.debug.print("Union with {d} fields\n", .{info.fields.len});
        },
        else => {},
    }
}
```

### Pointer Size Constants

```zig
// Lowercase now
comptime {
    std.debug.assert(@typeInfo(*u8).pointer.size == .one);
    std.debug.assert(@typeInfo([*]u8).pointer.size == .many);
    std.debug.assert(@typeInfo([]u8).pointer.size == .slice);
}
```

---

## 5. Language Features

### Branch Hints (replaces @setCold)

```zig
fn unlikelyPath() void {
    @branchHint(.cold);
    // ... error handling code
}

fn likelyPath() void {
    @branchHint(.likely);
    // ... hot path
}
```

### @export Requires Pointer

```zig
fn myFunction() void {}

comptime {
    @export(&myFunction, .{ .name = "my_exported_function" });
}
```

### Labeled Switch with Continue

```zig
fn stateMachine(input: []const u8) void {
    var state: enum { start, reading, done } = .start;

    state_loop: switch (state) {
        .start => {
            state = .reading;
            continue :state_loop;
        },
        .reading => {
            // process...
            state = .done;
            continue :state_loop;
        },
        .done => {},
    }
}
```

### Decl Literals

```zig
const Point = struct {
    x: i32,
    y: i32,
};

// Cleaner initialization
const p: Point = .{ .x = 10, .y = 20 };

// In function calls
fn draw(point: Point) void { ... }
draw(.{ .x = 5, .y = 10 });
```

---

## 6. Standard Library Changes

### Removed/Renamed Namespaces

| Old | New |
|-----|-----|
| `std.rand` | `std.Random` |
| `std.TailQueue` | `std.DoublyLinkedList` |
| `std.zig.CrossTarget` | `std.Target.Query` |
| `std.fs.MAX_PATH_BYTES` | `std.fs.max_path_bytes` |

### String Tokenization

```zig
// Use specific variants
var iter = std.mem.tokenizeScalar(u8, input, ' ');
while (iter.next()) |token| {
    // ...
}

// Or for sequences
var iter2 = std.mem.tokenizeSequence(u8, input, "\r\n");
```

### Unicode Functions

```zig
// UTF-16 functions now capitalize "Le"
std.unicode.utf16LeToUtf8(...);  // Note: Le not le
```

---

## 7. Allocator API

### Page Size

```zig
// Runtime page size (not compile-time constant anymore)
const page_size = std.heap.pageSize();

// Compile-time bounds for generic code
const min_page = std.heap.page_size_min;
const max_page = std.heap.page_size_max;
```

### Alignment Type

```zig
// VTable functions use std.mem.Alignment, not u8
const alignment: std.mem.Alignment = .@"16";
```

---

## 8. Format Strings

### New Specifiers

| Specifier | Purpose |
|-----------|---------|
| `{t}` | Tag names and error names |
| `{d}` | Custom number formatting (via `formatNumber` method) |
| `{b64}` | Standard base64 output |
| `{f}` | Required for custom format methods |

### Custom Formatter (Zig 0.15+)

```zig
const MyType = struct {
    value: i32,

    // New signature - takes *std.Io.Writer directly
    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("MyType({d})", .{self.value});
    }
};

// Usage requires {f} specifier
std.debug.print("{f}\n", .{my_instance});
```

---

## 9. Containers

### DoublyLinkedList (De-genericified)

```zig
const std = @import("std");

const MyData = struct {
    node: std.DoublyLinkedList.Node = .{},
    value: i32,

    fn fromNode(node: *std.DoublyLinkedList.Node) *MyData {
        return @fieldParentPtr("node", node);
    }
};

var list: std.DoublyLinkedList = .{};

var item = MyData{ .value = 42 };
list.append(&item.node);

// Iterate
var it = list.first;
while (it) |node| : (it = node.next) {
    const data = MyData.fromNode(node);
    std.debug.print("{d}\n", .{data.value});
}
```

### HashMap

```zig
// Use AutoHashMap for simple cases
var map = std.AutoHashMap([]const u8, i32).init(allocator);
defer map.deinit();

try map.put("key", 42);
if (map.get("key")) |value| {
    std.debug.print("Found: {d}\n", .{value});
}
```

---

## 10. Quick Reference Table

| Task | Zig 0.15+ Code |
|------|----------------|
| ArrayList init | `var list: std.ArrayListUnmanaged(T) = .{};` |
| ArrayList append | `try list.append(allocator, item);` |
| ArrayList deinit | `list.deinit(allocator);` |
| stdout writer | `var buf: [4096]u8 = undefined; var w = std.fs.File.stdout().writer(&buf); const stdout = &w.interface;` |
| Print to stdout | `try stdout.print("{s}\n", .{msg}); try stdout.flush();` |
| Type switch | `.int`, `.float`, `.@"struct"`, `.@"enum"` |
| Cold function | `@branchHint(.cold);` |
| Export symbol | `@export(&func, .{ .name = "name" });` |
| Page size | `std.heap.pageSize()` (runtime) |
| Build executable | `b.addExecutable(.{ .name = "x", .root_module = b.createModule(.{ ... }) });` |

---

## Common Pitfalls to Avoid

1. **Forgetting to flush stdout/stderr** - Always call `try stdout.flush()` before program exit
2. **Using `ArrayList.init(allocator)`** - This doesn't exist anymore; use `.{}` empty literal
3. **Forgetting allocator in append/deinit** - Every mutating ArrayList operation needs the allocator
4. **Using uppercase type tags** - `.Int` is now `.int`, `.Struct` is now `.@"struct"`
5. **Using `std.io.getStdOut()`** - Use `std.fs.File.stdout().writer(&buffer)` instead
6. **Using old build.zig patterns** - Use `root_module` with `b.createModule()`, not `root_source_file` directly

---

## 11. Signal Handling (POSIX)

**Key Points**: Use `std.posix.Sigaction` for cross-platform POSIX signal handling. The calling convention is `.c` (lowercase).

### Basic SIGINT Handler (Ctrl+C)

```zig
const std = @import("std");
const posix = std.posix;

// Global flag for cooperative cancellation
var g_cancel_flag = std.atomic.Value(bool).init(false);

// Signal handler - use .c calling convention (lowercase!)
fn sigintHandler(_: c_int) callconv(.c) void {
    // Signal handlers should avoid allocations - use direct write
    const msg = "\nCancelling...\n";
    _ = posix.write(posix.STDERR_FILENO, msg) catch {};
    g_cancel_flag.store(true, .release);
}

fn setupSignalHandler() void {
    const act = posix.Sigaction{
        .handler = .{ .handler = sigintHandler },
        .mask = std.mem.zeroes(posix.sigset_t),  // Empty signal mask
        .flags = 0,
    };
    // Note: sigaction returns void, not an error
    posix.sigaction(posix.SIG.INT, &act, null);
}

pub fn main() !u8 {
    setupSignalHandler();

    // Check cancel flag periodically in your work loop
    while (!g_cancel_flag.load(.acquire)) {
        // ... do work ...
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }

    return 130; // Standard exit code for Ctrl+C
}
```

### Important Notes

- **Calling convention**: Use `.c` (lowercase), not `.C`
- **Empty sigset**: Use `std.mem.zeroes(posix.sigset_t)` - `empty_sigset` was removed
- **Return type**: `posix.sigaction()` returns void, not an error union
- **Signal safety**: Avoid allocations in signal handlers; use `posix.write()` for output
- **Atomic flags**: Use `std.atomic.Value(bool)` for thread-safe cancel flags

### Available Signals

```zig
posix.SIG.INT   // Ctrl+C (interrupt)
posix.SIG.TERM  // Termination request
posix.SIG.HUP   // Hangup
posix.SIG.USR1  // User-defined signal 1
posix.SIG.USR2  // User-defined signal 2
```

---

*Last updated: January 2026*
*Zig version: 0.15.x*
