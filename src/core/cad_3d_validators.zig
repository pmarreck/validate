//! 3D model and CAD format validators extracted from format_validation.zig.
//! Covers DWG, DXF, Blender, STEP, STL, OBJ, PLY, glTF, and GLB.

const std = @import("std");
const heap = @import("heap.zig");
const Allocator = std.mem.Allocator;
const file_source = @import("file_source.zig");
const FileSource = file_source.FileSource;
const format_validation = @import("format_validation.zig");
const errmsg = @import("error_messages.zig");
const archive_validators = @import("archive_validators.zig");
const ValidationResult = format_validation.ValidationResult;
const FileFormat = format_validation.FileFormat;

const FormatValidator = format_validation.FormatValidator;
const detectFormat = format_validation.detectFormat;
const ValidationDepth = format_validation.ValidationDepth;

// ============ Helper Functions ============

/// Check if a byte is an ASCII digit.
fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// Check if IEEE 754 float bits represent NaN or Infinity.
fn isInvalidFloat(bits: u32) bool {
    const exponent = (bits >> 23) & 0xFF;
    // Exponent of 255 means NaN or Infinity
    return exponent == 255;
}

/// Parse and validate a triple of floating-point numbers from a string.
fn parseStlFloatTriple(s: []const u8) bool {
    const trimmed = std.mem.trim(u8, s, " \t");
    var parts = std.mem.tokenizeAny(u8, trimmed, " \t");

    var count: usize = 0;
    while (parts.next()) |part| {
        // Validate each part is a valid float
        _ = std.fmt.parseFloat(f32, part) catch return false;
        count += 1;
    }

    return count == 3;
}

/// Count the number of valid floats in a space-separated string.
/// Returns 0 if any token is not a valid float.
fn countAndValidateFloats(s: []const u8) usize {
    const trimmed = std.mem.trim(u8, s, " \t");
    if (trimmed.len == 0) return 0;

    var parts = std.mem.tokenizeAny(u8, trimmed, " \t");
    var count: usize = 0;

    while (parts.next()) |part| {
        _ = std.fmt.parseFloat(f64, part) catch return 0;
        count += 1;
    }

    return count;
}

// ============ DWG Validator ============

pub fn validateDwg(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.dwg, .failed_to_seek, "to start");

    var header: [12]u8 = undefined;
    const bytes_read = file.read(&header) catch {
        return ValidationResult.invalidCode(.dwg, .failed_to_read, "DWG header");
    };

    if (bytes_read < 6) {
        return ValidationResult.invalidCode(.dwg, .file_too_small, "DWG format");
    }

    // Check for "AC" magic at start
    if (header[0] != 'A' or header[1] != 'C') {
        return ValidationResult.invalidCodeMsg(.dwg, .invalid_signature_expected, "DWG", errmsg.invalidSignatureExpected("DWG", "AC"));
    }

    // Verify version code format: should be "AC10xx" where xx are digits
    // Known versions: AC1009 (R11), AC1012 (R13), AC1014 (R14), AC1015 (2000),
    // AC1018 (2004), AC1021 (2007), AC1024 (2010), AC1027 (2013), AC1032 (2018)
    if (header[2] != '1' or header[3] != '0') {
        return ValidationResult.invalidCode(.dwg, .invalid_value, "DWG version code");
    }

    // Check that bytes 4-5 are digits (version suffix)
    if (!isDigit(header[4]) or !isDigit(header[5])) {
        return ValidationResult.invalidCode(.dwg, .invalid_value, "DWG version format");
    }

    // DWG is proprietary binary - structural validation only
    return ValidationResult.structuralOnly(.dwg);
}

pub fn validateDwgDeep(allocator: Allocator, source: *FileSource) ValidationResult {
    _ = allocator;
    const file = source;

    // Basic validation first
    const result = validateDwg(file);
    if (!result.is_valid) return result;

    // Get file size for bounds checking
    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCode(.dwg, .failed_to_get, "file size");
    };

    // Minimum DWG file size (header + some data)
    if (file_size < 0x80) {
        return ValidationResult.invalidCode(.dwg, .file_too_small, "valid DWG");
    }

    // Read extended header for version-specific validation
    file.seekTo(0) catch return ValidationResult.structuralOnly(.dwg);

    var header: [128]u8 = undefined;
    const bytes_read = file.read(&header) catch return ValidationResult.structuralOnly(.dwg);
    if (bytes_read < 128) return ValidationResult.structuralOnly(.dwg);

    // Get version for version-specific checks
    const version_num: u16 = (@as(u16, header[4] - '0') * 10) + (header[5] - '0');

    // For AC1015 (R2000) and later: validate section page map sentinel
    // DWG R2000+ has more structured sections we can validate
    if (version_num >= 15) {
        // Byte 6 should be maintenance release version (small number)
        if (header[6] > 50) {
            return ValidationResult.okWithDepthAndWarning(.dwg, .structural, "Unexpected maintenance version");
        }

        // Bytes 7-9 should be 0x00 padding or small values
        // Bytes 0x0D-0x1B contain codepage and other metadata

        // For R2004+ (AC1018+), check for encrypted header flag at offset 0x0C
        if (version_num >= 18) {
            // If encrypted, we can only do structural validation
            // Byte at 0x0C: bit 0 = encrypted
            const is_encrypted = (header[0x0C] & 0x01) != 0;
            if (is_encrypted) {
                return ValidationResult.okWithDepthAndWarning(.dwg, .structural, "Encrypted DWG - limited validation");
            }
        }

        // Validate section locator records (R2004+)
        // Section locators start at offset 0x20 for uncompressed R2004+ files
        if (version_num >= 18 and !((header[0x0C] & 0x01) != 0)) {
            // Read number of section locator records
            const num_records = std.mem.readInt(i32, header[0x18..0x1C], .little);
            if (num_records < 0 or num_records > 1000) {
                return ValidationResult.okWithDepthAndWarning(.dwg, .structural, "Invalid section record count");
            }
        }
    }

    // Validate that file doesn't end abruptly in header area
    // DWG files should have data sections after header
    if (file_size < 512) {
        return ValidationResult.okWithDepthAndWarning(.dwg, .structural, "Unusually small DWG file");
    }

    // Successfully validated DWG structure
    return ValidationResult.structuralOnly(.dwg);
}

// ============ Blender Validator ============

pub fn validateBlend(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.blend, .failed_to_seek, "to start");

    var header: [12]u8 = undefined;
    const bytes_read = file.read(&header) catch {
        return ValidationResult.invalidCode(.blend, .failed_to_read, "Blender header");
    };

    if (bytes_read < 12) {
        return ValidationResult.invalidCode(.blend, .file_too_small, "Blender format");
    }

    // Check for "BLENDER" magic (7 bytes)
    if (!std.mem.eql(u8, header[0..7], "BLENDER")) {
        return ValidationResult.invalidCode(.blend, .invalid_signature, "Blender");
    }

    // Check pointer size: '_' (0x5F) = 32-bit, '-' (0x2D) = 64-bit
    if (header[7] != '_' and header[7] != '-') {
        return ValidationResult.invalidCode(.blend, .invalid_value, "pointer size indicator");
    }

    // Check endianness: 'v' (0x76) = little-endian, 'V' (0x56) = big-endian
    if (header[8] != 'v' and header[8] != 'V') {
        return ValidationResult.invalidCode(.blend, .invalid_value, "endianness indicator");
    }

    // Check version: 3 ASCII digits (e.g., "254" for 2.54, "280" for 2.80)
    if (!isDigit(header[9]) or !isDigit(header[10]) or !isDigit(header[11])) {
        return ValidationResult.invalidCode(.blend, .invalid_value, "version number");
    }

    // Blender's DNA system means structure is self-describing
    // Full validation would require parsing all blocks and verifying DNA1
    return ValidationResult.ok(.blend);
}

pub fn validateBlendDeep(allocator: Allocator, source: *FileSource) ValidationResult {
    const file = source;

    // First do structural validation
    const structural_result = validateBlend(file);
    if (!structural_result.is_valid) return structural_result;

    // Reset to start
    file.seekTo(0) catch return ValidationResult.invalidCode(.blend, .failed_to_seek, "in Blender file");

    var header: [12]u8 = undefined;
    _ = file.read(&header) catch return ValidationResult.invalidCode(.blend, .failed_to_read, "header");

    // Determine pointer size for block header parsing
    const pointer_size: u8 = if (header[7] == '-') 8 else 4;
    const endian: std.builtin.Endian = if (header[8] == 'v') .little else .big;

    // Calculate block header size (code[4] + size[4] + old_pointer[4 or 8] + sdna_index[4] + count[4])
    const block_header_size: usize = 4 + 4 + pointer_size + 4 + 4;

    // Scan through file blocks looking for DNA1 and ENDB
    var found_endb = false;
    var found_dna1 = false;
    var dna_fully_valid = false;
    var block_count: usize = 0;
    const max_blocks: usize = 1000000; // Sanity limit

    var block_header_buf = allocator.alloc(u8, block_header_size) catch {
        return ValidationResult.invalidCode(.blend, .failed_to_allocate, "block header buffer");
    };
    defer allocator.free(block_header_buf);

    while (block_count < max_blocks) {
        const read_bytes = file.read(block_header_buf) catch break;
        if (read_bytes < block_header_size) break;

        // Get block code (first 4 bytes)
        const code = block_header_buf[0..4];

        // Get block data size (bytes 4-8)
        const data_size = std.mem.readInt(u32, block_header_buf[4..8], endian);

        // Check for end block
        if (std.mem.eql(u8, code, "ENDB")) {
            found_endb = true;
            break;
        }

        // Check for DNA1 block - contains the schema
        if (std.mem.eql(u8, code, "DNA1")) {
            found_dna1 = true;

            // Read entire DNA1 block for full validation
            if (data_size > 0 and data_size < 50 * 1024 * 1024) { // Cap at 50MB
                const dna_data = allocator.alloc(u8, data_size) catch {
                    file.seekBy(@intCast(data_size)) catch break;
                    block_count += 1;
                    continue;
                };
                defer allocator.free(dna_data);

                const dna_read = file.readAll(dna_data) catch {
                    block_count += 1;
                    continue;
                };

                if (dna_read == data_size) {
                    // Full DNA1 block parsing
                    dna_fully_valid = validateDNA1Block(dna_data, endian);
                }
            } else {
                file.seekBy(@intCast(data_size)) catch break;
            }
        } else {
            // Skip block data
            file.seekBy(@intCast(data_size)) catch break;
        }
        block_count += 1;
    }

    if (!found_endb) {
        return ValidationResult.invalidCode(.blend, .missing, "ENDB terminator block");
    }

    if (!found_dna1) {
        return ValidationResult.invalidCode(.blend, .missing, "DNA1 schema block");
    }

    if (!dna_fully_valid) {
        return ValidationResult.invalidCode(.blend, .invalid_value, "DNA1 block structure");
    }

    // Successfully validated: header + DNA1 full schema + ENDB terminator
    // No checksums in Blend format — structural validation only
    return ValidationResult.okWithDepth(.blend, .structural);
}

