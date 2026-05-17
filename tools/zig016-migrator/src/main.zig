//! zig016-migrator — AST-guided text patcher for Zig 0.15 → 0.16 source
//! pattern migrations.
//!
//! Approach: parse each .zig file via std.zig.Ast, walk the AST looking for
//! specific call-site patterns we need to rewrite, extract their byte spans,
//! and apply edits to the source text in reverse byte order. Comments and
//! formatting outside the edited spans are preserved automatically — we only
//! mutate the byte ranges we explicitly target.
//!
//! Patterns currently supported:
//!
//!   • std.fs.File                    → std.Io.File          (type rename)
//!   • std.fs.Dir                     → std.Io.Dir           (type rename)
//!   • std.fs.cwd().openFile(P, O)    → runtime.openFile(P, O)
//!   • std.fs.cwd().openDir(P, O)     → runtime.openDir(P, O)
//!   • std.fs.cwd().access(P, O)      → runtime.access(P, O)
//!   • std.fs.cwd().statFile(P)       → runtime.statFile(P)
//!   • std.fs.cwd().createFile(P, O)  → runtime.createFile(P, O)
//!   • std.fs.cwd().readFileAlloc(...) → runtime.readFileAlloc(...)
//!   • std.time.nanoTimestamp()       → runtime.nanoTimestamp()
//!
//! Usage:
//!   zig016-migrator [--dry-run] [--runtime IDENT] <file>...
//!
//!   --dry-run        : print proposed edits, don't write files
//!   --runtime IDENT  : module identifier exposing the wrappers (default "runtime")

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Edit = struct {
    start: u32,
    end: u32,
    replacement: []const u8,
    pattern_name: []const u8,
};

const Options = struct {
    dry_run: bool = false,
    runtime_ident: []const u8 = "runtime",
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var opts: Options = .{};
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer files.deinit(gpa);

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer it.deinit();
    _ = it.next(); // skip argv[0]

    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--dry-run")) {
            opts.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--runtime")) {
            opts.runtime_ident = try gpa.dupe(u8, it.next() orelse {
                std.debug.print("--runtime requires an argument\n", .{});
                std.process.exit(3);
            });
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            std.debug.print("unknown flag: {s}\n", .{arg});
            std.process.exit(3);
        } else {
            try files.append(gpa, try gpa.dupe(u8, arg));
        }
    }

    if (files.items.len == 0) {
        printUsage();
        std.process.exit(3);
    }

    var total_files: u32 = 0;
    var changed_files: u32 = 0;
    var total_edits: u32 = 0;

    for (files.items) |path| {
        total_files += 1;
        const result = try processFile(gpa, io, path, &opts);
        if (result.edits_count > 0) {
            changed_files += 1;
            total_edits += result.edits_count;
        }
    }

    std.debug.print(
        "\nfiles scanned: {} | files changed: {} | edits {s}: {}\n",
        .{
            total_files,
            changed_files,
            if (opts.dry_run) "proposed" else "applied",
            total_edits,
        },
    );
}

fn printUsage() void {
    std.debug.print(
        \\zig016-migrator — AST-guided Zig 0.15→0.16 migration helper
        \\
        \\Usage: zig016-migrator [OPTIONS] <file>...
        \\
        \\Options:
        \\  --dry-run         Print proposed edits, don't write files
        \\  --runtime IDENT   Module identifier for runtime wrappers (default: runtime)
        \\  --help, -h        Show this help
        \\
    , .{});
}

const ProcessResult = struct {
    edits_count: u32,
};

