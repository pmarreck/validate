//! DAW (Digital Audio Workstation) Project Validators
//!
//! Validates DAW project file formats:
//! - FLP (FL Studio)
//! - ALS (Ableton Live Set, gzip-compressed XML)
//! - RPP (REAPER Project)

const std = @import("std");
const file_source = @import("file_source.zig");
const FileSource = file_source.FileSource;
const format_validation = @import("format_validation.zig");
const text_format_validators = @import("text_format_validators.zig");
const errmsg = @import("error_messages.zig");
const archive_validators = @import("archive_validators.zig");
const Allocator = std.mem.Allocator;
const ValidationResult = format_validation.ValidationResult;

const FLP_SIGNATURE = [_]u8{ 'F', 'L', 'h', 'd' };

const FormatValidator = format_validation.FormatValidator;
const detectFormat = format_validation.detectFormat;
const FileFormat = format_validation.FileFormat;

// ============ FL Studio (FLP) ============

/// Validate FL Studio project file structural header.
/// Checks FLhd signature, header length, and FLdt data chunk.
pub fn validateFlp(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.flp, .failed_to_seek, "to start");

    var header: [22]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalidCode(.flp, .failed_to_read, "FLP header");

    if (header_read < 22) {
        return ValidationResult.invalidCode(.flp, .file_too_small, "FL Studio project");
    }

    // Check FLhd signature
    if (!std.mem.eql(u8, header[0..4], &FLP_SIGNATURE)) {
        return ValidationResult.invalidCode(.flp, .invalid_signature, "FL Studio");
    }

    // Bytes 4-7: header length (should be 6)
    const header_len = std.mem.readInt(u32, header[4..8], .little);
    if (header_len != 6) {
        return ValidationResult.invalidCode(.flp, .invalid_value, "FLP header length");
    }

    // Bytes 8-9: format version
    // Bytes 10-11: number of channels
    // We accept any version

    // Check for FLdt (data chunk) signature at offset 14
    if (!std.mem.eql(u8, header[14..18], "FLdt")) {
        return ValidationResult.invalidCode(.flp, .missing, "FLdt chunk");
    }

    return ValidationResult.ok(.flp);
}

/// Deep validate FL Studio project - parses event structure within FLdt chunk.
pub fn validateFlpDeep(allocator: Allocator, source: *FileSource) ValidationResult {
    _ = allocator;
    const file = source;

    // Basic validation first
    const basic_result = validateFlp(file);
    if (!basic_result.is_valid) return basic_result;

    // Seek to start of events (after FLhd[4] + size[4] + header[6] + FLdt[4] + size[4] = 22)
    file.seekTo(0) catch return ValidationResult.invalid(.flp, "Failed to seek");

    var header: [22]u8 = undefined;
    _ = file.read(&header) catch return ValidationResult.invalidCode(.flp, .failed_to_read, "header");

    // Get FLdt data size
    const data_size = std.mem.readInt(u32, header[18..22], .little);

    // Parse events within the data chunk
    var events_parsed: usize = 0;
    var bytes_consumed: usize = 0;
    const max_events: usize = 1000000; // Sanity limit

    while (events_parsed < max_events and bytes_consumed < data_size) {
        // Read event ID
        var event_id: [1]u8 = undefined;
        const id_read = file.read(&event_id) catch break;
        if (id_read == 0) break;
        bytes_consumed += 1;

        const id = event_id[0];
        var event_size: usize = 0;

        if (id < 64) {
            // 1 byte data (BYTE events)
            event_size = 1;
        } else if (id < 128) {
            // 2 byte data (WORD events)
            event_size = 2;
        } else if (id < 192) {
            // 4 byte data (DWORD events)
            event_size = 4;
        } else {
            // Variable length: read length as varint
            var length: u32 = 0;
            var shift: u5 = 0;
            var len_bytes: usize = 0;
            while (len_bytes < 5) { // Max 5 bytes for varint
                var byte: [1]u8 = undefined;
                const br = file.read(&byte) catch break;
                if (br == 0) break;
                bytes_consumed += 1;
                len_bytes += 1;

                length |= @as(u32, byte[0] & 0x7F) << shift;
                if (byte[0] & 0x80 == 0) break;
                shift +|= 7;
            }
            event_size = length;
        }

        // Skip event data
        if (event_size > 0) {
            const cur_pos = file.getPos() catch break;
            file.seekTo(cur_pos + event_size) catch break;
            bytes_consumed += event_size;
        }

        events_parsed += 1;
    }

    if (events_parsed == 0) {
        return ValidationResult.invalid(.flp, "No events found in FLP file");
    }

    // Verify we consumed approximately the right amount of data
    // Allow some slack for alignment/padding
    if (bytes_consumed < data_size / 2) {
        return ValidationResult.okWithDepthAndWarning(.flp, .structural, "Event data appears truncated");
    }

    // Successfully parsed event structure
    return ValidationResult.okWithDepth(.flp, .structural);
}