/// Validate the DNA1 block structure in a Blender file.
pub fn validateDNA1Block(data: []const u8, endian: std.builtin.Endian) bool {
    if (data.len < 12) return false;

    var pos: usize = 0;

    // Check SDNA identifier
    if (!std.mem.eql(u8, data[pos..][0..4], "SDNA")) return false;
    pos += 4;

    // NAME section
    if (pos + 8 > data.len) return false;
    if (!std.mem.eql(u8, data[pos..][0..4], "NAME")) return false;
    pos += 4;

    const name_count = std.mem.readInt(u32, data[pos..][0..4], endian);
    pos += 4;

    if (name_count == 0 or name_count > 100000) return false;

    // Skip name strings (null-terminated)
    var names_read: u32 = 0;
    while (names_read < name_count and pos < data.len) {
        // Find null terminator
        while (pos < data.len and data[pos] != 0) {
            pos += 1;
        }
        if (pos >= data.len) return false;
        pos += 1; // Skip null
        names_read += 1;
    }

    if (names_read < name_count) return false;

    // Align to 4-byte boundary
    pos = (pos + 3) & ~@as(usize, 3);

    // TYPE section
    if (pos + 8 > data.len) return false;
    if (!std.mem.eql(u8, data[pos..][0..4], "TYPE")) return false;
    pos += 4;

    const type_count = std.mem.readInt(u32, data[pos..][0..4], endian);
    pos += 4;

    if (type_count == 0 or type_count > 100000) return false;

    // Skip type names (null-terminated)
    var types_read: u32 = 0;
    while (types_read < type_count and pos < data.len) {
        while (pos < data.len and data[pos] != 0) {
            pos += 1;
        }
        if (pos >= data.len) return false;
        pos += 1;
        types_read += 1;
    }

    if (types_read < type_count) return false;

    // Align to 4-byte boundary
    pos = (pos + 3) & ~@as(usize, 3);

    // TLEN section (type lengths)
    if (pos + 4 > data.len) return false;
    if (!std.mem.eql(u8, data[pos..][0..4], "TLEN")) return false;
    pos += 4;

    // Type lengths are 2 bytes each
    const tlen_size = type_count * 2;
    if (pos + tlen_size > data.len) return false;
    pos += tlen_size;

    // Align to 4-byte boundary
    pos = (pos + 3) & ~@as(usize, 3);

    // STRC section (structures)
    if (pos + 8 > data.len) return false;
    if (!std.mem.eql(u8, data[pos..][0..4], "STRC")) return false;
    pos += 4;

    const struct_count = std.mem.readInt(u32, data[pos..][0..4], endian);
    pos += 4;

    if (struct_count > 100000) return false;

    // Validate structure entries
    var structs_read: u32 = 0;
    while (structs_read < struct_count and pos + 4 <= data.len) {
        // Structure: type_index (2) + field_count (2)
        const field_count = std.mem.readInt(u16, data[pos + 2 ..][0..2], endian);
        pos += 4;

        // Each field: type_index (2) + name_index (2)
        const field_size: usize = @as(usize, field_count) * 4;
        if (pos + field_size > data.len) return false;
        pos += field_size;

        structs_read += 1;
    }

    if (structs_read < struct_count) return false;

    // All DNA1 components validated
    return true;
}

// ============ DXF Validator ============

pub fn validateDxf(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.dxf, .failed_to_seek, "to start");

    var header: [256]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalidCode(.dxf, .failed_to_read, "DXF header");

    if (header_read < 10) {
        return ValidationResult.invalidCode(.dxf, .file_too_small, "DXF");
    }

    const content = header[0..header_read];

    // Binary DXF starts with "AutoCAD Binary DXF"
    if (content.len >= 18 and std.mem.eql(u8, content[0..18], "AutoCAD Binary DXF")) {
        return ValidationResult.ok(.dxf);
    }

    // Text DXF: skip whitespace, then look for "0" followed by newline and "SECTION"
    var i: usize = 0;
    while (i < content.len and (content[i] == ' ' or content[i] == '\t' or content[i] == '\r')) : (i += 1) {}

    if (i < content.len and content[i] == '0') {
        i += 1;
        // Skip to newline
        while (i < content.len and content[i] != '\n') : (i += 1) {}
        if (i < content.len) i += 1; // Skip newline
        // Skip whitespace
        while (i < content.len and (content[i] == ' ' or content[i] == '\t' or content[i] == '\r')) : (i += 1) {}
        // Check for SECTION
        if (i + 7 <= content.len and std.mem.eql(u8, content[i..][0..7], "SECTION")) {
            return ValidationResult.ok(.dxf);
        }
    }

    return ValidationResult.invalid(.dxf, "Not a valid DXF file");
}

// ============ STEP Validator ============

pub fn validateStep(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.step, .failed_to_seek, "to start");

    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.step, .failed_to_get, "file size");
    if (file_size > 500 * 1024 * 1024) {
        // Very large STEP file - use chunked validation
        return validateStepChunked(file, file_size);
    }

    // Read entire file
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const slurp_step = file.getMappedOrSlurp(allocator, 64 << 20) catch
        return ValidationResult.invalidCode(.step, .failed_to_read, "file");
    var h1: ?[]u8 = null;
    defer if (h1) |b| allocator.free(b);
    const content: []const u8 = switch (slurp_step) {
        .mapped => |m| m,
        .heap => |b| blk: { h1 = b; break :blk b; },
        .too_large => return ValidationResult.invalid(.step, "STEP too large for non-mmap deep validation"),
    };

    return parseStepContent(content);
}

fn parseStepContent(content: []const u8) ValidationResult {
    if (content.len < 13) {
        return ValidationResult.invalidCode(.step, .file_too_small, "STEP");
    }

    // Check for ISO-10303-21 signature
    if (!std.mem.eql(u8, content[0..13], "ISO-10303-21;")) {
        return ValidationResult.invalidCode(.step, .invalid_signature, "STEP");
    }

    // Required sections in order: HEADER, DATA (one or more), END-ISO-10303-21
    var has_header = false;
    var has_data = false;
    var has_end = false;
    var in_header = false;
    var in_data = false;
    var entity_count: usize = 0;
    var paren_depth: i32 = 0;
    var in_string = false;

    var i: usize = 13;
    while (i < content.len) {
        const c = content[i];

        // Handle string literals (can contain anything)
        if (c == '\'') {
            if (!in_string) {
                in_string = true;
            } else if (i + 1 < content.len and content[i + 1] == '\'') {
                // Escaped quote
                i += 2;
                continue;
            } else {
                in_string = false;
            }
            i += 1;
            continue;
        }

        if (in_string) {
            i += 1;
            continue;
        }

        // Track parentheses for entity validation
        if (c == '(') {
            paren_depth += 1;
        } else if (c == ')') {
            paren_depth -= 1;
            if (paren_depth < 0) {
                return ValidationResult.invalid(.step, "Unmatched closing parenthesis");
            }
        }

        // Look for keywords
        if (c == 'H' and i + 6 <= content.len and std.mem.eql(u8, content[i..][0..6], "HEADER")) {
            if (has_header) {
                return ValidationResult.invalid(.step, "Duplicate HEADER section");
            }
            has_header = true;
            in_header = true;
            in_data = false;
        } else if (c == 'E' and i + 9 <= content.len and std.mem.eql(u8, content[i..][0..9], "ENDSEC;")) {
            in_header = false;
            in_data = false;
        } else if (c == 'D' and i + 4 <= content.len and std.mem.eql(u8, content[i..][0..4], "DATA")) {
            if (!has_header) {
                return ValidationResult.invalid(.step, "DATA before HEADER");
            }
            has_data = true;
            in_header = false;
            in_data = true;
        } else if (c == 'E' and i + 17 <= content.len and std.mem.eql(u8, content[i..][0..17], "END-ISO-10303-21;")) {
            if (!has_data) {
                return ValidationResult.invalid(.step, "END-ISO without DATA");
            }
            has_end = true;
            break;
        }

        // Count entities in DATA section (lines starting with #number)
        if (in_data and c == '#') {
            // Verify it's followed by digits
            var j = i + 1;
            while (j < content.len and content[j] >= '0' and content[j] <= '9') {
                j += 1;
            }
            if (j > i + 1) {
                entity_count += 1;
            }
        }

        i += 1;
    }

    if (!has_header) {
        return ValidationResult.invalidCode(.step, .missing, "HEADER section");
    }
    if (!has_data) {
        return ValidationResult.invalidCode(.step, .missing, "DATA section");
    }
    if (!has_end) {
        return ValidationResult.invalidCode(.step, .missing, "END-ISO-10303-21");
    }
    if (paren_depth != 0) {
        return ValidationResult.invalid(.step, "Unmatched parentheses");
    }

    return ValidationResult.okWithDepth(.step, .structural);
}

pub fn validateStepChunked(file: *FileSource, file_size: u64) ValidationResult {
    const chunk_size: usize = 64 * 1024;
    var buffer: [chunk_size]u8 = undefined;
    var position: u64 = 0;
    var has_header = false;
    var has_data = false;
    var has_end = false;

    file.seekTo(0) catch return ValidationResult.invalidCode(.step, .failed_to_seek, "in STEP file");

    // Check signature first
    var sig_buf: [13]u8 = undefined;
    _ = file.read(&sig_buf) catch return ValidationResult.invalidCode(.step, .failed_to_read, "STEP signature");
    if (!std.mem.eql(u8, &sig_buf, "ISO-10303-21;")) {
        return ValidationResult.invalidCode(.step, .invalid_signature, "STEP");
    }

    file.seekTo(0) catch return ValidationResult.invalidCode(.step, .failed_to_seek, "in STEP file");

    while (position < file_size) {
        const bytes_read = file.read(&buffer) catch {
            return ValidationResult.invalidCode(.step, .failed_to_read, "chunk");
        };
        if (bytes_read == 0) break;

        const chunk = buffer[0..bytes_read];

        // Look for section markers
        if (std.mem.indexOf(u8, chunk, "HEADER") != null) {
            has_header = true;
        }
        if (std.mem.indexOf(u8, chunk, "DATA") != null) {
            has_data = true;
        }
        if (std.mem.indexOf(u8, chunk, "END-ISO-10303-21;") != null) {
            has_end = true;
        }

        position += bytes_read;
    }

    if (!has_header) {
        return ValidationResult.invalidCode(.step, .missing, "HEADER section");
    }
    if (!has_data) {
        return ValidationResult.invalidCode(.step, .missing, "DATA section");
    }
    if (!has_end) {
        return ValidationResult.invalidCode(.step, .missing, "END-ISO-10303-21");
    }

    return ValidationResult.okWithDepth(.step, .structural);
}

// ============ STL Validator ============

pub fn validateStl(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.stl, .failed_to_seek, "to start");

    var header: [84]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalidCode(.stl, .failed_to_read, "STL header");

    if (header_read < 6) {
        return ValidationResult.invalidCode(.stl, .file_too_small, "STL");
    }

    // Check if ASCII STL (starts with "solid ")
    if (std.mem.eql(u8, header[0..6], "solid ")) {
        // Verify it's actually ASCII STL by looking for "facet" keyword
        file.seekTo(0) catch return ValidationResult.invalidCode(.stl, .failed_to_seek, "in STL file");
        var peek_buffer: [1024]u8 = undefined;
        const peek_read = file.read(&peek_buffer) catch return ValidationResult.invalidCode(.stl, .failed_to_read, "STL data");
        const peek_content = peek_buffer[0..peek_read];

        if (std.mem.indexOf(u8, peek_content, "facet") != null) {
            // ASCII STL - full decode
            return validateStlAscii(file);
        }
        // Could be binary STL that happens to start with "solid"
    }

    // Binary STL: 80-byte header + 4-byte triangle count + triangles
    if (header_read >= 84) {
        return validateStlBinary(file, header);
    }

    return ValidationResult.invalidCode(.stl, .invalid_value, "STL format");
}

pub fn validateStlAscii(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.stl, .failed_to_seek, "to start");

    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.stl, .failed_to_get, "file size");
    if (file_size > 500 * 1024 * 1024) {
        // For very large files (>500MB), do chunked validation
        return validateStlAsciiChunked(file, file_size);
    }

    // Read entire file for parsing
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const slurp_stl = file.getMappedOrSlurp(allocator, 256 << 20) catch
        return ValidationResult.invalidCode(.stl, .failed_to_read, "file");
    var h2: ?[]u8 = null;
    defer if (h2) |b| allocator.free(b);
    const content: []const u8 = switch (slurp_stl) {
        .mapped => |m| m,
        .heap => |b| blk: { h2 = b; break :blk b; },
        .too_large => return ValidationResult.invalid(.stl, "STL too large for non-mmap deep validation"),
    };

    return parseStlAsciiContent(content);
}

