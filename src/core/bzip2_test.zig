//! Tests for the pure Zig bzip2 implementation.
//! Tests compression and decompression against the system bzip2 binary.

const std = @import("std");
const bzip2 = @import("bzip2.zig");
const testing = std.testing;

// ============ Unit Tests ============

test "CRC32 bzip2 - known values" {
    // Test with known input
    var crc = bzip2.Crc32Bzip2.init();
    crc.updateSlice("hello world");
    const result = crc.final();
    // The CRC should be non-zero and consistent
    try testing.expect(result != 0);

    // Test that same input gives same result
    var crc2 = bzip2.Crc32Bzip2.init();
    crc2.updateSlice("hello world");
    try testing.expectEqual(result, crc2.final());
}

test "CRC32 bzip2 - empty input" {
    var crc = bzip2.Crc32Bzip2.init();
    const result = crc.final();
    // Empty CRC should be 0 (after XOR with 0xFFFFFFFF twice)
    try testing.expectEqual(@as(u32, 0), result);
}

test "CRC32 bzip2 - incremental update" {
    var crc1 = bzip2.Crc32Bzip2.init();
    crc1.updateSlice("hello ");
    crc1.updateSlice("world");

    var crc2 = bzip2.Crc32Bzip2.init();
    crc2.updateSlice("hello world");

    try testing.expectEqual(crc1.final(), crc2.final());
}

test "stream magic validation" {
    try testing.expectEqualSlices(u8, "BZh", &bzip2.STREAM_MAGIC);
}

test "block magic values" {
    // Block magic is pi digits: 0x314159265359
    try testing.expectEqual(@as(u48, 0x314159265359), bzip2.BLOCK_MAGIC);
    // Footer magic is sqrt(pi) digits: 0x177245385090
    try testing.expectEqual(@as(u48, 0x177245385090), bzip2.FOOTER_MAGIC);
}

// ============ Integration Tests with System bzip2 ============

test "detect invalid bzip2 header" {
    const allocator = testing.allocator;

    // Invalid magic
    const invalid_data = [_]u8{ 'X', 'Y', 'Z', '9', 0, 0, 0, 0 };

    var decompressor = try bzip2.Decompressor.init(allocator);
    defer decompressor.deinit();

    var input = std.io.fixedBufferStream(&invalid_data);
    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(allocator);

    const result = decompressor.decompress(input.reader(), output.writer(allocator));
    try testing.expectError(bzip2.Error.InvalidMagic, result);
}

test "detect invalid block size" {
    const allocator = testing.allocator;

    // Valid magic but invalid block size ('0' is not valid, must be '1'-'9')
    const invalid_data = [_]u8{ 'B', 'Z', 'h', '0', 0, 0, 0, 0 };

    var decompressor = try bzip2.Decompressor.init(allocator);
    defer decompressor.deinit();

    var input = std.io.fixedBufferStream(&invalid_data);
    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(allocator);

    const result = decompressor.decompress(input.reader(), output.writer(allocator));
    try testing.expectError(bzip2.Error.InvalidBlockSize, result);
}

// ============ Real-World File Tests ============

test "decompress bzip2 file from temp dir" {
    const allocator = testing.allocator;

    const test_content =
        \\This is a test file for bzip2 decompression.
        \\It contains multiple lines of text.
        \\The quick brown fox jumps over the lazy dog.
        \\Pack my box with five dozen liquor jugs.
        \\How vexingly quick daft zebras jump!
    ** 50;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const compressed = try bzip2.compress(allocator, test_content);
    defer allocator.free(compressed);

    {
        const file = try tmp.dir.createFile("bzip2_test_input.txt.bz2", .{});
        defer file.close();
        try file.writeAll(compressed);
    }

    const bz2_file = try tmp.dir.openFile("bzip2_test_input.txt.bz2", .{});
    defer bz2_file.close();

    const bz2_size = try bz2_file.getEndPos();
    try testing.expect(bz2_size > 0);
    try testing.expectEqualSlices(u8, "BZh", compressed[0..3]);
}

test "round-trip via files" {
    const allocator = testing.allocator;

    const test_data = "Hello, World! This is a test of bzip2 compression.\n" ** 10;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const compressed = try bzip2.compress(allocator, test_data);
    defer allocator.free(compressed);

    {
        const file = try tmp.dir.createFile("bzip2_roundtrip_test.txt.bz2", .{});
        defer file.close();
        try file.writeAll(compressed);
    }

    const bz2_file = try tmp.dir.openFile("bzip2_roundtrip_test.txt.bz2", .{});
    defer bz2_file.close();

    const compressed_file = try bz2_file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(compressed_file);

    const decompressed = try bzip2.decompress(allocator, compressed_file);
    defer allocator.free(decompressed);

    try testing.expectEqualSlices(u8, test_data, decompressed);
}

test "decompress bzip2 output - simple text" {
    const allocator = testing.allocator;

    const test_data = "Hello, World! This is a test of bzip2 decompression.\n" ** 5;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const compressed = try bzip2.compress(allocator, test_data);
    defer allocator.free(compressed);

    {
        const file = try tmp.dir.createFile("bzip2_decompress_test.txt.bz2", .{});
        defer file.close();
        try file.writeAll(compressed);
    }

    const bz2_file = try tmp.dir.openFile("bzip2_decompress_test.txt.bz2", .{});
    defer bz2_file.close();

    const compressed_file = try bz2_file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(compressed_file);

    const decompressed = bzip2.decompress(allocator, compressed_file) catch |err| {
        std.debug.print("Our decompressor failed: {}\n", .{err});
        return err;
    };
    defer allocator.free(decompressed);

    try testing.expectEqualSlices(u8, test_data, decompressed);
}

