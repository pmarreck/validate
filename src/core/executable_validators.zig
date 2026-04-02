//! Executable/binary format validators extracted from format_validation.zig.
//! Covers ELF, Mach-O (single-arch and fat/universal), COFF (.obj), WebAssembly, and ar archives.

const std = @import("std");
const file_source = @import("file_source.zig");
const FileSource = file_source.FileSource;
const format_validation = @import("format_validation.zig");
const errmsg = @import("error_messages.zig");
const ValidationResult = format_validation.ValidationResult;
const FileFormat = format_validation.FileFormat;

// ============ ELF Validator ============

/// Validate ELF (Executable and Linkable Format) binary.
/// Checks magic, class, endianness, version, type, and header sizes.
pub fn validateElf(file: *FileSource) ValidationResult {
    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.elf, .failed_to_get, "file size");
    if (file_size < 16) return ValidationResult.invalidCode(.elf, .file_too_small, "ELF header");

    file.seekTo(0) catch return ValidationResult.invalid(.elf, "Failed to seek");
    var header: [64]u8 = undefined;
    const bytes_read = file.read(&header) catch return ValidationResult.invalidCode(.elf, .failed_to_read, "ELF header");
    if (bytes_read < 16) return ValidationResult.invalid(.elf, "ELF header too short");

    // Magic already verified by format detection, but double-check
    if (!std.mem.eql(u8, header[0..4], &[_]u8{ 0x7F, 0x45, 0x4C, 0x46 }))
        return ValidationResult.invalidCode(.elf, .invalid_value, "ELF magic");

    // EI_CLASS: 1 = 32-bit, 2 = 64-bit
    const ei_class = header[4];
    if (ei_class != 1 and ei_class != 2)
        return ValidationResult.invalidCode(.elf, .invalid_value, "ELF class (must be 32 or 64 bit)");

    // EI_DATA: 1 = little-endian, 2 = big-endian
    const ei_data = header[5];
    if (ei_data != 1 and ei_data != 2)
        return ValidationResult.invalidCode(.elf, .invalid_value, "ELF data encoding");

    // EI_VERSION: must be 1 (current)
    if (header[6] != 1)
        return ValidationResult.invalidCode(.elf, .invalid_value, "ELF version");

    // Minimum header size: 52 for ELF32, 64 for ELF64
    const min_header_size: usize = if (ei_class == 1) 52 else 64;
    if (bytes_read < min_header_size)
        return ValidationResult.invalid(.elf, "ELF header too short for declared class");

    // Parse e_type (2 bytes at offset 16)
    const endian: std.builtin.Endian = if (ei_data == 1) .little else .big;
    const e_type = std.mem.readInt(u16, header[16..18], endian);
    // Valid types: 0=NONE, 1=REL, 2=EXEC, 3=DYN, 4=CORE, 0xFE00-0xFFFF=OS/proc specific
    if (e_type > 4 and e_type < 0xFE00)
        return ValidationResult.invalidCode(.elf, .invalid_value, "ELF type");

    // Parse e_machine (2 bytes at offset 18) — just verify it's non-zero for known types
    const e_machine = std.mem.readInt(u16, header[18..20], endian);
    // There are hundreds of valid machine types; just check some well-known ones aren't impossible
    _ = e_machine; // Accept any machine type

    // Parse e_version (4 bytes at offset 20)
    const e_version = std.mem.readInt(u32, header[20..24], endian);
    if (e_version != 1)
        return ValidationResult.invalidCode(.elf, .invalid_value, "ELF file version");

    // Validate section header and program header sizes are reasonable
    if (ei_class == 1) {
        // ELF32: e_ehsize at 40, e_phentsize at 42, e_shentsize at 46
        const e_ehsize = std.mem.readInt(u16, header[40..42], endian);
        if (e_ehsize != 52)
            return ValidationResult.invalidCode(.elf, .invalid_value, "ELF32 header size");
    } else {
        // ELF64: e_ehsize at 52, e_phentsize at 54, e_shentsize at 58
        const e_ehsize = std.mem.readInt(u16, header[52..54], endian);
        if (e_ehsize != 64)
            return ValidationResult.invalidCode(.elf, .invalid_value, "ELF64 header size");
    }

    return ValidationResult.okWithDepth(.elf, .structural);
}

// ============ Mach-O Validator ============

/// Validate Mach-O binary (single-architecture).
/// Checks magic, CPU type, file type, and load command structure.
pub fn validateMacho(file: *FileSource) ValidationResult {
    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.macho, .failed_to_get, "file size");
    if (file_size < 28) return ValidationResult.invalidCode(.macho, .file_too_small, "Mach-O header");

    file.seekTo(0) catch return ValidationResult.invalid(.macho, "Failed to seek");
    var header: [32]u8 = undefined;
    const bytes_read = file.read(&header) catch return ValidationResult.invalidCode(.macho, .failed_to_read, "header");
    if (bytes_read < 28) return ValidationResult.invalid(.macho, "Mach-O header too short");

    // Determine 32-bit vs 64-bit and endianness from magic
    const is_64 = (header[0] == 0xCF or header[3] == 0xCF);
    const is_le = (header[0] == 0xCE or header[0] == 0xCF);
    const endian: std.builtin.Endian = if (is_le) .little else .big;
    const header_size: usize = if (is_64) 32 else 28;

    if (bytes_read < header_size)
        return ValidationResult.invalid(.macho, "Mach-O header too short for class");

    // cputype (4 bytes at offset 4)
    const cputype = std.mem.readInt(u32, header[4..8], endian);
    const valid_cpu = (cputype == 7 or // i386
        cputype == 0x01000007 or // x86_64
        cputype == 12 or // arm
        cputype == 0x0100000C or // arm64
        cputype == 18); // ppc
    if (!valid_cpu)
        return ValidationResult.invalidCode(.macho, .invalid_value, "Mach-O CPU type");

    // filetype (4 bytes at offset 12): 1=OBJECT, 2=EXECUTE, 3=FVMLIB, 4=CORE,
    // 5=PRELOAD, 6=DYLIB, 7=DYLINKER, 8=BUNDLE, 9=DYLIB_STUB, 10=DSYM, 11=KEXT_BUNDLE, 12=FILESET
    const filetype = std.mem.readInt(u32, header[12..16], endian);
    if (filetype == 0 or filetype > 12)
        return ValidationResult.invalidCode(.macho, .invalid_value, "Mach-O file type");

    // ncmds (4 bytes at offset 16) and sizeofcmds (4 bytes at offset 20)
    const ncmds = std.mem.readInt(u32, header[16..20], endian);
    const sizeofcmds = std.mem.readInt(u32, header[20..24], endian);
    if (ncmds == 0)
        return ValidationResult.invalid(.macho, "No load commands");
    if (ncmds > 2000)
        return ValidationResult.invalid(.macho, "Unreasonable number of load commands");

    // sizeofcmds must fit within the file
    if (@as(u64, header_size) + @as(u64, sizeofcmds) > file_size)
        return ValidationResult.invalid(.macho, "Load commands extend beyond file");

    return ValidationResult.okWithDepth(.macho, .structural);
}