fn parseStlAsciiContent(content: []const u8) ValidationResult {
    var facet_count: usize = 0;
    var in_facet = false;
    var vertex_count: usize = 0;
    var found_solid = false;
    var found_endsolid = false;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        if (std.mem.startsWith(u8, trimmed, "solid")) {
            if (found_solid and !found_endsolid) {
                return ValidationResult.invalid(.stl, "Nested solid without endsolid");
            }
            found_solid = true;
            found_endsolid = false;
        } else if (std.mem.startsWith(u8, trimmed, "endsolid")) {
            if (!found_solid) {
                return ValidationResult.invalid(.stl, "endsolid without solid");
            }
            found_endsolid = true;
        } else if (std.mem.startsWith(u8, trimmed, "facet normal")) {
            if (in_facet) {
                return ValidationResult.invalid(.stl, "Nested facet");
            }
            in_facet = true;
            vertex_count = 0;
            // Parse normal vector (3 floats)
            const normal_part = trimmed[12..]; // Skip "facet normal"
            if (!parseStlFloatTriple(normal_part)) {
                return ValidationResult.invalidCode(.stl, .invalid_value, "facet normal");
            }
        } else if (std.mem.startsWith(u8, trimmed, "endfacet")) {
            if (!in_facet) {
                return ValidationResult.invalid(.stl, "endfacet without facet");
            }
            if (vertex_count != 3) {
                return ValidationResult.invalid(.stl, "Facet must have exactly 3 vertices");
            }
            in_facet = false;
            facet_count += 1;
        } else if (std.mem.startsWith(u8, trimmed, "vertex")) {
            if (!in_facet) {
                return ValidationResult.invalid(.stl, "vertex outside facet");
            }
            // Parse vertex coordinates (3 floats)
            const vertex_part = trimmed[6..]; // Skip "vertex"
            if (!parseStlFloatTriple(vertex_part)) {
                return ValidationResult.invalidCode(.stl, .invalid_value, "vertex coordinates");
            }
            vertex_count += 1;
            if (vertex_count > 3) {
                return ValidationResult.invalidCode(.stl, .too_many, "vertices in facet");
            }
        } else if (std.mem.startsWith(u8, trimmed, "outer loop") or
            std.mem.startsWith(u8, trimmed, "endloop"))
        {
            // Valid structural keywords, continue
        } else if (trimmed[0] != '#') {
            // Unknown keyword (not a comment)
            // Be lenient - some exporters add extra data
        }
    }

    if (in_facet) {
        return ValidationResult.invalid(.stl, "Unclosed facet");
    }
    if (found_solid and !found_endsolid) {
        return ValidationResult.invalidCode(.stl, .missing, "endsolid");
    }
    if (!found_solid) {
        return ValidationResult.invalidCode(.stl, .missing, "solid declaration");
    }

    return ValidationResult.okWithDepth(.stl, .full);
}

pub fn validateStlAsciiChunked(file: *FileSource, file_size: u64) ValidationResult {
    // For huge ASCII files, read in chunks and validate structure
    const chunk_size: usize = 64 * 1024; // 64KB chunks
    var buffer: [chunk_size]u8 = undefined;
    var position: u64 = 0;
    var facet_count: usize = 0;
    var found_solid = false;
    var found_endsolid = false;

    file.seekTo(0) catch return ValidationResult.invalidCode(.stl, .failed_to_seek, "in STL file");

    while (position < file_size) {
        const bytes_read = file.read(&buffer) catch {
            return ValidationResult.invalidCode(.stl, .failed_to_read, "chunk");
        };
        if (bytes_read == 0) break;

        const chunk = buffer[0..bytes_read];

        // Count structural keywords
        var i: usize = 0;
        while (i < chunk.len) {
            if (i + 5 <= chunk.len and std.mem.eql(u8, chunk[i..][0..5], "solid")) {
                found_solid = true;
            } else if (i + 8 <= chunk.len and std.mem.eql(u8, chunk[i..][0..8], "endsolid")) {
                found_endsolid = true;
            } else if (i + 5 <= chunk.len and std.mem.eql(u8, chunk[i..][0..5], "facet")) {
                facet_count += 1;
            }
            i += 1;
        }

        position += bytes_read;
    }

    if (!found_solid) {
        return ValidationResult.invalidCode(.stl, .missing, "solid declaration");
    }
    if (!found_endsolid) {
        return ValidationResult.invalidCode(.stl, .missing, "endsolid");
    }
    if (facet_count == 0) {
        return ValidationResult.okWithWarning(.stl, errmsg.empty("STL (no facets)"));
    }

    return ValidationResult.okWithDepth(.stl, .full);
}

pub fn validateStlBinary(file: *FileSource, header: [84]u8) ValidationResult {
    const triangle_count = std.mem.readInt(u32, header[80..84], .little);

    // Each triangle is 50 bytes: normal (12) + v1 (12) + v2 (12) + v3 (12) + attr (2)
    const expected_size: u64 = 84 + @as(u64, triangle_count) * 50;
    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.stl, .failed_to_get, "file size");

    if (file_size < expected_size) {
        return ValidationResult.invalid(.stl, "File truncated");
    }

    if (triangle_count == 0) {
        return ValidationResult.okWithDepth(.stl, .full);
    }

    // Validate triangles by reading them all
    file.seekTo(84) catch return ValidationResult.invalidCode(.stl, .failed_to_seek, "past header");

    var triangle_buffer: [50]u8 = undefined;
    var triangles_read: u32 = 0;

    while (triangles_read < triangle_count) {
        const bytes_read = file.read(&triangle_buffer) catch {
            return ValidationResult.invalidCode(.stl, .failed_to_read, "triangle");
        };
        if (bytes_read < 50) {
            return ValidationResult.invalidCode(.stl, .truncated, "triangle data");
        }

        // Parse and validate floats (check for NaN/Inf which indicate corruption)
        // Normal vector
        const nx = std.mem.readInt(u32, triangle_buffer[0..4], .little);
        const ny = std.mem.readInt(u32, triangle_buffer[4..8], .little);
        const nz = std.mem.readInt(u32, triangle_buffer[8..12], .little);

        if (isInvalidFloat(nx) or isInvalidFloat(ny) or isInvalidFloat(nz)) {
            return ValidationResult.invalidCode(.stl, .invalid_value, "normal vector (NaN/Inf)");
        }

        // Vertex 1
        const v1x = std.mem.readInt(u32, triangle_buffer[12..16], .little);
        const v1y = std.mem.readInt(u32, triangle_buffer[16..20], .little);
        const v1z = std.mem.readInt(u32, triangle_buffer[20..24], .little);

        if (isInvalidFloat(v1x) or isInvalidFloat(v1y) or isInvalidFloat(v1z)) {
            return ValidationResult.invalidCode(.stl, .invalid_value, "vertex 1 (NaN/Inf)");
        }

        // Vertex 2
        const v2x = std.mem.readInt(u32, triangle_buffer[24..28], .little);
        const v2y = std.mem.readInt(u32, triangle_buffer[28..32], .little);
        const v2z = std.mem.readInt(u32, triangle_buffer[32..36], .little);

        if (isInvalidFloat(v2x) or isInvalidFloat(v2y) or isInvalidFloat(v2z)) {
            return ValidationResult.invalidCode(.stl, .invalid_value, "vertex 2 (NaN/Inf)");
        }

        // Vertex 3
        const v3x = std.mem.readInt(u32, triangle_buffer[36..40], .little);
        const v3y = std.mem.readInt(u32, triangle_buffer[40..44], .little);
        const v3z = std.mem.readInt(u32, triangle_buffer[44..48], .little);

        if (isInvalidFloat(v3x) or isInvalidFloat(v3y) or isInvalidFloat(v3z)) {
            return ValidationResult.invalidCode(.stl, .invalid_value, "vertex 3 (NaN/Inf)");
        }

        // Attribute byte count (2 bytes) - usually 0, but some software uses it
        // No validation needed, any value is technically valid

        triangles_read += 1;
    }

    return ValidationResult.okWithDepth(.stl, .full);
}

// ============ OBJ Validator ============

pub fn validateObj(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.obj, .failed_to_seek, "to start");

    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.obj, .failed_to_get, "file size");
    if (file_size > 500 * 1024 * 1024) {
        // For very large files, use chunked validation
        return validateObjChunked(file, file_size);
    }

    // Read entire file
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const slurp_obj = file.getMappedOrSlurp(allocator, 256 << 20) catch
        return ValidationResult.invalidCode(.obj, .failed_to_read, "file");
    var h3: ?[]u8 = null;
    defer if (h3) |b| allocator.free(b);
    const content: []const u8 = switch (slurp_obj) {
        .mapped => |m| m,
        .heap => |b| blk: { h3 = b; break :blk b; },
        .too_large => return ValidationResult.invalid(.obj, "OBJ too large for non-mmap deep validation"),
    };

    return parseObjContent(content);
}

fn parseObjContent(content: []const u8) ValidationResult {
    var vertex_count: usize = 0;
    var texcoord_count: usize = 0;
    var normal_count: usize = 0;
    var face_count: usize = 0;
    var has_obj_directive = false;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        // Skip comments
        if (trimmed[0] == '#') {
            has_obj_directive = true;
            continue;
        }

        if (trimmed.len < 2) continue;

        // Vertex position: v x y z [w]
        if (trimmed[0] == 'v' and trimmed[1] == ' ') {
            const coords = trimmed[2..];
            const float_count = countAndValidateFloats(coords);
            if (float_count < 3 or float_count > 4) {
                return ValidationResult.invalidCode(.obj, .invalid_value, "vertex coordinates");
            }
            vertex_count += 1;
            has_obj_directive = true;
        }
        // Texture coordinate: vt u [v] [w]
        else if (std.mem.startsWith(u8, trimmed, "vt ")) {
            const coords = trimmed[3..];
            const float_count = countAndValidateFloats(coords);
            if (float_count < 1 or float_count > 3) {
                return ValidationResult.invalidCode(.obj, .invalid_value, "texture coordinate");
            }
            texcoord_count += 1;
            has_obj_directive = true;
        }
        // Vertex normal: vn x y z
        else if (std.mem.startsWith(u8, trimmed, "vn ")) {
            const coords = trimmed[3..];
            const float_count = countAndValidateFloats(coords);
            if (float_count != 3) {
                return ValidationResult.invalidCode(.obj, .invalid_value, "vertex normal");
            }
            normal_count += 1;
            has_obj_directive = true;
        }
        // Face: f v1[/vt1][/vn1] v2[/vt2][/vn2] v3[/vt3][/vn3] ...
        else if (trimmed[0] == 'f' and trimmed[1] == ' ') {
            const face_data = trimmed[2..];
            const result = validateObjFace(face_data, vertex_count, texcoord_count, normal_count);
            if (!result.valid) {
                return ValidationResult.invalid(.obj, result.message);
            }
            face_count += 1;
            has_obj_directive = true;
        }
        // Other valid directives
        else if (std.mem.startsWith(u8, trimmed, "g ") or
            std.mem.startsWith(u8, trimmed, "o ") or
            std.mem.startsWith(u8, trimmed, "s ") or
            std.mem.startsWith(u8, trimmed, "mtllib ") or
            std.mem.startsWith(u8, trimmed, "usemtl ") or
            std.mem.startsWith(u8, trimmed, "l ") or // Line element
            std.mem.startsWith(u8, trimmed, "p ")) // Point element
        {
            has_obj_directive = true;
        }
    }

    if (!has_obj_directive) {
        return ValidationResult.invalidCode(.obj, .no_valid_x_found, "OBJ directives");
    }

    if (vertex_count == 0) {
        return ValidationResult.invalid(.obj, "No vertices found");
    }

    return ValidationResult.okWithDepth(.obj, .structural);
}

pub const ObjFaceResult = struct {
    valid: bool,
    message: []const u8,
};

