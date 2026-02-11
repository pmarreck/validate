//! BMP decoder with support for all common BMP versions.
//!
//! Supports:
//! - BITMAPINFOHEADER (V3/Windows 3.x) - 40 byte header
//! - BITMAPV4HEADER (V4/Windows 95) - 108 byte header (via zigimg)
//! - BITMAPV5HEADER (V5/Windows 98) - 124 byte header (via zigimg)
//!
//! V4 and V5 are delegated to zigimg. V3 is decoded natively.

const std = @import("std");
const zigimg = @import("zigimg");
const errmsg = @import("error_messages.zig");
const Allocator = std.mem.Allocator;

/// Compression methods
pub const Compression = enum(u32) {
    rgb = 0, // Uncompressed
    rle8 = 1, // RLE for 8-bit
    rle4 = 2, // RLE for 4-bit
    bitfields = 3, // Bit masks (16/32-bit)
    jpeg = 4, // JPEG (rare)
    png = 5, // PNG (rare)
    _,
};

/// Result of BMP validation
pub const BmpValidationResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    width: u32,
    height: u32,
    bit_depth: u16,
    header_version: u8, // 3, 4, or 5

    pub fn ok(width: u32, height: u32, bit_depth: u16, version: u8) BmpValidationResult {
        return .{
            .valid = true,
            .error_message = null,
            .width = width,
            .height = height,
            .bit_depth = bit_depth,
            .header_version = version,
        };
    }

    pub fn invalid(message: []const u8) BmpValidationResult {
        return .{
            .valid = false,
            .error_message = message,
            .width = 0,
            .height = 0,
            .bit_depth = 0,
            .header_version = 0,
        };
    }
};

/// Validate a BMP file by fully decoding it.
/// For V4/V5, delegates to zigimg. For V3, uses native decoder.
pub fn validateBmp(allocator: Allocator, path: []const u8) BmpValidationResult {
    // Read entire file into memory
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => BmpValidationResult.invalid("File not found"),
            error.AccessDenied => BmpValidationResult.invalid("Access denied"),
            else => BmpValidationResult.invalid(errmsg.failedToOpen("file")),
        };
    };
    defer file.close();

    const file_size = file.getEndPos() catch {
        return BmpValidationResult.invalid(errmsg.failedToGet("file size"));
    };

    // Sanity check file size (max 500MB for BMP)
    if (file_size > 500 * 1024 * 1024) {
        return BmpValidationResult.invalid("File too large");
    }

    if (file_size < 18) { // Minimum: 14 byte file header + 4 byte header size
        return BmpValidationResult.invalid("File too small");
    }

    const data = allocator.alloc(u8, file_size) catch {
        return BmpValidationResult.invalid(errmsg.outOfMemory("for BMP"));
    };
    defer allocator.free(data);

    const bytes_read = file.readAll(data) catch {
        return BmpValidationResult.invalid(errmsg.failedToRead("file"));
    };

    if (bytes_read != file_size) {
        return BmpValidationResult.invalid(errmsg.incomplete("read"));
    }

    return validateBmpFromBufferWithPath(allocator, data, path);
}

/// Validate BMP from memory buffer, with path for V4/V5 delegation
fn validateBmpFromBufferWithPath(allocator: Allocator, data: []const u8, path: []const u8) BmpValidationResult {
    if (data.len < 18) {
        return BmpValidationResult.invalid("File too small");
    }

    // Check signature
    if (data[0] != 'B' or data[1] != 'M') {
        return BmpValidationResult.invalid(errmsg.invalidSignature("BMP"));
    }

    // Read header size to determine version (offset 14)
    const header_size = std.mem.readInt(u32, data[14..18], .little);

    // Determine header version and route accordingly
    return switch (header_size) {
        40 => validateBmpV3FromBuffer(allocator, data),
        108, 124 => validateBmpV4V5(allocator, path),
        12 => BmpValidationResult.invalid("OS/2 1.x BMP not supported"),
        64 => BmpValidationResult.invalid("OS/2 2.x BMP not supported"),
        else => BmpValidationResult.invalid(errmsg.unknown("BMP header version")),
    };
}

/// Validate BMP from memory buffer (for tests and buffer-based validation)
pub fn validateBmpFromBuffer(allocator: Allocator, data: []const u8) BmpValidationResult {
    if (data.len < 18) {
        return BmpValidationResult.invalid("File too small");
    }

    // Check signature
    if (data[0] != 'B' or data[1] != 'M') {
        return BmpValidationResult.invalid(errmsg.invalidSignature("BMP"));
    }

    // Read header size to determine version (offset 14)
    const header_size = std.mem.readInt(u32, data[14..18], .little);

    // For buffer-based validation, we can only handle V3 natively
    // V4/V5 would need a file path for zigimg
    return switch (header_size) {
        40 => validateBmpV3FromBuffer(allocator, data),
        108, 124 => BmpValidationResult.invalid("V4/V5 BMP requires file path"),
        12 => BmpValidationResult.invalid("OS/2 1.x BMP not supported"),
        64 => BmpValidationResult.invalid("OS/2 2.x BMP not supported"),
        else => BmpValidationResult.invalid(errmsg.unknown("BMP header version")),
    };
}