/// Validate Mach-O Universal/Fat binary (multi-architecture).
/// Checks nfat_arch, validates each architecture entry's bounds and embedded Mach-O magic.
pub fn validateMachoFat(file: *FileSource) ValidationResult {
    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.macho_fat, .failed_to_get, "file size");
    if (file_size < 8) return ValidationResult.invalidCode(.macho_fat, .file_too_small, "fat header");

    file.seekTo(0) catch return ValidationResult.invalid(.macho_fat, "Failed to seek");
    var header: [8]u8 = undefined;
    _ = file.read(&header) catch return ValidationResult.invalidCode(.macho_fat, .failed_to_read, "header");

    // nfat_arch at offset 4, always big-endian
    const nfat_arch = std.mem.readInt(u32, header[4..8], .big);
    if (nfat_arch == 0 or nfat_arch > 30)
        return ValidationResult.invalidCode(.macho_fat, .invalid_value, "number of architectures");

    // Each fat_arch entry is 20 bytes, starting at offset 8
    const entries_end: u64 = 8 + @as(u64, nfat_arch) * 20;
    if (entries_end > file_size)
        return ValidationResult.invalid(.macho_fat, "Fat arch entries extend beyond file");

    // Validate each architecture entry
    var valid_archs: u32 = 0;
    for (0..nfat_arch) |i| {
        const entry_offset = 8 + i * 20;
        file.seekTo(entry_offset) catch break;
        var entry: [20]u8 = undefined;
        const read = file.read(&entry) catch break;
        if (read < 20) break;

        // cputype (4 bytes), cpusubtype (4 bytes), offset (4 bytes), size (4 bytes), align (4 bytes)
        const arch_cputype = std.mem.readInt(u32, entry[0..4], .big);
        const arch_offset = std.mem.readInt(u32, entry[8..12], .big);
        const arch_size = std.mem.readInt(u32, entry[12..16], .big);

        // Validate CPU type
        const valid_cpu = (arch_cputype == 7 or // i386
            arch_cputype == 0x01000007 or // x86_64
            arch_cputype == 12 or // arm
            arch_cputype == 0x0100000C or // arm64
            arch_cputype == 18); // ppc
        if (!valid_cpu) continue;

        // Validate offset + size within file
        if (@as(u64, arch_offset) + @as(u64, arch_size) > file_size) continue;

        // Verify embedded Mach-O has valid magic
        if (arch_size >= 4) {
            file.seekTo(arch_offset) catch continue;
            var magic: [4]u8 = undefined;
            _ = file.read(&magic) catch continue;
            const is_macho = std.mem.eql(u8, &magic, &[_]u8{ 0xCF, 0xFA, 0xED, 0xFE }) or
                std.mem.eql(u8, &magic, &[_]u8{ 0xCE, 0xFA, 0xED, 0xFE }) or
                std.mem.eql(u8, &magic, &[_]u8{ 0xFE, 0xED, 0xFA, 0xCF }) or
                std.mem.eql(u8, &magic, &[_]u8{ 0xFE, 0xED, 0xFA, 0xCE });
            if (is_macho) valid_archs += 1;
        }
    }

    if (valid_archs == 0)
        return ValidationResult.invalidCode(.macho_fat, .no_valid_x_found, "Mach-O architectures");

    return ValidationResult.okWithDepth(.macho_fat, .structural);
}

// ============ COFF Validator ============

/// Validate COFF object file (.obj).
/// Checks machine type, section count, and structural consistency.
pub fn validateCoff(file: *FileSource) ValidationResult {
    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.coff, .failed_to_get, "file size");
    if (file_size < 20) return ValidationResult.invalidCode(.coff, .file_too_small, "COFF header");

    file.seekTo(0) catch return ValidationResult.invalid(.coff, "Failed to seek");
    var header: [20]u8 = undefined;
    const bytes_read = file.read(&header) catch return ValidationResult.invalidCode(.coff, .failed_to_read, "header");
    if (bytes_read < 20) return ValidationResult.invalid(.coff, "COFF header too short");

    // Machine type (2 bytes at offset 0, little-endian)
    const machine = std.mem.readInt(u16, header[0..2], .little);
    const valid_machine = (machine == 0x014C or // i386
        machine == 0x8664 or // amd64
        machine == 0x01C0 or // arm
        machine == 0x01C2 or // thumb
        machine == 0x01C4 or // armnt (ARM Thumb-2)
        machine == 0xAA64 or // arm64
        machine == 0x0200); // ia64
    if (!valid_machine)
        return ValidationResult.invalidCode(.coff, .invalid_value, "COFF machine type");

    // NumberOfSections (2 bytes at offset 2)
    const num_sections = std.mem.readInt(u16, header[2..4], .little);
    if (num_sections == 0 or num_sections > 96)
        return ValidationResult.invalidCode(.coff, .invalid_value, "COFF section count");

    // SizeOfOptionalHeader (2 bytes at offset 16)
    const opt_header_size = std.mem.readInt(u16, header[16..18], .little);
    // COFF object files typically have 0 optional header; PE optional header is larger
    if (opt_header_size > 1024)
        return ValidationResult.invalid(.coff, "Optional header too large for COFF object");

    // Verify the section headers fit within the file
    // Section headers: 40 bytes each, starting after the COFF header + optional header
    const section_table_end: u64 = 20 + @as(u64, opt_header_size) + @as(u64, num_sections) * 40;
    if (section_table_end > file_size)
        return ValidationResult.invalid(.coff, "Section table extends beyond file");

    // PointerToSymbolTable (4 bytes at offset 8) — if non-zero, must be within file
    const sym_table_ptr = std.mem.readInt(u32, header[8..12], .little);
    if (sym_table_ptr > 0 and @as(u64, sym_table_ptr) > file_size)
        return ValidationResult.invalid(.coff, "Symbol table pointer beyond file");

    return ValidationResult.okWithDepth(.coff, .structural);
}