fn processFile(gpa: Allocator, io: Io, path: []const u8, opts: *const Options) !ProcessResult {
    const source_z = try readFileSentinel(gpa, io, path);
    defer gpa.free(source_z);

    var ast = try std.zig.Ast.parse(gpa, source_z, .zig);
    defer ast.deinit(gpa);

    if (ast.errors.len > 0) {
        std.debug.print("parse error in {s}: {} error(s) — skipping\n", .{ path, ast.errors.len });
        return .{ .edits_count = 0 };
    }

    var edits: std.ArrayListUnmanaged(Edit) = .empty;
    defer {
        for (edits.items) |e| gpa.free(e.replacement);
        edits.deinit(gpa);
    }

    try collectEdits(gpa, &ast, opts, &edits);

    if (edits.items.len == 0) return .{ .edits_count = 0 };

    // If any pattern referenced the runtime module, make sure the file
    // imports it. Skip if the import is already present.
    if (needsRuntimeImport(edits.items) and !hasRuntimeImport(source_z)) {
        try insertRuntimeImport(gpa, source_z, opts, &edits);
    }

    // Sort by start descending so back-to-front application doesn't shift positions.
    std.sort.block(Edit, edits.items, {}, struct {
        fn lt(_: void, a: Edit, b: Edit) bool {
            return a.start > b.start;
        }
    }.lt);

    if (opts.dry_run) {
        std.debug.print("\n=== {s} ===\n", .{path});
        var i: usize = edits.items.len;
        while (i > 0) : (i -= 1) {
            const e = edits.items[i - 1];
            const line = byteOffsetToLine(source_z, e.start);
            std.debug.print(
                "  line {d:>5} [{s}]\n    {s}\n    → {s}\n",
                .{ line, e.pattern_name, source_z[e.start..e.end], e.replacement },
            );
        }
    } else {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(gpa);
        try out.appendSlice(gpa, source_z);
        for (edits.items) |e| {
            try out.replaceRange(gpa, e.start, e.end - e.start, e.replacement);
        }
        try writeFileBytes(io, path, out.items);
        std.debug.print("✓ {s}: {} edit(s) applied\n", .{ path, edits.items.len });
    }

    return .{ .edits_count = @intCast(edits.items.len) };
}

fn readFileSentinel(gpa: Allocator, io: Io, path: []const u8) ![:0]u8 {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024));
    defer gpa.free(bytes);
    const buf = try gpa.allocSentinel(u8, bytes.len, 0);
    @memcpy(buf, bytes);
    return buf;
}

fn writeFileBytes(io: Io, path: []const u8, bytes: []const u8) !void {
    var file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writePositionalAll(io, bytes, 0);
}

fn byteOffsetToLine(source: []const u8, offset: u32) u32 {
    var line: u32 = 1;
    var i: u32 = 0;
    while (i < offset and i < source.len) : (i += 1) {
        if (source[i] == '\n') line += 1;
    }
    return line;
}

// ─── Auto-import handling ────────────────────────────────────────────────

fn needsRuntimeImport(edits: []const Edit) bool {
    for (edits) |e| {
        if (std.mem.indexOf(u8, e.replacement, "runtime.") != null) return true;
    }
    return false;
}

fn hasRuntimeImport(source: []const u8) bool {
    return std.mem.indexOf(u8, source, "const runtime = @import") != null or
        std.mem.indexOf(u8, source, "core.runtime") != null;
}

/// Insert `const runtime = @import("runtime.zig");` after the last top-level
/// `@import(...)` we can find within the first 4 KB. Brittle-but-works: relies
/// on the conventional "imports clustered at the top of the file" layout.
fn insertRuntimeImport(
    gpa: Allocator,
    source: [:0]const u8,
    opts: *const Options,
    edits: *std.ArrayListUnmanaged(Edit),
) !void {
    _ = opts;
    const search_limit = @min(source.len, 4096);
    var last_line_end: ?u32 = null;
    var search_start: usize = 0;
    while (std.mem.indexOfPos(u8, source, search_start, "@import(")) |pos| {
        if (pos >= search_limit) break;
        const nl = std.mem.indexOfScalarPos(u8, source, pos, '\n') orelse break;
        last_line_end = @intCast(nl + 1);
        search_start = nl + 1;
    }
    if (last_line_end) |pos| {
        try edits.append(gpa, .{
            .start = pos,
            .end = pos,
            .replacement = try gpa.dupe(u8, "const runtime = @import(\"runtime.zig\");\n"),
            .pattern_name = "auto-insert: const runtime = @import(\"runtime.zig\")",
        });
    }
}