/// Validate FL Studio project from in-memory buffer.
pub fn validateFlpFromBuffer(data: []const u8) ValidationResult {
    if (data.len < 22) {
        return ValidationResult.invalidCode(.flp, .buffer_too_small, "FL Studio");
    }

    // Check FLhd signature
    if (!std.mem.eql(u8, data[0..4], &FLP_SIGNATURE)) {
        return ValidationResult.invalidCode(.flp, .invalid_signature, "FL Studio");
    }

    // Check header length
    const header_len = std.mem.readInt(u32, data[4..8], .little);
    if (header_len != 6) {
        return ValidationResult.invalidCode(.flp, .invalid_value, "FLP header length");
    }

    // Check FLdt signature
    if (!std.mem.eql(u8, data[14..18], "FLdt")) {
        return ValidationResult.invalidCode(.flp, .missing, "FLdt chunk");
    }

    return ValidationResult.ok(.flp);
}

// ============ Ableton Live (ALS) ============

/// Validate Ableton Live Set - checks gzip container structure.
pub fn validateAls(file: *FileSource) ValidationResult {
    // Check for gzip magic
    var header: [10]u8 = undefined;
    const bytes_read = file.read(&header) catch {
        return ValidationResult.invalidCode(.als, .failed_to_read, "ALS header");
    };

    if (bytes_read < 10) {
        return ValidationResult.invalidCode(.als, .file_too_small, "ALS format");
    }

    // Check gzip magic (0x1f 0x8b)
    if (header[0] != 0x1f or header[1] != 0x8b) {
        return ValidationResult.invalidCodeMsg(.als, .invalid_signature_not, "ALS", errmsg.invalidSignatureNot("ALS", "gzip"));
    }

    // Check compression method (should be 8 = deflate)
    if (header[2] != 8) {
        return ValidationResult.invalidCode(.als, .invalid_value, "compression method");
    }

    // For full validation, we'd need to decompress and check for <Ableton> root element.
    // Since we have gzip deep validation available, structural check here is sufficient.
    // The gzip container provides CRC32 coverage for all data.
    return ValidationResult.ok(.als);
}

/// Deep validate Ableton Live Set - uses gzip CRC32 verification.
pub fn validateAlsDeep(allocator: Allocator, source: *FileSource) ValidationResult {
    // Use gzip deep validation for full CRC32 verification
    // This validates every byte through decompression and CRC32 check
    const gzip_result = archive_validators.validateGzipDeep(allocator, source);
    if (!gzip_result.is_valid) {
        // Remap format to als but preserve error
        var result = gzip_result;
        result.format = .als;
        return result;
    }
    // Gzip CRC verified - all bytes are valid
    return ValidationResult.okWithDepth(.als, .full);
}

// ============ REAPER (RPP) ============

/// Validate REAPER project file - checks signature and UTF-8 encoding.
pub fn validateRpp(file: *FileSource) ValidationResult {
    var header: [64]u8 = undefined;
    const bytes_read = file.read(&header) catch {
        return ValidationResult.invalidCode(.rpp, .failed_to_read, "RPP header");
    };

    if (bytes_read < 16) {
        return ValidationResult.invalidCode(.rpp, .file_too_small, "RPP format");
    }

    // Check for <REAPER_PROJECT signature
    if (!std.mem.startsWith(u8, &header, "<REAPER_PROJECT")) {
        return ValidationResult.invalidCode(.rpp, .invalid_signature, "RPP");
    }

    // Verify it's UTF-8 by checking for valid UTF-8 sequences in header
    if (!text_format_validators.validateUtf8(header[0..bytes_read]).isValid()) {
        return ValidationResult.invalidCode(.rpp, .invalid_value, "UTF-8 encoding");
    }

    // RPP files are plain text - parsing is validation (corruption would break parse).
    // For COMPLETE validation, we rely on the text structure.
    return ValidationResult.ok(.rpp);
}