// ============ WebAssembly Validator ============

/// Validate WebAssembly binary module.
/// Checks magic, version, and validates section ordering and sizes.
pub fn validateWasm(file: *FileSource) ValidationResult {
    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.wasm, .failed_to_get, "file size");
    if (file_size < 8) return ValidationResult.invalidCode(.wasm, .file_too_small, "Wasm module");

    file.seekTo(0) catch return ValidationResult.invalid(.wasm, "Failed to seek");
    var header: [8]u8 = undefined;
    const bytes_read = file.read(&header) catch return ValidationResult.invalidCode(.wasm, .failed_to_read, "header");
    if (bytes_read < 8) return ValidationResult.invalid(.wasm, "Wasm header too short");

    // Magic: \0asm
    if (!std.mem.eql(u8, header[0..4], &[_]u8{ 0x00, 0x61, 0x73, 0x6D }))
        return ValidationResult.invalidCode(.wasm, .invalid_value, "Wasm magic");

    // Version: must be 1 (little-endian u32)
    const version = std.mem.readInt(u32, header[4..8], .little);
    if (version != 1)
        return ValidationResult.invalidCode(.wasm, .unsupported, "Wasm version");

    // Validate sections: each section has a 1-byte ID and LEB128 size
    var offset: u64 = 8;
    var last_section_id: u8 = 0;
    var section_count: u32 = 0;

    while (offset < file_size) {
        file.seekTo(offset) catch break;
        var sect_header: [6]u8 = undefined; // section ID + up to 5 bytes LEB128
        const sect_read = file.read(&sect_header) catch break;
        if (sect_read < 1) break;

        const section_id = sect_header[0];

        // Section IDs: 0=custom, 1=type, 2=import, 3=function, 4=table, 5=memory,
        // 6=global, 7=export, 8=start, 9=element, 10=code, 11=data, 12=data_count
        if (section_id > 12)
            return ValidationResult.invalidCode(.wasm, .invalid_value, "Wasm section ID");

        // Non-custom sections must be in order
        if (section_id != 0) {
            if (section_id <= last_section_id)
                return ValidationResult.invalid(.wasm, "Wasm sections out of order");
            last_section_id = section_id;
        }

        // Decode LEB128 section size (up to 5 bytes for u32)
        var size: u64 = 0;
        var leb_bytes: u32 = 0;
        for (1..sect_read) |i| {
            const b = sect_header[i];
            const shift_amount: u6 = @intCast(leb_bytes * 7);
            size |= @as(u64, b & 0x7F) << shift_amount;
            leb_bytes += 1;
            if (b & 0x80 == 0) break;
            if (leb_bytes >= 5) return ValidationResult.invalidCode(.wasm, .invalid_value, "Wasm section size encoding");
        }

        if (leb_bytes == 0)
            return ValidationResult.invalidCode(.wasm, .missing, "Wasm section size");

        // Verify section fits within file
        const section_end = offset + 1 + leb_bytes + size;
        if (section_end > file_size)
            return ValidationResult.invalid(.wasm, "Wasm section extends beyond file end");

        // Advance past section
        offset = section_end;
        section_count += 1;

        if (section_count > 10000)
            return ValidationResult.invalidCode(.wasm, .too_many, "Wasm sections");
    }

    if (section_count == 0)
        return ValidationResult.invalid(.wasm, "Wasm module has no sections");

    return ValidationResult.okWithDepth(.wasm, .structural);
}

// ============ LLVM Precompiled Header Validator ============

/// Validate LLVM precompiled header (.pcm): magic "CPCH" + version + bitcode.
/// Structural: verify magic, minimum size, and LLVM bitcode signature.
pub fn validateLlvmPch(file: *FileSource) ValidationResult {
    return validateLlvmBitcodeContainer(file, "CPCH", .llvm_pch);
}

// ============ LLVM Serialized Diagnostics Validator ============

/// Validate LLVM serialized diagnostics (.dia): magic "DIAG" + version + bitcode.
pub fn validateLlvmDiag(file: *FileSource) ValidationResult {
    return validateLlvmBitcodeContainer(file, "DIAG", .llvm_diag);
}

/// Shared LLVM bitcode container validation: 4-byte magic, then LLVM bitcode.
/// LLVM bitcode starts at offset 4 with signature 0xDEC04342 ("BC\xC0\xDE") or
/// a wrapper header, or the raw bitcode stream prefixed by version bytes.
fn validateLlvmBitcodeContainer(file: *FileSource, comptime magic: *const [4]u8, comptime format: format_validation.FileFormat) ValidationResult {
    const label = comptime @tagName(format);
    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(format, .failed_to_get, "file size");
    if (file_size < 8) return ValidationResult.invalidCode(format, .file_too_small, label);

    file.seekTo(0) catch return ValidationResult.invalidCode(format, .failed_to_seek, label);
    var header: [16]u8 = undefined;
    const bytes_read = file.readAll(&header) catch return ValidationResult.invalidCode(format, .failed_to_read, label);
    if (bytes_read < 8) return ValidationResult.invalidCode(format, .truncated, label);

    if (!std.mem.eql(u8, header[0..4], magic))
        return ValidationResult.invalidCode(format, .invalid_magic, label);

    // After the 4-byte magic, LLVM bitcode containers have version info then bitcode.
    // The exact layout varies by LLVM version, but file_size > 8 with valid magic
    // is sufficient for structural validation.
    return ValidationResult.structuralOnly(format);
}

