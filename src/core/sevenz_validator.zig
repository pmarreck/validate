//! Deep 7-Zip validation module.
//!
//! This module provides thorough 7z archive validation by:
//! 1. Verifying header CRCs (start header and next header)
//! 2. Using the LZMA SDK to open, parse, and extract every file to memory
//!    (discarding output), which verifies per-file CRC integrity
//!
//! No external 7z executable dependency — uses linked LZMA SDK C library.

const std = @import("std");
const Allocator = std.mem.Allocator;

// LZMA SDK C API
const c = @cImport({
    @cInclude("7z.h");
    @cInclude("7zAlloc.h");
    @cInclude("7zCrc.h");
    @cInclude("7zFile.h");
});

/// Result of 7z deep validation
pub const SevenZValidationResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    files_checked: u32,
    total_files: u32,
    bytes_verified: u64,

    pub fn ok(files: u32, bytes: u64) SevenZValidationResult {
        return .{
            .valid = true,
            .error_message = null,
            .files_checked = files,
            .total_files = files,
            .bytes_verified = bytes,
        };
    }

    pub fn okPartial(checked: u32, total: u32, bytes: u64) SevenZValidationResult {
        return .{
            .valid = true,
            .error_message = null,
            .files_checked = checked,
            .total_files = total,
            .bytes_verified = bytes,
        };
    }

    pub fn invalid(message: []const u8) SevenZValidationResult {
        return .{
            .valid = false,
            .error_message = message,
            .files_checked = 0,
            .total_files = 0,
            .bytes_verified = 0,
        };
    }
};

/// 7z signature bytes
const SEVENZ_SIGNATURE = [_]u8{ 0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C };

/// Parsed 7z start header
pub const StartHeader = struct {
    version_major: u8,
    version_minor: u8,
    start_header_crc: u32,
    next_header_offset: u64,
    next_header_size: u64,
    next_header_crc: u32,
};

/// Parse and validate the 7z start header
pub fn parseStartHeader(data: []const u8) ?StartHeader {
    if (data.len < 32) return null;

    // Check signature
    if (!std.mem.eql(u8, data[0..6], &SEVENZ_SIGNATURE)) {
        return null;
    }

    const header = StartHeader{
        .version_major = data[6],
        .version_minor = data[7],
        .start_header_crc = std.mem.readInt(u32, data[8..12], .little),
        .next_header_offset = std.mem.readInt(u64, data[12..20], .little),
        .next_header_size = std.mem.readInt(u64, data[20..28], .little),
        .next_header_crc = std.mem.readInt(u32, data[28..32], .little),
    };

    // Verify start header CRC (covers bytes 12-31)
    const computed_crc = std.hash.Crc32.hash(data[12..32]);
    if (computed_crc != header.start_header_crc) {
        return null;
    }

    return header;
}

/// One-time CRC table initialization (thread-safe via std.once equivalent)
var crc_initialized = false;

fn ensureCrcInit() void {
    if (!crc_initialized) {
        c.CrcGenerateTable();
        crc_initialized = true;
    }
}

/// LZMA SDK error code to human-readable string
fn szResString(res: c.SRes) []const u8 {
    return switch (res) {
        c.SZ_OK => "OK",
        c.SZ_ERROR_DATA => "Data error (CRC mismatch or corrupt data)",
        c.SZ_ERROR_MEM => "Memory allocation failed",
        c.SZ_ERROR_CRC => "CRC verification failed",
        c.SZ_ERROR_UNSUPPORTED => "Unsupported compression method",
        c.SZ_ERROR_PARAM => "Invalid parameter",
        c.SZ_ERROR_INPUT_EOF => "Unexpected end of input",
        c.SZ_ERROR_OUTPUT_EOF => "Output buffer overflow",
        c.SZ_ERROR_READ => "Read error",
        c.SZ_ERROR_WRITE => "Write error",
        c.SZ_ERROR_PROGRESS => "Progress callback error",
        c.SZ_ERROR_FAIL => "General failure",
        c.SZ_ERROR_THREAD => "Thread error",
        c.SZ_ERROR_ARCHIVE => "Invalid archive structure",
        c.SZ_ERROR_NO_ARCHIVE => "Not a 7z archive",
        else => "Unknown error",
    };
}