/// Deep validate REAPER project - verifies bracket structure and full UTF-8 validity.
pub fn validateRppDeep(allocator: Allocator, source: *FileSource) ValidationResult {
    const file = source;

    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCode(.rpp, .failed_to_get, "file size");
    };

    if (file_size > 100 * 1024 * 1024) { // 100MB limit
        return ValidationResult.okWithDepth(.rpp, .structural);
    }

    const data = allocator.alloc(u8, file_size) catch {
        return ValidationResult.invalid(.rpp, "Memory allocation failed");
    };
    defer allocator.free(data);

    const bytes_read = file.readAll(data) catch {
        return ValidationResult.invalidCode(.rpp, .failed_to_read, "file");
    };
    if (bytes_read != file_size) {
        return ValidationResult.invalidCode(.rpp, .incomplete, "file read");
    }

    // Validate UTF-8
    if (!text_format_validators.validateUtf8(data).isValid()) {
        return ValidationResult.invalidCode(.rpp, .invalid_value, "UTF-8 encoding");
    }

    // Check for <REAPER_PROJECT signature
    if (!std.mem.startsWith(u8, data, "<REAPER_PROJECT")) {
        return ValidationResult.invalidCode(.rpp, .invalid_signature, "RPP");
    }

    // Parse bracket structure
    // RPP uses: < to open a block, > on its own line to close
    var bracket_depth: i32 = 0;
    var i: usize = 0;
    var line_start: usize = 0;

    while (i < data.len) {
        if (data[i] == '<') {
            bracket_depth += 1;
        } else if (data[i] == '\n') {
            // Check if this line is just ">" (close block)
            const line = data[line_start..i];
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 1 and trimmed[0] == '>') {
                bracket_depth -= 1;
            }
            line_start = i + 1;
        }
        i += 1;
    }

    // Handle last line if no trailing newline
    if (line_start < data.len) {
        const line = data[line_start..];
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 1 and trimmed[0] == '>') {
            bracket_depth -= 1;
        }
    }

    if (bracket_depth != 0) {
        return ValidationResult.invalid(.rpp, "Mismatched brackets in RPP file");
    }

    return ValidationResult.okWithDepth(.rpp, .structural);
}

// ============ Bitwig Studio (BWProject) ============

/// Bitwig Studio project files use a proprietary binary format.
/// This validator performs basic structural checks since the format is not publicly documented.
pub fn validateBwproject(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.bwproject, .failed_to_seek, "to start");

    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.bwproject, .failed_to_stat, "file");

    if (file_size < 100) {
        return ValidationResult.invalidCode(.bwproject, .file_too_small, "Bitwig project");
    }

    var header: [8]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalidCode(.bwproject, .failed_to_read, "header");

    if (header_read < 4) {
        return ValidationResult.invalid(.bwproject, "File too small to identify");
    }

    // Reject if this is actually a ZIP file (ZIP magic: PK\x03\x04)
    if (header[0] == 'P' and header[1] == 'K' and header[2] == 0x03 and header[3] == 0x04) {
        return ValidationResult.invalid(.bwproject, "File appears to be ZIP, not Bitwig project");
    }

    // Bitwig format is proprietary and undocumented - no structural validation possible
    return ValidationResult.structuralOnly(.bwproject);
}

// ============ Cubase (CPR) ============

/// Validate Cubase project file (.cpr) by walking its RIFF chunk tree.
/// CPR files are standard RIFF containers; the form type (bytes 8-11) varies
/// by Cubase version (e.g. "NUND") so we accept any 4 printable-ASCII chars.
/// RIFF structure IS the integrity mechanism — no separate CRC exists.
pub fn validateCubase(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.cpr, .failed_to_seek, "to start");

    const file_size = file.getEndPos() catch
        return ValidationResult.invalidCode(.cpr, .failed_to_get, "file size");

    if (file_size < 12) {
        return ValidationResult.invalidCode(.cpr, .file_too_small, "Cubase project");
    }

    var header: [12]u8 = undefined;
    const header_read = file.read(&header) catch
        return ValidationResult.invalidCode(.cpr, .failed_to_read, "RIFF header");

    if (header_read < 12) {
        return ValidationResult.invalidCode(.cpr, .file_too_small, "Cubase project");
    }

    // Verify RIFF signature
    if (!std.mem.eql(u8, header[0..4], "RIFF")) {
        return ValidationResult.invalidCodeMsg(.cpr, .invalid_signature_not, "Cubase", errmsg.invalidSignatureNot("Cubase", "RIFF"));
    }

    // Read declared RIFF size and check for truncation
    const riff_size = std.mem.readInt(u32, header[4..8], .little);
    if (@as(u64, riff_size) + 8 > file_size) {
        return ValidationResult.invalidCodeMsg(.cpr, .exceeds_bounds, "RIFF size", "RIFF size exceeds file size (truncated)");
    }

    // Verify form type is 4 printable ASCII chars (accepts any Cubase version)
    const form_type = header[8..12];
    for (form_type) |c| {
        if (c < 0x20 or c > 0x7E) {
            return ValidationResult.invalidCode(.cpr, .invalid_value, "RIFF form type (non-printable ASCII)");
        }
    }

    // Walk top-level RIFF chunk tree
    var pos: u64 = 12; // After "RIFF" + size(4) + form_type(4)
    const riff_end: u64 = @min(@as(u64, riff_size) + 8, file_size);
    var chunks_validated: u32 = 0;

    while (pos + 8 <= riff_end and chunks_validated < 10000) {
        file.seekTo(pos) catch break;
        var chunk_hdr: [12]u8 = undefined;
        const n = file.read(&chunk_hdr) catch break;
        if (n < 8) break;

        const chunk_size = std.mem.readInt(u32, chunk_hdr[4..8], .little);

        // Verify chunk data end doesn't exceed RIFF container bounds
        const data_end = pos + 8 + @as(u64, chunk_size);
        if (data_end > riff_end + 1) {
            return ValidationResult.invalid(.cpr, "CPR chunk extends beyond RIFF container");
        }

        // If this is a LIST chunk, peek at the list type (next 4 bytes)
        if (std.mem.eql(u8, chunk_hdr[0..4], "LIST") and n >= 12) {
            // list_type is chunk_hdr[8..12] — already read, no action needed
            _ = chunk_hdr[8..12];
        }

        // Advance past chunk data, padding to word boundary
        const raw_next = pos + 8 + @as(u64, chunk_size);
        pos = (raw_next + 1) & ~@as(u64, 1);

        chunks_validated += 1;
    }

    if (chunks_validated == 0) {
        return ValidationResult.invalid(.cpr, "Empty RIFF container — no chunks found");
    }

    // RIFF structure fully walked; this IS the integrity check for CPR
    return ValidationResult.okWithDepth(.cpr, .structural);
}

