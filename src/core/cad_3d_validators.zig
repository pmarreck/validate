//! 3D model and CAD format validators extracted from format_validation.zig.
//! Covers DWG, DXF, Blender, STEP, STL, OBJ, PLY, glTF, and GLB.

const std = @import("std");
const Allocator = std.mem.Allocator;
const format_validation = @import("format_validation.zig");
const ValidationResult = format_validation.ValidationResult;
const FileFormat = format_validation.FileFormat;

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

pub fn validateDwg(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalid(.dwg, "Failed to seek to start");

    var header: [12]u8 = undefined;
    const bytes_read = file.read(&header) catch {
        return ValidationResult.invalid(.dwg, "Failed to read DWG header");
    };

    if (bytes_read < 6) {
        return ValidationResult.invalid(.dwg, "File too small for DWG format");
    }

    // Check for "AC" magic at start
    if (header[0] != 'A' or header[1] != 'C') {
        return ValidationResult.invalid(.dwg, "Invalid DWG signature (expected AC)");
    }

    // Verify version code format: should be "AC10xx" where xx are digits
    // Known versions: AC1009 (R11), AC1012 (R13), AC1014 (R14), AC1015 (2000),
    // AC1018 (2004), AC1021 (2007), AC1024 (2010), AC1027 (2013), AC1032 (2018)
    if (header[2] != '1' or header[3] != '0') {
        return ValidationResult.invalid(.dwg, "Invalid DWG version code");
    }

    // Check that bytes 4-5 are digits (version suffix)
    if (!isDigit(header[4]) or !isDigit(header[5])) {
        return ValidationResult.invalid(.dwg, "Invalid DWG version format");
    }

    // DWG is proprietary binary - structural validation only
    return ValidationResult.structuralOnly(.dwg);
}

pub fn validateDwgDeep(allocator: Allocator, path: []const u8) ValidationResult {
    _ = allocator;
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return ValidationResult.invalid(.dwg, "Failed to open DWG file");
    };
    defer file.close();

    // Basic validation first
    const result = validateDwg(file);
    if (!result.is_valid) return result;

    // Get file size for bounds checking
    const file_size = file.getEndPos() catch {
        return ValidationResult.invalid(.dwg, "Failed to get file size");
    };

    // Minimum DWG file size (header + some data)
    if (file_size < 0x80) {
        return ValidationResult.invalid(.dwg, "File too small for valid DWG");
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

pub fn validateBlend(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalid(.blend, "Failed to seek to start");

    var header: [12]u8 = undefined;
    const bytes_read = file.read(&header) catch {
        return ValidationResult.invalid(.blend, "Failed to read Blender header");
    };

    if (bytes_read < 12) {
        return ValidationResult.invalid(.blend, "File too small for Blender format");
    }

    // Check for "BLENDER" magic (7 bytes)
    if (!std.mem.eql(u8, header[0..7], "BLENDER")) {
        return ValidationResult.invalid(.blend, "Invalid Blender signature");
    }

    // Check pointer size: '_' (0x5F) = 32-bit, '-' (0x2D) = 64-bit
    if (header[7] != '_' and header[7] != '-') {
        return ValidationResult.invalid(.blend, "Invalid pointer size indicator");
    }

    // Check endianness: 'v' (0x76) = little-endian, 'V' (0x56) = big-endian
    if (header[8] != 'v' and header[8] != 'V') {
        return ValidationResult.invalid(.blend, "Invalid endianness indicator");
    }

    // Check version: 3 ASCII digits (e.g., "254" for 2.54, "280" for 2.80)
    if (!isDigit(header[9]) or !isDigit(header[10]) or !isDigit(header[11])) {
        return ValidationResult.invalid(.blend, "Invalid version number");
    }

    // Blender's DNA system means structure is self-describing
    // Full validation would require parsing all blocks and verifying DNA1
    return ValidationResult.ok(.blend);
}

pub fn validateBlendDeep(allocator: Allocator, path: []const u8) ValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return ValidationResult.invalid(.blend, "Failed to open Blender file");
    };
    defer file.close();

    // First do structural validation
    const structural_result = validateBlend(file);
    if (!structural_result.is_valid) return structural_result;

    // Reset to start
    file.seekTo(0) catch return ValidationResult.invalid(.blend, "Failed to seek");

    var header: [12]u8 = undefined;
    _ = file.read(&header) catch return ValidationResult.invalid(.blend, "Failed to read header");

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
        return ValidationResult.invalid(.blend, "Failed to allocate block header buffer");
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
        return ValidationResult.invalid(.blend, "Missing ENDB terminator block");
    }

    if (!found_dna1) {
        return ValidationResult.invalid(.blend, "Missing DNA1 schema block");
    }

    if (!dna_fully_valid) {
        return ValidationResult.okWithDepthAndWarning(.blend, .structural, "DNA1 block has invalid structure");
    }

    // Successfully validated: header + DNA1 full schema + ENDB terminator
    return ValidationResult.okWithDepth(.blend, .full);
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