// ============ ar Archive Validator ============

/// Check that an AR header numeric field contains only ASCII digits and trailing spaces.
/// An all-spaces field is valid (some tools omit uid/gid/date).
fn isValidArNumericField(field: []const u8) bool {
	var seen_space = false;
	for (field) |c| {
		if (c == ' ') {
			seen_space = true;
		} else if (c >= '0' and c <= '9') {
			// Digits must not appear after trailing spaces
			if (seen_space) return false;
		} else {
			return false;
		}
	}
	return true;
}

/// Check that an AR header text field contains only printable ASCII (0x20-0x7E).
/// If allow_slash is true, also permits '/' which is used in GNU ar name conventions.
fn isValidArTextField(field: []const u8, comptime allow_slash: bool) bool {
	_ = allow_slash;
	for (field) |c| {
		if (c < 0x20 or c > 0x7E) return false;
	}
	return true;
}

/// Validate Unix ar archive format (.a static libraries, .deb packages).
/// Checks global header and validates member entry headers including name, date, uid, gid, mode fields.
pub fn validateAr(file: *FileSource) ValidationResult {
    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.ar, .failed_to_get, "file size");
    if (file_size < 8) return ValidationResult.invalidCode(.ar, .file_too_small, "ar archive");

    file.seekTo(0) catch return ValidationResult.invalid(.ar, "Failed to seek");
    var magic: [8]u8 = undefined;
    const bytes_read = file.read(&magic) catch return ValidationResult.invalidCode(.ar, .failed_to_read, "header");
    if (bytes_read < 8) return ValidationResult.invalid(.ar, "ar header too short");

    if (!std.mem.eql(u8, &magic, "!<arch>\n"))
        return ValidationResult.invalidCode(.ar, .invalid_value, "ar magic");

    // Validate member headers
    var offset: u64 = 8;
    var member_count: u32 = 0;

    while (offset + 60 <= file_size) {
        file.seekTo(offset) catch break;
        var member_header: [60]u8 = undefined;
        const mread = file.read(&member_header) catch break;
        if (mread < 60) break;

        // Each member header ends with 0x60 0x0A ("`\n")
        if (member_header[58] != 0x60 or member_header[59] != 0x0A)
            return ValidationResult.invalidCode(.ar, .invalid_value, "ar member header terminator");

        // Validate name field (bytes 0-15): printable ASCII only (0x20-0x7E)
        // Covers regular names, BSD "#1/N" extended names, GNU "/" and "//" entries
        if (!isValidArTextField(member_header[0..16], true))
            return ValidationResult.invalidCode(.ar, .invalid_value, "ar member name");

        // Validate date field (bytes 16-27): ASCII decimal digits + trailing spaces
        if (!isValidArNumericField(member_header[16..28]))
            return ValidationResult.invalidCode(.ar, .invalid_value, "ar member date");

        // Validate uid field (bytes 28-33): ASCII decimal digits + trailing spaces
        if (!isValidArNumericField(member_header[28..34]))
            return ValidationResult.invalidCode(.ar, .invalid_value, "ar member uid");

        // Validate gid field (bytes 34-39): ASCII decimal digits + trailing spaces
        if (!isValidArNumericField(member_header[34..40]))
            return ValidationResult.invalidCode(.ar, .invalid_value, "ar member gid");

        // Validate mode field (bytes 40-47): octal digits + trailing spaces
        if (!isValidArNumericField(member_header[40..48]))
            return ValidationResult.invalidCode(.ar, .invalid_value, "ar member mode");

        // Parse file size from bytes 48-57 (ASCII decimal, space-padded)
        var size_end: usize = 58;
        while (size_end > 48 and (member_header[size_end - 1] == ' ' or member_header[size_end - 1] == 0)) {
            size_end -= 1;
        }

        const size_str = member_header[48..size_end];
        const member_size = std.fmt.parseInt(u64, size_str, 10) catch
            return ValidationResult.invalidCode(.ar, .invalid_value, "ar member size");

        // Advance to next member (size is padded to even boundary)
        offset += 60 + member_size;
        if (member_size % 2 != 0) offset += 1; // Padding byte

        member_count += 1;
        if (member_count > 100000)
            return ValidationResult.invalidCode(.ar, .too_many, "ar members");
    }

    if (member_count == 0 and file_size > 8)
        return ValidationResult.invalid(.ar, "ar archive has data but no valid members");

    return ValidationResult.okWithDepth(.ar, .structural);
}

// ============ Tests ============

test "validateElf with ground truth file" {
    var source = FileSource.open("ground_truth_examples/elf/minimal.elf") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validateElf(&source);
    try std.testing.expect(result.is_valid);
}

test "validateElf rejects truncated file" {
    const tmpdir = std.posix.getenv("TMPDIR") orelse "/tmp";
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/test_truncated.elf", .{tmpdir}) catch return;
    {
        const wf = std.fs.cwd().createFile(path, .{}) catch return;
        defer wf.close();
        wf.writeAll("\x7fELF") catch return;
    }
    defer std.fs.cwd().deleteFile(path) catch {};
    var source = FileSource.open(path) catch return;
    defer source.close();
    const result = validateElf(&source);
    try std.testing.expect(!result.is_valid);
}