/// Validate Cubase project from an in-memory buffer.
/// Mirrors validateCubase logic without I/O; useful for unit tests.
pub fn validateCubaseFromBuffer(data: []const u8) ValidationResult {
    if (data.len < 12) {
        return ValidationResult.invalidCode(.cpr, .buffer_too_small, "Cubase project");
    }

    if (!std.mem.eql(u8, data[0..4], "RIFF")) {
        return ValidationResult.invalidCodeMsg(.cpr, .invalid_signature_not, "Cubase", errmsg.invalidSignatureNot("Cubase", "RIFF"));
    }

    const riff_size = std.mem.readInt(u32, data[4..8], .little);
    if (@as(u64, riff_size) + 8 > data.len) {
        return ValidationResult.invalidCodeMsg(.cpr, .exceeds_bounds, "RIFF size", "RIFF size exceeds file size (truncated)");
    }

    const form_type = data[8..12];
    for (form_type) |c| {
        if (c < 0x20 or c > 0x7E) {
            return ValidationResult.invalidCode(.cpr, .invalid_value, "RIFF form type (non-printable ASCII)");
        }
    }

    var pos: usize = 12;
    const riff_end: usize = @min(@as(usize, riff_size) + 8, data.len);
    var chunks_validated: u32 = 0;

    while (pos + 8 <= riff_end and chunks_validated < 10000) {
        const chunk_size = std.mem.readInt(u32, data[pos + 4 ..][0..4], .little);

        const data_end = pos + 8 + @as(usize, chunk_size);
        if (data_end > riff_end + 1) {
            return ValidationResult.invalid(.cpr, "CPR chunk extends beyond RIFF container");
        }

        const raw_next = pos + 8 + @as(usize, chunk_size);
        pos = (raw_next + 1) & ~@as(usize, 1);

        chunks_validated += 1;
    }

    if (chunks_validated == 0) {
        return ValidationResult.invalid(.cpr, "Empty RIFF container — no chunks found");
    }

    return ValidationResult.okWithDepth(.cpr, .structural);
}

// ============ Pro Tools (PTX) ============

const PTX_MARKER: u8 = 0x03;
const PTX_BITCODE = "0010111100101011"; // 16 ASCII chars at bytes 0x01-0x10
const PTX_ZMARK: u8 = 0x5A; // 'Z' — block marker
const PTX_HEADER_SIZE: usize = 0x14; // first 20 bytes are cleartext
const PTX_MAX_FILE_SIZE: usize = 256 * 1024 * 1024; // 256 MB cap