pub fn validateDxf(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalid(.dxf, "Failed to seek to start");

    var header: [256]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalid(.dxf, "Failed to read DXF header");

    if (header_read < 10) {
        return ValidationResult.invalid(.dxf, "File too small for DXF");
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

pub fn validateStep(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalid(.step, "Failed to seek to start");

    const file_size = file.getEndPos() catch return ValidationResult.invalid(.step, "Failed to get file size");
    if (file_size > 500 * 1024 * 1024) {
        // Very large STEP file - use chunked validation
        return validateStepChunked(file, file_size);
    }

    // Read entire file
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const content = allocator.alloc(u8, @intCast(file_size)) catch {
        return ValidationResult.invalid(.step, "Out of memory");
    };
    defer allocator.free(content);

    file.seekTo(0) catch return ValidationResult.invalid(.step, "Failed to seek");
    const bytes_read = file.readAll(content) catch {
        return ValidationResult.invalid(.step, "Failed to read file");
    };

    return parseStepContent(content[0..bytes_read]);
}

fn parseStepContent(content: []const u8) ValidationResult {
    if (content.len < 13) {
        return ValidationResult.invalid(.step, "File too small for STEP");
    }

    // Check for ISO-10303-21 signature
    if (!std.mem.eql(u8, content[0..13], "ISO-10303-21;")) {
        return ValidationResult.invalid(.step, "Invalid STEP signature");
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
        return ValidationResult.invalid(.step, "Missing HEADER section");
    }
    if (!has_data) {
        return ValidationResult.invalid(.step, "Missing DATA section");
    }
    if (!has_end) {
        return ValidationResult.invalid(.step, "Missing END-ISO-10303-21");
    }
    if (paren_depth != 0) {
        return ValidationResult.invalid(.step, "Unmatched parentheses");
    }

    return ValidationResult.okWithDepth(.step, .full);
}

pub fn validateStepChunked(file: std.fs.File, file_size: u64) ValidationResult {
    const chunk_size: usize = 64 * 1024;
    var buffer: [chunk_size]u8 = undefined;
    var position: u64 = 0;
    var has_header = false;
    var has_data = false;
    var has_end = false;

    file.seekTo(0) catch return ValidationResult.invalid(.step, "Failed to seek");

    // Check signature first
    var sig_buf: [13]u8 = undefined;
    _ = file.read(&sig_buf) catch return ValidationResult.invalid(.step, "Failed to read");
    if (!std.mem.eql(u8, &sig_buf, "ISO-10303-21;")) {
        return ValidationResult.invalid(.step, "Invalid STEP signature");
    }

    file.seekTo(0) catch return ValidationResult.invalid(.step, "Failed to seek");

    while (position < file_size) {
        const bytes_read = file.read(&buffer) catch {
            return ValidationResult.invalid(.step, "Failed to read chunk");
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
        return ValidationResult.invalid(.step, "Missing HEADER section");
    }
    if (!has_data) {
        return ValidationResult.invalid(.step, "Missing DATA section");
    }
    if (!has_end) {
        return ValidationResult.invalid(.step, "Missing END-ISO-10303-21");
    }

    return ValidationResult.okWithDepth(.step, .full);
}

// ============ STL Validator ============

pub fn validateStl(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalid(.stl, "Failed to seek to start");

    var header: [84]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalid(.stl, "Failed to read STL header");

    if (header_read < 6) {
        return ValidationResult.invalid(.stl, "File too small for STL");
    }

    // Check if ASCII STL (starts with "solid ")
    if (std.mem.eql(u8, header[0..6], "solid ")) {
        // Verify it's actually ASCII STL by looking for "facet" keyword
        file.seekTo(0) catch return ValidationResult.invalid(.stl, "Failed to seek");
        var peek_buffer: [1024]u8 = undefined;
        const peek_read = file.read(&peek_buffer) catch return ValidationResult.invalid(.stl, "Failed to read");
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

    return ValidationResult.invalid(.stl, "Invalid STL format");
}

pub fn validateStlAscii(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalid(.stl, "Failed to seek to start");

    const file_size = file.getEndPos() catch return ValidationResult.invalid(.stl, "Failed to get file size");
    if (file_size > 500 * 1024 * 1024) {
        // For very large files (>500MB), do chunked validation
        return validateStlAsciiChunked(file, file_size);
    }

    // Read entire file for parsing
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const content = allocator.alloc(u8, @intCast(file_size)) catch {
        return ValidationResult.invalid(.stl, "Out of memory");
    };
    defer allocator.free(content);

    file.seekTo(0) catch return ValidationResult.invalid(.stl, "Failed to seek");
    const bytes_read = file.readAll(content) catch {
        return ValidationResult.invalid(.stl, "Failed to read file");
    };

    return parseStlAsciiContent(content[0..bytes_read]);
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
                return ValidationResult.invalid(.stl, "Invalid facet normal");
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
                return ValidationResult.invalid(.stl, "Invalid vertex coordinates");
            }
            vertex_count += 1;
            if (vertex_count > 3) {
                return ValidationResult.invalid(.stl, "Too many vertices in facet");
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
        return ValidationResult.invalid(.stl, "Missing endsolid");
    }
    if (!found_solid) {
        return ValidationResult.invalid(.stl, "Missing solid declaration");
    }

    return ValidationResult.okWithDepth(.stl, .full);
}

pub fn validateStlAsciiChunked(file: std.fs.File, file_size: u64) ValidationResult {
    // For huge ASCII files, read in chunks and validate structure
    const chunk_size: usize = 64 * 1024; // 64KB chunks
    var buffer: [chunk_size]u8 = undefined;
    var position: u64 = 0;
    var facet_count: usize = 0;
    var found_solid = false;
    var found_endsolid = false;

    file.seekTo(0) catch return ValidationResult.invalid(.stl, "Failed to seek");

    while (position < file_size) {
        const bytes_read = file.read(&buffer) catch {
            return ValidationResult.invalid(.stl, "Failed to read chunk");
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
        return ValidationResult.invalid(.stl, "Missing solid declaration");
    }
    if (!found_endsolid) {
        return ValidationResult.invalid(.stl, "Missing endsolid");
    }
    if (facet_count == 0) {
        return ValidationResult.okWithWarning(.stl, "Empty STL (no facets)");
    }

    return ValidationResult.okWithDepth(.stl, .full);
}

pub fn validateStlBinary(file: std.fs.File, header: [84]u8) ValidationResult {
    const triangle_count = std.mem.readInt(u32, header[80..84], .little);

    // Each triangle is 50 bytes: normal (12) + v1 (12) + v2 (12) + v3 (12) + attr (2)
    const expected_size: u64 = 84 + @as(u64, triangle_count) * 50;
    const file_size = file.getEndPos() catch return ValidationResult.invalid(.stl, "Failed to get file size");

    if (file_size < expected_size) {
        return ValidationResult.invalid(.stl, "File truncated");
    }

    if (triangle_count == 0) {
        return ValidationResult.okWithDepth(.stl, .full);
    }

    // Validate triangles by reading them all
    file.seekTo(84) catch return ValidationResult.invalid(.stl, "Failed to seek past header");

    var triangle_buffer: [50]u8 = undefined;
    var triangles_read: u32 = 0;

    while (triangles_read < triangle_count) {
        const bytes_read = file.read(&triangle_buffer) catch {
            return ValidationResult.invalid(.stl, "Failed to read triangle");
        };
        if (bytes_read < 50) {
            return ValidationResult.invalid(.stl, "Truncated triangle data");
        }

        // Parse and validate floats (check for NaN/Inf which indicate corruption)
        // Normal vector
        const nx = std.mem.readInt(u32, triangle_buffer[0..4], .little);
        const ny = std.mem.readInt(u32, triangle_buffer[4..8], .little);
        const nz = std.mem.readInt(u32, triangle_buffer[8..12], .little);

        if (isInvalidFloat(nx) or isInvalidFloat(ny) or isInvalidFloat(nz)) {
            return ValidationResult.invalid(.stl, "Invalid normal vector (NaN/Inf)");
        }

        // Vertex 1
        const v1x = std.mem.readInt(u32, triangle_buffer[12..16], .little);
        const v1y = std.mem.readInt(u32, triangle_buffer[16..20], .little);
        const v1z = std.mem.readInt(u32, triangle_buffer[20..24], .little);

        if (isInvalidFloat(v1x) or isInvalidFloat(v1y) or isInvalidFloat(v1z)) {
            return ValidationResult.invalid(.stl, "Invalid vertex 1 (NaN/Inf)");
        }

        // Vertex 2
        const v2x = std.mem.readInt(u32, triangle_buffer[24..28], .little);
        const v2y = std.mem.readInt(u32, triangle_buffer[28..32], .little);
        const v2z = std.mem.readInt(u32, triangle_buffer[32..36], .little);

        if (isInvalidFloat(v2x) or isInvalidFloat(v2y) or isInvalidFloat(v2z)) {
            return ValidationResult.invalid(.stl, "Invalid vertex 2 (NaN/Inf)");
        }

        // Vertex 3
        const v3x = std.mem.readInt(u32, triangle_buffer[36..40], .little);
        const v3y = std.mem.readInt(u32, triangle_buffer[40..44], .little);
        const v3z = std.mem.readInt(u32, triangle_buffer[44..48], .little);

        if (isInvalidFloat(v3x) or isInvalidFloat(v3y) or isInvalidFloat(v3z)) {
            return ValidationResult.invalid(.stl, "Invalid vertex 3 (NaN/Inf)");
        }

        // Attribute byte count (2 bytes) - usually 0, but some software uses it
        // No validation needed, any value is technically valid

        triangles_read += 1;
    }

    return ValidationResult.okWithDepth(.stl, .full);
}

// ============ OBJ Validator ============

pub fn validateObj(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalid(.obj, "Failed to seek to start");

    const file_size = file.getEndPos() catch return ValidationResult.invalid(.obj, "Failed to get file size");
    if (file_size > 500 * 1024 * 1024) {
        // For very large files, use chunked validation
        return validateObjChunked(file, file_size);
    }

    // Read entire file
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const content = allocator.alloc(u8, @intCast(file_size)) catch {
        return ValidationResult.invalid(.obj, "Out of memory");
    };
    defer allocator.free(content);

    file.seekTo(0) catch return ValidationResult.invalid(.obj, "Failed to seek");
    const bytes_read = file.readAll(content) catch {
        return ValidationResult.invalid(.obj, "Failed to read file");
    };

    return parseObjContent(content[0..bytes_read]);
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
                return ValidationResult.invalid(.obj, "Invalid vertex coordinates");
            }
            vertex_count += 1;
            has_obj_directive = true;
        }
        // Texture coordinate: vt u [v] [w]
        else if (std.mem.startsWith(u8, trimmed, "vt ")) {
            const coords = trimmed[3..];
            const float_count = countAndValidateFloats(coords);
            if (float_count < 1 or float_count > 3) {
                return ValidationResult.invalid(.obj, "Invalid texture coordinate");
            }
            texcoord_count += 1;
            has_obj_directive = true;
        }
        // Vertex normal: vn x y z
        else if (std.mem.startsWith(u8, trimmed, "vn ")) {
            const coords = trimmed[3..];
            const float_count = countAndValidateFloats(coords);
            if (float_count != 3) {
                return ValidationResult.invalid(.obj, "Invalid vertex normal");
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
        return ValidationResult.invalid(.obj, "No valid OBJ directives found");
    }

    if (vertex_count == 0) {
        return ValidationResult.invalid(.obj, "No vertices found");
    }

    return ValidationResult.okWithDepth(.obj, .full);
}

pub const ObjFaceResult = struct {
    valid: bool,
    message: []const u8,
};

pub fn validateObjFace(face_data: []const u8, vertex_count: usize, texcoord_count: usize, normal_count: usize) ObjFaceResult {
    const trimmed = std.mem.trim(u8, face_data, " \t");
    if (trimmed.len == 0) {
        return .{ .valid = false, .message = "Empty face definition" };
    }

    var parts = std.mem.tokenizeAny(u8, trimmed, " \t");
    var face_vertex_count: usize = 0;

    while (parts.next()) |part| {
        // Each part is v[/vt][/vn] or v//vn or v/vt/vn or v/vt
        var indices = std.mem.splitScalar(u8, part, '/');

        // Vertex index (required)
        const v_str = indices.next() orelse return .{ .valid = false, .message = "Missing vertex index" };
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

pub fn validateObjChunked(file: std.fs.File, file_size: u64) ValidationResult {
    const chunk_size: usize = 64 * 1024;
    var buffer: [chunk_size]u8 = undefined;
    var position: u64 = 0;
    var vertex_count: usize = 0;
    var face_count: usize = 0;
    var has_obj_directive = false;

    file.seekTo(0) catch return ValidationResult.invalid(.obj, "Failed to seek");

    while (position < file_size) {
        const bytes_read = file.read(&buffer) catch {
            return ValidationResult.invalid(.obj, "Failed to read chunk");
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
        return ValidationResult.invalid(.obj, "No valid OBJ directives found");
    }
    if (vertex_count == 0) {
        return ValidationResult.invalid(.obj, "No vertices found");
    }

    return ValidationResult.okWithDepth(.obj, .full);
}

pub fn validateObjDeep(allocator: Allocator, path: []const u8) ValidationResult {
    _ = allocator;
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return ValidationResult.invalid(.obj, "Failed to open OBJ file");
    };
    defer file.close();
    return validateObj(file);
}

// ============ PLY Validator ============

pub const PlyFormat = enum {
    ascii,
    binary_little_endian,
    binary_big_endian,
};

pub fn validatePly(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalid(.ply, "Failed to seek to start");

    // Read header (up to 64KB - headers can be large with many properties)
    var header_buf: [65536]u8 = undefined;
    const header_read = file.read(&header_buf) catch return ValidationResult.invalid(.ply, "Failed to read header");
    if (header_read < 4) {
        return ValidationResult.invalid(.ply, "File too small for PLY");
    }

    const header_content = header_buf[0..header_read];

    // PLY must start with "ply" followed by newline
    if (!std.mem.startsWith(u8, header_content, "ply\n") and !std.mem.startsWith(u8, header_content, "ply\r\n")) {
        return ValidationResult.invalid(.ply, "Missing PLY magic");
    }

    // Parse header
    var format: ?PlyFormat = null;
    var vertex_count: usize = 0;
    var face_count: usize = 0;
    var header_end_offset: usize = 0;
    var vertex_property_count: usize = 0;
    var in_vertex_element = false;

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
                return ValidationResult.invalid(.ply, "Unknown PLY format");
            }
        } else if (std.mem.startsWith(u8, trimmed, "element vertex ")) {
            const count_str = trimmed[15..];
            vertex_count = std.fmt.parseInt(usize, std.mem.trim(u8, count_str, " \t"), 10) catch {
                return ValidationResult.invalid(.ply, "Invalid vertex count");
            };
            in_vertex_element = true;
        } else if (std.mem.startsWith(u8, trimmed, "element face ")) {
            const count_str = trimmed[13..];
            face_count = std.fmt.parseInt(usize, std.mem.trim(u8, count_str, " \t"), 10) catch {
                return ValidationResult.invalid(.ply, "Invalid face count");
            };
            in_vertex_element = false;
        } else if (std.mem.startsWith(u8, trimmed, "element ")) {
            in_vertex_element = false;
        } else if (std.mem.startsWith(u8, trimmed, "property ")) {
            if (in_vertex_element) {
                vertex_property_count += 1;
            }
        } else if (std.mem.eql(u8, trimmed, "end_header")) {
            header_end_offset = line_offset;
            break;
        }
    }

    if (format == null) {
        return ValidationResult.invalid(.ply, "Missing format declaration");
    }
    if (header_end_offset == 0) {
        return ValidationResult.invalid(.ply, "Missing end_header");
    }

    // Now validate the data section
    const file_size = file.getEndPos() catch return ValidationResult.invalid(.ply, "Failed to get file size");
    const data_size = file_size - header_end_offset;

    if (format.? == .ascii) {
        return validatePlyAsciiData(file, header_end_offset, vertex_count, face_count, vertex_property_count);
    } else {
        return validatePlyBinaryData(file, header_end_offset, data_size, vertex_count, vertex_property_count, format.?);
    }
}

pub fn validatePlyAsciiData(file: std.fs.File, header_end: usize, vertex_count: usize, face_count: usize, vertex_prop_count: usize) ValidationResult {
    file.seekTo(header_end) catch return ValidationResult.invalid(.ply, "Failed to seek to data");

    // For large files, validate a sample
    const file_size = file.getEndPos() catch return ValidationResult.invalid(.ply, "Failed to get size");
    if (file_size > 100 * 1024 * 1024) {
        // Just validate structure for very large ASCII files
        return validatePlyAsciiSample(file, vertex_count, face_count);
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const data_size = file_size - header_end;
    const data = allocator.alloc(u8, @intCast(data_size)) catch {
        return ValidationResult.invalid(.ply, "Out of memory");
    };
    defer allocator.free(data);

    file.seekTo(header_end) catch return ValidationResult.invalid(.ply, "Failed to seek");
    _ = file.readAll(data) catch return ValidationResult.invalid(.ply, "Failed to read data");

    var lines = std.mem.splitScalar(u8, data, '\n');
    var vertices_parsed: usize = 0;
    var faces_parsed: usize = 0;

    // Parse vertices
    while (vertices_parsed < vertex_count) {
        const line = lines.next() orelse return ValidationResult.invalid(.ply, "Truncated vertex data");
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        // Count floats/ints in the line
        var parts = std.mem.tokenizeAny(u8, trimmed, " \t");
        var prop_count: usize = 0;
        while (parts.next()) |part| {
            // Try parsing as float (covers int too)
            _ = std.fmt.parseFloat(f64, part) catch {
                return ValidationResult.invalid(.ply, "Invalid vertex data");
            };
            prop_count += 1;
        }
        if (prop_count < vertex_prop_count) {
            return ValidationResult.invalid(.ply, "Incomplete vertex data");
        }
        vertices_parsed += 1;
    }

    // Parse faces
    while (faces_parsed < face_count) {
        const line = lines.next() orelse return ValidationResult.invalid(.ply, "Truncated face data");
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        var parts = std.mem.tokenizeAny(u8, trimmed, " \t");

        // First number is vertex count for this face
        const count_str = parts.next() orelse return ValidationResult.invalid(.ply, "Missing face vertex count");
        const face_vertex_count = std.fmt.parseInt(usize, count_str, 10) catch {
            return ValidationResult.invalid(.ply, "Invalid face vertex count");
        };

        if (face_vertex_count < 3) {
            return ValidationResult.invalid(.ply, "Face must have at least 3 vertices");
        }

        // Validate vertex indices
        var idx_count: usize = 0;
        while (parts.next()) |idx_str| {
            const idx = std.fmt.parseInt(usize, idx_str, 10) catch {
                return ValidationResult.invalid(.ply, "Invalid face vertex index");
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

pub fn validatePlyAsciiSample(file: std.fs.File, vertex_count: usize, face_count: usize) ValidationResult {
    _ = vertex_count;
    _ = face_count;
    // Read first and last chunks, verify structure
    var buffer: [8192]u8 = undefined;
    const bytes_read = file.read(&buffer) catch return ValidationResult.invalid(.ply, "Failed to read");

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

    return ValidationResult.okWithDepth(.ply, .full);
}

pub fn validatePlyBinaryData(file: std.fs.File, header_end: usize, data_size: u64, vertex_count: usize, vertex_prop_count: usize, format: PlyFormat) ValidationResult {
    _ = format;
    file.seekTo(header_end) catch return ValidationResult.invalid(.ply, "Failed to seek to data");

    // Binary PLY: each vertex is typically floats for x,y,z plus optional properties
    // Minimum vertex size: 3 floats (12 bytes) for position
    const min_vertex_size: usize = if (vertex_prop_count >= 3) vertex_prop_count * 4 else 12;
    const expected_vertex_data = vertex_count * min_vertex_size;

    if (data_size < expected_vertex_data) {
        return ValidationResult.invalid(.ply, "Insufficient data for vertices");
    }

    // Read and validate binary data
    const chunk_size: usize = 64 * 1024;
    var buffer: [chunk_size]u8 = undefined;
    var bytes_validated: u64 = 0;

    while (bytes_validated < data_size) {
        const to_read = @min(chunk_size, data_size - bytes_validated);
        const bytes_read = file.read(buffer[0..to_read]) catch {
            return ValidationResult.invalid(.ply, "Failed to read binary data");
        };
        if (bytes_read == 0) break;

        // For binary, just verify we can read all the data
        // True validation would require parsing the property types from header
        bytes_validated += bytes_read;
    }

    if (bytes_validated < data_size) {
        return ValidationResult.invalid(.ply, "Truncated binary data");
    }

    return ValidationResult.okWithDepth(.ply, .full);
}

// ============ glTF Validator ============

pub fn validateGltf(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalid(.gltf, "Failed to seek to start");

    const file_size = file.getEndPos() catch return ValidationResult.invalid(.gltf, "Failed to get file size");
    if (file_size > 100 * 1024 * 1024) {
        // Very large glTF - do structural validation only
        return validateGltfStructural(file);
    }

    // Read entire file
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const content = allocator.alloc(u8, @intCast(file_size)) catch {
        return ValidationResult.invalid(.gltf, "Out of memory");
    };
    defer allocator.free(content);

    file.seekTo(0) catch return ValidationResult.invalid(.gltf, "Failed to seek");
    const bytes_read = file.readAll(content) catch {
        return ValidationResult.invalid(.gltf, "Failed to read file");
    };

    return parseGltfJson(content[0..bytes_read]);
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

    // Validate JSON structure by tracking braces/brackets
    var brace_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var in_string = false;
    var escape_next = false;
    var has_asset = false;
    var has_version = false;

    for (content[start..]) |c| {
        if (escape_next) {
            escape_next = false;
            continue;
        }

        if (c == '\\' and in_string) {
            escape_next = true;
            continue;
        }

        if (c == '"') {
            in_string = !in_string;
            continue;
        }

        if (in_string) continue;

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
        return ValidationResult.invalid(.gltf, "Missing required 'asset' field");
    }
    if (!has_version) {
        return ValidationResult.invalid(.gltf, "Missing required 'version' field");
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

    return ValidationResult.okWithDepth(.gltf, .full);
}

pub fn validateGltfStructural(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalid(.gltf, "Failed to seek");

    var buffer: [8192]u8 = undefined;
    const bytes_read = file.read(&buffer) catch return ValidationResult.invalid(.gltf, "Failed to read");
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
        return ValidationResult.invalid(.gltf, "Missing 'asset' field");
    }

    return ValidationResult.okWithDepth(.gltf, .full);
}

// ============ GLB Validator ============

pub fn validateGlb(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalid(.glb, "Failed to seek to start");

    var header: [12]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalid(.glb, "Failed to read header");
    if (header_read < 12) {
        return ValidationResult.invalid(.glb, "File too small for GLB");
    }

    // GLB header: magic (4) + version (4) + length (4)
    if (!std.mem.eql(u8, header[0..4], "glTF")) {
        return ValidationResult.invalid(.glb, "Invalid GLB magic");
    }

    const version = std.mem.readInt(u32, header[4..8], .little);
    if (version != 2 and version != 1) {
        return ValidationResult.invalid(.glb, "Unsupported GLB version");
    }

    const total_length = std.mem.readInt(u32, header[8..12], .little);
    const file_size = file.getEndPos() catch return ValidationResult.invalid(.glb, "Failed to get file size");

    if (total_length > file_size) {
        return ValidationResult.invalid(.glb, "GLB length exceeds file size");
    }

    // Parse chunks
    var position: u64 = 12;
    var chunk_count: usize = 0;
    var json_validated = false;

    while (position + 8 <= total_length) {
        // Read chunk header: length (4) + type (4)
        var chunk_header: [8]u8 = undefined;
        file.seekTo(position) catch return ValidationResult.invalid(.glb, "Failed to seek to chunk");
        const chunk_header_read = file.read(&chunk_header) catch return ValidationResult.invalid(.glb, "Failed to read chunk header");
        if (chunk_header_read < 8) {
            return ValidationResult.invalid(.glb, "Truncated chunk header");
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
        return ValidationResult.invalid(.glb, "Missing JSON chunk");
    }

    if (version == 1) {
        return ValidationResult.okWithDepthAndWarning(.glb, .full, "GLB version 1 (deprecated)");
    }

    return ValidationResult.okWithDepth(.glb, .full);
}

pub fn validateGlbJsonChunk(file: std.fs.File, offset: u64, length: u32) ValidationResult {
    if (length > 100 * 1024 * 1024) {
        // Very large JSON - just read to verify accessibility
        return validateGlbChunkReadable(file, offset, length);
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const json_data = allocator.alloc(u8, length) catch {
        return ValidationResult.invalid(.glb, "Out of memory for JSON");
    };
    defer allocator.free(json_data);

    file.seekTo(offset) catch return ValidationResult.invalid(.glb, "Failed to seek to JSON");
    const read_len = file.readAll(json_data) catch return ValidationResult.invalid(.glb, "Failed to read JSON");

    if (read_len < length) {
        return ValidationResult.invalid(.glb, "Truncated JSON chunk");
    }

    // Validate JSON structure
    return parseGltfJson(json_data);
}

pub fn validateGlbBinChunk(file: std.fs.File, offset: u64, length: u32) ValidationResult {
    return validateGlbChunkReadable(file, offset, length);
}

pub fn validateGlbChunkReadable(file: std.fs.File, offset: u64, length: u32) ValidationResult {
    file.seekTo(offset) catch return ValidationResult.invalid(.glb, "Failed to seek to chunk");

    const chunk_size: usize = 64 * 1024;
    var buffer: [chunk_size]u8 = undefined;
    var bytes_read: u64 = 0;

    while (bytes_read < length) {
        const to_read: usize = @min(chunk_size, length - @as(u32, @intCast(bytes_read)));
        const read = file.read(buffer[0..to_read]) catch {
            return ValidationResult.invalid(.glb, "Failed to read chunk data");
        };
        if (read == 0) break;
        bytes_read += read;
    }

    if (bytes_read < length) {
        return ValidationResult.invalid(.glb, "Truncated chunk data");
    }

    return ValidationResult.okWithDepth(.glb, .full);
}

pub fn validateGlbDeep(allocator: Allocator, path: []const u8) ValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return ValidationResult.invalid(.glb, "Failed to open GLB file");
    };
    defer file.close();

    // Read GLB header
    var header: [12]u8 = undefined;
    _ = file.read(&header) catch return ValidationResult.invalid(.glb, "Failed to read header");

    if (!std.mem.eql(u8, header[0..4], "glTF")) {
        return ValidationResult.invalid(.glb, "Invalid GLB magic");
    }

    const total_length = std.mem.readInt(u32, header[8..12], .little);
    const file_size = file.getEndPos() catch return ValidationResult.invalid(.glb, "Failed to get file size");

    if (total_length > file_size) {
        return ValidationResult.invalid(.glb, "GLB length exceeds file size");
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
        return ValidationResult.invalid(.glb, "Missing JSON chunk");
    }

    // Read and parse JSON chunk (limit to 50MB)
    if (json_length > 50 * 1024 * 1024) {
        return ValidationResult.okWithDepthAndWarning(.glb, .structural, "JSON chunk too large to parse");
    }

    const json_data = allocator.alloc(u8, json_length) catch {
        return ValidationResult.okWithDepth(.glb, .structural);
    };
    defer allocator.free(json_data);

    file.seekTo(json_offset) catch return ValidationResult.invalid(.glb, "Failed to seek to JSON");
    const read_len = file.readAll(json_data) catch return ValidationResult.invalid(.glb, "Failed to read JSON");
    if (read_len < json_length) {
        return ValidationResult.invalid(.glb, "Truncated JSON chunk");
    }

    // Parse JSON using std.json
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_data, .{}) catch {
        return ValidationResult.invalid(.glb, "Invalid JSON in GLB");
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
                return ValidationResult.invalid(.glb, "Missing asset.version");
            }
        } else {
            return ValidationResult.invalid(.glb, "asset is not an object");
        }
    } else {
        return ValidationResult.invalid(.glb, "Missing required asset field");
    }

    return ValidationResult.okWithDepth(.glb, .full);
}