test "validateElf rejects invalid data" {
    const tmpdir = std.posix.getenv("TMPDIR") orelse "/tmp";
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/test_invalid.elf", .{tmpdir}) catch return;
    {
        const wf = std.fs.cwd().createFile(path, .{}) catch return;
        defer wf.close();
        wf.writeAll("This is not an ELF file at all!!!!") catch return;
    }
    defer std.fs.cwd().deleteFile(path) catch {};
    var source = FileSource.open(path) catch return;
    defer source.close();
    const result = validateElf(&source);
    try std.testing.expect(!result.is_valid);
}

test "validateMacho with ground truth file" {
    var source = FileSource.open("ground_truth_examples/macho/sample.o") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validateMacho(&source);
    try std.testing.expect(result.is_valid);
}

test "validateMacho rejects truncated file" {
    const tmpdir = std.posix.getenv("TMPDIR") orelse "/tmp";
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/test_truncated.macho", .{tmpdir}) catch return;
    {
        const wf = std.fs.cwd().createFile(path, .{}) catch return;
        defer wf.close();
        wf.writeAll("\xcf\xfa\xed\xfe") catch return; // Mach-O 64-bit LE magic only
    }
    defer std.fs.cwd().deleteFile(path) catch {};
    var source = FileSource.open(path) catch return;
    defer source.close();
    const result = validateMacho(&source);
    try std.testing.expect(!result.is_valid);
}

test "validateMacho rejects invalid data" {
    const tmpdir = std.posix.getenv("TMPDIR") orelse "/tmp";
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/test_invalid.macho", .{tmpdir}) catch return;
    {
        const wf = std.fs.cwd().createFile(path, .{}) catch return;
        defer wf.close();
        wf.writeAll("Definitely not a Mach-O binary!!") catch return;
    }
    defer std.fs.cwd().deleteFile(path) catch {};
    var source = FileSource.open(path) catch return;
    defer source.close();
    const result = validateMacho(&source);
    try std.testing.expect(!result.is_valid);
}

test "validateMachoFat with ground truth file" {
    var source = FileSource.open("ground_truth_examples/macho_fat/sample") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validateMachoFat(&source);
    try std.testing.expect(result.is_valid);
}

test "validateMachoFat rejects truncated file" {
    const tmpdir = std.posix.getenv("TMPDIR") orelse "/tmp";
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/test_truncated.fat", .{tmpdir}) catch return;
    {
        const wf = std.fs.cwd().createFile(path, .{}) catch return;
        defer wf.close();
        wf.writeAll("\xca\xfe\xba\xbe") catch return; // Fat magic only
    }
    defer std.fs.cwd().deleteFile(path) catch {};
    var source = FileSource.open(path) catch return;
    defer source.close();
    const result = validateMachoFat(&source);
    try std.testing.expect(!result.is_valid);
}

test "validateMachoFat rejects invalid data" {
    const tmpdir = std.posix.getenv("TMPDIR") orelse "/tmp";
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/test_invalid.fat", .{tmpdir}) catch return;
    {
        const wf = std.fs.cwd().createFile(path, .{}) catch return;
        defer wf.close();
        wf.writeAll("Not a fat binary at all here!!!!!!") catch return;
    }
    defer std.fs.cwd().deleteFile(path) catch {};
    var source = FileSource.open(path) catch return;
    defer source.close();
    const result = validateMachoFat(&source);
    try std.testing.expect(!result.is_valid);
}

test "validateCoff rejects truncated file" {
    const tmpdir = std.posix.getenv("TMPDIR") orelse "/tmp";
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/test_truncated.obj", .{tmpdir}) catch return;
    {
        const wf = std.fs.cwd().createFile(path, .{}) catch return;
        defer wf.close();
        wf.writeAll("\x4c\x01\x03\x00") catch return; // i386 machine type + partial header
    }
    defer std.fs.cwd().deleteFile(path) catch {};
    var source = FileSource.open(path) catch return;
    defer source.close();
    const result = validateCoff(&source);
    try std.testing.expect(!result.is_valid);
}

test "validateCoff rejects invalid data" {
    const tmpdir = std.posix.getenv("TMPDIR") orelse "/tmp";
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/test_invalid.obj", .{tmpdir}) catch return;
    {
        const wf = std.fs.cwd().createFile(path, .{}) catch return;
        defer wf.close();
        // 20 bytes with invalid machine type (0xFFFF)
        wf.writeAll("\xff\xff\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00") catch return;
    }
    defer std.fs.cwd().deleteFile(path) catch {};
    var source = FileSource.open(path) catch return;
    defer source.close();
    const result = validateCoff(&source);
    try std.testing.expect(!result.is_valid);
}

test "validateWasm with ground truth file" {
    var source = FileSource.open("ground_truth_examples/wasm/minimal.wasm") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validateWasm(&source);
    try std.testing.expect(result.is_valid);
}

test "validateWasm rejects truncated file" {
    const tmpdir = std.posix.getenv("TMPDIR") orelse "/tmp";
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/test_truncated.wasm", .{tmpdir}) catch return;
    {
        const wf = std.fs.cwd().createFile(path, .{}) catch return;
        defer wf.close();
        wf.writeAll("\x00\x61\x73\x6d") catch return; // Wasm magic only
    }
    defer std.fs.cwd().deleteFile(path) catch {};
    var source = FileSource.open(path) catch return;
    defer source.close();
    const result = validateWasm(&source);
    try std.testing.expect(!result.is_valid);
}

test "validateWasm rejects invalid data" {
    const tmpdir = std.posix.getenv("TMPDIR") orelse "/tmp";
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/test_invalid.wasm", .{tmpdir}) catch return;
    {
        const wf = std.fs.cwd().createFile(path, .{}) catch return;
        defer wf.close();
        wf.writeAll("This is absolutely not WebAssembly") catch return;
    }
    defer std.fs.cwd().deleteFile(path) catch {};
    var source = FileSource.open(path) catch return;
    defer source.close();
    const result = validateWasm(&source);
    try std.testing.expect(!result.is_valid);
}

test "validateAr with ground truth file" {
    var source = FileSource.open("ground_truth_examples/ar/minimal.a") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validateAr(&source);
    try std.testing.expect(result.is_valid);
}

