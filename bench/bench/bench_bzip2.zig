//! Bzip2 compression benchmark
//!
//! Compares pure Zig bzip2 implementation against system bzip2 binary.
//! Measures throughput (MB/s) and memory consumption.
//!
//! Usage: bench-bzip2 [--iterations N] [--size SIZE] [--pattern PATTERN]
//!
//! Patterns: text, binary, repetitive, random, mixed

const std = @import("std");
const core = @import("core");
const bzip2 = core.bzip2;
const Allocator = std.mem.Allocator;

// Zig 0.15 compatible I/O helpers
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
    iterations: u32 = 3,
    size: usize = 10 * 1024, // 10KB default (larger sizes very slow due to O(n²) BWT)
    pattern: Pattern = .mixed,
    verbose: bool = false,
};

const Pattern = enum {
    text,
    binary,
    repetitive,
    random,
    mixed,
};

fn parseArgs(args_iter: anytype) !Args {
    var result = Args{};
    var args = args_iter.*;

    // Skip program name
    _ = args.next();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--iterations") or std.mem.eql(u8, arg, "-n")) {
            if (args.next()) |n_str| {
                result.iterations = std.fmt.parseInt(u32, n_str, 10) catch 5;
            }
        } else if (std.mem.eql(u8, arg, "--size") or std.mem.eql(u8, arg, "-s")) {
            if (args.next()) |s_str| {
                result.size = parseSize(s_str);
            }
        } else if (std.mem.eql(u8, arg, "--pattern") or std.mem.eql(u8, arg, "-p")) {
            if (args.next()) |p_str| {
                result.pattern = std.meta.stringToEnum(Pattern, p_str) orelse .mixed;
            }
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            result.verbose = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return error.HelpRequested;
        }
    }

    return result;
}

fn parseSize(s: []const u8) usize {
    var str = s;
    var multiplier: usize = 1;

    if (str.len > 0) {
        const last = str[str.len - 1];
        if (last == 'k' or last == 'K') {
            multiplier = 1024;
            str = str[0 .. str.len - 1];
        } else if (last == 'm' or last == 'M') {
            multiplier = 1024 * 1024;
            str = str[0 .. str.len - 1];
        }
    }

    const base = std.fmt.parseInt(usize, str, 10) catch 100;
    return base * multiplier;
}

fn printHelp() void {
    stdoutPrint(
        \\bench-bzip2 - Bzip2 compression benchmark
        \\
        \\Usage: bench-bzip2 [OPTIONS]
        \\
        \\Options:
        \\  -n, --iterations N   Number of iterations (default: 5)
        \\  -s, --size SIZE      Input size, e.g. 100k, 1M (default: 100k)
        \\  -p, --pattern PAT    Data pattern: text, binary, repetitive, random, mixed
        \\  -v, --verbose        Show detailed output
        \\  -h, --help           Show this help
        \\
        \\Examples:
        \\  bench-bzip2 -n 10 -s 1M -p text
        \\  bench-bzip2 --size 500k --pattern random
        \\
    , .{});
}

/// Generate test data based on pattern
fn generateTestData(allocator: Allocator, size: usize, pattern: Pattern) ![]u8 {
    const data = try allocator.alloc(u8, size);
    errdefer allocator.free(data);

    // Use a seeded PRNG for reproducibility
    var prng = std.Random.DefaultPrng.init(0x12345678);
    const random = prng.random();

    switch (pattern) {
        .text => {
            // English-like text with word patterns
            const words = [_][]const u8{
                "the ", "quick ", "brown ", "fox ", "jumps ", "over ", "lazy ", "dog ",
                "hello ", "world ", "this ", "is ", "a ", "test ", "of ", "compression ",
                "algorithm ", "performance ", "benchmark ", "suite ", "data ", "entropy ",
            };
            var i: usize = 0;
            while (i < size) {
                const word = words[random.intRangeAtMost(usize, 0, words.len - 1)];
                const copy_len = @min(word.len, size - i);
                @memcpy(data[i..][0..copy_len], word[0..copy_len]);
                i += copy_len;
            }
        },
        .binary => {
            // All byte values 0-255
            for (data, 0..) |*b, i| {
                b.* = @truncate(i);
            }
        },
        .repetitive => {
            // Highly repetitive - great for BWT
            const pattern_str = "ABCDEFGH";
            for (data, 0..) |*b, i| {
                b.* = pattern_str[i % pattern_str.len];
            }
        },
        .random => {
            // Random bytes - worst case for compression
            random.bytes(data);
        },
        .mixed => {
            // Mix of patterns in chunks
            var i: usize = 0;
            const chunk_size = size / 4;
            // 25% text
            while (i < chunk_size) : (i += 1) {
                data[i] = @as(u8, @intCast('a')) + @as(u8, @truncate(i % 26));
            }
            // 25% repetitive
            while (i < chunk_size * 2) : (i += 1) {
                data[i] = if (i % 2 == 0) 'X' else 'Y';
            }
            // 25% sequential
            while (i < chunk_size * 3) : (i += 1) {
                data[i] = @truncate(i);
            }
            // 25% random
            random.bytes(data[i..]);
        },
    }

    return data;
}