// ─── Pattern matching ────────────────────────────────────────────────────

fn collectEdits(
    gpa: Allocator,
    ast: *std.zig.Ast,
    opts: *const Options,
    edits: *std.ArrayListUnmanaged(Edit),
) !void {
    const node_tags = ast.nodes.items(.tag);
    var raw: u32 = 0;
    while (raw < node_tags.len) : (raw += 1) {
        const node_idx: std.zig.Ast.Node.Index = @enumFromInt(raw);
        const tag = node_tags[raw];
        switch (tag) {
            .field_access => try patternStdFsTypeRename(gpa, ast, node_idx, edits),
            .call, .call_comma, .call_one, .call_one_comma => {
                var buf: [1]std.zig.Ast.Node.Index = undefined;
                if (ast.fullCall(&buf, node_idx)) |call| {
                    try patternCallChains(gpa, ast, node_idx, call, opts, edits);
                }
            },
            else => {},
        }
    }
}

/// Match `std.fs.File` / `std.fs.Dir` (type position).
/// We don't restrict to type-position contexts; any `std.fs.{File,Dir}` field
/// chain gets the `fs` → `Io` token rewritten. Method calls on these types
/// (e.g. `std.fs.File.ReadError`) need separate handling — `std.fs.File` is
/// gone in 0.16 so `std.fs.File.ReadError` would also need migration. The
/// `fs`-only token rewrite makes both work in one pass.
fn patternStdFsTypeRename(
    gpa: Allocator,
    ast: *std.zig.Ast,
    node_idx: std.zig.Ast.Node.Index,
    edits: *std.ArrayListUnmanaged(Edit),
) !void {
    const data = ast.nodeData(node_idx).node_and_token;
    const parent_node = data[0];
    const field_token = data[1];
    const field_name = ast.tokenSlice(field_token);

    if (!std.mem.eql(u8, field_name, "File") and !std.mem.eql(u8, field_name, "Dir")) return;

    if (ast.nodeTag(parent_node) != .field_access) return;
    const parent_data = ast.nodeData(parent_node).node_and_token;
    if (!std.mem.eql(u8, ast.tokenSlice(parent_data[1]), "fs")) return;

    const grandparent = parent_data[0];
    if (ast.nodeTag(grandparent) != .identifier) return;
    if (!std.mem.eql(u8, ast.tokenSlice(ast.nodeMainToken(grandparent)), "std")) return;

    // Replace just the `fs` token with `Io`.
    const fs_token_start = ast.tokens.items(.start)[parent_data[1]];
    const fs_token_end = fs_token_start + 2; // "fs" is 2 bytes
    try edits.append(gpa, .{
        .start = fs_token_start,
        .end = fs_token_end,
        .replacement = try gpa.dupe(u8, "Io"),
        .pattern_name = "std.fs.{File,Dir} → std.Io.{File,Dir}",
    });
}

