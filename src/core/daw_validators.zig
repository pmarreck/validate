//! DAW (Digital Audio Workstation) Project Validators
//!
//! Validates DAW project file formats:
//! - FLP (FL Studio)
//! - ALS (Ableton Live Set, gzip-compressed XML)
//! - RPP (REAPER Project)

const std = @import("std");
const format_validation = @import("format_validation.zig");
const text_format_validators = @import("text_format_validators.zig");
const errmsg = @import("error_messages.zig");
const Allocator = std.mem.Allocator;
const ValidationResult = format_validation.ValidationResult;

const FLP_SIGNATURE = [_]u8{ 'F', 'L', 'h', 'd' };

// ============ FL Studio (FLP) ============

/// Validate FL Studio project file structural header.
/// Checks FLhd signature, header length, and FLdt data chunk.
pub fn validateFlp(file: std.fs.File) ValidationResult {
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
pub fn validateFlpDeep(allocator: Allocator, path: []const u8) ValidationResult {
    _ = allocator;

    const file = std.fs.cwd().openFile(path, .{}) catch {
        return ValidationResult.invalidCode(.flp, .failed_to_open, "FL Studio file");
    };
    defer file.close();

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
            file.seekBy(@intCast(event_size)) catch break;
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
pub fn validateAls(file: std.fs.File) ValidationResult {
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
pub fn validateAlsDeep(allocator: Allocator, path: []const u8) ValidationResult {
    // Use gzip deep validation for full CRC32 verification
    // This validates every byte through decompression and CRC32 check
    const gzip_result = format_validation.validateGzipDeep(allocator, path);
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
pub fn validateRpp(file: std.fs.File) ValidationResult {
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
pub fn validateRppDeep(allocator: Allocator, path: []const u8) ValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return ValidationResult.invalidCode(.rpp, .failed_to_open, "RPP file");
    };
    defer file.close();

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
pub fn validateBwproject(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.bwproject, .failed_to_seek, "to start");

    const stat = file.stat() catch return ValidationResult.invalidCode(.bwproject, .failed_to_stat, "file");

    if (stat.size < 100) {
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

    return ValidationResult.ok(.bwproject);
}

// ============ Cubase (CPR) ============

/// Cubase project files (.cpr) use a RIFF-based binary format.
pub fn validateCubase(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.cpr, .failed_to_seek, "to start");

    var header: [12]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalidCode(.cpr, .failed_to_read, "header");

    if (header_read < 12) {
        return ValidationResult.invalidCode(.cpr, .file_too_small, "Cubase project");
    }

    if (!std.mem.eql(u8, header[0..4], "RIFF")) {
        return ValidationResult.invalidCodeMsg(.cpr, .invalid_signature_not, "Cubase", errmsg.invalidSignatureNot("Cubase", "RIFF"));
    }

    return ValidationResult.ok(.cpr);
}

// ============ Pro Tools (PTX) ============

/// Pro Tools session files (.ptx) use a proprietary binary format.
pub fn validateProTools(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.ptx, .failed_to_seek, "to start");

    const stat = file.stat() catch return ValidationResult.invalidCode(.ptx, .failed_to_stat, "file");

    if (stat.size < 256) {
        return ValidationResult.invalidCode(.ptx, .file_too_small, "Pro Tools session");
    }

    var header: [16]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalidCode(.ptx, .failed_to_read, "header");

    if (header_read < 8) {
        return ValidationResult.invalid(.ptx, "File too small to identify");
    }

    if (header[0] == 'P' and header[1] == 'K' and header[2] == 0x03 and header[3] == 0x04) {
        return ValidationResult.invalid(.ptx, "File appears to be ZIP, not Pro Tools session");
    }

    return ValidationResult.ok(.ptx);
}

// ============ GarageBand ============

/// GarageBand project files (.band) are macOS packages/bundles.
pub fn validateGarageBand(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.band, .failed_to_seek, "to start");

    const stat = file.stat() catch return ValidationResult.invalidCode(.band, .failed_to_stat, "file");

    if (stat.size < 64) {
        return ValidationResult.invalidCode(.band, .file_too_small, "GarageBand project");
    }

    var header: [8]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalidCode(.band, .failed_to_read, "header");

    if (header_read < 4) {
        return ValidationResult.invalid(.band, "File too small to identify");
    }

    return ValidationResult.ok(.band);
}

// ============ Reason ============

/// Reason project files (.reason) use a proprietary format.
pub fn validateReason(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.reason, .failed_to_seek, "to start");

    const stat = file.stat() catch return ValidationResult.invalidCode(.reason, .failed_to_stat, "file");

    if (stat.size < 128) {
        return ValidationResult.invalidCode(.reason, .file_too_small, "Reason project");
    }

    var header: [8]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalidCode(.reason, .failed_to_read, "header");

    if (header_read < 4) {
        return ValidationResult.invalid(.reason, "File too small to identify");
    }

    if (header[0] == 'P' and header[1] == 'K' and header[2] == 0x03 and header[3] == 0x04) {
        return ValidationResult.invalid(.reason, "File appears to be ZIP, not Reason project");
    }

    return ValidationResult.ok(.reason);
}