pub fn validateObjFace(face_data: []const u8, vertex_count: usize, texcoord_count: usize, normal_count: usize) ObjFaceResult {
    const trimmed = std.mem.trim(u8, face_data, " \t");
    if (trimmed.len == 0) {
        return .{ .valid = false, .message = errmsg.empty("face definition") };
    }

    var parts = std.mem.tokenizeAny(u8, trimmed, " \t");
    var face_vertex_count: usize = 0;

    while (parts.next()) |part| {
        // Each part is v[/vt][/vn] or v//vn or v/vt/vn or v/vt
        var indices = std.mem.splitScalar(u8, part, '/');

        // Vertex index (required)
        const v_str = indices.next() orelse return .{ .valid = false, .message = errmsg.missing("vertex index") };
        if (v_str.len > 0) {
            const v_idx = std.fmt.parseInt(i32, v_str, 10) catch {
                return .{ .valid = false, .message = "Invalid vertex index" };
            };
            // OBJ indices are 1-based, can be negative (relative)
            if (v_idx == 0) {
                return .{ .valid = false, .message = "Zero vertex index not allowed" };
            }
            const abs_idx: usize = if (v_idx > 0) @intCast(v_idx) else blk: {
                const neg: usize = @intCast(-v_idx);
                if (neg > vertex_count) break :blk 0;
                break :blk vertex_count - neg + 1;
            };
            if (abs_idx > vertex_count) {
                return .{ .valid = false, .message = "Vertex index out of range" };
            }
        }

        // Texture coordinate index (optional)
        if (indices.next()) |vt_str| {
            if (vt_str.len > 0) {
                const vt_idx = std.fmt.parseInt(i32, vt_str, 10) catch {
                    return .{ .valid = false, .message = "Invalid texture coordinate index" };
                };
                if (vt_idx != 0 and texcoord_count > 0) {
                    const abs_idx: usize = if (vt_idx > 0) @intCast(vt_idx) else blk: {
                        const neg: usize = @intCast(-vt_idx);
                        if (neg > texcoord_count) break :blk 0;
                        break :blk texcoord_count - neg + 1;
                    };
                    if (abs_idx > texcoord_count) {
                        return .{ .valid = false, .message = "Texture coordinate index out of range" };
                    }
                }
            }
        }

        // Normal index (optional)
        if (indices.next()) |vn_str| {
            if (vn_str.len > 0) {
                const vn_idx = std.fmt.parseInt(i32, vn_str, 10) catch {
                    return .{ .valid = false, .message = "Invalid normal index" };
                };
                if (vn_idx != 0 and normal_count > 0) {
                    const abs_idx: usize = if (vn_idx > 0) @intCast(vn_idx) else blk: {
                        const neg: usize = @intCast(-vn_idx);
                        if (neg > normal_count) break :blk 0;
                        break :blk normal_count - neg + 1;
                    };
                    if (abs_idx > normal_count) {
                        return .{ .valid = false, .message = "Normal index out of range" };
                    }
                }
            }
        }

        face_vertex_count += 1;
    }

    if (face_vertex_count < 3) {
        return .{ .valid = false, .message = "Face must have at least 3 vertices" };
    }

    return .{ .valid = true, .message = "" };
}

pub fn validateObjChunked(file: *FileSource, file_size: u64) ValidationResult {
    const chunk_size: usize = 64 * 1024;
    var buffer: [chunk_size]u8 = undefined;
    var position: u64 = 0;
    var vertex_count: usize = 0;
    var face_count: usize = 0;
    var has_obj_directive = false;

    file.seekTo(0) catch return ValidationResult.invalidCode(.obj, .failed_to_seek, "in OBJ file");

    while (position < file_size) {
        const bytes_read = file.read(&buffer) catch {
            return ValidationResult.invalidCode(.obj, .failed_to_read, "chunk");
        };
        if (bytes_read == 0) break;

        const chunk = buffer[0..bytes_read];

        // Count directives (simple heuristic for large files)
        var i: usize = 0;
        while (i < chunk.len) {
            // Look for "v " at line start (preceded by newline or at position 0)
            if (i + 2 <= chunk.len and chunk[i] == 'v' and chunk[i + 1] == ' ') {
                if (i == 0 or chunk[i - 1] == '\n') {
                    vertex_count += 1;
                    has_obj_directive = true;
                }
            }
            // Look for "f " at line start
            if (i + 2 <= chunk.len and chunk[i] == 'f' and chunk[i + 1] == ' ') {
                if (i == 0 or chunk[i - 1] == '\n') {
                    face_count += 1;
                    has_obj_directive = true;
                }
            }
            i += 1;
        }

        position += bytes_read;
    }

    if (!has_obj_directive) {
        return ValidationResult.invalidCode(.obj, .no_valid_x_found, "OBJ directives");
    }
    if (vertex_count == 0) {
        return ValidationResult.invalid(.obj, "No vertices found");
    }

    return ValidationResult.okWithDepth(.obj, .structural);
}

pub fn validateObjDeep(allocator: Allocator, source: *FileSource) ValidationResult {
    _ = allocator;
    return validateObj(source);
}

// ============ PLY Validator ============

pub const PlyFormat = enum {
    ascii,
    binary_little_endian,
    binary_big_endian,
};

/// PLY property scalar types with their byte sizes.
pub const PlyPropType = enum {
    char_t, // 1 byte signed
    uchar_t, // 1 byte unsigned
    short_t, // 2 bytes signed
    ushort_t, // 2 bytes unsigned
    int_t, // 4 bytes signed
    uint_t, // 4 bytes unsigned
    float_t, // 4 bytes IEEE 754
    double_t, // 8 bytes IEEE 754

    pub fn byteSize(self: PlyPropType) usize {
        return switch (self) {
            .char_t, .uchar_t => 1,
            .short_t, .ushort_t => 2,
            .int_t, .uint_t, .float_t => 4,
            .double_t => 8,
        };
    }

    pub fn isFloat(self: PlyPropType) bool {
        return self == .float_t or self == .double_t;
    }

    pub fn fromString(s: []const u8) ?PlyPropType {
        if (std.mem.eql(u8, s, "float") or std.mem.eql(u8, s, "float32")) return .float_t;
        if (std.mem.eql(u8, s, "double") or std.mem.eql(u8, s, "float64")) return .double_t;
        if (std.mem.eql(u8, s, "char") or std.mem.eql(u8, s, "int8")) return .char_t;
        if (std.mem.eql(u8, s, "uchar") or std.mem.eql(u8, s, "uint8")) return .uchar_t;
        if (std.mem.eql(u8, s, "short") or std.mem.eql(u8, s, "int16")) return .short_t;
        if (std.mem.eql(u8, s, "ushort") or std.mem.eql(u8, s, "uint16")) return .ushort_t;
        if (std.mem.eql(u8, s, "int") or std.mem.eql(u8, s, "int32")) return .int_t;
        if (std.mem.eql(u8, s, "uint") or std.mem.eql(u8, s, "uint32")) return .uint_t;
        return null;
    }
};

const MAX_PLY_PROPS = 64;

/// Face list property info for binary PLY validation.
const PlyFaceListInfo = struct {
    count_type: PlyPropType,
    elem_type: PlyPropType,
};

pub fn validatePly(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.ply, .failed_to_seek, "to start");

    // Read header (up to 64KB - headers can be large with many properties)
    const header_buf = heap.validateAllocator().alloc(u8, 65536) catch {
        return ValidationResult.invalidCode(.ply, .out_of_memory, "header buffer");
    };
    defer heap.validateAllocator().free(header_buf);
    const header_read = file.read(header_buf) catch return ValidationResult.invalidCode(.ply, .failed_to_read, "header");
    if (header_read < 4) {
        return ValidationResult.invalidCode(.ply, .file_too_small, "PLY");
    }

    const header_content = header_buf[0..header_read];

    // PLY must start with "ply" followed by newline
    if (!std.mem.startsWith(u8, header_content, "ply\n") and !std.mem.startsWith(u8, header_content, "ply\r\n")) {
        return ValidationResult.invalidCode(.ply, .missing, "PLY magic");
    }

    // Parse header
    var format: ?PlyFormat = null;
    var vertex_count: usize = 0;
    var face_count: usize = 0;
    var header_end_offset: usize = 0;
    var vertex_property_count: usize = 0;
    var in_vertex_element = false;
    var in_face_element = false;

    // Track vertex property types for binary validation
    var vertex_prop_types: [MAX_PLY_PROPS]PlyPropType = undefined;
    var face_list_info: ?PlyFaceListInfo = null;

    var lines = std.mem.splitScalar(u8, header_content, '\n');
    var line_offset: usize = 0;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        line_offset += line.len + 1; // +1 for newline

        if (std.mem.startsWith(u8, trimmed, "format ")) {
            if (std.mem.indexOf(u8, trimmed, "ascii") != null) {
                format = .ascii;
            } else if (std.mem.indexOf(u8, trimmed, "binary_little_endian") != null) {
                format = .binary_little_endian;
            } else if (std.mem.indexOf(u8, trimmed, "binary_big_endian") != null) {
                format = .binary_big_endian;
            } else {
                return ValidationResult.invalidCode(.ply, .unknown_element, "PLY format");
            }
        } else if (std.mem.startsWith(u8, trimmed, "element vertex ")) {
            const count_str = trimmed[15..];
            vertex_count = std.fmt.parseInt(usize, std.mem.trim(u8, count_str, " \t"), 10) catch {
                return ValidationResult.invalidCode(.ply, .invalid_value, "vertex count");
            };
            in_vertex_element = true;
            in_face_element = false;
        } else if (std.mem.startsWith(u8, trimmed, "element face ")) {
            const count_str = trimmed[13..];
            face_count = std.fmt.parseInt(usize, std.mem.trim(u8, count_str, " \t"), 10) catch {
                return ValidationResult.invalidCode(.ply, .invalid_value, "face count");
            };
            in_vertex_element = false;
            in_face_element = true;
        } else if (std.mem.startsWith(u8, trimmed, "element ")) {
            in_vertex_element = false;
            in_face_element = false;
        } else if (std.mem.startsWith(u8, trimmed, "property list ")) {
            // "property list <count_type> <elem_type> <name>"
            if (in_face_element) {
                var parts = std.mem.tokenizeAny(u8, trimmed, " \t");
                _ = parts.next(); // "property"
                _ = parts.next(); // "list"
                const ct_str = parts.next() orelse continue;
                const et_str = parts.next() orelse continue;
                const ct = PlyPropType.fromString(ct_str) orelse continue;
                const et = PlyPropType.fromString(et_str) orelse continue;
                face_list_info = .{ .count_type = ct, .elem_type = et };
            }
        } else if (std.mem.startsWith(u8, trimmed, "property ")) {
            if (in_vertex_element) {
                if (vertex_property_count < MAX_PLY_PROPS) {
                    // "property <type> <name>"
                    var parts = std.mem.tokenizeAny(u8, trimmed, " \t");
                    _ = parts.next(); // "property"
                    const type_str = parts.next();
                    if (type_str) |ts| {
                        vertex_prop_types[vertex_property_count] = PlyPropType.fromString(ts) orelse .float_t;
                    }
                }
                vertex_property_count += 1;
            }
        } else if (std.mem.eql(u8, trimmed, "end_header")) {
            header_end_offset = line_offset;
            break;
        }
    }

    if (format == null) {
        return ValidationResult.invalidCode(.ply, .missing, "format declaration");
    }
    if (header_end_offset == 0) {
        return ValidationResult.invalidCode(.ply, .missing, "end_header");
    }

    // Now validate the data section
    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.ply, .failed_to_get, "file size");
    const data_size = file_size - header_end_offset;

    if (format.? == .ascii) {
        return validatePlyAsciiData(file, header_end_offset, vertex_count, face_count, vertex_property_count);
    } else {
        const prop_count = @min(vertex_property_count, MAX_PLY_PROPS);
        return validatePlyBinaryData(file, header_end_offset, data_size, vertex_count, prop_count, format.?, vertex_prop_types[0..prop_count], face_count, face_list_info);
    }
}