/// Match call patterns:
///   std.fs.cwd().METHOD(args)    where METHOD ∈ allow-list
///   std.time.nanoTimestamp()
fn patternCallChains(
    gpa: Allocator,
    ast: *std.zig.Ast,
    node_idx: std.zig.Ast.Node.Index,
    call: std.zig.Ast.full.Call,
    opts: *const Options,
    edits: *std.ArrayListUnmanaged(Edit),
) !void {
    if (ast.nodeTag(call.ast.fn_expr) != .field_access) return;
    const fa_data = ast.nodeData(call.ast.fn_expr).node_and_token;
    const method_token = fa_data[1];
    const method_name = ast.tokenSlice(method_token);
    const receiver_node = fa_data[0];

    // ── Case 1: std.time.nanoTimestamp() ────────────────────────────────
    if (std.mem.eql(u8, method_name, "nanoTimestamp")) {
        if (!isFieldAccessChain(ast, receiver_node, "std", "time")) return;
        const span = ast.nodeToSpan(node_idx);
        const replacement = try std.fmt.allocPrint(gpa, "{s}.nanoTimestamp()", .{opts.runtime_ident});
        try edits.append(gpa, .{
            .start = span.start,
            .end = span.end,
            .replacement = replacement,
            .pattern_name = "std.time.nanoTimestamp() → runtime.nanoTimestamp()",
        });
        return;
    }

    // ── Case 2: std.fs.cwd().METHOD(...) ────────────────────────────────
    const cwd_methods = [_][]const u8{
        "openFile",
        "openDir",
        "access",
        "statFile",
        "createFile",
        "readFileAlloc",
    };
    var is_cwd_method = false;
    for (cwd_methods) |m| {
        if (std.mem.eql(u8, method_name, m)) {
            is_cwd_method = true;
            break;
        }
    }
    if (!is_cwd_method) return;

    // receiver_node must be a call to std.fs.cwd()
    const rcv_tag = ast.nodeTag(receiver_node);
    const is_call = rcv_tag == .call or rcv_tag == .call_comma or
        rcv_tag == .call_one or rcv_tag == .call_one_comma;
    if (!is_call) return;

    var rcv_buf: [1]std.zig.Ast.Node.Index = undefined;
    const rcv_call = ast.fullCall(&rcv_buf, receiver_node) orelse return;
    if (ast.nodeTag(rcv_call.ast.fn_expr) != .field_access) return;
    const rcv_fa = ast.nodeData(rcv_call.ast.fn_expr).node_and_token;
    if (!std.mem.eql(u8, ast.tokenSlice(rcv_fa[1]), "cwd")) return;
    if (!isFieldAccessChain(ast, rcv_fa[0], "std", "fs")) return;

    // Span: the WHOLE outer call (`std.fs.cwd().METHOD(args)`).
    const span = ast.nodeToSpan(node_idx);

    // Args slice: from the method token's byte position (which we know is
    // followed immediately by `(`) to the end of the outer call's span.
    // E.g. for `std.fs.cwd().openFile("p", .{})`, after method = `openFile`,
    // the byte range starting at method_token's offset+len is `("p", .{})`
    // which is exactly what we want to splice in.
    const method_token_start = ast.tokens.items(.start)[method_token];
    const args_span_start = method_token_start + @as(u32, @intCast(method_name.len));
    const args_slice = ast.source[args_span_start..span.end];

    const replacement = try std.fmt.allocPrint(
        gpa,
        "{s}.{s}{s}",
        .{ opts.runtime_ident, method_name, args_slice },
    );

    try edits.append(gpa, .{
        .start = span.start,
        .end = span.end,
        .replacement = replacement,
        .pattern_name = "std.fs.cwd().X(...) → runtime.X(...)",
    });
}

fn isFieldAccessChain(
    ast: *std.zig.Ast,
    node: std.zig.Ast.Node.Index,
    expected_root: []const u8,
    expected_field: []const u8,
) bool {
    if (ast.nodeTag(node) != .field_access) return false;
    const fa = ast.nodeData(node).node_and_token;
    if (!std.mem.eql(u8, ast.tokenSlice(fa[1]), expected_field)) return false;
    const root = fa[0];
    if (ast.nodeTag(root) != .identifier) return false;
    return std.mem.eql(u8, ast.tokenSlice(ast.nodeMainToken(root)), expected_root);
}

// ─── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "type rename: std.fs.File → std.Io.File" {
    try expectContains(
        \\const std = @import("std");
        \\const F = std.fs.File;
        \\
    , "std.Io.File");
}

test "type rename: std.fs.Dir → std.Io.Dir" {
    try expectContains(
        \\const std = @import("std");
        \\fn foo() std.fs.Dir { unreachable; }
        \\
    , "std.Io.Dir");
}