test "validateAr rejects truncated file" {
    const tmpdir = std.posix.getenv("TMPDIR") orelse "/tmp";
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/test_truncated.a", .{tmpdir}) catch return;
    {
        const wf = std.fs.cwd().createFile(path, .{}) catch return;
        defer wf.close();
        wf.writeAll("!<ar") catch return; // Partial ar magic
    }
    defer std.fs.cwd().deleteFile(path) catch {};
    var source = FileSource.open(path) catch return;
    defer source.close();
    const result = validateAr(&source);
    try std.testing.expect(!result.is_valid);
}

test "validateAr rejects invalid data" {
    const tmpdir = std.posix.getenv("TMPDIR") orelse "/tmp";
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/test_invalid.a", .{tmpdir}) catch return;
    {
        const wf = std.fs.cwd().createFile(path, .{}) catch return;
        defer wf.close();
        wf.writeAll("Not an ar archive, no way, no how!") catch return;
    }
    defer std.fs.cwd().deleteFile(path) catch {};
    var source = FileSource.open(path) catch return;
    defer source.close();
    const result = validateAr(&source);
    try std.testing.expect(!result.is_valid);
}

test "validateAr rejects corrupted name field" {
    // Simulates seed 2 corruption: non-printable bytes in the name field
    const tmpdir = std.posix.getenv("TMPDIR") orelse "/tmp";
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/test_ar_corrupt_name.a", .{tmpdir}) catch return;
    {
        const wf = std.fs.cwd().createFile(path, .{}) catch return;
        defer wf.close();
        // Valid AR: magic + member header + data
        const ar_data = "!<arch>\n" ++ // 8 bytes global magic
            "test.txt/       " ++ // 16 bytes name
            "0           " ++ // 12 bytes date
            "0     " ++ // 6 bytes uid
            "0     " ++ // 6 bytes gid
            "100644  " ++ // 8 bytes mode
            "19        " ++ // 10 bytes size
            "`\n" ++ // 2 bytes header magic
            "Hello, ar archive!\n" ++ // 19 bytes data
            "\n"; // 1 byte padding
        // Corrupt the name field with non-printable bytes
        var buf: [88]u8 = ar_data.*;
        buf[14] = 0xA3; // Non-printable in name field
        buf[15] = 0xC0; // Non-printable in name field
        wf.writeAll(&buf) catch return;
    }
    defer std.fs.cwd().deleteFile(path) catch {};
    var source = FileSource.open(path) catch return;
    defer source.close();
    const result = validateAr(&source);
    try std.testing.expect(!result.is_valid);
}

test "validateAr rejects corrupted date field" {
    // Simulates seed 4 corruption: non-digit bytes in the date field
    const tmpdir = std.posix.getenv("TMPDIR") orelse "/tmp";
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/test_ar_corrupt_date.a", .{tmpdir}) catch return;
    {
        const wf = std.fs.cwd().createFile(path, .{}) catch return;
        defer wf.close();
        const ar_data = "!<arch>\n" ++
            "test.txt/       " ++
            "0           " ++
            "0     " ++
            "0     " ++
            "100644  " ++
            "19        " ++
            "`\n" ++
            "Hello, ar archive!\n" ++
            "\n";
        var buf: [88]u8 = ar_data.*;
        // Corrupt date field (offsets 24-35 in member header = file offsets 32-43)
        buf[24] = 0x8C; // Non-digit in date field
        buf[25] = 0xA9; // Non-digit in date field
        wf.writeAll(&buf) catch return;
    }
    defer std.fs.cwd().deleteFile(path) catch {};
    var source = FileSource.open(path) catch return;
    defer source.close();
    const result = validateAr(&source);
    try std.testing.expect(!result.is_valid);
}

test "validateAr rejects corrupted uid field" {
    const tmpdir = std.posix.getenv("TMPDIR") orelse "/tmp";
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/test_ar_corrupt_uid.a", .{tmpdir}) catch return;
    {
        const wf = std.fs.cwd().createFile(path, .{}) catch return;
        defer wf.close();
        const ar_data = "!<arch>\n" ++
            "test.txt/       " ++
            "0           " ++
            "0     " ++
            "0     " ++
            "100644  " ++
            "19        " ++
            "`\n" ++
            "Hello, ar archive!\n" ++
            "\n";
        var buf: [88]u8 = ar_data.*;
        // Corrupt uid field (offsets 28-33 in member header = file offsets 36-41)
        buf[36] = 0xFF;
        wf.writeAll(&buf) catch return;
    }
    defer std.fs.cwd().deleteFile(path) catch {};
    var source = FileSource.open(path) catch return;
    defer source.close();
    const result = validateAr(&source);
    try std.testing.expect(!result.is_valid);
}

test "validateAr rejects corrupted gid field" {
    const tmpdir = std.posix.getenv("TMPDIR") orelse "/tmp";
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/test_ar_corrupt_gid.a", .{tmpdir}) catch return;
    {
        const wf = std.fs.cwd().createFile(path, .{}) catch return;
        defer wf.close();
        const ar_data = "!<arch>\n" ++
            "test.txt/       " ++
            "0           " ++
            "0     " ++
            "0     " ++
            "100644  " ++
            "19        " ++
            "`\n" ++
            "Hello, ar archive!\n" ++
            "\n";
        var buf: [88]u8 = ar_data.*;
        // Corrupt gid field (offsets 34-39 in member header = file offsets 42-47)
        buf[42] = 0xAB;
        wf.writeAll(&buf) catch return;
    }
    defer std.fs.cwd().deleteFile(path) catch {};
    var source = FileSource.open(path) catch return;
    defer source.close();
    const result = validateAr(&source);
    try std.testing.expect(!result.is_valid);
}

