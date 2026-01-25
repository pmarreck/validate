//! PCRE2 glob matching benchmark (Pure Zig implementation)
//!
//! Benchmarks PCRE2 regex matching performance against file paths using
//! gitignore-style glob patterns. This replaces bench_pcre2.c.
//!
//! Usage: bench_pcre2 --patterns FILE --paths FILE [--merge] [--iterations N]

const std = @import("std");
const core = @import("core");
const pcre2 = core.pcre2;
const filter = core.filter;
const Allocator = std.mem.Allocator;

// Zig 0.15 compatible helpers
fn stdoutPrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    std.fs.File.stdout().writeAll(msg) catch return;
}

fn stderrPrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    std.fs.File.stderr().writeAll(msg) catch return;
}

const Args = struct {
    patterns_path: ?[]const u8 = null,
    paths_path: ?[]const u8 = null,
    merge: bool = false,
    iterations: u32 = 1,
};

fn parseArgs(args_iter: anytype) !Args {
    var result = Args{};
    var args = args_iter.*;

    // Skip program name
    _ = args.next();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--patterns")) {
            result.patterns_path = args.next();
        } else if (std.mem.eql(u8, arg, "--paths")) {
            result.paths_path = args.next();
        } else if (std.mem.eql(u8, arg, "--merge")) {
            result.merge = true;
        } else if (std.mem.eql(u8, arg, "--iterations")) {
            if (args.next()) |n_str| {
                result.iterations = std.fmt.parseInt(u32, n_str, 10) catch 1;
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            stdoutPrint("Usage: bench_pcre2 --patterns FILE --paths FILE [--merge] [--iterations N]\n", .{});
            return error.HelpRequested;
        } else {
            stderrPrint("Unknown arg: {s}\n", .{arg});
            return error.InvalidArgument;
        }
    }

    return result;
}

fn trimLine(line: []const u8) []const u8 {
    var s = line;
    // Trim leading whitespace
    while (s.len > 0 and (s[0] == ' ' or s[0] == '\t' or s[0] == '\n' or s[0] == '\r')) {
        s = s[1..];
    }
    // Trim trailing whitespace
    while (s.len > 0) {
        const last = s[s.len - 1];
        if (last == ' ' or last == '\t' or last == '\n' or last == '\r') {
            s = s[0 .. s.len - 1];
        } else {
            break;
        }
    }
    return s;
}

fn isPathPattern(pattern: []const u8) bool {
    return std.mem.indexOf(u8, pattern, "/") != null;
}

/// Load patterns from a file, separating name patterns (no /) from path patterns (with /)
fn loadPatterns(
    allocator: Allocator,
    path: []const u8,
    is_path_mode: bool,
    merge: bool,
) ![]pcre2.Regex {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        stderrPrint("Failed to read patterns: {s} ({s})\n", .{ path, @errorName(err) });
        return error.FileOpenFailed;
    };
    defer file.close();

    var patterns: std.ArrayListUnmanaged(pcre2.Regex) = .{};
    defer if (!merge) {} else patterns.deinit(allocator);

    var merged_pattern: std.ArrayListUnmanaged(u8) = .{};
    defer merged_pattern.deinit(allocator);

    // Read entire file
    const contents = file.readToEndAlloc(allocator, 1024 * 1024) catch return error.OutOfMemory;
    defer allocator.free(contents);

    // Process lines
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        const trimmed = trimLine(line);
        if (trimmed.len == 0) continue;

        // Filter by pattern type
        const is_path = isPathPattern(trimmed);
        if (is_path_mode != is_path) continue;

        // Convert glob to regex using filter.zig's glob_to_regex
        const regex_inner = filter.globToRegex(allocator, trimmed) catch continue;
        defer allocator.free(regex_inner);

        if (merge) {
            // Build alternation: ^(?:pattern1)|(?:pattern2)$
            if (merged_pattern.items.len == 0) {
                merged_pattern.appendSlice(allocator, "(?:") catch continue;
            } else {
                merged_pattern.appendSlice(allocator, "|(?:") catch continue;
            }
            merged_pattern.appendSlice(allocator, regex_inner) catch continue;
            merged_pattern.append(allocator, ')') catch continue;
        } else {
            // Compile each pattern separately with anchors
            var anchored: std.ArrayListUnmanaged(u8) = .{};
            defer anchored.deinit(allocator);
            anchored.append(allocator, '^') catch continue;
            anchored.appendSlice(allocator, regex_inner) catch continue;
            anchored.append(allocator, '$') catch continue;

            const re = pcre2.Regex.compile(allocator, anchored.items) catch continue;
            patterns.append(allocator, re) catch {
                var re_copy = re;
                re_copy.deinit();
                continue;
            };
        }
    }

    if (merge and merged_pattern.items.len > 0) {
        // Finalize merged pattern
        var final_pattern: std.ArrayListUnmanaged(u8) = .{};
        defer final_pattern.deinit(allocator);
        final_pattern.append(allocator, '^') catch return error.OutOfMemory;
        final_pattern.appendSlice(allocator, merged_pattern.items) catch return error.OutOfMemory;
        final_pattern.append(allocator, '$') catch return error.OutOfMemory;

        const re = pcre2.Regex.compile(allocator, final_pattern.items) catch return error.CompileFailed;
        const result = try allocator.alloc(pcre2.Regex, 1);
        result[0] = re;
        return result;
    }

    return try patterns.toOwnedSlice(allocator);
}