const BenchResult = struct {
    compress_ns: i128,
    decompress_ns: i128,
    compressed_size: usize,
    original_size: usize,
    peak_memory: usize,

    fn compressionRatio(self: BenchResult) f64 {
        return @as(f64, @floatFromInt(self.original_size)) /
            @as(f64, @floatFromInt(self.compressed_size));
    }

    fn compressThroughputMBs(self: BenchResult) f64 {
        const bytes_per_sec = @as(f64, @floatFromInt(self.original_size)) /
            (@as(f64, @floatFromInt(self.compress_ns)) / 1_000_000_000.0);
        return bytes_per_sec / (1024.0 * 1024.0);
    }

    fn decompressThroughputMBs(self: BenchResult) f64 {
        const bytes_per_sec = @as(f64, @floatFromInt(self.original_size)) /
            (@as(f64, @floatFromInt(self.decompress_ns)) / 1_000_000_000.0);
        return bytes_per_sec / (1024.0 * 1024.0);
    }
};

/// Benchmark our Zig bzip2 implementation
fn benchZigBzip2(data: []const u8) !BenchResult {
    // Use standard allocator (memory tracking via GPA is unreliable across Zig versions)
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Compress
    const compress_start = std.time.nanoTimestamp();
    const compressed = try bzip2.compress(allocator, data);
    const compress_end = std.time.nanoTimestamp();

    // Decompress
    const decompress_start = std.time.nanoTimestamp();
    const decompressed = try bzip2.decompress(allocator, compressed);
    const decompress_end = std.time.nanoTimestamp();

    // Verify correctness
    if (!std.mem.eql(u8, data, decompressed)) {
        return error.DecompressionMismatch;
    }

    // Estimate peak memory: roughly original + compressed + decompressed + overhead
    // For bzip2: ~2MB block buffer + suffix arrays for BWT
    const estimated_peak = data.len + compressed.len + decompressed.len + 2 * 1024 * 1024;

    allocator.free(compressed);
    allocator.free(decompressed);

    return BenchResult{
        .compress_ns = compress_end - compress_start,
        .decompress_ns = decompress_end - decompress_start,
        .compressed_size = compressed.len,
        .original_size = data.len,
        .peak_memory = estimated_peak,
    };
}

/// Benchmark system bzip2 via subprocess
fn benchSystemBzip2(allocator: Allocator, data: []const u8) !BenchResult {
    // Write to temp file
    const tmp_path = "/tmp/bench_bzip2_input.dat";
    const bz2_path = "/tmp/bench_bzip2_input.dat.bz2";

    {
        const file = try std.fs.cwd().createFile(tmp_path, .{});
        defer file.close();
        try file.writeAll(data);
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};
    defer std.fs.cwd().deleteFile(bz2_path) catch {};

    // Compress with system bzip2
    const compress_start = std.time.nanoTimestamp();
    const compress_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "bzip2", "-k", "-f", "-9", tmp_path },
    }) catch |err| {
        stderrPrint("System bzip2 failed: {s}\n", .{@errorName(err)});
        return err;
    };
    const compress_end = std.time.nanoTimestamp();
    allocator.free(compress_result.stdout);
    allocator.free(compress_result.stderr);

    // Read compressed size
    const bz2_file = try std.fs.cwd().openFile(bz2_path, .{});
    const compressed_size = try bz2_file.getEndPos();
    bz2_file.close();

    // Decompress with system bzip2
    const decompress_start = std.time.nanoTimestamp();
    const decompress_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "bzip2", "-d", "-k", "-f", bz2_path },
    }) catch |err| {
        stderrPrint("System bzip2 decompress failed: {s}\n", .{@errorName(err)});
        return err;
    };
    const decompress_end = std.time.nanoTimestamp();
    allocator.free(decompress_result.stdout);
    allocator.free(decompress_result.stderr);

    return BenchResult{
        .compress_ns = compress_end - compress_start,
        .decompress_ns = decompress_end - decompress_start,
        .compressed_size = compressed_size,
        .original_size = data.len,
        .peak_memory = 0, // Can't easily measure for subprocess
    };
}