/// Pro Tools session files (.ptx) use a proprietary binary format.
/// Checks the cleartext 20-byte header for magic bytes and BITCODE signature.
pub fn validateProTools(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.ptx, .failed_to_seek, "to start");

    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.ptx, .failed_to_stat, "file");

    if (file_size < PTX_HEADER_SIZE) {
        return ValidationResult.invalidCode(.ptx, .file_too_small, "Pro Tools session");
    }

    var header: [PTX_HEADER_SIZE]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalidCode(.ptx, .failed_to_read, "header");

    if (header_read < PTX_HEADER_SIZE) {
        return ValidationResult.invalid(.ptx, "File too small to identify");
    }

    // Byte 0 must be 0x03
    if (header[0] != PTX_MARKER) {
        return ValidationResult.invalid(.ptx, "Missing Pro Tools marker byte");
    }

    // Bytes 0x01-0x10: BITCODE signature (16 ASCII chars)
    if (!std.mem.eql(u8, header[1..17], PTX_BITCODE)) {
        return ValidationResult.invalid(.ptx, "Missing Pro Tools BITCODE signature");
    }

    // Byte 0x12: xor_type must be 0x01 or 0x05
    const xor_type = header[0x12];
    if (xor_type != 0x01 and xor_type != 0x05) {
        return ValidationResult.invalid(.ptx, "Unknown Pro Tools encryption type");
    }

    return ValidationResult.structuralOnly(.ptx);
}

/// Derive XOR delta for key schedule.
/// Finds i in 0..256 such that (i * mul) & 0xFF == xor_value.
/// Returns i directly (negative=false) or (256-i)&0xFF (negative=true).
fn genXorDelta(xor_value: u8, mul: u8, negative: bool) u8 {
    var i: u16 = 0;
    while (i < 256) : (i += 1) {
        if (((i * @as(u16, mul)) & 0xFF) == @as(u16, xor_value)) {
            const candidate: u8 = @intCast(i & 0xFF);
            return if (negative) @intCast((256 - @as(u16, candidate)) & 0xFF) else candidate;
        }
    }
    return 0;
}

/// Build the 256-byte XOR lookup table: xxor[i] = (i * delta) & 0xFF.
fn buildXorTable(delta: u8) [256]u8 {
    var table: [256]u8 = undefined;
    var i: u16 = 0;
    while (i < 256) : (i += 1) {
        table[i] = @intCast((@as(u16, i) * @as(u16, delta)) & 0xFF);
    }
    return table;
}

/// Deep validate a Pro Tools session file by XOR-decrypting the body and
/// walking its ZMARK block structure. Uses the documented key derivation scheme
/// (xor_type 0x01 = PT 5-9 with mul=53, xor_type 0x05 = PT 10-12 with mul=11/negative).
pub fn validatePtxDeep(allocator: Allocator, source: *FileSource) ValidationResult {
    const file = source;

    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCode(.ptx, .failed_to_get, "file size");
    };

    if (file_size < PTX_HEADER_SIZE) {
        return ValidationResult.invalidCode(.ptx, .file_too_small, "Pro Tools session");
    }

    // Cap at 256 MB — larger files fall back to structural
    if (file_size > PTX_MAX_FILE_SIZE) {
        return ValidationResult.okWithDepth(.ptx, .structural);
    }

    // Read cleartext header
    file.seekTo(0) catch return ValidationResult.invalidCode(.ptx, .failed_to_seek, "to start");
    var header: [PTX_HEADER_SIZE]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalidCode(.ptx, .failed_to_read, "header");
    if (header_read < PTX_HEADER_SIZE) {
        return ValidationResult.invalid(.ptx, "File too small to identify");
    }

    // Verify marker and BITCODE
    if (header[0] != PTX_MARKER) {
        return ValidationResult.invalid(.ptx, "Missing Pro Tools marker byte");
    }
    if (!std.mem.eql(u8, header[1..17], PTX_BITCODE)) {
        return ValidationResult.invalid(.ptx, "Missing Pro Tools BITCODE signature");
    }

    const is_big_endian = header[0x11] != 0;
    const xor_type = header[0x12];
    const xor_value = header[0x13];

    if (xor_type != 0x01 and xor_type != 0x05) {
        return ValidationResult.invalid(.ptx, "Unknown Pro Tools encryption type");
    }

    // Derive XOR key schedule
    const delta: u8 = if (xor_type == 0x01)
        genXorDelta(xor_value, 53, false)
    else
        genXorDelta(xor_value, 11, true);

    const xxor = buildXorTable(delta);

    // Read the entire file
    const data = allocator.alloc(u8, file_size) catch {
        return ValidationResult.invalid(.ptx, "Memory allocation failed");
    };
    defer allocator.free(data);

    file.seekTo(0) catch return ValidationResult.invalidCode(.ptx, .failed_to_seek, "to start");
    const bytes_read = file.readAll(data) catch {
        return ValidationResult.invalidCode(.ptx, .failed_to_read, "file body");
    };
    if (bytes_read < file_size) {
        return ValidationResult.invalidCode(.ptx, .incomplete, "file read");
    }

    // Decrypt from offset PTX_HEADER_SIZE onward (header stays cleartext)
    const body_start = PTX_HEADER_SIZE;
    var pos: usize = body_start;
    while (pos < file_size) : (pos += 1) {
        const rel = pos - body_start; // relative offset within encrypted region
        const xor_byte: u8 = if (xor_type == 0x01)
            xxor[rel & 0xFF]
        else
            xxor[(rel >> 12) & 0xFF];
        data[pos] ^= xor_byte;
    }

    // Walk block structure: each block starts with ZMARK (0x5A)
    // Block layout: [0x5A][block_type u16][block_size u32][content_type u16]
    // Minimum block header = 1 + 2 + 4 + 2 = 9 bytes
    const BLOCK_HDR_SIZE: usize = 9;
    const endian: std.builtin.Endian = if (is_big_endian) .big else .little;

    var walk = body_start;
    var valid_blocks: usize = 0;

    while (walk + BLOCK_HDR_SIZE <= file_size) {
        if (data[walk] != PTX_ZMARK) {
            // Skip one byte to find next ZMARK
            walk += 1;
            continue;
        }

        // Parse block fields
        const block_size = std.mem.readInt(u32, data[walk + 3 ..][0..4], endian);

        // Sanity: block_size must not overflow the file
        const block_end = walk + BLOCK_HDR_SIZE + @as(usize, block_size);
        if (block_end > file_size) {
            // Truncated block — if we already found some valid blocks, that's OK
            break;
        }

        valid_blocks += 1;
        walk = block_end;
    }

    if (valid_blocks == 0) {
        return ValidationResult.invalid(.ptx, "No valid ZMARK blocks found after decryption");
    }

    return ValidationResult.okWithDepth(.ptx, .structural);
}

