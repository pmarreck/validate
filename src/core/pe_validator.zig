//! PE (Portable Executable) Validator
//!
//! Validates Windows PE format (.exe, .dll, .sys, etc.) by checking:
//! DOS header (MZ), PE signature, COFF header, optional header, and section table.

const std = @import("std");
const format_validation = @import("format_validation.zig");
const errmsg = @import("error_messages.zig");
const ValidationResult = format_validation.ValidationResult;

/// Validate Windows PE (Portable Executable) format (.exe, .dll, .sys, etc.)
/// Performs deep structural validation of the PE headers and section table.
pub fn validatePe(file: std.fs.File) ValidationResult {
    const stat = file.stat() catch {
        return ValidationResult.invalidCode(.pe, .failed_to_stat, "file");
    };

    // Minimum size: DOS header (64) + PE sig (4) + COFF header (20) + minimal opt header
    if (stat.size < 128) {
        return ValidationResult.invalidCode(.pe, .file_too_small, "PE format");
    }

    // Read DOS header (first 64 bytes)
    var dos_header: [64]u8 = undefined;
    file.seekTo(0) catch {
        return ValidationResult.invalidCode(.pe, .failed_to_seek, "to start");
    };
    const dos_bytes = file.readAll(&dos_header) catch {
        return ValidationResult.invalidCode(.pe, .failed_to_read, "DOS header");
    };
    if (dos_bytes < 64) {
        return ValidationResult.invalidCode(.pe, .truncated, "DOS header");
    }

    // Verify MZ magic
    if (dos_header[0] != 'M' or dos_header[1] != 'Z') {
        return ValidationResult.invalidCodeMsg(.pe, .invalid_signature_expected, "DOS", errmsg.invalidSignatureExpected("DOS", "MZ"));
    }

    // Get PE header offset from DOS header at 0x3C (e_lfanew, little-endian)
    const pe_offset = @as(u32, dos_header[0x3C]) |
        (@as(u32, dos_header[0x3D]) << 8) |
        (@as(u32, dos_header[0x3E]) << 16) |
        (@as(u32, dos_header[0x3F]) << 24);

    // Validate PE offset is reasonable
    if (pe_offset < 64 or pe_offset > 0x10000) {
        return ValidationResult.invalidCode(.pe, .invalid_value, "PE header offset");
    }

    if (pe_offset + 24 > stat.size) {
        return ValidationResult.invalidCodeMsg(.pe, .exceeds_bounds, "PE header offset", "PE header offset exceeds file size");
    }

    // Seek to PE signature and read PE header
    file.seekTo(pe_offset) catch {
        return ValidationResult.invalidCode(.pe, .failed_to_seek, "to PE header");
    };

    // Read PE signature (4) + COFF header (20) + start of optional header (enough for magic)
    var pe_header: [256]u8 = undefined;
    const header_size = @min(256, stat.size - pe_offset);
    const pe_bytes = file.read(pe_header[0..@intCast(header_size)]) catch {
        return ValidationResult.invalidCode(.pe, .failed_to_read, "PE header");
    };

    if (pe_bytes < 24) {
        return ValidationResult.invalidCode(.pe, .truncated, "PE header");
    }

    // Verify PE signature: "PE\0\0"
    if (pe_header[0] != 'P' or pe_header[1] != 'E' or pe_header[2] != 0 or pe_header[3] != 0) {
        return ValidationResult.invalidCode(.pe, .invalid_signature, "PE");
    }

    // Parse COFF header (starts at offset 4 after PE signature)
    const coff = pe_header[4..24];

    // Machine type (bytes 0-1, little-endian)
    const machine = @as(u16, coff[0]) | (@as(u16, coff[1]) << 8);

    // Validate known machine types
    const valid_machines = [_]u16{
        0x014c, // IMAGE_FILE_MACHINE_I386
        0x0200, // IMAGE_FILE_MACHINE_IA64
        0x8664, // IMAGE_FILE_MACHINE_AMD64
        0x01c0, // IMAGE_FILE_MACHINE_ARM
        0x01c4, // IMAGE_FILE_MACHINE_ARMNT (ARM Thumb-2)
        0xaa64, // IMAGE_FILE_MACHINE_ARM64
    };

    var valid_machine = false;
    for (valid_machines) |m| {
        if (machine == m) {
            valid_machine = true;
            break;
        }
    }
    if (!valid_machine) {
        return ValidationResult.invalidCode(.pe, .unknown_element, "machine type");
    }

    // Number of sections (bytes 2-3)
    const num_sections = @as(u16, coff[2]) | (@as(u16, coff[3]) << 8);
    if (num_sections == 0 or num_sections > 96) {
        // Windows loader limit is 96 sections
        return ValidationResult.invalidCode(.pe, .invalid_value, "section count");
    }

    // SizeOfOptionalHeader (bytes 16-17)
    const optional_header_size = @as(u16, coff[16]) | (@as(u16, coff[17]) << 8);
    if (optional_header_size < 28) {
        // Minimum for standard fields
        return ValidationResult.invalid(.pe, "Optional header too small");
    }

    // Characteristics (bytes 18-19)
    const characteristics = @as(u16, coff[18]) | (@as(u16, coff[19]) << 8);

    // Check for executable or DLL flag
    const IMAGE_FILE_EXECUTABLE_IMAGE: u16 = 0x0002;
    const IMAGE_FILE_DLL: u16 = 0x2000;
    if (characteristics & (IMAGE_FILE_EXECUTABLE_IMAGE | IMAGE_FILE_DLL) == 0) {
        // Neither executable nor DLL - unusual but maybe valid
        // Don't fail, just note it's unusual
    }

    // Parse optional header (starts at offset 24)
    if (pe_bytes < 26) {
        return ValidationResult.invalidCode(.pe, .missing, "optional header");
    }

    const opt_header = pe_header[24..];
    const opt_magic = @as(u16, opt_header[0]) | (@as(u16, opt_header[1]) << 8);

    // Optional header magic
    const PE32_MAGIC: u16 = 0x010b;
    const PE32PLUS_MAGIC: u16 = 0x020b;

    var is_pe32plus = false;
    if (opt_magic == PE32_MAGIC) {
        // PE32 (32-bit)
        is_pe32plus = false;
    } else if (opt_magic == PE32PLUS_MAGIC) {
        // PE32+ (64-bit)
        is_pe32plus = true;
    } else {
        return ValidationResult.invalidCode(.pe, .invalid_value, "optional header magic");
    }

    // Minimum optional header sizes
    const min_opt_size: u16 = if (is_pe32plus) 112 else 96;
    if (optional_header_size < min_opt_size) {
        return ValidationResult.invalid(.pe, "Optional header size too small for PE type");
    }

    // Calculate section table offset
    const section_table_offset: u64 = pe_offset + 24 + optional_header_size;
    const section_table_size: u64 = @as(u64, num_sections) * 40; // Each section header is 40 bytes

    if (section_table_offset + section_table_size > stat.size) {
        return ValidationResult.invalidCodeMsg(.pe, .exceeds_bounds, "Section table", "Section table exceeds file size");
    }

    // Read and validate section table
    file.seekTo(section_table_offset) catch {
        return ValidationResult.invalidCode(.pe, .failed_to_seek, "to section table");
    };

    // Allocate buffer for section headers
    const section_buffer = std.heap.page_allocator.alloc(u8, @intCast(section_table_size)) catch {
        return ValidationResult.invalidCode(.pe, .failed_to_allocate, "section buffer");
    };
    defer std.heap.page_allocator.free(section_buffer);

    const section_bytes = file.readAll(section_buffer) catch {
        return ValidationResult.invalidCode(.pe, .failed_to_read, "section table");
    };

    if (section_bytes < section_table_size) {
        return ValidationResult.invalidCode(.pe, .truncated, "section table");
    }

    // Validate each section header
    var i: u16 = 0;
    while (i < num_sections) : (i += 1) {
        const sec_offset = @as(usize, i) * 40;
        const section = section_buffer[sec_offset .. sec_offset + 40];

        // Section name (8 bytes) - can be anything, including nulls
        // VirtualSize (4 bytes at offset 8)
        // VirtualAddress (4 bytes at offset 12)
        // SizeOfRawData (4 bytes at offset 16)
        const size_of_raw_data = @as(u32, section[16]) |
            (@as(u32, section[17]) << 8) |
            (@as(u32, section[18]) << 16) |
            (@as(u32, section[19]) << 24);

        // PointerToRawData (4 bytes at offset 20)
        const pointer_to_raw_data = @as(u32, section[20]) |
            (@as(u32, section[21]) << 8) |
            (@as(u32, section[22]) << 16) |
            (@as(u32, section[23]) << 24);

        // Validate section data doesn't exceed file
        if (size_of_raw_data > 0 and pointer_to_raw_data > 0) {
            const section_end = @as(u64, pointer_to_raw_data) + @as(u64, size_of_raw_data);
            if (section_end > stat.size) {
                return ValidationResult.invalidCodeMsg(.pe, .exceeds_bounds, "Section data", "Section data exceeds file bounds");
            }
        }
    }

    // For deep validation, we could parse data directories (imports, exports, resources, etc.)
    // For now, structural validation is sufficient

    return ValidationResult.okWithDepth(.pe, .structural);
}