fn formatSize(size: usize) struct { value: f64, unit: []const u8 } {
    if (size >= 1024 * 1024) {
        return .{ .value = @as(f64, @floatFromInt(size)) / (1024.0 * 1024.0), .unit = "MB" };
    } else if (size >= 1024) {
        return .{ .value = @as(f64, @floatFromInt(size)) / 1024.0, .unit = "KB" };
    } else {
        return .{ .value = @as(f64, @floatFromInt(size)), .unit = "B" };
    }
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

    const size_fmt = formatSize(args.size);
    stdoutPrint("\n=== Bzip2 Benchmark ===\n", .{});
    stdoutPrint("Size: {d:.1} {s}, Pattern: {s}, Iterations: {d}\n\n", .{
        size_fmt.value,
        size_fmt.unit,
        @tagName(args.pattern),
        args.iterations,
    });

    // Generate test data
    const test_data = try generateTestData(allocator, args.size, args.pattern);
    defer allocator.free(test_data);

    // Accumulators for averages
    var zig_compress_total: i128 = 0;
    var zig_decompress_total: i128 = 0;
    var zig_compressed_size: usize = 0;
    var zig_peak_memory: usize = 0;

    var sys_compress_total: i128 = 0;
    var sys_decompress_total: i128 = 0;
    var sys_compressed_size: usize = 0;

    // Run benchmarks
    for (0..args.iterations) |i| {
        if (args.verbose) {
            stdoutPrint("Iteration {d}/{d}...\n", .{ i + 1, args.iterations });
        }

        // Zig implementation
        const zig_result = benchZigBzip2(test_data) catch |err| {
            stderrPrint("Zig bzip2 failed: {s}\n", .{@errorName(err)});
            return 1;
        };
        zig_compress_total += zig_result.compress_ns;
        zig_decompress_total += zig_result.decompress_ns;
        zig_compressed_size = zig_result.compressed_size;
        zig_peak_memory = @max(zig_peak_memory, zig_result.peak_memory);

        // System bzip2
        const sys_result = benchSystemBzip2(allocator, test_data) catch |err| {
            stderrPrint("System bzip2 failed: {s}\n", .{@errorName(err)});
            return 1;
        };
        sys_compress_total += sys_result.compress_ns;
        sys_decompress_total += sys_result.decompress_ns;
        sys_compressed_size = sys_result.compressed_size;
    }

    // Calculate averages
    const n: i128 = @intCast(args.iterations);
    const zig_avg = BenchResult{
        .compress_ns = @divTrunc(zig_compress_total, n),
        .decompress_ns = @divTrunc(zig_decompress_total, n),
        .compressed_size = zig_compressed_size,
        .original_size = args.size,
        .peak_memory = zig_peak_memory,
    };
    const sys_avg = BenchResult{
        .compress_ns = @divTrunc(sys_compress_total, n),
        .decompress_ns = @divTrunc(sys_decompress_total, n),
        .compressed_size = sys_compressed_size,
        .original_size = args.size,
        .peak_memory = 0,
    };

    // Print results
    stdoutPrint("                    Zig bzip2       System bzip2    Ratio\n", .{});
    stdoutPrint("                    ---------       ------------    -----\n", .{});

    stdoutPrint("Compress (MB/s):    {d:8.2}        {d:8.2}        {d:.2}x\n", .{
        zig_avg.compressThroughputMBs(),
        sys_avg.compressThroughputMBs(),
        zig_avg.compressThroughputMBs() / sys_avg.compressThroughputMBs(),
    });

    stdoutPrint("Decompress (MB/s):  {d:8.2}        {d:8.2}        {d:.2}x\n", .{
        zig_avg.decompressThroughputMBs(),
        sys_avg.decompressThroughputMBs(),
        zig_avg.decompressThroughputMBs() / sys_avg.decompressThroughputMBs(),
    });

    stdoutPrint("Compressed size:    {d:8}        {d:8}        {d:.2}x\n", .{
        zig_avg.compressed_size,
        sys_avg.compressed_size,
        @as(f64, @floatFromInt(sys_avg.compressed_size)) / @as(f64, @floatFromInt(zig_avg.compressed_size)),
    });

    stdoutPrint("Compression ratio:  {d:8.2}x       {d:8.2}x\n", .{
        zig_avg.compressionRatio(),
        sys_avg.compressionRatio(),
    });

    const mem_fmt = formatSize(zig_avg.peak_memory);
    stdoutPrint("Peak memory (Zig):  {d:.1} {s}\n", .{ mem_fmt.value, mem_fmt.unit });

    stdoutPrint("\n", .{});

    return 0;
}