pub fn validatePlyAsciiData(file: *FileSource, header_end: usize, vertex_count: usize, face_count: usize, vertex_prop_count: usize) ValidationResult {
    file.seekTo(header_end) catch return ValidationResult.invalidCode(.ply, .failed_to_seek, "to data");

    // For large files, validate a sample
    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.ply, .failed_to_get, "size");
    if (file_size > 100 * 1024 * 1024) {
        // Just validate structure for very large ASCII files
        return validatePlyAsciiSample(file, vertex_count, face_count);
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const data_size = file_size - header_end;
    const data = allocator.alloc(u8, @intCast(data_size)) catch {
        return ValidationResult.invalidCode(.ply, .out_of_memory, "for PLY");
    };
    defer allocator.free(data);

    file.seekTo(header_end) catch return ValidationResult.invalidCode(.ply, .failed_to_seek, "in PLY file");
    _ = file.readAll(data) catch return ValidationResult.invalidCode(.ply, .failed_to_read, "data");

    var lines = std.mem.splitScalar(u8, data, '\n');
    var vertices_parsed: usize = 0;
    var faces_parsed: usize = 0;

    // Parse vertices
    while (vertices_parsed < vertex_count) {
        const line = lines.next() orelse return ValidationResult.invalidCode(.ply, .truncated, "vertex data");
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        // Count floats/ints in the line
        var parts = std.mem.tokenizeAny(u8, trimmed, " \t");
        var prop_count: usize = 0;
        while (parts.next()) |part| {
            // Try parsing as float (covers int too)
            _ = std.fmt.parseFloat(f64, part) catch {
                return ValidationResult.invalidCode(.ply, .invalid_value, "vertex data");
            };
            prop_count += 1;
        }
        if (prop_count != vertex_prop_count) {
            return ValidationResult.invalidCode(.ply, .incomplete, "vertex data");
        }
        vertices_parsed += 1;
    }

    // Parse faces
    while (faces_parsed < face_count) {
        const line = lines.next() orelse return ValidationResult.invalidCode(.ply, .truncated, "face data");
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        var parts = std.mem.tokenizeAny(u8, trimmed, " \t");

        // First number is vertex count for this face
        const count_str = parts.next() orelse return ValidationResult.invalidCode(.ply, .missing, "face vertex count");
        const face_vertex_count = std.fmt.parseInt(usize, count_str, 10) catch {
            return ValidationResult.invalidCode(.ply, .invalid_value, "face vertex count");
        };

        if (face_vertex_count < 3) {
            return ValidationResult.invalid(.ply, "Face must have at least 3 vertices");
        }

        // Validate vertex indices
        var idx_count: usize = 0;
        while (parts.next()) |idx_str| {
            const idx = std.fmt.parseInt(usize, idx_str, 10) catch {
                return ValidationResult.invalidCode(.ply, .invalid_value, "face vertex index");
            };
            if (idx >= vertex_count) {
                return ValidationResult.invalid(.ply, "Face vertex index out of range");
            }
            idx_count += 1;
        }

        if (idx_count < face_vertex_count) {
            return ValidationResult.invalid(.ply, "Face has fewer indices than declared");
        }

        faces_parsed += 1;
    }

    return ValidationResult.okWithDepth(.ply, .full);
}

pub fn validatePlyAsciiSample(file: *FileSource, vertex_count: usize, face_count: usize) ValidationResult {
    _ = vertex_count;
    _ = face_count;
    // Read first and last chunks, verify structure
    var buffer: [8192]u8 = undefined;
    const bytes_read = file.read(&buffer) catch return ValidationResult.invalidCode(.ply, .failed_to_read, "PLY data");

    // Check that data looks like numbers
    var has_numbers = false;
    for (buffer[0..bytes_read]) |c| {
        if (c >= '0' and c <= '9') {
            has_numbers = true;
            break;
        }
    }

    if (!has_numbers) {
        return ValidationResult.invalid(.ply, "No numeric data found");
    }

    return ValidationResult.okWithDepth(.ply, .structural);
}

/// Validate binary PLY data by parsing vertex properties (checking floats for
/// NaN/Inf) and face vertex indices (checking range). Property types are extracted
/// from the header by validatePly and passed here for type-aware parsing.
pub fn validatePlyBinaryData(
    file: *FileSource,
    header_end: usize,
    data_size: u64,
    vertex_count: usize,
    vertex_prop_count: usize,
    format: PlyFormat,
    vertex_prop_types: []const PlyPropType,
    face_count: usize,
    face_list_info: ?PlyFaceListInfo,
) ValidationResult {
    file.seekTo(header_end) catch return ValidationResult.invalidCode(.ply, .failed_to_seek, "to data");

    // Compute vertex stride from declared property types
    var vertex_stride: usize = 0;
    var has_float_props = false;
    for (vertex_prop_types) |pt| {
        vertex_stride += pt.byteSize();
        if (pt.isFloat()) has_float_props = true;
    }
    if (vertex_stride == 0) vertex_stride = if (vertex_prop_count >= 3) vertex_prop_count * 4 else 12;

    const expected_vertex_data = vertex_count * vertex_stride;
    if (data_size < expected_vertex_data) {
        return ValidationResult.invalid(.ply, "Insufficient data for vertices");
    }

    const endian: std.builtin.Endian = if (format == .binary_big_endian) .big else .little;

    // Read all vertex data (cap at 256MB to avoid excessive memory use)
    const vertex_data_size = @min(expected_vertex_data, 256 * 1024 * 1024);
    if (vertex_data_size > 0 and has_float_props) {
        // Validate float properties for NaN/Inf in streaming chunks
        var remaining = expected_vertex_data;
        // Process in row-aligned chunks
        const rows_per_chunk = @max(1, (64 * 1024) / vertex_stride);
        const chunk_bytes = rows_per_chunk * vertex_stride;
        var buf: [256 * 1024]u8 = undefined;

        while (remaining > 0) {
            const to_read = @min(@min(remaining, chunk_bytes), buf.len);
            // Align to vertex stride
            const aligned_read = (to_read / vertex_stride) * vertex_stride;
            if (aligned_read == 0) break;

            const bytes_read = file.readAll(buf[0..aligned_read]) catch {
                return ValidationResult.invalidCode(.ply, .failed_to_read, "vertex data");
            };
            if (bytes_read < aligned_read) {
                return ValidationResult.invalidCode(.ply, .truncated, "vertex data");
            }

            // Check each vertex's float properties
            var row_offset: usize = 0;
            while (row_offset + vertex_stride <= bytes_read) : (row_offset += vertex_stride) {
                var prop_offset: usize = 0;
                for (vertex_prop_types) |pt| {
                    const sz = pt.byteSize();
                    if (pt == .float_t) {
                        const val: f32 = @bitCast(std.mem.readInt(u32, buf[row_offset + prop_offset ..][0..4], endian));
                        if (std.math.isNan(val) or std.math.isInf(val)) {
                            return ValidationResult.invalidWithDepth(.ply, "NaN/Inf in binary vertex float (corruption)", .full);
                        }
                    } else if (pt == .double_t) {
                        const val: f64 = @bitCast(std.mem.readInt(u64, buf[row_offset + prop_offset ..][0..8], endian));
                        if (std.math.isNan(val) or std.math.isInf(val)) {
                            return ValidationResult.invalidWithDepth(.ply, "NaN/Inf in binary vertex double (corruption)", .full);
                        }
                    }
                    prop_offset += sz;
                }
            }

            remaining -= bytes_read;
        }
    } else {
        // No float properties — just skip vertex data
        file.seekTo(header_end + expected_vertex_data) catch {
            return ValidationResult.invalidCode(.ply, .failed_to_seek, "past vertices");
        };
    }

    // Validate face vertex indices (if face element with list property exists)
    if (face_count > 0 and face_list_info != null) {
        const fli = face_list_info.?;
        const count_sz = fli.count_type.byteSize();
        const elem_sz = fli.elem_type.byteSize();
        var face_buf: [1024]u8 = undefined;

        var faces_checked: usize = 0;
        while (faces_checked < face_count) : (faces_checked += 1) {
            // Read count byte(s)
            if (file.readAll(face_buf[0..count_sz]) catch null) |n| {
                if (n < count_sz) break;
            } else break;

            const n_verts: usize = switch (fli.count_type) {
                .uchar_t => face_buf[0],
                .ushort_t => std.mem.readInt(u16, face_buf[0..2], endian),
                .uint_t => @intCast(std.mem.readInt(u32, face_buf[0..4], endian)),
                .int_t => @intCast(@max(0, std.mem.readInt(i32, face_buf[0..4], endian))),
                else => face_buf[0],
            };

            if (n_verts < 3 or n_verts > 256) {
                return ValidationResult.invalid(.ply, "Invalid face vertex count in binary data");
            }

            // Read and validate vertex indices
            const idx_bytes = n_verts * elem_sz;
            if (idx_bytes > face_buf.len) break; // face too large for buffer
            if (file.readAll(face_buf[0..idx_bytes]) catch null) |n| {
                if (n < idx_bytes) break;
            } else break;

            var j: usize = 0;
            while (j < n_verts) : (j += 1) {
                const idx: usize = switch (fli.elem_type) {
                    .uint_t => @intCast(std.mem.readInt(u32, face_buf[j * 4 ..][0..4], endian)),
                    .int_t => @intCast(@max(0, std.mem.readInt(i32, face_buf[j * 4 ..][0..4], endian))),
                    .ushort_t => std.mem.readInt(u16, face_buf[j * 2 ..][0..2], endian),
                    .uchar_t => face_buf[j],
                    else => @intCast(std.mem.readInt(u32, face_buf[j * elem_sz ..][0..4], endian)),
                };
                if (idx >= vertex_count) {
                    return ValidationResult.invalidWithDepth(.ply, "Face vertex index out of range", .full);
                }
            }
        }
    }

    return ValidationResult.okWithDepth(.ply, .full);
}

// ============ glTF Validator ============

pub fn validateGltf(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.gltf, .failed_to_seek, "to start");

    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.gltf, .failed_to_get, "file size");
    if (file_size > 100 * 1024 * 1024) {
        // Very large glTF - do structural validation only
        return validateGltfStructural(file);
    }

    // Read entire file
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const slurp_gltf = file.getMappedOrSlurp(allocator, 64 << 20) catch
        return ValidationResult.invalidCode(.gltf, .failed_to_read, "file");
    var h4: ?[]u8 = null;
    defer if (h4) |b| allocator.free(b);
    const content: []const u8 = switch (slurp_gltf) {
        .mapped => |m| m,
        .heap => |b| blk: { h4 = b; break :blk b; },
        .too_large => return ValidationResult.invalid(.gltf, "glTF too large for non-mmap deep validation"),
    };

    return parseGltfJson(content);
}

fn parseGltfJson(content: []const u8) ValidationResult {
    // Skip leading whitespace
    var start: usize = 0;
    while (start < content.len and (content[start] == ' ' or content[start] == '\t' or content[start] == '\n' or content[start] == '\r')) {
        start += 1;
    }

    if (start >= content.len or content[start] != '{') {
        return ValidationResult.invalid(.gltf, "Not valid JSON");
    }

    // Validate JSON structure by tracking braces/brackets and checking byte validity
    var brace_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var in_string = false;
    var escape_next = false;
    var has_asset = false;
    var has_version = false;
    const data = content[start..];

    var i: usize = 0;
    while (i < data.len) {
        const c = data[i];

        if (escape_next) {
            escape_next = false;
            i += 1;
            continue;
        }

        if (c == '\\' and in_string) {
            escape_next = true;
            i += 1;
            continue;
        }

        if (c == '"') {
            in_string = !in_string;
            i += 1;
            continue;
        }

        if (in_string) {
            // Inside strings: validate UTF-8 encoding for high bytes
            if (c >= 0x80) {
                const utf8_len = std.unicode.utf8ByteSequenceLength(c) catch {
                    return ValidationResult.invalid(.gltf, "Invalid UTF-8 byte in JSON string");
                };
                if (i + utf8_len > data.len) {
                    return ValidationResult.invalid(.gltf, "Truncated UTF-8 sequence in JSON string");
                }
                // Validate continuation bytes
                var j: usize = 1;
                while (j < utf8_len) : (j += 1) {
                    if (data[i + j] & 0xC0 != 0x80) {
                        return ValidationResult.invalid(.gltf, "Invalid UTF-8 continuation byte in JSON string");
                    }
                }
                i += utf8_len;
                continue;
            }
            // Bare control chars (except \t) are invalid in JSON strings
            if (c < 0x20 and c != '\t') {
                return ValidationResult.invalid(.gltf, "Control character in JSON string");
            }
            i += 1;
            continue;
        }

        // Outside strings: only ASCII printable chars and whitespace are valid in JSON
        if (c > 0x7E) {
            return ValidationResult.invalid(.gltf, "Non-ASCII byte outside JSON string");
        }

        switch (c) {
            '{' => brace_depth += 1,
            '}' => {
                brace_depth -= 1;
                if (brace_depth < 0) {
                    return ValidationResult.invalid(.gltf, "Unmatched closing brace");
                }
            },
            '[' => bracket_depth += 1,
            ']' => {
                bracket_depth -= 1;
                if (bracket_depth < 0) {
                    return ValidationResult.invalid(.gltf, "Unmatched closing bracket");
                }
            },
            else => {},
        }
        i += 1;
    }

    if (brace_depth != 0) {
        return ValidationResult.invalid(.gltf, "Unclosed brace");
    }
    if (bracket_depth != 0) {
        return ValidationResult.invalid(.gltf, "Unclosed bracket");
    }
    if (in_string) {
        return ValidationResult.invalid(.gltf, "Unclosed string");
    }

    // Check for required glTF fields
    if (std.mem.indexOf(u8, content, "\"asset\"") != null) {
        has_asset = true;
    }
    if (std.mem.indexOf(u8, content, "\"version\"") != null) {
        has_version = true;
    }

    if (!has_asset) {
        return ValidationResult.invalidCode(.gltf, .missing, "required 'asset' field");
    }
    if (!has_version) {
        return ValidationResult.invalidCode(.gltf, .missing, "required 'version' field");
    }

    // Count and validate array indices for common fields
    const has_meshes = std.mem.indexOf(u8, content, "\"meshes\"") != null;
    const has_nodes = std.mem.indexOf(u8, content, "\"nodes\"") != null;
    const has_scenes = std.mem.indexOf(u8, content, "\"scenes\"") != null;
    const has_accessors = std.mem.indexOf(u8, content, "\"accessors\"") != null;
    const has_bufferViews = std.mem.indexOf(u8, content, "\"bufferViews\"") != null;
    const has_buffers = std.mem.indexOf(u8, content, "\"buffers\"") != null;

    // If file has geometry data, validate that supporting structures exist
    if (has_meshes) {
        if (!has_accessors or !has_bufferViews or !has_buffers) {
            return ValidationResult.okWithWarning(.gltf, "Mesh without complete buffer chain");
        }
    }

    _ = has_nodes;
    _ = has_scenes;

    return ValidationResult.okWithDepth(.gltf, .structural);
}