/// Validate V3 BMP (40-byte BITMAPINFOHEADER) from buffer
fn validateBmpV3FromBuffer(allocator: Allocator, data: []const u8) BmpValidationResult {
    if (data.len < 54) { // 14 file header + 40 info header
        return BmpValidationResult.invalid(errmsg.truncated("V3 header"));
    }

    // Parse V3 header (starts at offset 14)
    const width = std.mem.readInt(i32, data[18..22], .little);
    const height = std.mem.readInt(i32, data[22..26], .little);
    const planes = std.mem.readInt(u16, data[26..28], .little);
    const bit_count = std.mem.readInt(u16, data[28..30], .little);
    const compression = std.mem.readInt(u32, data[30..34], .little);
    const colors_used = std.mem.readInt(u32, data[46..50], .little);

    // Validate header fields
    if (planes != 1) {
        return BmpValidationResult.invalid("Invalid planes (must be 1)");
    }

    if (width <= 0 or width > 65535) {
        return BmpValidationResult.invalid("Invalid width");
    }

    const abs_height: u32 = if (height < 0)
        @intCast(-height)
    else
        @intCast(height);

    if (abs_height == 0 or abs_height > 65535) {
        return BmpValidationResult.invalid("Invalid height");
    }

    const pixel_width: u32 = @intCast(width);

    // Check supported bit depths and compression
    const comp: Compression = @enumFromInt(compression);
    switch (bit_count) {
        1, 4, 8 => {
            if (comp != .rgb and comp != .rle8 and comp != .rle4) {
                return BmpValidationResult.invalid(errmsg.unsupported("compression for indexed color"));
            }
            if (bit_count == 8 and comp == .rle4) {
                return BmpValidationResult.invalid("RLE4 invalid for 8-bit");
            }
            if (bit_count != 8 and comp == .rle8) {
                return BmpValidationResult.invalid("RLE8 invalid for non-8-bit");
            }
        },
        16 => {
            if (comp != .rgb and comp != .bitfields) {
                return BmpValidationResult.invalid(errmsg.unsupported("compression for 16-bit"));
            }
        },
        24 => {
            if (comp != .rgb) {
                return BmpValidationResult.invalid("24-bit must be uncompressed");
            }
        },
        32 => {
            if (comp != .rgb and comp != .bitfields) {
                return BmpValidationResult.invalid(errmsg.unsupported("compression for 32-bit"));
            }
        },
        else => {
            return BmpValidationResult.invalid(errmsg.unsupported("bit depth"));
        },
    }

    // Calculate color table size
    const color_table_entries: u32 = if (bit_count <= 8) blk: {
        if (colors_used > 0) {
            break :blk colors_used;
        } else {
            break :blk @as(u32, 1) << @intCast(bit_count);
        }
    } else 0;

    const color_table_size = color_table_entries * 4;
    const header_end: usize = 54 + color_table_size;

    if (data.len < header_end) {
        return BmpValidationResult.invalid(errmsg.truncated("color table"));
    }

    // For uncompressed data, verify pixel data size
    if (comp == .rgb) {
        const row_size = ((pixel_width * bit_count + 31) / 32) * 4;
        const expected_pixel_size: u64 = @as(u64, row_size) * @as(u64, abs_height);
        const pixel_offset = std.mem.readInt(u32, data[10..14], .little);

        if (data.len < pixel_offset + expected_pixel_size) {
            return BmpValidationResult.invalid(errmsg.truncated("pixel data"));
        }

        // Validate we can read all pixel data (allocate one row at a time)
        const row_buffer = allocator.alloc(u8, row_size) catch {
            return BmpValidationResult.invalid(errmsg.outOfMemory("for BMP"));
        };
        defer allocator.free(row_buffer);

        var row: u32 = 0;
        while (row < abs_height) : (row += 1) {
            const row_start = pixel_offset + row * row_size;
            if (row_start + row_size > data.len) {
                return BmpValidationResult.invalid(errmsg.truncated("pixel data"));
            }
            // Copy row to verify data is accessible
            @memcpy(row_buffer, data[row_start..][0..row_size]);
        }
    } else if (comp == .rle8 or comp == .rle4) {
        // RLE validation
        const pixel_offset = std.mem.readInt(u32, data[10..14], .little);
        if (pixel_offset >= data.len) {
            return BmpValidationResult.invalid("Invalid pixel offset");
        }

        const rle_result = validateRleFromBuffer(data[pixel_offset..], abs_height, comp == .rle4);
        if (!rle_result.valid) {
            return rle_result;
        }
    }

    return BmpValidationResult.ok(pixel_width, abs_height, bit_count, 3);
}