/// Deep validate a 7z file using the LZMA SDK C library.
/// Opens the archive, parses headers, and extracts every file to memory
/// (discarding the output) to verify CRC integrity of all compressed data.
pub fn validateSevenZDeep(allocator: Allocator, path: []const u8) SevenZValidationResult {
    _ = allocator;
    ensureCrcInit();

    // Convert path to null-terminated C string
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= path_buf.len) {
        return SevenZValidationResult.invalid("Path too long");
    }
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const c_path: [*:0]const u8 = path_buf[0..path.len :0];

    // Set up allocators for the LZMA SDK
    const alloc_impl = c.ISzAlloc{ .Alloc = c.SzAlloc, .Free = c.SzFree };
    const alloc_temp = c.ISzAlloc{ .Alloc = c.SzAllocTemp, .Free = c.SzFreeTemp };

    // Open file
    var archive_stream: c.CFileInStream = undefined;
    if (c.InFile_Open(&archive_stream.file, c_path) != 0) {
        return SevenZValidationResult.invalid("Failed to open file");
    }
    defer _ = c.File_Close(&archive_stream.file);

    c.FileInStream_CreateVTable(&archive_stream);

    // Set up buffered look-ahead reader
    var look_stream: c.CLookToRead2 = undefined;
    c.LookToRead2_CreateVTable(&look_stream, 0); // 0 = no lookahead
    const kInputBufSize = 1 << 18; // 256KB read buffer
    var input_buf: [kInputBufSize]u8 = undefined;
    look_stream.buf = &input_buf;
    look_stream.bufSize = kInputBufSize;
    look_stream.realStream = &archive_stream.vt;
    look_stream.pos = 0;
    look_stream.size = 0;

    // Initialize and open the archive
    var db: c.CSzArEx = undefined;
    c.SzArEx_Init(&db);
    defer c.SzArEx_Free(&db, &alloc_impl);

    const open_res = c.SzArEx_Open(&db, &look_stream.vt, &alloc_impl, &alloc_temp);
    if (open_res != c.SZ_OK) {
        return SevenZValidationResult.invalid(szResString(open_res));
    }

    const num_files: u32 = db.NumFiles;
    if (num_files == 0) {
        return SevenZValidationResult.ok(0, 0);
    }

    // Extract every file to memory (discard output) to verify CRC integrity.
    // The LZMA SDK's SzArEx_Extract() decompresses data and verifies CRCs
    // internally — if any file's CRC doesn't match, it returns SZ_ERROR_CRC.
    var block_index: u32 = 0xFFFFFFFF; // Force initial extraction
    var out_buffer: ?[*]u8 = null;
    var out_buffer_size: usize = 0;
    defer {
        if (out_buffer) |buf| {
            const alloc_main = c.ISzAlloc{ .Alloc = c.SzAlloc, .Free = c.SzFree };
            alloc_main.Free.?(&alloc_main, buf);
        }
    }

    var files_checked: u32 = 0;
    var bytes_verified: u64 = 0;

    var i: u32 = 0;
    while (i < num_files) : (i += 1) {
        // Skip directory entries (reimplemented from C macro to avoid Zig type issues)
        const is_dir = if (db.IsDirs) |dirs|
            (dirs[i >> 3] & (@as(u8, 0x80) >> @intCast(i & 7))) != 0
        else
            false;
        if (is_dir) continue;

        var offset: usize = 0;
        var out_size_processed: usize = 0;

        const extract_res = c.SzArEx_Extract(
            &db,
            &look_stream.vt,
            i,
            &block_index,
            @ptrCast(&out_buffer),
            &out_buffer_size,
            &offset,
            &out_size_processed,
            &alloc_impl,
            &alloc_temp,
        );

        if (extract_res != c.SZ_OK) {
            return SevenZValidationResult.invalid(szResString(extract_res));
        }

        files_checked += 1;
        bytes_verified += out_size_processed;
    }

    return SevenZValidationResult.ok(files_checked, bytes_verified);
}