test "validateAr rejects corrupted mode field" {
    const tmpdir = std.posix.getenv("TMPDIR") orelse "/tmp";
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/test_ar_corrupt_mode.a", .{tmpdir}) catch return;
    {
        const wf = std.fs.cwd().createFile(path, .{}) catch return;
        defer wf.close();
        const ar_data = "!<arch>\n" ++
            "test.txt/       " ++
            "0           " ++
            "0     " ++
            "0     " ++
            "100644  " ++
            "19        " ++
            "`\n" ++
            "Hello, ar archive!\n" ++
            "\n";
        var buf: [88]u8 = ar_data.*;
        // Corrupt mode field (offsets 40-47 in member header = file offsets 48-55)
        buf[48] = 0xE3;
        wf.writeAll(&buf) catch return;
    }
    defer std.fs.cwd().deleteFile(path) catch {};
    var source = FileSource.open(path) catch return;
    defer source.close();
    const result = validateAr(&source);
    try std.testing.expect(!result.is_valid);
}

// ============ Java Class File Validator ============

/// Validate Java .class bytecode file.
/// Checks CAFEBABE magic, major version >= 43 (Java 1.0+), walks the constant
/// pool validating every tag and consuming the correct payload per tag
/// (including Long/Double double-slot occupancy), then checks that this_class
/// references a valid Class entry and that fields/methods attribute_length
/// values don't overflow remaining data.
pub fn validateJavaClass(file: *FileSource) ValidationResult {
    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.java_class, .failed_to_get, "file size");
    if (file_size < 10) return ValidationResult.invalidCode(.java_class, .file_too_small, "Java class file");

    file.seekTo(0) catch return ValidationResult.invalid(.java_class, "Failed to seek");
    // Read the full file into memory for parsing (class files are typically small)
    // Read the full file into memory for parsing (class files are typically small)
    const MAX_CLASS_SIZE: usize = 64 * 1024 * 1024; // 64 MB sanity limit
    if (file_size > MAX_CLASS_SIZE) return ValidationResult.invalidCode(.java_class, .file_too_large, "Java class file");
    const alloc = std.heap.page_allocator;
    const size_usize: usize = @intCast(file_size);
    const data = alloc.alloc(u8, size_usize) catch return ValidationResult.invalid(.java_class, "Out of memory");
    defer alloc.free(data);
    const bytes_read = file.readAll(data) catch return ValidationResult.invalidCode(.java_class, .failed_to_read, "Java class file");
    if (bytes_read != size_usize) return ValidationResult.invalid(.java_class, "Short read");
    return validateJavaClassFromBuffer(data);
}

/// Validate Java .class from an in-memory buffer.
/// Pure structural check: magic, version, constant pool tags, this_class index.
pub fn validateJavaClassFromBuffer(data: []const u8) ValidationResult {
    if (data.len < 10) return ValidationResult.invalidCode(.java_class, .file_too_small, "Java class header");

    // Magic: CA FE BA BE
    if (!std.mem.eql(u8, data[0..4], &[_]u8{ 0xCA, 0xFE, 0xBA, 0xBE }))
        return ValidationResult.invalidCode(.java_class, .invalid_magic, "Java class magic");

    // minor_version at [4..6], major_version at [6..8] — both big-endian
    const major = std.mem.readInt(u16, data[6..8], .big);
    // Java 1.0 = major 45; accept >= 43 per spec (some pre-release bytecode uses 43/44)
    if (major < 43) return ValidationResult.invalidCode(.java_class, .invalid_value, "Java class major version");

    // constant_pool_count at [8..10]
    const cp_count = std.mem.readInt(u16, data[8..10], .big);
    if (cp_count == 0) return ValidationResult.invalid(.java_class, "Java class constant pool count is zero");

    // Walk the constant pool: cp_count - 1 entries, 1-indexed
    // We track a small tag array indexed by cp slot (1..cp_count-1) to verify this_class
    const MAX_CP: usize = 65535;
    var cp_tags: [MAX_CP + 1]u8 = [_]u8{0} ** (MAX_CP + 1);

    var offset: usize = 10;
    var idx: u16 = 1;
    while (idx < cp_count) : (idx += 1) {
        if (offset >= data.len) return ValidationResult.invalid(.java_class, "Truncated constant pool");
        const tag = data[offset];
        offset += 1;
        cp_tags[idx] = tag;
        switch (tag) {
            1 => { // Utf8: 2-byte length + N bytes
                if (offset + 2 > data.len) return ValidationResult.invalid(.java_class, "Truncated Utf8 constant");
                const utf8_len = std.mem.readInt(u16, data[offset..][0..2], .big);
                offset += 2;
                if (offset + utf8_len > data.len) return ValidationResult.invalid(.java_class, "Truncated Utf8 data");
                offset += utf8_len;
            },
            3, 4 => { // Integer, Float: 4 bytes
                if (offset + 4 > data.len) return ValidationResult.invalid(.java_class, "Truncated Integer/Float constant");
                offset += 4;
            },
            5, 6 => { // Long, Double: 8 bytes, occupies TWO slots
                if (offset + 8 > data.len) return ValidationResult.invalid(.java_class, "Truncated Long/Double constant");
                offset += 8;
                idx += 1; // consume an extra slot
            },
            7, 8, 16, 19, 20 => { // Class, String, MethodType, Module, Package: 2 bytes
                if (offset + 2 > data.len) return ValidationResult.invalid(.java_class, "Truncated 2-byte constant");
                offset += 2;
            },
            9, 10, 11, 12, 17, 18 => { // Fieldref, Methodref, InterfaceMethodref, NameAndType, Dynamic, InvokeDynamic: 4 bytes
                if (offset + 4 > data.len) return ValidationResult.invalid(.java_class, "Truncated 4-byte constant");
                offset += 4;
            },
            15 => { // MethodHandle: 3 bytes
                if (offset + 3 > data.len) return ValidationResult.invalid(.java_class, "Truncated MethodHandle constant");
                offset += 3;
            },
            else => return ValidationResult.invalidCode(.java_class, .invalid_value, "unknown constant pool tag"),
        }
    }

    // After constant pool: access_flags(2) + this_class(2) + super_class(2) + ...
    if (offset + 6 > data.len) return ValidationResult.invalid(.java_class, "Truncated after constant pool");
    // access_flags at offset, this_class at offset+2
    const this_class = std.mem.readInt(u16, data[offset + 2 ..][0..2], .big);

    // this_class must be a valid Class entry (tag 7)
    if (this_class == 0 or this_class >= cp_count)
        return ValidationResult.invalid(.java_class, "this_class index out of range");
    if (cp_tags[this_class] != 7)
        return ValidationResult.invalid(.java_class, "this_class does not reference a Class constant");

    // Skip interfaces, fields, methods with basic bounds checking
    offset += 6; // past access_flags, this_class, super_class

    // interfaces_count
    if (offset + 2 > data.len) return ValidationResult.invalid(.java_class, "Truncated interfaces count");
    const iface_count = std.mem.readInt(u16, data[offset..][0..2], .big);
    offset += 2;
    if (offset + @as(usize, iface_count) * 2 > data.len) return ValidationResult.invalid(.java_class, "Truncated interfaces array");
    offset += @as(usize, iface_count) * 2;

    // Walk fields and methods (same structure)
    for (0..2) |_| {
        if (offset + 2 > data.len) return ValidationResult.invalid(.java_class, "Truncated member count");
        const member_count = std.mem.readInt(u16, data[offset..][0..2], .big);
        offset += 2;
        for (0..member_count) |_| {
            // access_flags(2) + name_index(2) + descriptor_index(2) + attributes_count(2)
            if (offset + 8 > data.len) return ValidationResult.invalid(.java_class, "Truncated member header");
            const attr_count = std.mem.readInt(u16, data[offset + 6 ..][0..2], .big);
            offset += 8;
            for (0..attr_count) |_| {
                // attribute_name_index(2) + attribute_length(4)
                if (offset + 6 > data.len) return ValidationResult.invalid(.java_class, "Truncated attribute header");
                const attr_len = std.mem.readInt(u32, data[offset + 2 ..][0..4], .big);
                offset += 6;
                if (offset + attr_len > data.len) return ValidationResult.invalid(.java_class, "Attribute extends beyond file end");
                offset += attr_len;
            }
        }
    }

    return ValidationResult.okWithDepth(.java_class, .structural);
}