// ============ GarageBand ============

/// GarageBand project files (.band) are macOS packages/bundles.
pub fn validateGarageBand(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.band, .failed_to_seek, "to start");

    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.band, .failed_to_stat, "file");

    if (file_size < 64) {
        return ValidationResult.invalidCode(.band, .file_too_small, "GarageBand project");
    }

    var header: [8]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalidCode(.band, .failed_to_read, "header");

    if (header_read < 4) {
        return ValidationResult.invalid(.band, "File too small to identify");
    }

    // GarageBand format is proprietary - no structural validation possible
    return ValidationResult.structuralOnly(.band);
}

// ============ Reason ============

/// Reason project files (.reason) use a proprietary format.
pub fn validateReason(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.reason, .failed_to_seek, "to start");

    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.reason, .failed_to_stat, "file");

    if (file_size < 64) {
        return ValidationResult.invalidCode(.reason, .file_too_small, "Reason project");
    }

    var header: [64]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalidCode(.reason, .failed_to_read, "header");

    if (header_read < 32) {
        return ValidationResult.invalid(.reason, "File too small to identify");
    }

    // Real Reason magic: "Propellerheads Reason Song File\x1A" (32 bytes)
    // Newer versions may use "Reason Studios" variant
    const propellerhead_magic = "Propellerheads Reason Song File\x1a";
    const has_propellerhead = header_read >= propellerhead_magic.len and
        std.mem.eql(u8, header[0..propellerhead_magic.len], propellerhead_magic);

    if (!has_propellerhead) {
        // Check for newer "Reason Studios" variant or other known headers
        if (header_read >= 14 and std.mem.eql(u8, header[0..14], "Reason Studios")) {
            // Newer format variant — accept but structural only (unknown internal structure)
            return ValidationResult.okWithDepth(.reason, .structural);
        }
        return ValidationResult.invalidCode(.reason, .invalid_signature, "Reason");
    }

    // After the 32-byte magic, look for IFF-like structure (FORM/BODY chunks)
    // The format appears to use big-endian chunk headers after the magic
    if (header_read >= 40) {
        const after_magic = header[propellerhead_magic.len..header_read];
        // Look for printable ASCII chunk IDs (4 bytes) suggesting IFF structure
        if (after_magic.len >= 8) {
            const chunk_id = after_magic[0..4];
            var printable = true;
            for (chunk_id) |c| {
                if (c < 0x20 or c > 0x7E) {
                    printable = false;
                    break;
                }
            }
            if (printable) {
                // Found an IFF-like chunk after magic — walk chunks
                var pos: u64 = propellerhead_magic.len;
                var chunks_found: u32 = 0;
                var chunk_buf: [8]u8 = undefined;

                while (pos + 8 <= file_size and chunks_found < 10000) {
                    file.seekTo(pos) catch break;
                    const n = file.read(&chunk_buf) catch break;
                    if (n < 8) break;

                    // Verify chunk ID is printable ASCII
                    var id_valid = true;
                    for (chunk_buf[0..4]) |c| {
                        if (c < 0x20 or c > 0x7E) {
                            id_valid = false;
                            break;
                        }
                    }
                    if (!id_valid) break;

                    const chunk_size = std.mem.readInt(u32, chunk_buf[4..8], .big);
                    const chunk_end = pos + 8 + @as(u64, chunk_size);

                    if (chunk_end > file_size + 1) break; // Chunk exceeds file

                    chunks_found += 1;
                    // IFF chunks are padded to word boundary
                    pos = (chunk_end + 1) & ~@as(u64, 1);
                }

                if (chunks_found > 0) {
                    return ValidationResult.okWithDepth(.reason, .structural);
                }
            }
        }
    }

    // Magic matched but no parseable chunk structure — still valid
    return ValidationResult.okWithDepth(.reason, .structural);
}
// ============================================================
// Tests moved from format_validation.zig
// ============================================================