pub fn validateGltfStructural(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.gltf, .failed_to_seek, "in glTF file");

    var buffer: [8192]u8 = undefined;
    const bytes_read = file.read(&buffer) catch return ValidationResult.invalidCode(.gltf, .failed_to_read, "glTF data");
    const content = buffer[0..bytes_read];

    // Check basic structure
    var start: usize = 0;
    while (start < content.len and (content[start] == ' ' or content[start] == '\t' or content[start] == '\n' or content[start] == '\r')) {
        start += 1;
    }

    if (start >= content.len or content[start] != '{') {
        return ValidationResult.invalid(.gltf, "Not valid JSON");
    }

    if (std.mem.indexOf(u8, content, "\"asset\"") == null) {
        return ValidationResult.invalidCode(.gltf, .missing, "'asset' field");
    }

    return ValidationResult.okWithDepth(.gltf, .structural);
}

// ============ GLB Validator ============

pub fn validateGlb(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.glb, .failed_to_seek, "to start");

    var header: [12]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalidCode(.glb, .failed_to_read, "header");
    if (header_read < 12) {
        return ValidationResult.invalidCode(.glb, .file_too_small, "GLB");
    }

    // GLB header: magic (4) + version (4) + length (4)
    if (!std.mem.eql(u8, header[0..4], "glTF")) {
        return ValidationResult.invalidCode(.glb, .invalid_value, "GLB magic");
    }

    const version = std.mem.readInt(u32, header[4..8], .little);
    if (version != 2 and version != 1) {
        return ValidationResult.invalidCode(.glb, .unsupported, "GLB version");
    }

    const total_length = std.mem.readInt(u32, header[8..12], .little);
    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.glb, .failed_to_get, "file size");

    if (total_length > file_size) {
        return ValidationResult.invalidCodeMsg(.glb, .exceeds_bounds, "GLB length", "GLB length exceeds file size");
    }

    // Parse chunks
    var position: u64 = 12;
    var chunk_count: usize = 0;
    var json_validated = false;

    while (position + 8 <= total_length) {
        // Read chunk header: length (4) + type (4)
        var chunk_header: [8]u8 = undefined;
        file.seekTo(position) catch return ValidationResult.invalidCode(.glb, .failed_to_seek, "to chunk");
        const chunk_header_read = file.read(&chunk_header) catch return ValidationResult.invalidCode(.glb, .failed_to_read, "chunk header");
        if (chunk_header_read < 8) {
            return ValidationResult.invalidCode(.glb, .truncated, "chunk header");
        }

        const chunk_length = std.mem.readInt(u32, chunk_header[0..4], .little);
        const chunk_type = std.mem.readInt(u32, chunk_header[4..8], .little);

        if (position + 8 + chunk_length > total_length) {
            return ValidationResult.invalid(.glb, "Chunk extends beyond file");
        }

        // Validate chunk based on type
        // JSON chunk: 0x4E4F534A ("JSON" in little-endian)
        // BIN chunk: 0x004E4942 ("BIN\0" in little-endian)
        if (chunk_type == 0x4E4F534A) {
            // JSON chunk - validate content
            if (chunk_count != 0) {
                return ValidationResult.invalid(.glb, "JSON chunk must be first");
            }
            const json_result = validateGlbJsonChunk(file, position + 8, chunk_length);
            if (!json_result.is_valid) {
                return json_result;
            }
            json_validated = true;
        } else if (chunk_type == 0x004E4942) {
            // BIN chunk - validate by reading all data
            const bin_result = validateGlbBinChunk(file, position + 8, chunk_length);
            if (!bin_result.is_valid) {
                return bin_result;
            }
        }
        // Unknown chunk types are allowed per spec

        position += 8 + chunk_length;
        // Chunks are padded to 4-byte boundaries
        position = (position + 3) & ~@as(u64, 3);
        chunk_count += 1;
    }

    if (!json_validated) {
        return ValidationResult.invalidCode(.glb, .missing, "JSON chunk");
    }

    if (version == 1) {
        return ValidationResult.okWithDepthAndWarning(.glb, .structural, "GLB version 1 (deprecated)");
    }

    return ValidationResult.okWithDepth(.glb, .structural);
}

pub fn validateGlbJsonChunk(file: *FileSource, offset: u64, length: u32) ValidationResult {
    if (length > 100 * 1024 * 1024) {
        // Very large JSON - just read to verify accessibility
        return validateGlbChunkReadable(file, offset, length);
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const json_data = allocator.alloc(u8, length) catch {
        return ValidationResult.invalidCode(.glb, .out_of_memory, "for JSON");
    };
    defer allocator.free(json_data);

    file.seekTo(offset) catch return ValidationResult.invalidCode(.glb, .failed_to_seek, "to JSON");
    const read_len = file.readAll(json_data) catch return ValidationResult.invalidCode(.glb, .failed_to_read, "JSON");

    if (read_len < length) {
        return ValidationResult.invalidCode(.glb, .truncated, "JSON chunk");
    }

    // Validate JSON structure
    return parseGltfJson(json_data);
}

pub fn validateGlbBinChunk(file: *FileSource, offset: u64, length: u32) ValidationResult {
    return validateGlbChunkReadable(file, offset, length);
}

pub fn validateGlbChunkReadable(file: *FileSource, offset: u64, length: u32) ValidationResult {
    file.seekTo(offset) catch return ValidationResult.invalidCode(.glb, .failed_to_seek, "to chunk");

    const chunk_size: usize = 64 * 1024;
    var buffer: [chunk_size]u8 = undefined;
    var bytes_read: u64 = 0;

    while (bytes_read < length) {
        const to_read: usize = @min(chunk_size, length - @as(u32, @intCast(bytes_read)));
        const read = file.read(buffer[0..to_read]) catch {
            return ValidationResult.invalidCode(.glb, .failed_to_read, "chunk data");
        };
        if (read == 0) break;
        bytes_read += read;
    }

    if (bytes_read < length) {
        return ValidationResult.invalidCode(.glb, .truncated, "chunk data");
    }

    return ValidationResult.okWithDepth(.glb, .structural);
}

pub fn validateGlbDeep(allocator: Allocator, source: *FileSource) ValidationResult {
    const file = source;

    // Read GLB header
    var header: [12]u8 = undefined;
    _ = file.read(&header) catch return ValidationResult.invalidCode(.glb, .failed_to_read, "header");

    if (!std.mem.eql(u8, header[0..4], "glTF")) {
        return ValidationResult.invalidCode(.glb, .invalid_value, "GLB magic");
    }

    const total_length = std.mem.readInt(u32, header[8..12], .little);
    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.glb, .failed_to_get, "file size");

    if (total_length > file_size) {
        return ValidationResult.invalidCodeMsg(.glb, .exceeds_bounds, "GLB length", "GLB length exceeds file size");
    }

    // Find JSON chunk
    var json_offset: u64 = 0;
    var json_length: u32 = 0;
    var bin_length: u32 = 0;
    var position: u64 = 12;

    while (position + 8 <= total_length) {
        var chunk_header: [8]u8 = undefined;
        file.seekTo(position) catch break;
        _ = file.read(&chunk_header) catch break;

        const chunk_length = std.mem.readInt(u32, chunk_header[0..4], .little);
        const chunk_type = std.mem.readInt(u32, chunk_header[4..8], .little);

        if (chunk_type == 0x4E4F534A) { // "JSON"
            json_offset = position + 8;
            json_length = chunk_length;
        } else if (chunk_type == 0x004E4942) { // "BIN\0"
            bin_length = chunk_length;
        }

        position += 8 + chunk_length;
        position = (position + 3) & ~@as(u64, 3);
    }

    if (json_length == 0) {
        return ValidationResult.invalidCode(.glb, .missing, "JSON chunk");
    }

    // Read and parse JSON chunk (limit to 50MB)
    if (json_length > 50 * 1024 * 1024) {
        return ValidationResult.okWithDepthAndWarning(.glb, .structural, "JSON chunk too large to parse");
    }

    const json_data = allocator.alloc(u8, json_length) catch {
        return ValidationResult.okWithDepth(.glb, .structural);
    };
    defer allocator.free(json_data);

    file.seekTo(json_offset) catch return ValidationResult.invalidCode(.glb, .failed_to_seek, "to JSON");
    const read_len = file.readAll(json_data) catch return ValidationResult.invalidCode(.glb, .failed_to_read, "JSON");
    if (read_len < json_length) {
        return ValidationResult.invalidCode(.glb, .truncated, "JSON chunk");
    }

    // Parse JSON using std.json
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_data, .{}) catch {
        return ValidationResult.invalidCode(.glb, .invalid_value, "JSON in GLB");
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) {
        return ValidationResult.invalid(.glb, "JSON root is not an object");
    }

    // Extract arrays
    const buffers = root.object.get("buffers");
    const buffer_views = root.object.get("bufferViews");
    const accessors_val = root.object.get("accessors");

    // Count elements
    const buffer_count: usize = if (buffers) |b| if (b == .array) b.array.items.len else 0 else 0;
    const buffer_view_count: usize = if (buffer_views) |bv| if (bv == .array) bv.array.items.len else 0 else 0;

    // Validate buffer byte lengths
    if (buffers) |b| {
        if (b == .array) {
            for (b.array.items) |buffer| {
                if (buffer == .object) {
                    if (buffer.object.get("byteLength")) |bl| {
                        if (bl == .integer) {
                            const byte_len = bl.integer;
                            if (byte_len < 0) {
                                return ValidationResult.invalid(.glb, "Buffer has negative byteLength");
                            }
                        }
                    }
                }
            }
        }
    }

    // For GLB, first buffer should be embedded - verify BIN chunk is large enough
    if (buffer_count > 0 and bin_length > 0) {
        if (buffers) |b| {
            if (b == .array and b.array.items.len > 0) {
                const first_buffer = b.array.items[0];
                if (first_buffer == .object) {
                    if (first_buffer.object.get("byteLength")) |bl| {
                        if (bl == .integer) {
                            const expected_size: u64 = @intCast(bl.integer);
                            if (bin_length < expected_size) {
                                return ValidationResult.invalid(.glb, "BIN chunk smaller than first buffer byteLength");
                            }
                        }
                    }
                }
            }
        }
    }

    // Validate bufferView references
    if (buffer_views) |bv| {
        if (bv == .array) {
            for (bv.array.items) |view| {
                if (view == .object) {
                    if (view.object.get("buffer")) |buf_idx| {
                        if (buf_idx == .integer) {
                            const idx: i64 = buf_idx.integer;
                            if (idx < 0 or idx >= @as(i64, @intCast(buffer_count))) {
                                return ValidationResult.invalid(.glb, "bufferView references invalid buffer index");
                            }
                        }
                    }
                }
            }
        }
    }

    // Validate accessor references
    if (accessors_val) |acc| {
        if (acc == .array) {
            for (acc.array.items) |accessor| {
                if (accessor == .object) {
                    if (accessor.object.get("bufferView")) |bv_idx| {
                        if (bv_idx == .integer) {
                            const idx: i64 = bv_idx.integer;
                            if (idx < 0 or idx >= @as(i64, @intCast(buffer_view_count))) {
                                return ValidationResult.invalid(.glb, "accessor references invalid bufferView index");
                            }
                        }
                    }
                    // Accessors must have count > 0
                    if (accessor.object.get("count")) |cnt| {
                        if (cnt == .integer and cnt.integer <= 0) {
                            return ValidationResult.invalid(.glb, "accessor has invalid count");
                        }
                    }
                }
            }
        }
    }

    // Validate required asset field
    if (root.object.get("asset")) |asset| {
        if (asset == .object) {
            if (asset.object.get("version") == null) {
                return ValidationResult.invalidCode(.glb, .missing, "asset.version");
            }
        } else {
            return ValidationResult.invalid(.glb, "asset is not an object");
        }
    } else {
        return ValidationResult.invalidCode(.glb, .missing, "required asset field");
    }

    return ValidationResult.okWithDepth(.glb, .structural);
}