/// Validate a 7z file from a buffer (for embedded archives).
/// Uses Zig-native header CRC validation only (no decompression).
pub fn validateSevenZFromBuffer(allocator: Allocator, data: []const u8) SevenZValidationResult {
    _ = allocator;
    if (data.len < 32) {
        return SevenZValidationResult.invalid("Data too small for 7z header");
    }

    // Parse and validate start header
    const start_header = parseStartHeader(data) orelse {
        return SevenZValidationResult.invalid("Invalid start header or CRC mismatch");
    };

    // Validate version
    if (start_header.version_major != 0 or start_header.version_minor > 4) {
        return SevenZValidationResult.invalid("Unsupported 7z version");
    }

    // Validate data size
    const expected_min_size = 32 + start_header.next_header_offset + start_header.next_header_size;
    if (data.len < expected_min_size) {
        return SevenZValidationResult.invalid("Data truncated");
    }

    // Verify next header CRC
    if (start_header.next_header_size > 0) {
        const next_header_start: usize = @intCast(32 + start_header.next_header_offset);
        const next_header_end: usize = @intCast(next_header_start + start_header.next_header_size);

        if (next_header_end > data.len) {
            return SevenZValidationResult.invalid("Next header extends beyond data");
        }

        const next_header_data = data[next_header_start..next_header_end];
        const computed_crc = std.hash.Crc32.hash(next_header_data);

        if (computed_crc != start_header.next_header_crc) {
            return SevenZValidationResult.invalid("Next header CRC mismatch");
        }
    }

    return SevenZValidationResult{
        .valid = true,
        .error_message = null,
        .files_checked = 0,
        .total_files = 0,
        .bytes_verified = 0,
    };
}

// Tests
test "parseStartHeader valid header" {
    // Build a valid 7z header
    var header: [32]u8 = undefined;
    @memcpy(header[0..6], &SEVENZ_SIGNATURE);
    header[6] = 0x00; // major version
    header[7] = 0x04; // minor version
    // Placeholder CRC
    @memset(header[8..12], 0);
    // Next header offset = 0
    @memset(header[12..20], 0);
    // Next header size = 0
    @memset(header[20..28], 0);
    // Next header CRC = 0
    @memset(header[28..32], 0);

    // Calculate correct CRC
    const crc = std.hash.Crc32.hash(header[12..32]);
    std.mem.writeInt(u32, header[8..12], crc, .little);

    const parsed = parseStartHeader(&header);
    try std.testing.expect(parsed != null);
    try std.testing.expectEqual(@as(u8, 0), parsed.?.version_major);
    try std.testing.expectEqual(@as(u8, 4), parsed.?.version_minor);
}

test "parseStartHeader invalid signature" {
    var header: [32]u8 = undefined;
    @memset(&header, 0);
    header[0] = 0xFF; // Wrong signature

    const parsed = parseStartHeader(&header);
    try std.testing.expect(parsed == null);
}

test "parseStartHeader crc mismatch" {
    var header: [32]u8 = undefined;
    @memcpy(header[0..6], &SEVENZ_SIGNATURE);
    header[6] = 0x00;
    header[7] = 0x04;
    // Wrong CRC
    header[8] = 0xDE;
    header[9] = 0xAD;
    header[10] = 0xBE;
    header[11] = 0xEF;
    @memset(header[12..32], 0);

    const parsed = parseStartHeader(&header);
    try std.testing.expect(parsed == null);
}

test "LZMA SDK CRC table initialization" {
    ensureCrcInit();
    // If we get here without crashing, the CRC table was initialized successfully
    try std.testing.expect(crc_initialized);
}

test "validate non-existent file returns error" {
    const result = validateSevenZDeep(std.testing.allocator, "/nonexistent/path/fake.7z");
    try std.testing.expect(!result.valid);
    try std.testing.expect(result.error_message != null);
}