// -- Tests ------------------------------------------------------------------

test "validatePe with ground truth" {
    const file = std.fs.cwd().openFile("ground_truth_examples/pe/sample.exe", .{}) catch return;
    defer file.close();
    const result = validatePe(file);
    try std.testing.expect(result.is_valid);
}

test "validatePe with truncated PE" {
    const tmp_dir = std.posix.getenv("TMPDIR") orelse "/tmp";
    const tmp_path = std.fmt.comptimePrint("{s}", .{"pe_truncated_test.exe"});
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ tmp_dir, tmp_path }) catch unreachable;

    // Write "MZ" + 2 zero bytes (4 bytes total — well below 128 minimum)
    {
        const file = std.fs.createFileAbsolute(full_path, .{}) catch return;
        defer file.close();
        file.writeAll(&[_]u8{ 'M', 'Z', 0, 0 }) catch return;
    }
    defer std.fs.deleteFileAbsolute(full_path) catch {};

    const file = std.fs.openFileAbsolute(full_path, .{}) catch return;
    defer file.close();
    const result = validatePe(file);
    try std.testing.expect(!result.is_valid);
}

test "validatePe with invalid magic" {
    const tmp_dir = std.posix.getenv("TMPDIR") orelse "/tmp";
    const tmp_path = std.fmt.comptimePrint("{s}", .{"pe_badmagic_test.exe"});
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ tmp_dir, tmp_path }) catch unreachable;

    // Write 4 random (non-MZ) bytes, padded to 256 bytes to pass size check
    {
        const file = std.fs.createFileAbsolute(full_path, .{}) catch return;
        defer file.close();
        var buf: [256]u8 = undefined;
        @memset(&buf, 0);
        buf[0] = 0xDE;
        buf[1] = 0xAD;
        buf[2] = 0xBE;
        buf[3] = 0xEF;
        file.writeAll(&buf) catch return;
    }
    defer std.fs.deleteFileAbsolute(full_path) catch {};

    const file = std.fs.openFileAbsolute(full_path, .{}) catch return;
    defer file.close();
    const result = validatePe(file);
    try std.testing.expect(!result.is_valid);
}