// ============ Tests ============

test "validateDxf with ground truth" {
    var file = FileSource.open("ground_truth_examples/dxf/sample.dxf") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer file.close();
    const result = validateDxf(&file);
    try std.testing.expect(result.is_valid);
}

test "validateDxf rejects invalid data" {
    const tmpdir = std.posix.getenv("TMPDIR") orelse "/tmp";
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/test_invalid.dxf", .{tmpdir}) catch return;
    {
        const wf = std.fs.cwd().createFile(path, .{}) catch return;
        defer wf.close();
        wf.writeAll("this is not a DXF file at all") catch return;
    }
    defer std.fs.cwd().deleteFile(path) catch {};
    var file = FileSource.open(path) catch return;
    defer file.close();
    const result = validateDxf(&file);
    try std.testing.expect(!result.is_valid);
}

test "validateStep with ground truth" {
    var file = FileSource.open("ground_truth_examples/step/sample.stp") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer file.close();
    const result = validateStep(&file);
    try std.testing.expect(result.is_valid);
}

test "validateStep rejects invalid data" {
    const tmpdir = std.posix.getenv("TMPDIR") orelse "/tmp";
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/test_invalid.stp", .{tmpdir}) catch return;
    {
        const wf = std.fs.cwd().createFile(path, .{}) catch return;
        defer wf.close();
        wf.writeAll("this is not a STEP file at all") catch return;
    }
    defer std.fs.cwd().deleteFile(path) catch {};
    var file = FileSource.open(path) catch return;
    defer file.close();
    const result = validateStep(&file);
    try std.testing.expect(!result.is_valid);
}

test "validateStl with ground truth" {
    var file = FileSource.open("ground_truth_examples/stl/sample.stl") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer file.close();
    const result = validateStl(&file);
    try std.testing.expect(result.is_valid);
}

test "validateStl rejects invalid data" {
    const tmpdir = std.posix.getenv("TMPDIR") orelse "/tmp";
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/test_invalid.stl", .{tmpdir}) catch return;
    {
        const wf = std.fs.cwd().createFile(path, .{}) catch return;
        defer wf.close();
        wf.writeAll("this is not a STL file at all") catch return;
    }
    defer std.fs.cwd().deleteFile(path) catch {};
    var file = FileSource.open(path) catch return;
    defer file.close();
    const result = validateStl(&file);
    try std.testing.expect(!result.is_valid);
}

test "validateObj with ground truth" {
    var file = FileSource.open("ground_truth_examples/obj/sample.obj") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer file.close();
    const result = validateObj(&file);
    try std.testing.expect(result.is_valid);
}

test "validateObj rejects invalid data" {
    const tmpdir = std.posix.getenv("TMPDIR") orelse "/tmp";
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/test_invalid.obj", .{tmpdir}) catch return;
    {
        const wf = std.fs.cwd().createFile(path, .{}) catch return;
        defer wf.close();
        wf.writeAll("this is not an OBJ file at all") catch return;
    }
    defer std.fs.cwd().deleteFile(path) catch {};
    var file = FileSource.open(path) catch return;
    defer file.close();
    const result = validateObj(&file);
    try std.testing.expect(!result.is_valid);
}

test "validatePly with ground truth" {
    var file = FileSource.open("ground_truth_examples/ply/sample.ply") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer file.close();
    const result = validatePly(&file);
    try std.testing.expect(result.is_valid);
}

test "validatePly rejects invalid data" {
    const tmpdir = std.posix.getenv("TMPDIR") orelse "/tmp";
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/test_invalid.ply", .{tmpdir}) catch return;
    {
        const wf = std.fs.cwd().createFile(path, .{}) catch return;
        defer wf.close();
        wf.writeAll("this is not a PLY file at all") catch return;
    }
    defer std.fs.cwd().deleteFile(path) catch {};
    var file = FileSource.open(path) catch return;
    defer file.close();
    const result = validatePly(&file);
    try std.testing.expect(!result.is_valid);
}

test "validateGltf with ground truth" {
    var file = FileSource.open("ground_truth_examples/gltf/box.gltf") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer file.close();
    const result = validateGltf(&file);
    try std.testing.expect(result.is_valid);
}

test "validateGltf rejects invalid data" {
    const tmpdir = std.posix.getenv("TMPDIR") orelse "/tmp";
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/test_invalid.gltf", .{tmpdir}) catch return;
    {
        const wf = std.fs.cwd().createFile(path, .{}) catch return;
        defer wf.close();
        wf.writeAll("this is not a glTF file at all") catch return;
    }
    defer std.fs.cwd().deleteFile(path) catch {};
    var file = FileSource.open(path) catch return;
    defer file.close();
    const result = validateGltf(&file);
    try std.testing.expect(!result.is_valid);
}

test "validateGlb with ground truth" {
    var file = FileSource.open("ground_truth_examples/glb/box.glb") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer file.close();
    const result = validateGlb(&file);
    try std.testing.expect(result.is_valid);
}

test "validateGlb rejects invalid data" {
    const tmpdir = std.posix.getenv("TMPDIR") orelse "/tmp";
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/test_invalid.glb", .{tmpdir}) catch return;
    {
        const wf = std.fs.cwd().createFile(path, .{}) catch return;
        defer wf.close();
        wf.writeAll("this is not a GLB file at all") catch return;
    }
    defer std.fs.cwd().deleteFile(path) catch {};
    var file = FileSource.open(path) catch return;
    defer file.close();
    const result = validateGlb(&file);
    try std.testing.expect(!result.is_valid);
}

// ============ 3MF Validator ============

pub fn validate3mf(file: *FileSource) ValidationResult {
    const zip_result = archive_validators.validateZip(file, .@"3mf");
    if (!zip_result.is_valid) {
        return zip_result;
    }

    file.seekTo(0) catch return ValidationResult.invalidCode(.@"3mf", .failed_to_seek, "to start");

    var header: [4096]u8 = undefined;
    const bytes_read = file.read(&header) catch return ValidationResult.invalidCode(.@"3mf", .failed_to_read, "header");
    if (bytes_read < 30) {
        return ValidationResult.invalidCode(.@"3mf", .file_too_small, "3MF");
    }

    if (std.mem.indexOf(u8, header[0..bytes_read], "[Content_Types].xml") != null or
        std.mem.indexOf(u8, header[0..bytes_read], "3dmodel.model") != null or
        std.mem.indexOf(u8, header[0..bytes_read], "3D/") != null)
    {
        return ValidationResult.okWithDepth(.@"3mf", .full);
    }

    return ValidationResult.ok(.@"3mf");
}

pub fn validate3mfDeep(allocator: Allocator, source: *FileSource) ValidationResult {
    const zip_result = archive_validators.validateZipDeep(allocator, source);
    var coerced = zip_result;
    coerced.format = .@"3mf";
    return coerced;
}

// ============ Buffer Validators ============

pub fn validateDwgFromBuffer(data: []const u8) ValidationResult {
    if (data.len < 6) {
        return ValidationResult.invalidCode(.dwg, .buffer_too_small, "DWG");
    }

    // Check for "AC" magic at start
    if (data[0] != 'A' or data[1] != 'C') {
        return ValidationResult.invalidCodeMsg(.dwg, .invalid_signature_expected, "DWG", errmsg.invalidSignatureExpected("DWG", "AC"));
    }

    // Verify version code format: should be "AC10xx"
    if (data[2] != '1' or data[3] != '0') {
        return ValidationResult.invalidCode(.dwg, .invalid_value, "DWG version code");
    }

    // Check that bytes 4-5 are digits
    if (!isDigit(data[4]) or !isDigit(data[5])) {
        return ValidationResult.invalidCode(.dwg, .invalid_value, "DWG version format");
    }

    return ValidationResult.structuralOnly(.dwg);
}

pub fn validateBlendFromBuffer(data: []const u8) ValidationResult {
    if (data.len < 12) {
        return ValidationResult.invalidCode(.blend, .buffer_too_small, "Blender");
    }

    // Check for "BLENDER" magic
    if (!std.mem.eql(u8, data[0..7], "BLENDER")) {
        return ValidationResult.invalidCode(.blend, .invalid_signature, "Blender");
    }

    // Check pointer size
    if (data[7] != '_' and data[7] != '-') {
        return ValidationResult.invalidCode(.blend, .invalid_value, "pointer size indicator");
    }

    // Check endianness
    if (data[8] != 'v' and data[8] != 'V') {
        return ValidationResult.invalidCode(.blend, .invalid_value, "endianness indicator");
    }

    // Check version
    if (!isDigit(data[9]) or !isDigit(data[10]) or !isDigit(data[11])) {
        return ValidationResult.invalidCode(.blend, .invalid_value, "version number");
    }

    return ValidationResult.ok(.blend);
}

pub fn validateObjFromBuffer(data: []const u8) ValidationResult {
    if (data.len < 2) {
        return ValidationResult.invalidCode(.obj, .buffer_too_small, "OBJ");
    }

    // Check for ASCII content
    const check_len = @min(data.len, 4096);
    for (data[0..check_len]) |c| {
        if (c > 127 and c != '\t' and c != '\n' and c != '\r') {
            return ValidationResult.invalid(.obj, "OBJ contains non-ASCII characters");
        }
    }

    // Use parseObjContent for validation
    return parseObjContent(data);
}

// ============================================================
// Tests moved from format_validation.zig
// ============================================================

test "FormatValidator accepts valid DXF text" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dxf_content =
        \\0
        \\SECTION
        \\2
        \\HEADER
        \\0
        \\ENDSEC
        \\0
        \\EOF
    ;

    const file = try tmp_dir.dir.createFile("test.dxf", .{});
    try file.writeAll(dxf_content);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test.dxf");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.dxf, result.format);
    try std.testing.expect(result.is_valid);
}

test "FormatValidator accepts valid ASCII STL" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const stl_content =
        \\solid test
        \\  facet normal 0 0 1
        \\    outer loop
        \\      vertex 0 0 0
        \\      vertex 1 0 0
        \\      vertex 0 1 0
        \\    endloop
        \\  endfacet
        \\endsolid test
    ;

    const file = try tmp_dir.dir.createFile("test.stl", .{});
    try file.writeAll(stl_content);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test.stl");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.stl, result.format);
    try std.testing.expect(result.is_valid);
}