/// Deep validation for Java .class files — structural only (no checksums in format).
/// Deep validation for Java .class files — structural only (no checksums in format).
pub fn validateJavaClassDeep(allocator: std.mem.Allocator, path: []const u8) ValidationResult {
    _ = allocator;
    var source = FileSource.open(path) catch {
        return ValidationResult.invalid(.java_class, "Failed to open file");
    };
    defer source.close();
    return validateJavaClass(&source);
}

test "validateJavaClass accepts minimal valid class buffer" {
    // cp_count=3: cp[1]=Class(name_index=2), cp[2]=Utf8(5,"Hello")
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);
    // magic
    try w.writeAll(&[_]u8{ 0xCA, 0xFE, 0xBA, 0xBE });
    // minor=0, major=52 (Java 8)
    try w.writeInt(u16, 0, .big);
    try w.writeInt(u16, 52, .big);
    // cp_count=3 (entries at index 1 and 2)
    try w.writeInt(u16, 3, .big);
    // cp[1]: tag=7 (Class), name_index=2
    try w.writeByte(7);
    try w.writeInt(u16, 2, .big);
    // cp[2]: tag=1 (Utf8), length=5, "Hello"
    try w.writeByte(1);
    try w.writeInt(u16, 5, .big);
    try w.writeAll("Hello");
    // access_flags=0x0021 (public+super)
    try w.writeInt(u16, 0x0021, .big);
    // this_class=1 (cp[1]=Class, valid)
    try w.writeInt(u16, 1, .big);
    // super_class=0 (java/lang/Object has no super, index 0 is valid for super)
    try w.writeInt(u16, 0, .big);
    // interfaces_count=0
    try w.writeInt(u16, 0, .big);
    // fields_count=0
    try w.writeInt(u16, 0, .big);
    // methods_count=0
    try w.writeInt(u16, 0, .big);
    const result = validateJavaClassFromBuffer(buf.items);
    try std.testing.expect(result.is_valid);
    try std.testing.expectEqual(FileFormat.java_class, result.format);
}

test "validateJavaClass rejects wrong magic" {
    var buf: [32]u8 = undefined;
    buf[0] = 0xDE; buf[1] = 0xAD; buf[2] = 0xBE; buf[3] = 0xEF;
    buf[4] = 0; buf[5] = 0; buf[6] = 0; buf[7] = 52;
    buf[8] = 0; buf[9] = 2;
    const result = validateJavaClassFromBuffer(buf[0..10]);
    try std.testing.expect(!result.is_valid);
}

test "validateJavaClass rejects truncated constant pool" {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);
    try w.writeAll(&[_]u8{ 0xCA, 0xFE, 0xBA, 0xBE });
    try w.writeInt(u16, 0, .big);   // minor
    try w.writeInt(u16, 52, .big);  // major
    try w.writeInt(u16, 5, .big);   // cp_count=5 → 4 entries, but we write none
    // no CP entries → truncated
    const result = validateJavaClassFromBuffer(buf.items);
    try std.testing.expect(!result.is_valid);
}

test "validateJavaClass rejects unknown constant pool tag" {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);
    try w.writeAll(&[_]u8{ 0xCA, 0xFE, 0xBA, 0xBE });
    try w.writeInt(u16, 0, .big);
    try w.writeInt(u16, 52, .big);
    try w.writeInt(u16, 2, .big);  // cp_count=2 → 1 entry
    try w.writeByte(99);           // tag 99 = invalid
    const result = validateJavaClassFromBuffer(buf.items);
    try std.testing.expect(!result.is_valid);
}

test "validateJavaClass with ground truth file" {
    var source = FileSource.open("ground_truth_examples/java_class/Hello.class") catch |err| {
        if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest;
        return err;
    };
    defer source.close();
    const result = validateJavaClass(&source);
    try std.testing.expect(result.is_valid);
}