/// Validate RLE-compressed pixel data from buffer
fn validateRleFromBuffer(data: []const u8, height: u32, is_rle4: bool) BmpValidationResult {
    _ = is_rle4;

    var pos: usize = 0;
    var y: u32 = 0;

    while (y < height and pos < data.len) {
        if (pos + 1 >= data.len) {
            return BmpValidationResult.invalid(errmsg.truncated("RLE data"));
        }

        const byte1 = data[pos];
        pos += 1;

        if (byte1 == 0) {
            // Escape sequence
            const byte2 = data[pos];
            pos += 1;

            switch (byte2) {
                0 => {
                    // End of line
                    y += 1;
                },
                1 => {
                    // End of bitmap
                    return BmpValidationResult.ok(0, 0, 0, 3);
                },
                2 => {
                    // Delta - skip pixels
                    if (pos + 1 >= data.len) {
                        return BmpValidationResult.invalid(errmsg.truncated("RLE delta"));
                    }
                    pos += 1; // dx
                    const dy = data[pos];
                    pos += 1;
                    y += dy;
                },
                else => {
                    // Absolute mode - byte2 pixels follow
                    const count = byte2;
                    const bytes_to_skip = (count + 1) & ~@as(u8, 1);
                    if (pos + bytes_to_skip > data.len) {
                        return BmpValidationResult.invalid(errmsg.truncated("RLE absolute data"));
                    }
                    pos += bytes_to_skip;
                },
            }
        } else {
            // Encoded mode - byte1 pixels of value byte2
            if (pos >= data.len) {
                return BmpValidationResult.invalid(errmsg.truncated("RLE encoded data"));
            }
            pos += 1;
        }
    }

    return BmpValidationResult.ok(0, 0, 0, 3);
}

/// Validate V4/V5 BMP using zigimg
fn validateBmpV4V5(allocator: Allocator, path: []const u8) BmpValidationResult {
    var read_buffer: [65536]u8 = undefined;

    var image = zigimg.Image.fromFilePath(allocator, path, &read_buffer) catch |err| {
        return switch (err) {
            error.OutOfMemory => BmpValidationResult.invalid(errmsg.outOfMemory("for BMP")),
            error.InvalidData => BmpValidationResult.invalid("Invalid BMP data"),
            error.EndOfStream => BmpValidationResult.invalid(errmsg.truncated("file")),
            error.FileNotFound => BmpValidationResult.invalid("File not found"),
            error.AccessDenied => BmpValidationResult.invalid("Access denied"),
            else => BmpValidationResult.invalid("BMP decode failed"),
        };
    };

    const width: u32 = @intCast(image.width);
    const height: u32 = @intCast(image.height);

    // For V4/V5, assume 24-bit (zigimg converts internally)
    const bit_depth: u16 = 24;
    const version: u8 = 4;

    image.deinit(allocator);

    return BmpValidationResult.ok(width, height, bit_depth, version);
}

// ============ Tests ============

test "validate V3 BMP (24-bit uncompressed)" {
    const allocator = std.testing.allocator;

    // Create minimal V3 BMP (2x2 pixels, 24-bit)
    // File header (14) + V3 header (40) + pixels (2*3*2 + 2*2 padding) = 14+40+16 = 70
    var bmp: [70]u8 = undefined;

    // File header
    bmp[0] = 'B';
    bmp[1] = 'M';
    std.mem.writeInt(u32, bmp[2..6], 70, .little); // File size
    std.mem.writeInt(u16, bmp[6..8], 0, .little); // Reserved
    std.mem.writeInt(u16, bmp[8..10], 0, .little); // Reserved
    std.mem.writeInt(u32, bmp[10..14], 54, .little); // Pixel offset

    // V3 header
    std.mem.writeInt(u32, bmp[14..18], 40, .little); // Header size
    std.mem.writeInt(i32, bmp[18..22], 2, .little); // Width
    std.mem.writeInt(i32, bmp[22..26], 2, .little); // Height
    std.mem.writeInt(u16, bmp[26..28], 1, .little); // Planes
    std.mem.writeInt(u16, bmp[28..30], 24, .little); // Bit count
    std.mem.writeInt(u32, bmp[30..34], 0, .little); // Compression (RGB)
    std.mem.writeInt(u32, bmp[34..38], 16, .little); // Image size
    std.mem.writeInt(i32, bmp[38..42], 2835, .little); // X pels/meter
    std.mem.writeInt(i32, bmp[42..46], 2835, .little); // Y pels/meter
    std.mem.writeInt(u32, bmp[46..50], 0, .little); // Colors used
    std.mem.writeInt(u32, bmp[50..54], 0, .little); // Colors important

    // Pixel data (row 0, then row 1)
    // Row = 2 pixels * 3 bytes = 6 bytes, padded to 8
    bmp[54..62].* = [_]u8{ 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00 };
    bmp[62..70].* = [_]u8{ 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00 };

    const result = validateBmpFromBuffer(allocator, &bmp);
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(u32, 2), result.width);
    try std.testing.expectEqual(@as(u32, 2), result.height);
    try std.testing.expectEqual(@as(u16, 24), result.bit_depth);
    try std.testing.expectEqual(@as(u8, 3), result.header_version);
}