test "type rename: std.fs.File.ReadError still gets fs→Io" {
    try expectContains(
        \\const std = @import("std");
        \\const E = std.fs.File.ReadError;
        \\
    , "std.Io.File.ReadError");
}

test "cwd method: openFile" {
    try expectContains(
        \\const std = @import("std");
        \\fn foo() !void {
        \\    const f = try std.fs.cwd().openFile("a.txt", .{});
        \\    _ = f;
        \\}
        \\
    , "runtime.openFile(\"a.txt\", .{})");
}

test "cwd method: statFile (no options)" {
    try expectContains(
        \\const std = @import("std");
        \\fn foo() !void {
        \\    _ = try std.fs.cwd().statFile("x");
        \\}
        \\
    , "runtime.statFile(\"x\")");
}

test "nanoTimestamp" {
    try expectContains(
        \\const std = @import("std");
        \\fn foo() i128 { return std.time.nanoTimestamp(); }
        \\
    , "runtime.nanoTimestamp()");
}

test "preserves comments adjacent to rewrites" {
    try expectContains(
        \\const std = @import("std");
        \\fn foo() !void {
        \\    // a comment about the next line
        \\    const f = try std.fs.cwd().openFile("a", .{}); // trailing comment
        \\    _ = f;
        \\}
        \\
    ,
        "// a comment about the next line",
    );
    // And the trailing comment.
    try expectContains(
        \\const std = @import("std");
        \\fn foo() !void {
        \\    const f = try std.fs.cwd().openFile("a", .{}); // trailing comment
        \\    _ = f;
        \\}
        \\
    , "// trailing comment");
}

test "no false match: receiver-method like dir.openFile" {
    const out = try applyToSource(testing.allocator,
        \\const std = @import("std");
        \\fn foo(dir: std.fs.Dir) !void {
        \\    _ = try dir.openFile("a", .{});
        \\}
        \\
    );
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "std.Io.Dir") != null);
    try testing.expect(std.mem.indexOf(u8, out, "dir.openFile") != null);
    try testing.expect(std.mem.indexOf(u8, out, "runtime.openFile") == null);
}

test "no false match: string literal mentioning std.fs.cwd" {
    const out = try applyToSource(testing.allocator,
        \\const std = @import("std");
        \\const msg = "std.fs.cwd().openFile is now gone";
        \\
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\const std = @import("std");
        \\const msg = "std.fs.cwd().openFile is now gone";
        \\
    , out);
}

fn expectContains(src: []const u8, must_contain: []const u8) !void {
    const out = try applyToSource(testing.allocator, src);
    defer testing.allocator.free(out);
    if (std.mem.indexOf(u8, out, must_contain) == null) {
        std.debug.print("\nexpected output to contain '{s}', got:\n{s}\n", .{ must_contain, out });
        return error.TestExpectationFailed;
    }
}

fn applyToSource(allocator: Allocator, src: []const u8) ![]u8 {
    const src_z = try allocator.allocSentinel(u8, src.len, 0);
    defer allocator.free(src_z);
    @memcpy(src_z, src);

    var ast = try std.zig.Ast.parse(allocator, src_z, .zig);
    defer ast.deinit(allocator);

    var edits: std.ArrayListUnmanaged(Edit) = .empty;
    defer {
        for (edits.items) |e| allocator.free(e.replacement);
        edits.deinit(allocator);
    }

    const opts: Options = .{};
    try collectEdits(allocator, &ast, &opts, &edits);

    std.sort.block(Edit, edits.items, {}, struct {
        fn lt(_: void, a: Edit, b: Edit) bool {
            return a.start > b.start;
        }
    }.lt);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, src);
    for (edits.items) |e| {
        try out.replaceRange(allocator, e.start, e.end - e.start, e.replacement);
    }
    return try allocator.dupe(u8, out.items);
}