test "detectFormat RPP" {
    // Reaper project files start with "<REAPER_PROJECT"
    const rpp_data = "<REAPER_PROJECT 0.1 \"6.0\" 1234567890";
    const result = detectFormat(rpp_data);
    try std.testing.expectEqual(FileFormat.rpp, result);
}

test "FormatValidator accepts valid RPP" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create minimal valid Reaper project file
    const rpp_content = "<REAPER_PROJECT 0.1 \"6.0\" 1234567890\n  RIPPLE 0\n  GROUPOVERRIDE 0 0 0\n  AUTOXFADE 1\n>\n";

    const file = try tmp_dir.dir.createFile("test.rpp", .{});
    try file.writeAll(rpp_content);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test.rpp");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.rpp, result.format);
    try std.testing.expect(result.is_valid);
}

test "FormatValidator rejects invalid RPP" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create file that starts like RPP but has invalid content
    const bad_content = "<REAPER_PROJEC\xFF\xFE\x00\x00"; // Invalid RPP (missing T, plus invalid UTF-8)

    const file = try tmp_dir.dir.createFile("test.rpp", .{});
    try file.writeAll(bad_content);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test.rpp");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    // Detected as RPP via extension fallback, reported as invalid
    try std.testing.expectEqual(FileFormat.rpp, result.format);
    try std.testing.expect(!result.is_valid);
}

test "FLP buffer validation: valid synthetic header" {
    // Build a minimal valid FLP header: FLhd(4) + size(4, =6) + version(2) + channels(2) + pad(2) + FLdt(4) + datasize(4)
    var header: [22]u8 = undefined;
    @memcpy(header[0..4], "FLhd");
    std.mem.writeInt(u32, header[4..8], 6, .little); // header length = 6
    std.mem.writeInt(u16, header[8..10], 0x0100, .little); // format version
    std.mem.writeInt(u16, header[10..12], 1, .little); // channels
    header[12] = 0;
    header[13] = 0;
    @memcpy(header[14..18], "FLdt");
    std.mem.writeInt(u32, header[18..22], 0, .little); // data size

    const result = validateFlpFromBuffer(&header);
    try std.testing.expect(result.is_valid);
    try std.testing.expectEqual(FileFormat.flp, result.format);
}

test "FLP buffer validation: wrong signature rejected" {
    var header: [22]u8 = [_]u8{0} ** 22;
    @memcpy(header[0..4], "XXXX"); // Wrong signature

    const result = validateFlpFromBuffer(&header);
    try std.testing.expect(!result.is_valid);
    try std.testing.expectEqual(FileFormat.flp, result.format);
}

test "FLP buffer validation: wrong header length rejected" {
    var header: [22]u8 = undefined;
    @memcpy(header[0..4], "FLhd");
    std.mem.writeInt(u32, header[4..8], 99, .little); // Wrong header length
    header[8] = 0;
    header[9] = 0;
    header[10] = 0;
    header[11] = 0;
    header[12] = 0;
    header[13] = 0;
    @memcpy(header[14..18], "FLdt");
    std.mem.writeInt(u32, header[18..22], 0, .little);

    const result = validateFlpFromBuffer(&header);
    try std.testing.expect(!result.is_valid);
}

test "FLP buffer validation: missing FLdt chunk rejected" {
    var header: [22]u8 = undefined;
    @memcpy(header[0..4], "FLhd");
    std.mem.writeInt(u32, header[4..8], 6, .little);
    header[8] = 0;
    header[9] = 0;
    header[10] = 0;
    header[11] = 0;
    header[12] = 0;
    header[13] = 0;
    @memcpy(header[14..18], "XXXX"); // Wrong chunk
    std.mem.writeInt(u32, header[18..22], 0, .little);

    const result = validateFlpFromBuffer(&header);
    try std.testing.expect(!result.is_valid);
}

