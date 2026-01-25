//! Glob matcher benchmark (Pure Zig implementation)
//!
//! Benchmarks glob pattern matching using the filter.Pattern API.
//! This replaces bench_glob_matcher.swift.
//!
//! Usage: bench_glob_matcher --patterns FILE --paths FILE [--iterations N]

const std = @import("std");
const core = @import("core");
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
        } else if (std.mem.eql(u8, arg, "--iterations")) {
            if (args.next()) |n_str| {
                result.iterations = std.fmt.parseInt(u32, n_str, 10) catch 1;
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            stdoutPrint("Usage: bench_glob_matcher --patterns FILE --paths FILE [--iterations N]\n", .{});
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
    while (s.len > 0 and (s[0] == ' ' or s[0] == '\t' or s[0] == '\n' or s[0] == '\r')) {
        s = s[1..];
    }
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

fn isAbsolutePattern(pattern: []const u8) bool {
    return pattern.len > 0 and pattern[0] == '/';
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

    // Load patterns file
    const patterns_file = std.fs.cwd().openFile(args.patterns_path.?, .{}) catch |err| {
        stderrPrint("Failed to read patterns: {s} ({s})\n", .{ args.patterns_path.?, @errorName(err) });
        return 1;
    };
    defer patterns_file.close();

    const patterns_contents = patterns_file.readToEndAlloc(allocator, 1024 * 1024) catch {
        stderrPrint("Failed to read patterns file\n", .{});
        return 1;
    };
    defer allocator.free(patterns_contents);

    // Compile patterns into three categories (like the Swift version)
    var name_patterns: std.ArrayListUnmanaged(filter.Pattern) = .{};
    defer {
        for (name_patterns.items) |*p| p.deinit();
        name_patterns.deinit(allocator);
    }

    var relative_patterns: std.ArrayListUnmanaged(filter.Pattern) = .{};
    defer {
        for (relative_patterns.items) |*p| p.deinit();
        relative_patterns.deinit(allocator);
    }

    var absolute_patterns: std.ArrayListUnmanaged(filter.Pattern) = .{};
    defer {
        for (absolute_patterns.items) |*p| p.deinit();
        absolute_patterns.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, patterns_contents, '\n');
    while (lines.next()) |line| {
        const trimmed = trimLine(line);
        if (trimmed.len == 0) continue;

        const pattern = filter.compile(allocator, trimmed) catch continue;

        const is_path = isPathPattern(trimmed);
        const is_abs = isAbsolutePattern(trimmed);

        if (!is_path) {
            name_patterns.append(allocator, pattern) catch {
                var p = pattern;
                p.deinit();
                continue;
            };
        } else if (is_abs) {
            absolute_patterns.append(allocator, pattern) catch {
                var p = pattern;
                p.deinit();
                continue;
            };
        } else {
            relative_patterns.append(allocator, pattern) catch {
                var p = pattern;
                p.deinit();
                continue;
            };
        }
    }

    // Load paths file
    const paths_file = std.fs.cwd().openFile(args.paths_path.?, .{}) catch |err| {
        stderrPrint("Failed to read paths: {s} ({s})\n", .{ args.paths_path.?, @errorName(err) });
        return 1;
    };
    defer paths_file.close();

    const paths_contents = paths_file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
        stderrPrint("Failed to read paths file\n", .{});
        return 1;
    };
    defer allocator.free(paths_contents);

    var paths: std.ArrayListUnmanaged([]const u8) = .{};
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }

    var path_lines = std.mem.splitScalar(u8, paths_contents, '\n');
    while (path_lines.next()) |line| {
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
            var matched = false;

            // Check name patterns (match against basename only)
            if (!matched and name_patterns.items.len > 0) {
                const name = basename(path);
                for (name_patterns.items) |*p| {
                    if (p.matches(name)) {
                        matched = true;
                        break;
                    }
                }
            }

            // Check relative patterns (match against full relative path)
            if (!matched and relative_patterns.items.len > 0) {
                for (relative_patterns.items) |*p| {
                    if (p.matches(path)) {
                        matched = true;
                        break;
                    }
                }
            }

            // Check absolute patterns (match against "/" + path)
            if (!matched and absolute_patterns.items.len > 0) {
                var abs_path_buf: [4096]u8 = undefined;
                if (path.len < abs_path_buf.len - 1) {
                    abs_path_buf[0] = '/';
                    @memcpy(abs_path_buf[1 .. 1 + path.len], path);
                    const abs_path = abs_path_buf[0 .. 1 + path.len];

                    for (absolute_patterns.items) |*p| {
                        if (p.matches(abs_path)) {
                            matched = true;
                            break;
                        }
                    }
                }
            }

            if (matched) total_matches += 1;
        }
    }

    const end = std.time.nanoTimestamp();
    const elapsed_ns = end - start;
    const elapsed_sec = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;

    stdoutPrint("glob-zig: matched {d} / {d} in {d:.3}s\n", .{ total_matches, total_paths, elapsed_sec });

    return 0;
}