fn freePatterns(allocator: Allocator, patterns: []pcre2.Regex) void {
    for (patterns) |*p| {
        var pat = p.*;
        pat.deinit();
    }
    allocator.free(patterns);
}

fn basename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOf(u8, path, "/")) |idx| {
        return path[idx + 1 ..];
    }
    return path;
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args_iter = try std.process.argsWithAllocator(allocator);
    defer args_iter.deinit();

    const args = parseArgs(&args_iter) catch |err| {
        if (err == error.HelpRequested) return 0;
        return 1;
    };

    if (args.patterns_path == null or args.paths_path == null) {
        stderrPrint("Missing --patterns or --paths\n", .{});
        return 1;
    }

    // Load patterns
    const name_patterns = loadPatterns(allocator, args.patterns_path.?, false, args.merge) catch {
        return 1;
    };
    defer freePatterns(allocator, name_patterns);

    const path_patterns = loadPatterns(allocator, args.patterns_path.?, true, args.merge) catch {
        return 1;
    };
    defer freePatterns(allocator, path_patterns);

    // Open paths file
    const paths_file = std.fs.cwd().openFile(args.paths_path.?, .{}) catch |err| {
        stderrPrint("Failed to read paths: {s} ({s})\n", .{ args.paths_path.?, @errorName(err) });
        return 1;
    };
    defer paths_file.close();

    // Read all paths into memory for iteration
    var paths: std.ArrayListUnmanaged([]const u8) = .{};
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }

    // Read entire file
    const paths_contents = paths_file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
        stderrPrint("Failed to read paths file\n", .{});
        return 1;
    };
    defer allocator.free(paths_contents);

    var lines = std.mem.splitScalar(u8, paths_contents, '\n');
    while (lines.next()) |line| {
        const trimmed = trimLine(line);
        if (trimmed.len == 0) continue;
        const path_copy = try allocator.dupe(u8, trimmed);
        try paths.append(allocator, path_copy);
    }

    // Benchmark
    const start = std.time.nanoTimestamp();

    var total_matches: u64 = 0;
    var total_paths: u64 = 0;

    for (0..args.iterations) |_| {
        for (paths.items) |path| {
            total_paths += 1;
            const name = basename(path);
            var matched = false;

            // Check name patterns first
            for (name_patterns) |*p| {
                if (p.matches(name)) {
                    matched = true;
                    break;
                }
            }

            // Then check path patterns
            if (!matched) {
                for (path_patterns) |*p| {
                    if (p.matches(path)) {
                        matched = true;
                        break;
                    }
                }
            }

            if (matched) total_matches += 1;
        }
    }

    const end = std.time.nanoTimestamp();
    const elapsed_ns = end - start;
    const elapsed_sec = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;

    const mode_str = if (args.merge) " (merged)" else "";
    stdoutPrint("pcre2-zig{s}: matched {d} / {d} in {d:.3}s\n", .{ mode_str, total_matches, total_paths, elapsed_sec });

    return 0;
}
