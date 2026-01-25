const std = @import("std");
const core = @import("core");
const bzip2 = core.bzip2;

pub fn main() !void {
    // Use GPA for memory safety checks
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Read input from stdin (AFL/honggfuzz style)
    const stdin = std.fs.File.stdin();
    // Limit to reasonable size for round-trip testing (1MB)
    const input = try stdin.readToEndAlloc(allocator, 1 * 1024 * 1024);
    defer allocator.free(input);

    // 1. Compression
    const compressed = bzip2.compress(allocator, input) catch |err| {
        // OOM is acceptable
        if (err == error.OutOfMemory) return;
        std.debug.print("Compression failed: {}\n", .{err});
        return;
    };
    defer allocator.free(compressed);

    // 2. Decompression
    var decompressor = try bzip2.Decompressor.init(allocator);
    defer decompressor.deinit();

    // Using ensureTotalCapacity to pre-allocate
    var decompressed: std.ArrayListUnmanaged(u8) = .{};
    decompressed.ensureTotalCapacity(allocator, input.len) catch return;
    defer decompressed.deinit(allocator);

    var fbs = std.io.fixedBufferStream(compressed);

    decompressor.decompress(fbs.reader(), decompressed.writer(allocator)) catch |err| {
        std.debug.print("Round-trip Decompression failed: {}\n", .{err});
        @panic("Decompression failed on valid inputs!");
    };

    // 3. Verification
    if (!std.mem.eql(u8, input, decompressed.items)) {
        std.debug.print("Mismatch! Input len={}, Output len={}\n", .{ input.len, decompressed.items.len });
        const min_len = @min(input.len, decompressed.items.len);
        for (0..min_len) |i| {
            if (input[i] != decompressed.items[i]) {
                std.debug.print("First mismatch at index {}: input={X:0>2}, output={X:0>2}\n", .{ i, input[i], decompressed.items[i] });
                break;
            }
        }
        @panic("Data mismatch after round-trip!");
    }
}