test "detectFormat binary STL returns unknown" {
    // Binary STL has no magic signature, so detectFormat should return .unknown
    var stl_data: [134]u8 = undefined;
    @memset(stl_data[0..80], 0);
    std.mem.writeInt(u32, stl_data[80..84], 1, .little);
    @memset(stl_data[84..134], 0);

    // detectFormat should return .unknown for binary STL (no magic bytes)
    const detected = detectFormat(&stl_data);
    try std.testing.expectEqual(FileFormat.unknown, detected);
}

test "validateStl accepts valid binary STL structure" {
    // Note: Binary STL has no magic bytes and cannot be auto-detected without file extension hints.
    // This test verifies the validator accepts valid binary STL structure when the format is known.
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Binary STL: 80-byte header + 4-byte triangle count + triangles
    // With 1 triangle: 84 + 50 = 134 bytes
    var stl_data: [134]u8 = undefined;
    @memset(stl_data[0..80], 0); // Header (not starting with "solid")
    std.mem.writeInt(u32, stl_data[80..84], 1, .little); // 1 triangle

    // Triangle: normal (12 bytes) + 3 vertices (36 bytes) + attribute (2 bytes) = 50 bytes
    @memset(stl_data[84..134], 0);

    {
        const wf = try tmp_dir.dir.createFile("test_binary.stl", .{});
        defer wf.close();
        try wf.writeAll(&stl_data);
    }

    // Open the file and call validateStl directly
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const stl_path = try tmp_dir.dir.realpath("test_binary.stl", &path_buf);
    var validate_file = try FileSource.open(stl_path);
    defer validate_file.close();

    const result = validateStl(&validate_file);

    // The validator should accept the binary STL structure
    try std.testing.expectEqual(FileFormat.stl, result.format);
    try std.testing.expect(result.is_valid);
}

test "FormatValidator detects and validates binary STL via extension fallback" {
    // Binary STL has no magic bytes (80-byte arbitrary header, not starting with "solid ").
    // This test verifies the full detection pipeline: extension → ext_has_no_magic → dispatch.
    // Without .stl in ext_has_no_magic, this file would be detected as .unknown or .plain_text.
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Binary STL: 80-byte header + 4-byte triangle count (LE) + N * 50-byte triangles
    // 1 triangle = 134 bytes total
    var stl_data: [134]u8 = undefined;
    @memset(stl_data[0..80], 'X'); // Header: arbitrary bytes, NOT "solid "
    std.mem.writeInt(u32, stl_data[80..84], 1, .little); // 1 triangle
    // Triangle: normal (12) + v1 (12) + v2 (12) + v3 (12) + attribute (2) = 50 bytes
    @memset(stl_data[84..134], 0);

    const file = try tmp_dir.dir.createFile("test_binary.stl", .{});
    try file.writeAll(&stl_data);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test_binary.stl");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    // Must be detected as STL (not unknown or plain_text) and valid
    try std.testing.expectEqual(FileFormat.stl, result.format);
    try std.testing.expect(result.is_valid);
}

test "validateDwg accepts valid DWG file structure" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Minimal valid DWG: "AC1032" (DWG 2018) + padding
    var dwg_data: [32]u8 = undefined;
    @memcpy(dwg_data[0..6], "AC1032"); // Version code for DWG 2018
    @memset(dwg_data[6..32], 0); // Padding

    const file = try tmp_dir.dir.createFile("test.dwg", .{});
    try file.writeAll(&dwg_data);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test.dwg");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);
    if (!result.is_valid) {
        std.debug.print("\nDWG validation failed: {s}\n", .{result.error_message orelse "no message"});
    }
    try std.testing.expectEqual(FileFormat.dwg, result.format);
    try std.testing.expect(result.is_valid);
}

test "validateDwg accepts older DWG version codes" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Test AC1015 (AutoCAD 2000)
    var dwg_data: [32]u8 = undefined;
    @memcpy(dwg_data[0..6], "AC1015");
    @memset(dwg_data[6..32], 0);

    const file = try tmp_dir.dir.createFile("old.dwg", .{});
    try file.writeAll(&dwg_data);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "old.dwg");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);
    try std.testing.expectEqual(FileFormat.dwg, result.format);
    try std.testing.expect(result.is_valid);
}

test "validateDwg rejects invalid magic" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Invalid: wrong magic bytes
    var bad_dwg: [32]u8 = undefined;
    @memcpy(bad_dwg[0..6], "XX1032"); // Wrong magic
    @memset(bad_dwg[6..32], 0);

    const file = try tmp_dir.dir.createFile("bad.dwg", .{});
    try file.writeAll(&bad_dwg);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "bad.dwg");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);
    try std.testing.expect(!result.is_valid or result.format != .dwg);
}

test "validateDwgFromBuffer matches file validation" {
    // Valid DWG buffer
    var dwg_data: [32]u8 = undefined;
    @memcpy(dwg_data[0..6], "AC1027"); // DWG 2013
    @memset(dwg_data[6..32], 0);

    const result = validateDwgFromBuffer(&dwg_data);
    try std.testing.expectEqual(FileFormat.dwg, result.format);
    try std.testing.expect(result.is_valid);
}

test "validateBlend accepts valid Blender file structure" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Minimal valid Blender: "BLENDER" + "_" (32-bit) + "v" (little-endian) + "280" (version 2.80)
    var blend_data: [32]u8 = undefined;
    @memcpy(blend_data[0..7], "BLENDER"); // Magic
    blend_data[7] = '_'; // 32-bit pointer
    blend_data[8] = 'v'; // Little-endian
    @memcpy(blend_data[9..12], "280"); // Version 2.80
    @memset(blend_data[12..32], 0);

    const file = try tmp_dir.dir.createFile("test.blend", .{});
    try file.writeAll(&blend_data);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test.blend");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);
    if (!result.is_valid) {
        std.debug.print("\nBlender validation failed: {s}\n", .{result.error_message orelse "no message"});
    }
    try std.testing.expectEqual(FileFormat.blend, result.format);
    try std.testing.expect(result.is_valid);
}

test "validateBlend accepts 64-bit big-endian Blender file" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // 64-bit big-endian Blender file
    var blend_data: [32]u8 = undefined;
    @memcpy(blend_data[0..7], "BLENDER");
    blend_data[7] = '-'; // 64-bit pointer
    blend_data[8] = 'V'; // Big-endian
    @memcpy(blend_data[9..12], "300"); // Version 3.00
    @memset(blend_data[12..32], 0);

    const file = try tmp_dir.dir.createFile("big.blend", .{});
    try file.writeAll(&blend_data);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "big.blend");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);
    try std.testing.expectEqual(FileFormat.blend, result.format);
    try std.testing.expect(result.is_valid);
}

test "validateBlend rejects invalid magic" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Invalid: wrong magic
    var bad_blend: [32]u8 = undefined;
    @memcpy(bad_blend[0..7], "BLENXXX"); // Wrong magic
    bad_blend[7] = '_';
    bad_blend[8] = 'v';
    @memcpy(bad_blend[9..12], "280");
    @memset(bad_blend[12..32], 0);

    const file = try tmp_dir.dir.createFile("bad.blend", .{});
    try file.writeAll(&bad_blend);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "bad.blend");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);
    try std.testing.expect(!result.is_valid or result.format != .blend);
}

test "validateBlendFromBuffer matches file validation" {
    // Valid Blender buffer
    var blend_data: [32]u8 = undefined;
    @memcpy(blend_data[0..7], "BLENDER");
    blend_data[7] = '-'; // 64-bit
    blend_data[8] = 'v'; // Little-endian
    @memcpy(blend_data[9..12], "400"); // Version 4.00
    @memset(blend_data[12..32], 0);

    const result = validateBlendFromBuffer(&blend_data);
    try std.testing.expectEqual(FileFormat.blend, result.format);
    try std.testing.expect(result.is_valid);
}

test "validateBlendDeep rejects corrupted DNA1 block data" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Construct a minimal valid .blend file with proper DNA1 and ENDB blocks
    // Header: BLENDER- (64-bit) v (little-endian) 360
    // DNA1 block with valid SDNA structure
    // ENDB terminator block
    const header = "BLENDER-v360";
    // DNA1 block: code(4) + size(4) + old_ptr(8) + sdna_idx(4) + count(4) = 24 byte block header
    // DNA1 data: SDNA(4) + NAME(4) + name_count(4) + "x\x00"(2) + padding(2) +
    //            TYPE(4) + type_count(4) + "x\x00"(2) + padding(2) +
    //            TLEN(4) + tlen(2) + padding(2) + STRC(4) + struct_count(4) = 44 bytes
    const dna1_data_size: u32 = 44;
    const block_header_size: usize = 4 + 4 + 8 + 4 + 4; // 24

    var blend_buf: [12 + block_header_size + dna1_data_size + block_header_size]u8 = undefined;
    @memset(&blend_buf, 0);

    // Header
    @memcpy(blend_buf[0..12], header);

    // DNA1 block header
    var pos: usize = 12;
    @memcpy(blend_buf[pos..][0..4], "DNA1");
    std.mem.writeInt(u32, blend_buf[pos + 4 ..][0..4], dna1_data_size, .little);
    pos += block_header_size;

    // DNA1 data: SDNA section
    @memcpy(blend_buf[pos..][0..4], "SDNA");
    pos += 4;
    @memcpy(blend_buf[pos..][0..4], "NAME");
    pos += 4;
    std.mem.writeInt(u32, blend_buf[pos..][0..4], 1, .little); // 1 name
    pos += 4;
    blend_buf[pos] = 'x';
    blend_buf[pos + 1] = 0; // null terminator
    pos += 2;
    pos = (pos + 3) & ~@as(usize, 3); // align to 4
    @memcpy(blend_buf[pos..][0..4], "TYPE");
    pos += 4;
    std.mem.writeInt(u32, blend_buf[pos..][0..4], 1, .little); // 1 type
    pos += 4;
    blend_buf[pos] = 'x';
    blend_buf[pos + 1] = 0;
    pos += 2;
    pos = (pos + 3) & ~@as(usize, 3); // align to 4
    @memcpy(blend_buf[pos..][0..4], "TLEN");
    pos += 4;
    std.mem.writeInt(u16, blend_buf[pos..][0..2], 1, .little); // type length = 1
    pos += 2;
    pos = (pos + 3) & ~@as(usize, 3); // align to 4
    @memcpy(blend_buf[pos..][0..4], "STRC");
    pos += 4;
    std.mem.writeInt(u32, blend_buf[pos..][0..4], 0, .little); // 0 structs
    pos += 4;

    // ENDB block header
    @memcpy(blend_buf[pos..][0..4], "ENDB");
    std.mem.writeInt(u32, blend_buf[pos + 4 ..][0..4], 0, .little);

    // First verify the valid file passes
    const valid_file = try tmp_dir.dir.createFile("valid.blend", .{});
    try valid_file.writeAll(&blend_buf);
    valid_file.close();

    const valid_path = try tmp_dir.dir.realpathAlloc(allocator, "valid.blend");
    defer allocator.free(valid_path);

    var valid_src = try FileSource.open(valid_path);
    defer valid_src.close();
    const valid_result = validateBlendDeep(allocator, &valid_src);
    try std.testing.expect(valid_result.is_valid);

    // Now corrupt the DNA1 data area (overwrite TYPE/TLEN/STRC sections)
    var corrupt_buf = blend_buf;
    const dna1_data_start = 12 + block_header_size; // where DNA1 data begins
    // Corrupt from offset 12 within DNA1 data (the TYPE section) onwards
    const corrupt_start = dna1_data_start + 12;
    for (corrupt_start..corrupt_start + 20) |i| {
        corrupt_buf[i] = 0xDE;
    }

    const corrupt_file = try tmp_dir.dir.createFile("corrupt.blend", .{});
    try corrupt_file.writeAll(&corrupt_buf);
    corrupt_file.close();

    const corrupt_path = try tmp_dir.dir.realpathAlloc(allocator, "corrupt.blend");
    defer allocator.free(corrupt_path);

    var corrupt_src = try FileSource.open(corrupt_path);
    defer corrupt_src.close();
    const corrupt_result = validateBlendDeep(allocator, &corrupt_src);
    // A corrupted DNA1 block should be detected as INVALID, not just a warning
    try std.testing.expect(!corrupt_result.is_valid);
}