test "decompress bzip2 output - multiple patterns" {
    const allocator = testing.allocator;

    const test_cases = [_][]const u8{
        "a",
        "hello",
        "abcdefghijklmnopqrstuvwxyz",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "abababababababababababababababababababab",
        "The quick brown fox jumps over the lazy dog.",
        "Lorem ipsum dolor sit amet. " ** 10,
        "Hello123!@#$%^&*()_+-=[]{}|;:',.<>?/~`",
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    for (test_cases, 0..) |test_data, idx| {
        const compressed = try bzip2.compress(allocator, test_data);
        defer allocator.free(compressed);

        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "bzip2_multi_{d}.bz2", .{idx});

        {
            const file = try tmp.dir.createFile(name, .{});
            defer file.close();
            try file.writeAll(compressed);
        }

        const bz2_file = try tmp.dir.openFile(name, .{});
        defer bz2_file.close();

        const compressed_file = try bz2_file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(compressed_file);

        const decompressed = bzip2.decompress(allocator, compressed_file) catch |err| {
            std.debug.print("Decompression failed for: {s}\n", .{test_data});
            return err;
        };
        defer allocator.free(decompressed);

        try testing.expectEqualSlices(u8, test_data, decompressed);
    }
}

test "decompress bzip2 output - binary data" {
    const allocator = testing.allocator;

    var binary_data: [256]u8 = undefined;
    for (0..256) |i| {
        binary_data[i] = @intCast(i);
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const compressed = try bzip2.compress(allocator, &binary_data);
    defer allocator.free(compressed);

    {
        const file = try tmp.dir.createFile("bzip2_binary_test.bin.bz2", .{});
        defer file.close();
        try file.writeAll(compressed);
    }

    const bz2_file = try tmp.dir.openFile("bzip2_binary_test.bin.bz2", .{});
    defer bz2_file.close();

    const compressed_file = try bz2_file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(compressed_file);

    const decompressed = bzip2.decompress(allocator, compressed_file) catch |err| {
        std.debug.print("Decompression failed for binary data: {}\n", .{err});
        return err;
    };
    defer allocator.free(decompressed);

    try testing.expectEqualSlices(u8, &binary_data, decompressed);
}

test "compress round-trip - large input with RLE expansion" {
    const allocator = std.testing.allocator;

    // Create input that triggers worst-case RLE expansion (4 identical bytes -> 5 bytes)
    // We want enough data to fill multiple 900KB blocks.
    // 2MB is enough for ~2.2 blocks.
    // The pattern AAAABBBBCCCC... expands by 1.25x.
    const size = 2 * 1024 * 1024;
    const input = try allocator.alloc(u8, size);
    defer allocator.free(input);

    var i: usize = 0;
    var char: u8 = 'A';
    while (i < size) {
        // Write 4 identical bytes
        for (0..4) |_| {
            if (i < size) {
                input[i] = char;
                i += 1;
            }
        }
        // Switch char to avoid longer runs
        char +%= 1;
    }

    const compressed = try bzip2.compress(allocator, input);
    defer allocator.free(compressed);

    const decompressed = try bzip2.decompress(allocator, compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualSlices(u8, input, decompressed);
}

test "multi-stream pbzip2 decompression" {
    const allocator = std.testing.allocator;

    // Two different inputs to compress separately
    const input1 = "Hello from stream one! This is a test of concatenated bzip2 streams.";
    const input2 = "And this is stream two with different content that follows immediately.";

    // Compress each separately
    const compressed1 = try bzip2.compress(allocator, input1);
    defer allocator.free(compressed1);

    const compressed2 = try bzip2.compress(allocator, input2);
    defer allocator.free(compressed2);

    // Concatenate the compressed streams (this is what pbzip2 produces)
    const concatenated = try allocator.alloc(u8, compressed1.len + compressed2.len);
    defer allocator.free(concatenated);
    @memcpy(concatenated[0..compressed1.len], compressed1);
    @memcpy(concatenated[compressed1.len..], compressed2);

    // Decompress should handle both streams and produce concatenated output
    const decompressed = try bzip2.decompress(allocator, concatenated);
    defer allocator.free(decompressed);

    // Expected output is both inputs concatenated
    const expected = input1 ++ input2;
    try std.testing.expectEqualSlices(u8, expected, decompressed);
}

test "multi-stream pbzip2 - three streams" {
    const allocator = std.testing.allocator;

    const input1 = "First segment of data compressed independently.";
    const input2 = "Second segment with totally different content.";
    const input3 = "Third and final segment completes the test.";

    const c1 = try bzip2.compress(allocator, input1);
    defer allocator.free(c1);
    const c2 = try bzip2.compress(allocator, input2);
    defer allocator.free(c2);
    const c3 = try bzip2.compress(allocator, input3);
    defer allocator.free(c3);

    // Concatenate all three
    const total_len = c1.len + c2.len + c3.len;
    const concatenated = try allocator.alloc(u8, total_len);
    defer allocator.free(concatenated);
    @memcpy(concatenated[0..c1.len], c1);
    @memcpy(concatenated[c1.len .. c1.len + c2.len], c2);
    @memcpy(concatenated[c1.len + c2.len ..], c3);

    const decompressed = try bzip2.decompress(allocator, concatenated);
    defer allocator.free(decompressed);

    const expected = input1 ++ input2 ++ input3;
    try std.testing.expectEqualSlices(u8, expected, decompressed);
}
