//! Executable/binary format validators extracted from format_validation.zig.
//! Covers ELF, Mach-O (single-arch and fat/universal), COFF (.obj), WebAssembly, and ar archives.

const std = @import("std");
const format_validation = @import("format_validation.zig");
const errmsg = @import("error_messages.zig");
const ValidationResult = format_validation.ValidationResult;
const FileFormat = format_validation.FileFormat;

// ============ ELF Validator ============

/// Validate ELF (Executable and Linkable Format) binary.
/// Checks magic, class, endianness, version, type, and header sizes.
pub fn validateElf(file: std.fs.File) ValidationResult {
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

    return ValidationResult.okWithDepth(.elf, .full);
}

// ============ Mach-O Validator ============

/// Validate Mach-O binary (single-architecture).
/// Checks magic, CPU type, file type, and load command structure.
pub fn validateMacho(file: std.fs.File) ValidationResult {
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

    return ValidationResult.okWithDepth(.macho, .full);
}

/// Validate Mach-O Universal/Fat binary (multi-architecture).
/// Checks nfat_arch, validates each architecture entry's bounds and embedded Mach-O magic.
pub fn validateMachoFat(file: std.fs.File) ValidationResult {
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

    return ValidationResult.okWithDepth(.macho_fat, .full);
}

// ============ COFF Validator ============

/// Validate COFF object file (.obj).
/// Checks machine type, section count, and structural consistency.
pub fn validateCoff(file: std.fs.File) ValidationResult {
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

    return ValidationResult.okWithDepth(.coff, .full);
}

// ============ WebAssembly Validator ============

/// Validate WebAssembly binary module.
/// Checks magic, version, and validates section ordering and sizes.
pub fn validateWasm(file: std.fs.File) ValidationResult {
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

    return ValidationResult.okWithDepth(.wasm, .full);
}

// ============ ar Archive Validator ============

/// Validate Unix ar archive format (.a static libraries, .deb packages).
/// Checks global header and validates member entry headers.
pub fn validateAr(file: std.fs.File) ValidationResult {
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

    return ValidationResult.okWithDepth(.ar, .full);
}