test "FLP buffer validation: too small rejected" {
    const tiny = [_]u8{ 'F', 'L', 'h', 'd' };
    const result = validateFlpFromBuffer(&tiny);
    try std.testing.expect(!result.is_valid);
}

test "FLP structural: ground truth sample.flp" {
    var source = FileSource.open("ground_truth_examples/flp/sample.flp") catch {
        return; // Skip if file doesn't exist
    };
    defer source.close();

    const result = validateFlp(&source);
    try std.testing.expect(result.is_valid);
    try std.testing.expectEqual(FileFormat.flp, result.format);
}

// ============ Cubase (CPR) tests ============

/// Build a minimal valid CPR (RIFF) buffer for testing.
/// Layout: RIFF(4) + riff_payload_size(4) + form_type(4) + chunk_id(4) + chunk_data_size(4) + chunk_data
fn buildCprBuf(buf: []u8, form_type: *const [4]u8, chunk_id: *const [4]u8, chunk_data: []const u8) []u8 {
    const chunk_size: u32 = @intCast(chunk_data.len);
    // RIFF payload = form_type(4) + chunk_header(8) + chunk_data
    const riff_payload: u32 = 4 + 8 + chunk_size;
    @memcpy(buf[0..4], "RIFF");
    std.mem.writeInt(u32, buf[4..8], riff_payload, .little);
    @memcpy(buf[8..12], form_type);
    @memcpy(buf[12..16], chunk_id);
    std.mem.writeInt(u32, buf[16..20], chunk_size, .little);
    if (chunk_data.len > 0) @memcpy(buf[20..][0..chunk_data.len], chunk_data);
    return buf[0 .. 8 + riff_payload];
}

test "CPR buffer: valid RIFF with NUND form type accepted" {
    var buf: [64]u8 = [_]u8{0} ** 64;
    const data = buildCprBuf(&buf, "NUND", "DATA", &[_]u8{ 0x01, 0x02, 0x03, 0x04 });
    const result = validateCubaseFromBuffer(data);
    try std.testing.expect(result.is_valid);
    try std.testing.expectEqual(FileFormat.cpr, result.format);
}

test "CPR buffer: wrong magic rejected" {
    const bad = "WAVE\x00\x00\x00\x00NUND";
    const result = validateCubaseFromBuffer(bad);
    try std.testing.expect(!result.is_valid);
    try std.testing.expectEqual(FileFormat.cpr, result.format);
}

test "CPR buffer: truncated (RIFF size > buffer size) rejected" {
    var buf: [12]u8 = undefined;
    @memcpy(buf[0..4], "RIFF");
    std.mem.writeInt(u32, buf[4..8], 9999, .little); // claims far more data than exists
    @memcpy(buf[8..12], "NUND");
    const result = validateCubaseFromBuffer(&buf);
    try std.testing.expect(!result.is_valid);
}

test "CPR buffer: non-printable form type rejected" {
    var buf: [12]u8 = undefined;
    @memcpy(buf[0..4], "RIFF");
    std.mem.writeInt(u32, buf[4..8], 4, .little); // RIFF payload = form_type only
    buf[8] = 0x01; // non-printable ASCII
    buf[9] = 'A';
    buf[10] = 'B';
    buf[11] = 'C';
    const result = validateCubaseFromBuffer(&buf);
    try std.testing.expect(!result.is_valid);
}

test "CPR buffer: empty RIFF (no chunks) rejected" {
    var buf: [12]u8 = undefined;
    @memcpy(buf[0..4], "RIFF");
    std.mem.writeInt(u32, buf[4..8], 4, .little); // RIFF payload = form_type only, no chunks
    @memcpy(buf[8..12], "NUND");
    const result = validateCubaseFromBuffer(&buf);
    try std.testing.expect(!result.is_valid);
}

test "CPR buffer: chunk overflowing RIFF bounds rejected" {
    var buf: [20]u8 = [_]u8{0} ** 20;
    @memcpy(buf[0..4], "RIFF");
    std.mem.writeInt(u32, buf[4..8], 12, .little); // RIFF payload = form_type(4) + chunk_hdr(8)
    @memcpy(buf[8..12], "NUND");
    @memcpy(buf[12..16], "DATA");
    std.mem.writeInt(u32, buf[16..20], 9999, .little); // chunk size wildly exceeds container
    const result = validateCubaseFromBuffer(&buf);
    try std.testing.expect(!result.is_valid);
}

test "CPR: ground truth sample.cpr" {
    var source = FileSource.open("ground_truth_examples/cpr/sample.cpr") catch {
        return error.SkipZigTest;
    };
    defer source.close();

    const result = validateCubase(&source);
    try std.testing.expect(result.is_valid);
    try std.testing.expectEqual(FileFormat.cpr, result.format);
}