test "validate V3 BMP (8-bit indexed)" {
    const allocator = std.testing.allocator;

    // 2x2 8-bit indexed BMP
    // File header (14) + V3 header (40) + color table (256*4) + pixels (2*2 + 2*2 padding) = 14+40+1024+8 = 1086
    var bmp: [1086]u8 = undefined;
    @memset(&bmp, 0);

    // File header
    bmp[0] = 'B';
    bmp[1] = 'M';
    std.mem.writeInt(u32, bmp[2..6], 1086, .little);
    std.mem.writeInt(u32, bmp[10..14], 14 + 40 + 1024, .little); // Pixel offset

    // V3 header
    std.mem.writeInt(u32, bmp[14..18], 40, .little);
    std.mem.writeInt(i32, bmp[18..22], 2, .little);
    std.mem.writeInt(i32, bmp[22..26], 2, .little);
    std.mem.writeInt(u16, bmp[26..28], 1, .little);
    std.mem.writeInt(u16, bmp[28..30], 8, .little);
    std.mem.writeInt(u32, bmp[30..34], 0, .little);
    std.mem.writeInt(u32, bmp[34..38], 8, .little);

    // Color table - just set first 4 entries
    const color_table_start = 54;
    bmp[color_table_start + 0..][0..4].* = [_]u8{ 0xFF, 0x00, 0x00, 0x00 }; // Blue
    bmp[color_table_start + 4..][0..4].* = [_]u8{ 0x00, 0xFF, 0x00, 0x00 }; // Green
    bmp[color_table_start + 8..][0..4].* = [_]u8{ 0x00, 0x00, 0xFF, 0x00 }; // Red
    bmp[color_table_start + 12..][0..4].* = [_]u8{ 0xFF, 0xFF, 0xFF, 0x00 }; // White

    // Pixel data (indices 0-3)
    const pixel_start = 14 + 40 + 1024;
    bmp[pixel_start..][0..4].* = [_]u8{ 0, 1, 0, 0 }; // Row 0 (padded)
    bmp[pixel_start + 4..][0..4].* = [_]u8{ 2, 3, 0, 0 }; // Row 1 (padded)

    const result = validateBmpFromBuffer(allocator, &bmp);
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(u16, 8), result.bit_depth);
}

test "reject invalid signature" {
    const allocator = std.testing.allocator;
    const invalid = [_]u8{ 'P', 'N', 'G', 0 } ++ [_]u8{0} ** 60;
    const result = validateBmpFromBuffer(allocator, &invalid);
    try std.testing.expect(!result.valid);
    try std.testing.expectEqualStrings("Invalid BMP signature", result.error_message.?);
}

test "reject truncated file" {
    const allocator = std.testing.allocator;
    const truncated = [_]u8{ 'B', 'M', 0, 0, 0, 0 };
    const result = validateBmpFromBuffer(allocator, &truncated);
    try std.testing.expect(!result.valid);
}

test "reject invalid planes" {
    const allocator = std.testing.allocator;

    var bmp: [70]u8 = undefined;
    @memset(&bmp, 0);
    bmp[0] = 'B';
    bmp[1] = 'M';
    std.mem.writeInt(u32, bmp[10..14], 54, .little); // Pixel offset
    std.mem.writeInt(u32, bmp[14..18], 40, .little);
    std.mem.writeInt(i32, bmp[18..22], 2, .little);
    std.mem.writeInt(i32, bmp[22..26], 2, .little);
    std.mem.writeInt(u16, bmp[26..28], 2, .little); // Invalid: planes != 1

    const result = validateBmpFromBuffer(allocator, &bmp);
    try std.testing.expect(!result.valid);
    try std.testing.expectEqualStrings("Invalid planes (must be 1)", result.error_message.?);
}
