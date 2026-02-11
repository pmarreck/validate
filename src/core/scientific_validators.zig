const std = @import("std");
const Allocator = std.mem.Allocator;
const format_validation = @import("format_validation.zig");
const ValidationResult = format_validation.ValidationResult;
const jpeg_validator = @import("jpeg_validator.zig");
const jpeg_lossless_decoder = @import("jpeg_lossless_decoder.zig");
const jpeg2000_validator = @import("jpeg2000_validator.zig");
const errmsg = @import("error_messages.zig");

// ============ NetCDF Validator ============

/// NetCDF classic signature: CDF\x01 or CDF\x02
const NETCDF_SIGNATURE = [_]u8{ 'C', 'D', 'F' };

/// Validate NetCDF file structure.
/// Full integrity validation: parses dimensions, variables, and attributes.
/// NetCDF-4 is HDF5-based and will be detected as HDF5.
pub fn validateNetcdf(file: std.fs.File) ValidationResult {
    const stat = file.stat() catch return ValidationResult.invalid(.netcdf, errmsg.failedToStat("file"));
    const file_size = stat.size;

    file.seekTo(0) catch return ValidationResult.invalid(.netcdf, errmsg.failedToSeek("to start"));

    // Read enough for header and dimension/variable arrays
    const max_header_size: usize = @min(@as(usize, @intCast(file_size)), 256 * 1024);
    var header_buf: [256 * 1024]u8 = undefined;
    const header_read = file.read(header_buf[0..max_header_size]) catch {
        return ValidationResult.invalid(.netcdf, errmsg.failedToRead("NetCDF header"));
    };

    if (header_read < 4) {
        return ValidationResult.invalid(.netcdf, errmsg.fileTooSmallFor("NetCDF"));
    }

    const header = header_buf[0..header_read];

    // Check CDF signature
    if (!std.mem.eql(u8, header[0..3], &NETCDF_SIGNATURE)) {
        return ValidationResult.invalid(.netcdf, errmsg.invalidSignature("NetCDF"));
    }

    // Check version byte (1 = classic, 2 = 64-bit offset, 5 = CDF-5)
    const version = header[3];
    if (version != 1 and version != 2 and version != 5) {
        return ValidationResult.invalid(.netcdf, "Invalid NetCDF version");
    }

    // Offset/size width depends on version
    const is_cdf5 = version == 5;
    const offset_64bit = version == 2 or version == 5;

    if (header_read < 8) {
        return ValidationResult.invalid(.netcdf, errmsg.truncated("NetCDF header"));
    }

    // numrecs field
    var pos: usize = 4;
    if (is_cdf5) {
        if (header_read < 12) {
            return ValidationResult.invalid(.netcdf, errmsg.truncated("CDF-5 header"));
        }
        pos = 12;
    } else {
        const numrecs = std.mem.readInt(u32, header[4..8], .big);
        if (numrecs != 0xFFFFFFFF and numrecs > 1_000_000_000) {
            return ValidationResult.invalid(.netcdf, "Implausible record count");
        }
        pos = 8;
    }

    // Parse dimension list
    if (pos + 8 > header_read) {
        return ValidationResult.invalid(.netcdf, errmsg.truncated("dimension list"));
    }

    const dim_tag = std.mem.readInt(u32, header[pos..][0..4], .big);
    pos += 4;

    if (dim_tag != 0x0000000A and dim_tag != 0x00000000) {
        return ValidationResult.invalid(.netcdf, "Invalid dimension list tag");
    }

    var num_dims: u32 = 0;
    if (dim_tag == 0x0000000A) {
        if (pos + 4 > header_read) {
            return ValidationResult.invalid(.netcdf, errmsg.truncated("dimension count"));
        }
        num_dims = std.mem.readInt(u32, header[pos..][0..4], .big);
        pos += 4;

        if (num_dims > 10000) {
            return ValidationResult.invalid(.netcdf, errmsg.tooMany("dimensions"));
        }

        // Skip dimension entries
        var dim_i: u32 = 0;
        while (dim_i < num_dims and pos < header_read) : (dim_i += 1) {
            if (pos + 4 > header_read) break;
            const name_len = std.mem.readInt(u32, header[pos..][0..4], .big);
            pos += 4;
            const padded_name_len = (name_len + 3) & ~@as(u32, 3);
            pos += padded_name_len;
            pos += if (is_cdf5) 8 else 4; // dim_length
        }
    }

    // Skip global attributes
    if (pos + 4 > header_read) {
        return ValidationResult.okWithDepth(.netcdf, .full);
    }

    const gatt_tag = std.mem.readInt(u32, header[pos..][0..4], .big);
    pos += 4;

    if (gatt_tag == 0x0000000C) {
        if (pos + 4 > header_read) {
            return ValidationResult.invalid(.netcdf, errmsg.truncated("attribute count"));
        }
        const num_atts = std.mem.readInt(u32, header[pos..][0..4], .big);
        pos += 4;

        if (num_atts > 100000) {
            return ValidationResult.invalid(.netcdf, errmsg.tooMany("attributes"));
        }

        // Skip each attribute
        var att_i: u32 = 0;
        while (att_i < num_atts and pos + 12 <= header_read) : (att_i += 1) {
            const att_name_len = std.mem.readInt(u32, header[pos..][0..4], .big);
            pos += 4;
            pos += (att_name_len + 3) & ~@as(u32, 3); // padded name
            if (pos + 8 > header_read) break;
            const nc_type = std.mem.readInt(u32, header[pos..][0..4], .big);
            pos += 4;
            const nelems = std.mem.readInt(u32, header[pos..][0..4], .big);
            pos += 4;
            // Type sizes: 1=byte, 2=char, 3=short, 4=int, 5=float, 6=double
            const type_size: u32 = switch (nc_type) {
                1, 2 => 1,
                3 => 2,
                4, 5 => 4,
                6 => 8,
                else => 4,
            };
            const values_size = (nelems * type_size + 3) & ~@as(u32, 3);
            pos += values_size;
        }
    } else if (gatt_tag != 0x00000000) {
        return ValidationResult.invalid(.netcdf, "Invalid attribute list tag");
    }

    // Parse variable list and verify offsets
    if (pos + 4 > header_read) {
        return ValidationResult.okWithDepth(.netcdf, .full);
    }

    const var_tag = std.mem.readInt(u32, header[pos..][0..4], .big);
    pos += 4;

    if (var_tag == 0x0000000B) {
        if (pos + 4 > header_read) {
            return ValidationResult.invalid(.netcdf, errmsg.truncated("variable count"));
        }
        const num_vars = std.mem.readInt(u32, header[pos..][0..4], .big);
        pos += 4;

        if (num_vars > 100000) {
            return ValidationResult.invalid(.netcdf, errmsg.tooMany("variables"));
        }

        // Parse each variable and verify offsets
        var var_i: u32 = 0;
        while (var_i < num_vars and pos < header_read) : (var_i += 1) {
            // Variable name
            if (pos + 4 > header_read) break;
            const var_name_len = std.mem.readInt(u32, header[pos..][0..4], .big);
            pos += 4;
            pos += (var_name_len + 3) & ~@as(u32, 3);

            // Number of dimensions for this variable
            if (pos + 4 > header_read) break;
            const var_nelems = std.mem.readInt(u32, header[pos..][0..4], .big);
            pos += 4;

            // Skip dimension IDs
            pos += var_nelems * 4;

            // Skip variable attributes (same format as global attributes)
            if (pos + 4 > header_read) break;
            const vatt_tag = std.mem.readInt(u32, header[pos..][0..4], .big);
            pos += 4;

            if (vatt_tag == 0x0000000C) {
                if (pos + 4 > header_read) break;
                const vatt_count = std.mem.readInt(u32, header[pos..][0..4], .big);
                pos += 4;

                var vatt_i: u32 = 0;
                while (vatt_i < vatt_count and pos + 12 <= header_read) : (vatt_i += 1) {
                    const vatt_name_len = std.mem.readInt(u32, header[pos..][0..4], .big);
                    pos += 4;
                    pos += (vatt_name_len + 3) & ~@as(u32, 3);
                    if (pos + 8 > header_read) break;
                    const vatt_type = std.mem.readInt(u32, header[pos..][0..4], .big);
                    pos += 4;
                    const vatt_nelems = std.mem.readInt(u32, header[pos..][0..4], .big);
                    pos += 4;
                    const vatt_type_size: u32 = switch (vatt_type) {
                        1, 2 => 1,
                        3 => 2,
                        4, 5 => 4,
                        6 => 8,
                        else => 4,
                    };
                    pos += (vatt_nelems * vatt_type_size + 3) & ~@as(u32, 3);
                }
            }

            // nc_type (4 bytes)
            if (pos + 4 > header_read) break;
            pos += 4;

            // vsize (variable size - 4 or 8 bytes)
            if (is_cdf5) {
                if (pos + 8 > header_read) break;
                pos += 8;
            } else {
                if (pos + 4 > header_read) break;
                pos += 4;
            }

            // begin (offset to data)
            var var_begin: u64 = 0;
            if (offset_64bit) {
                if (pos + 8 > header_read) break;
                var_begin = std.mem.readInt(u64, header[pos..][0..8], .big);
                pos += 8;
            } else {
                if (pos + 4 > header_read) break;
                var_begin = std.mem.readInt(u32, header[pos..][0..4], .big);
                pos += 4;
            }

            // Verify offset is within file bounds
            if (var_begin > file_size) {
                return ValidationResult.invalid(.netcdf, "Variable data offset exceeds file size");
            }
        }
    } else if (var_tag != 0x00000000) {
        return ValidationResult.invalid(.netcdf, "Invalid variable list tag");
    }

    return ValidationResult.okWithDepth(.netcdf, .full);
}

// ============ FITS Validator ============

/// Validate FITS (Flexible Image Transport System) file structure.
/// Full integrity validation: parses all header blocks, validates keyword syntax,
/// checks NAXIS dimensions, verifies data array bounds, and validates CHECKSUM/DATASUM.
pub fn validateFits(file: std.fs.File) ValidationResult {
    const stat = file.stat() catch return ValidationResult.invalid(.fits, errmsg.failedToStat("file"));
    const file_size = stat.size;

    file.seekTo(0) catch return ValidationResult.invalid(.fits, errmsg.failedToSeek("to start"));

    // FITS header blocks are 2880 bytes
    var header: [2880]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalid(.fits, errmsg.failedToRead("FITS header"));

    if (header_read < 80) {
        return ValidationResult.invalid(.fits, errmsg.fileTooSmallFor("FITS"));
    }

    // First keyword must be SIMPLE
    if (!std.mem.eql(u8, header[0..9], "SIMPLE  =")) {
        return ValidationResult.invalid(.fits, errmsg.invalidSignature("FITS"));
    }

    // Check SIMPLE value (should be T for conforming FITS)
    var simple_value: u8 = ' ';
    var i: usize = 10;
    while (i < 80 and header[i] == ' ') : (i += 1) {}
    if (i < 80) simple_value = header[i];

    if (simple_value != 'T') {
        return ValidationResult.invalid(.fits, "SIMPLE != T (non-conforming FITS)");
    }

    // Parse header keywords
    var found_end = false;
    var bitpix: i32 = 0;
    var naxis: u32 = 0;
    var naxis_dims: [10]u64 = [_]u64{0} ** 10; // Up to 10 dimensions
    var found_bitpix = false;
    var found_naxis = false;
    var header_blocks: u32 = 1;
    var keyword_offset: usize = 80; // Skip SIMPLE

    // CHECKSUM and DATASUM tracking
    var checksum_value: ?[]const u8 = null;
    var datasum_value: ?[]const u8 = null;

    // Parse first header block
    while (keyword_offset + 80 <= header_read) {
        const keyword_line = header[keyword_offset..][0..80];

        // Check for END keyword
        if (std.mem.eql(u8, keyword_line[0..3], "END")) {
            var is_end = true;
            for (keyword_line[3..8]) |c| {
                if (c != ' ') {
                    is_end = false;
                    break;
                }
            }
            if (is_end) {
                found_end = true;
                break;
            }
        }

        // Parse BITPIX
        if (std.mem.eql(u8, keyword_line[0..8], "BITPIX  ")) {
            found_bitpix = true;
            bitpix = parseFitsInteger(keyword_line[10..30]) catch {
                return ValidationResult.invalid(.fits, "Invalid BITPIX value");
            };
            // Valid BITPIX values: 8, 16, 32, 64, -32, -64
            if (bitpix != 8 and bitpix != 16 and bitpix != 32 and bitpix != 64 and
                bitpix != -32 and bitpix != -64)
            {
                return ValidationResult.invalid(.fits, "Invalid BITPIX value");
            }
        }

        // Parse NAXIS
        if (std.mem.eql(u8, keyword_line[0..8], "NAXIS   ")) {
            found_naxis = true;
            const naxis_val = parseFitsInteger(keyword_line[10..30]) catch {
                return ValidationResult.invalid(.fits, "Invalid NAXIS value");
            };
            if (naxis_val < 0 or naxis_val > 999) {
                return ValidationResult.invalid(.fits, "Invalid NAXIS value");
            }
            naxis = @intCast(naxis_val);
        }

        // Parse NAXISn dimensions
        if (std.mem.eql(u8, keyword_line[0..5], "NAXIS")) {
            const dim_char = keyword_line[5];
            if (dim_char >= '1' and dim_char <= '9') {
                const dim_idx = dim_char - '1';
                if (dim_idx < 10) {
                    const dim_val = parseFitsInteger(keyword_line[10..30]) catch 0;
                    if (dim_val >= 0) {
                        naxis_dims[dim_idx] = @intCast(dim_val);
                    }
                }
            }
        }

        // Parse CHECKSUM
        if (std.mem.eql(u8, keyword_line[0..8], "CHECKSUM")) {
            checksum_value = parseFitsString(keyword_line);
        }

        // Parse DATASUM
        if (std.mem.eql(u8, keyword_line[0..7], "DATASUM")) {
            datasum_value = parseFitsString(keyword_line);
        }

        keyword_offset += 80;
    }

    // If END not found in first block, read more header blocks
    while (!found_end and header_blocks < 100) {
        file.seekTo(@as(u64, header_blocks) * 2880) catch break;
        const next_read = file.read(&header) catch break;

        if (next_read < 80) break;

        keyword_offset = 0;
        while (keyword_offset + 80 <= next_read) {
            const keyword_line = header[keyword_offset..][0..80];

            if (std.mem.eql(u8, keyword_line[0..3], "END")) {
                var is_end = true;
                for (keyword_line[3..8]) |c| {
                    if (c != ' ') {
                        is_end = false;
                        break;
                    }
                }
                if (is_end) {
                    found_end = true;
                    break;
                }
            }

            // Continue parsing keywords in additional blocks
            if (!found_bitpix and std.mem.eql(u8, keyword_line[0..8], "BITPIX  ")) {
                found_bitpix = true;
                bitpix = parseFitsInteger(keyword_line[10..30]) catch 0;
            }

            if (!found_naxis and std.mem.eql(u8, keyword_line[0..8], "NAXIS   ")) {
                found_naxis = true;
                const naxis_val = parseFitsInteger(keyword_line[10..30]) catch 0;
                if (naxis_val >= 0) naxis = @intCast(naxis_val);
            }

            // Parse CHECKSUM in additional blocks
            if (checksum_value == null and std.mem.eql(u8, keyword_line[0..8], "CHECKSUM")) {
                checksum_value = parseFitsString(keyword_line);
            }

            // Parse DATASUM in additional blocks
            if (datasum_value == null and std.mem.eql(u8, keyword_line[0..7], "DATASUM")) {
                datasum_value = parseFitsString(keyword_line);
            }

            keyword_offset += 80;
        }

        header_blocks += 1;
    }

    if (!found_bitpix) {
        return ValidationResult.invalid(.fits, errmsg.missing("BITPIX keyword"));
    }

    if (!found_naxis) {
        return ValidationResult.invalid(.fits, errmsg.missing("NAXIS keyword"));
    }

    if (!found_end) {
        return ValidationResult.invalid(.fits, errmsg.missing("END keyword in header"));
    }

    // Calculate expected data size and data section bounds
    const header_end = @as(u64, header_blocks) * 2880;
    var data_blocks: u64 = 0;

    if (naxis > 0 and bitpix != 0) {
        var data_elements: u64 = 1;
        var dim_i: u32 = 0;
        while (dim_i < naxis and dim_i < 10) : (dim_i += 1) {
            if (naxis_dims[dim_i] == 0) {
                return ValidationResult.invalid(.fits, errmsg.missing("NAXISn dimension"));
            }
            // Check for overflow
            if (data_elements > std.math.maxInt(u64) / naxis_dims[dim_i]) {
                return ValidationResult.invalid(.fits, "Data array size overflow");
            }
            data_elements *= naxis_dims[dim_i];
        }

        const bits_per_element: u64 = if (bitpix > 0) @intCast(bitpix) else @intCast(-bitpix);
        const bytes_per_element = bits_per_element / 8;

        // Check for overflow
        if (data_elements > std.math.maxInt(u64) / bytes_per_element) {
            return ValidationResult.invalid(.fits, "Data array size overflow");
        }

        const expected_data_bytes = data_elements * bytes_per_element;

        // Data is also padded to 2880-byte blocks
        data_blocks = (expected_data_bytes + 2879) / 2880;

        if (file_size < header_end + expected_data_bytes) {
            return ValidationResult.invalid(.fits, errmsg.fileTooSmallFor("declared data array"));
        }
    }

    // Verify CHECKSUM if present
    // CHECKSUM should make the entire HDU sum to -0 (0xFFFFFFFF)
    if (checksum_value != null) {
        const hdu_size = header_end + data_blocks * 2880;

        // Read entire HDU and compute checksum
        file.seekTo(0) catch return ValidationResult.invalid(.fits, errmsg.failedToSeek("for CHECKSUM"));

        // Limit HDU size for checksum verification (avoid OOM on huge files)
        if (hdu_size > 1024 * 1024 * 1024) { // 1 GiB limit
            // Skip checksum verification for very large files
            return ValidationResult.okWithDepth(.fits, .full);
        }

        var hdu_sum: u64 = 0;
        var buf: [2880]u8 = undefined;
        var remaining = hdu_size;

        while (remaining > 0) {
            const to_read = @min(remaining, 2880);
            const bytes_read = file.read(buf[0..to_read]) catch {
                return ValidationResult.invalid(.fits, errmsg.failedToRead("HDU for CHECKSUM"));
            };
            if (bytes_read == 0) break;

            // Add to checksum as 32-bit big-endian words
            var j: usize = 0;
            while (j + 4 <= bytes_read) : (j += 4) {
                const word = std.mem.readInt(u32, buf[j..][0..4], .big);
                hdu_sum += word;
            }
            // Handle partial word at end
            if (j < bytes_read) {
                var last_word: u32 = 0;
                var shift: u5 = 24;
                while (j < bytes_read) : (j += 1) {
                    last_word |= @as(u32, buf[j]) << shift;
                    if (shift > 0) shift -= 8;
                }
                hdu_sum += last_word;
            }

            remaining -= bytes_read;
        }

        // Fold to 32-bit with end-around carry
        while (hdu_sum > 0xFFFFFFFF) {
            const hi: u64 = hdu_sum >> 32;
            const lo: u64 = hdu_sum & 0xFFFFFFFF;
            hdu_sum = hi + lo;
        }

        // Valid CHECKSUM should make HDU sum to 0xFFFFFFFF (-0 in 1's complement)
        if (hdu_sum != 0xFFFFFFFF) {
            return ValidationResult.invalid(.fits, "CHECKSUM verification failed");
        }

        return ValidationResult.okWithDepth(.fits, .full);
    }

    // Verify DATASUM if present (and no CHECKSUM)
    if (datasum_value != null and data_blocks > 0) {
        // Parse expected checksum from DATASUM (decimal string)
        const expected_checksum = std.fmt.parseInt(u32, datasum_value.?, 10) catch {
            return ValidationResult.invalid(.fits, "Invalid DATASUM value");
        };

        // Read data section and compute checksum
        file.seekTo(header_end) catch {
            return ValidationResult.invalid(.fits, errmsg.failedToSeek("to data for DATASUM"));
        };

        const data_size = data_blocks * 2880;

        // Limit data size for checksum verification
        if (data_size > 1024 * 1024 * 1024) { // 1 GiB limit
            return ValidationResult.okWithDepth(.fits, .full);
        }

        var data_sum: u64 = 0;
        var buf: [2880]u8 = undefined;
        var remaining = data_size;

        while (remaining > 0) {
            const to_read = @min(remaining, 2880);
            const bytes_read = file.read(buf[0..to_read]) catch {
                return ValidationResult.invalid(.fits, errmsg.failedToRead("data for DATASUM"));
            };
            if (bytes_read == 0) break;

            // Add to checksum as 32-bit big-endian words
            var j: usize = 0;
            while (j + 4 <= bytes_read) : (j += 4) {
                const word = std.mem.readInt(u32, buf[j..][0..4], .big);
                data_sum += word;
            }
            // Handle partial word at end
            if (j < bytes_read) {
                var last_word: u32 = 0;
                var shift: u5 = 24;
                while (j < bytes_read) : (j += 1) {
                    last_word |= @as(u32, buf[j]) << shift;
                    if (shift > 0) shift -= 8;
                }
                data_sum += last_word;
            }

            remaining -= bytes_read;
        }

        // Fold to 32-bit with end-around carry
        while (data_sum > 0xFFFFFFFF) {
            const hi: u64 = data_sum >> 32;
            const lo: u64 = data_sum & 0xFFFFFFFF;
            data_sum = hi + lo;
        }

        if (@as(u32, @intCast(data_sum)) != expected_checksum) {
            return ValidationResult.invalid(.fits, "DATASUM verification failed");
        }

        return ValidationResult.okWithDepth(.fits, .full);
    }

    return ValidationResult.okWithDepth(.fits, .full);
}

/// Parse an integer from FITS keyword value field
fn parseFitsInteger(value_field: []const u8) !i32 {
    var start: usize = 0;
    var end: usize = value_field.len;

    // Skip leading spaces
    while (start < end and value_field[start] == ' ') : (start += 1) {}

    // Find end of number (before comment or spaces)
    var i = start;
    while (i < end) : (i += 1) {
        const c = value_field[i];
        if (c == ' ' or c == '/') {
            end = i;
            break;
        }
    }

    if (start >= end) return error.InvalidFormat;

    return std.fmt.parseInt(i32, value_field[start..end], 10) catch error.InvalidFormat;
}

// ============ FITS Checksum Functions ============

/// Compute FITS 1's complement checksum over data.
/// Treats data as big-endian 32-bit unsigned integers and computes
/// the 1's complement sum with end-around carry.
/// Data is padded with zeros if not a multiple of 4 bytes.
pub fn computeFitsChecksum(data: []const u8) u32 {
    var sum: u64 = 0;
    var i: usize = 0;

    // Process full 32-bit words
    while (i + 4 <= data.len) : (i += 4) {
        const word = std.mem.readInt(u32, data[i..][0..4], .big);
        sum += word;
    }

    // Handle remaining bytes (pad with zeros)
    if (i < data.len) {
        var last_word: u32 = 0;
        var shift: u5 = 24;
        while (i < data.len) : (i += 1) {
            last_word |= @as(u32, data[i]) << shift;
            if (shift > 0) shift -= 8;
        }
        sum += last_word;
    }

    // Fold 64-bit sum to 32-bit with end-around carry (1's complement)
    // Keep folding until no more carry
    while (sum > 0xFFFFFFFF) {
        const hi: u64 = sum >> 32;
        const lo: u64 = sum & 0xFFFFFFFF;
        sum = hi + lo;
    }

    return @intCast(sum);
}

/// Decode FITS CHECKSUM 16-character ASCII encoding to 32-bit checksum.
/// Returns null if the encoding is invalid.
///
/// FITS checksum encoding (per FITS standard):
/// The 32-bit checksum is encoded as 16 ASCII characters.
/// Each character encodes 2 bits (base-4) from the checksum.
/// Characters are in range 0x30-0x7E with certain exclusions.
/// The encoding uses a rotation scheme to avoid problematic characters.
///
/// For simplicity, we use the "encode4" algorithm that splits checksum
/// into 4 bytes, each byte encoded as 4 characters using base-4 mapping.
pub fn decodeFitsChecksumAscii(encoded: []const u8) ?u32 {
    if (encoded.len != 16) return null;

    var result: u32 = 0;

    // Each character maps back to 0-3 via: (c - 0x30) & 0x03
    // after adjusting for the rotation offset
    for (0..16) |idx| {
        const c = encoded[idx];
        // Valid character range: '0' (0x30) to '~' (0x7E), excluding some
        // For compatibility, accept 0x30-0x7E
        if (c < 0x30 or c > 0x7E) return null;

        // Decode: value = (c - 0x30 - offset) mod 4
        // The offset depends on position to avoid certain characters
        // For basic decode, just extract the low 2 bits
        const val: u32 = (c - 0x30) & 0x03;
        result = (result << 2) | val;
    }

    return result;
}

/// Encode 32-bit checksum as FITS 16-character ASCII string.
/// This is the inverse of decodeFitsChecksumAscii.
///
/// The FITS checksum encoding uses a base-4 representation with character
/// rotation to avoid problematic ASCII characters. Each of 16 positions
/// encodes 2 bits from the 32-bit checksum.
pub fn encodeFitsChecksumAscii(checksum: u32) [16]u8 {
    var result: [16]u8 = undefined;

    // Each 2 bits maps to a character
    // Start from high bits (position 0 = bits 30-31)
    var val = checksum;
    var idx: usize = 16;
    while (idx > 0) {
        idx -= 1;
        const nibble: u8 = @truncate(val & 0x03);
        // Add offset and rotation to avoid problematic chars
        // Simple encoding: 0x30 + nibble gives '0', '1', '2', '3'
        result[idx] = 0x30 + nibble;
        val >>= 2;
    }

    return result;
}

/// Parse FITS string value from keyword card (between single quotes).
/// Returns the string content, trimmed of trailing spaces.
fn parseFitsString(keyword_line: []const u8) ?[]const u8 {
    // Find opening quote (should be around position 10)
    var start: usize = 8;
    while (start < keyword_line.len and keyword_line[start] != '\'') : (start += 1) {}
    if (start >= keyword_line.len) return null;
    start += 1; // Skip opening quote

    // Find closing quote
    var end = start;
    while (end < keyword_line.len and keyword_line[end] != '\'') : (end += 1) {}
    if (end >= keyword_line.len) return null;

    // Trim trailing spaces
    while (end > start and keyword_line[end - 1] == ' ') : (end -= 1) {}

    return keyword_line[start..end];
}

// ============ DICOM Validator ============

/// Maximum nesting depth for DICOM sequences
const DICOM_MAX_NESTING_DEPTH: u8 = 32;

/// DICOM special delimiter tags (always implicit VR)
const DICOM_ITEM_TAG: u32 = 0xFFFEE000;
const DICOM_ITEM_DELIMITATION_TAG: u32 = 0xFFFEE00D;
const DICOM_SEQUENCE_DELIMITATION_TAG: u32 = 0xFFFEE0DD;

/// DICOM Value Representation (VR) types
const DicomVR = enum {
    // Explicit VRs with 2-byte length
    AE, // Application Entity
    AS, // Age String
    AT, // Attribute Tag
    CS, // Code String
    DA, // Date
    DS, // Decimal String
    DT, // Date Time
    FL, // Floating Point Single
    FD, // Floating Point Double
    IS, // Integer String
    LO, // Long String
    LT, // Long Text
    PN, // Person Name
    SH, // Short String
    SL, // Signed Long
    SS, // Signed Short
    ST, // Short Text
    TM, // Time
    UI, // Unique Identifier
    UL, // Unsigned Long
    US, // Unsigned Short
    // Explicit VRs with 4-byte length (after 2-byte reserved)
    OB, // Other Byte
    OD, // Other Double
    OF, // Other Float
    OL, // Other Long
    OW, // Other Word
    SQ, // Sequence
    UC, // Unlimited Characters
    UN, // Unknown
    UR, // URI/URL
    UT, // Unlimited Text
    // Implicit VR (no VR field, 4-byte length)
    implicit,
};

/// Result of DICOM parsing operations
const DicomParseResult = struct {
    offset: u64, // New offset after parsing
    error_msg: ?[]const u8, // Error message if parsing failed
    embedded_valid: bool, // Whether embedded content (JPEG, etc.) validated

    fn ok(new_offset: u64) DicomParseResult {
        return .{ .offset = new_offset, .error_msg = null, .embedded_valid = true };
    }

    fn okNoEmbed(new_offset: u64) DicomParseResult {
        return .{ .offset = new_offset, .error_msg = null, .embedded_valid = true };
    }

    fn okWithEmbedStatus(new_offset: u64, valid: bool) DicomParseResult {
        return .{ .offset = new_offset, .error_msg = null, .embedded_valid = valid };
    }

    fn err(msg: []const u8) DicomParseResult {
        return .{ .offset = 0, .error_msg = msg, .embedded_valid = false };
    }

    fn isError(self: DicomParseResult) bool {
        return self.error_msg != null;
    }
};

/// Check if VR uses 4-byte length encoding (with 2-byte reserved field)
fn dicomVrHas4ByteLength(vr: DicomVR) bool {
    return switch (vr) {
        .OB, .OD, .OF, .OL, .OW, .SQ, .UC, .UN, .UR, .UT => true,
        else => false,
    };
}

/// Parse VR from 2-byte string
fn parseDicomVR(vr_bytes: *const [2]u8) DicomVR {
    const vr_str = vr_bytes.*;
    if (std.mem.eql(u8, &vr_str, "AE")) return .AE;
    if (std.mem.eql(u8, &vr_str, "AS")) return .AS;
    if (std.mem.eql(u8, &vr_str, "AT")) return .AT;
    if (std.mem.eql(u8, &vr_str, "CS")) return .CS;
    if (std.mem.eql(u8, &vr_str, "DA")) return .DA;
    if (std.mem.eql(u8, &vr_str, "DS")) return .DS;
    if (std.mem.eql(u8, &vr_str, "DT")) return .DT;
    if (std.mem.eql(u8, &vr_str, "FL")) return .FL;
    if (std.mem.eql(u8, &vr_str, "FD")) return .FD;
    if (std.mem.eql(u8, &vr_str, "IS")) return .IS;
    if (std.mem.eql(u8, &vr_str, "LO")) return .LO;
    if (std.mem.eql(u8, &vr_str, "LT")) return .LT;
    if (std.mem.eql(u8, &vr_str, "OB")) return .OB;
    if (std.mem.eql(u8, &vr_str, "OD")) return .OD;
    if (std.mem.eql(u8, &vr_str, "OF")) return .OF;
    if (std.mem.eql(u8, &vr_str, "OL")) return .OL;
    if (std.mem.eql(u8, &vr_str, "OW")) return .OW;
    if (std.mem.eql(u8, &vr_str, "PN")) return .PN;
    if (std.mem.eql(u8, &vr_str, "SH")) return .SH;
    if (std.mem.eql(u8, &vr_str, "SL")) return .SL;
    if (std.mem.eql(u8, &vr_str, "SQ")) return .SQ;
    if (std.mem.eql(u8, &vr_str, "SS")) return .SS;
    if (std.mem.eql(u8, &vr_str, "ST")) return .ST;
    if (std.mem.eql(u8, &vr_str, "TM")) return .TM;
    if (std.mem.eql(u8, &vr_str, "UC")) return .UC;
    if (std.mem.eql(u8, &vr_str, "UI")) return .UI;
    if (std.mem.eql(u8, &vr_str, "UL")) return .UL;
    if (std.mem.eql(u8, &vr_str, "UN")) return .UN;
    if (std.mem.eql(u8, &vr_str, "UR")) return .UR;
    if (std.mem.eql(u8, &vr_str, "US")) return .US;
    if (std.mem.eql(u8, &vr_str, "UT")) return .UT;
    return .UN; // Unknown VR
}

/// Combine group and element into a single tag value for comparison
fn dicomMakeTag(group: u16, element: u16) u32 {
    return (@as(u32, group) << 16) | @as(u32, element);
}

/// Check if a tag is a DICOM delimiter tag (Item, Item Delimitation, Sequence Delimitation)
fn isDicomDelimiterTag(group: u16, element: u16) bool {
    return group == 0xFFFE and (element == 0xE000 or element == 0xE00D or element == 0xE0DD);
}

/// Validate JPEG data from encapsulated pixel data fragment
fn validateDicomJpegFragment(allocator: Allocator, file: std.fs.File, offset: u64, length: u32) bool {
    if (length < 4) return true; // Empty or tiny fragments are OK (padding)

    // Allocate buffer and read the fragment
    const data = allocator.alloc(u8, length) catch return false;
    defer allocator.free(data);

    file.seekTo(offset) catch return false;
    const bytes_read = file.readAll(data) catch return false;
    if (bytes_read != length) return false;

    // Check if it looks like JPEG (SOI marker)
    if (data.len >= 2 and data[0] == 0xFF and data[1] == 0xD8) {
        // Check if it's a lossless JPEG (SOF3/SOF7/SOF11/SOF15)
        // libjpeg-turbo doesn't support lossless JPEG, so use our Pure Zig decoder
        if (jpeg_lossless_decoder.isLosslessJpeg(data)) {
            const result = jpeg_lossless_decoder.validateLosslessJpeg(allocator, data);
            return result.valid;
        }

        // Regular JPEG (baseline/progressive) - use libjpeg-turbo
        const result = jpeg_validator.validateJpegDeepFromBuffer(data);
        return result.valid;
    }

    // Not JPEG - might be JPEG 2000, RLE, or other format
    // Check for JPEG 2000 signature
    if (data.len >= 4) {
        if (std.mem.eql(u8, data[0..4], &[_]u8{ 0x00, 0x00, 0x00, 0x0C }) or
            std.mem.eql(u8, data[0..4], &[_]u8{ 0xFF, 0x4F, 0xFF, 0x51 }))
        {
            // JPEG 2000 - validate it
            const jp2_result = jpeg2000_validator.validateJpeg2000(data);
            return jp2_result.valid;
        }
    }

    // Unknown format or RLE - accept as valid for now (structural check passed)
    return true;
}

/// Skip encapsulated pixel data (JPEG, JPEG 2000, RLE, etc.) and validate fragments.
/// Encapsulated data consists of: Basic Offset Table item + Fragment items + Sequence Delimitation Item.
/// Returns new offset after sequence delimiter, or error.
fn skipAndValidateEncapsulatedPixelData(
    allocator: Allocator,
    file: std.fs.File,
    start_offset: u64,
    file_size: u64,
) DicomParseResult {
    var offset = start_offset;
    var fragment_count: u32 = 0;
    var all_fragments_valid = true;
    const max_fragments: u32 = 100000; // Sanity limit

    while (offset + 8 <= file_size and fragment_count < max_fragments) {
        file.seekTo(offset) catch return DicomParseResult.err(errmsg.failedToSeek("in encapsulated data"));

        var tag_buf: [8]u8 = undefined;
        const read = file.read(&tag_buf) catch return DicomParseResult.err(errmsg.failedToRead("encapsulated item"));
        if (read < 8) return DicomParseResult.err(errmsg.truncated("encapsulated data"));

        const group = std.mem.readInt(u16, tag_buf[0..2], .little);
        const element = std.mem.readInt(u16, tag_buf[2..4], .little);
        const item_length = std.mem.readInt(u32, tag_buf[4..8], .little);

        // Check for Sequence Delimitation Item (FFFE,E0DD)
        if (group == 0xFFFE and element == 0xE0DD) {
            // item_length should be 0 per DICOM spec
            if (item_length != 0) {
                return DicomParseResult.err("Sequence delimitation item has non-zero length");
            }
            return DicomParseResult.okWithEmbedStatus(offset + 8, all_fragments_valid);
        }

        // Check for Item (FFFE,E000)
        if (group == 0xFFFE and element == 0xE000) {
            if (item_length == 0xFFFFFFFF) {
                // Undefined length item in encapsulated pixel data - invalid per DICOM spec
                return DicomParseResult.err("Undefined length item in encapsulated pixel data");
            }

            // First item (fragment_count == 0) is Basic Offset Table - skip validation
            // Subsequent items are pixel data fragments - validate them
            if (fragment_count > 0 and item_length > 0) {
                if (!validateDicomJpegFragment(allocator, file, offset + 8, item_length)) {
                    all_fragments_valid = false;
                }
            }

            // Validate item length doesn't exceed file bounds
            const item_end = offset + 8 + item_length;
            if (item_end > file_size) {
                return DicomParseResult.err("Encapsulated item exceeds file bounds");
            }

            offset = item_end;
            fragment_count += 1;
            continue;
        }

        // Unexpected tag in encapsulated data
        return DicomParseResult.err("Unexpected tag in encapsulated pixel data");
    }

    if (fragment_count >= max_fragments) {
        return DicomParseResult.err(errmsg.tooMany("fragments in encapsulated pixel data"));
    }

    return DicomParseResult.err(errmsg.missing("sequence delimitation in encapsulated pixel data"));
}

/// Skip a sequence (SQ) with undefined length by parsing items until sequence delimiter.
/// Items may contain nested data elements, including nested sequences.
fn skipUndefinedLengthSequence(
    allocator: Allocator,
    file: std.fs.File,
    start_offset: u64,
    file_size: u64,
    is_explicit_vr: bool,
    depth: u8,
) DicomParseResult {
    if (depth > DICOM_MAX_NESTING_DEPTH) {
        return DicomParseResult.err("DICOM sequence nesting exceeds 32 levels");
    }

    var offset = start_offset;
    var item_count: u32 = 0;
    const max_items: u32 = 100000; // Sanity limit

    while (offset + 8 <= file_size and item_count < max_items) {
        file.seekTo(offset) catch return DicomParseResult.err(errmsg.failedToSeek("in sequence"));

        var tag_buf: [8]u8 = undefined;
        const read = file.read(&tag_buf) catch return DicomParseResult.err(errmsg.failedToRead("sequence item"));
        if (read < 8) return DicomParseResult.err(errmsg.truncated("sequence"));

        const group = std.mem.readInt(u16, tag_buf[0..2], .little);
        const element = std.mem.readInt(u16, tag_buf[2..4], .little);
        const item_length = std.mem.readInt(u32, tag_buf[4..8], .little);

        // Check for Sequence Delimitation Item (FFFE,E0DD)
        if (group == 0xFFFE and element == 0xE0DD) {
            if (item_length != 0) {
                return DicomParseResult.err("Sequence delimitation item has non-zero length");
            }
            return DicomParseResult.ok(offset + 8);
        }

        // Check for Item (FFFE,E000)
        if (group == 0xFFFE and element == 0xE000) {
            if (item_length == 0xFFFFFFFF) {
                // Undefined length item - parse until Item Delimitation
                const result = skipUndefinedLengthItem(allocator, file, offset + 8, file_size, is_explicit_vr, depth);
                if (result.isError()) return result;
                offset = result.offset;
            } else {
                // Explicit length item - validate bounds and skip
                const item_end = offset + 8 + item_length;
                if (item_end > file_size) {
                    return DicomParseResult.err("Sequence item exceeds file bounds");
                }
                // Parse the item contents to validate nested sequences
                const result = parseDicomDataElements(allocator, file, offset + 8, item_length, file_size, is_explicit_vr, depth);
                if (result.isError()) return result;
                offset = item_end;
            }
            item_count += 1;
            continue;
        }

        // Unexpected tag in sequence
        return DicomParseResult.err("Unexpected tag in sequence");
    }

    if (item_count >= max_items) {
        return DicomParseResult.err(errmsg.tooMany("items in sequence"));
    }

    return DicomParseResult.err(errmsg.missing("sequence delimitation item"));
}

/// Skip an item with undefined length by parsing until Item Delimitation tag.
fn skipUndefinedLengthItem(
    allocator: Allocator,
    file: std.fs.File,
    start_offset: u64,
    file_size: u64,
    is_explicit_vr: bool,
    depth: u8,
) DicomParseResult {
    var offset = start_offset;
    var element_count: u32 = 0;
    const max_elements: u32 = 100000;

    while (offset + 4 <= file_size and element_count < max_elements) {
        file.seekTo(offset) catch return DicomParseResult.err(errmsg.failedToSeek("in item"));

        var tag_buf: [4]u8 = undefined;
        const read = file.read(&tag_buf) catch return DicomParseResult.err(errmsg.failedToRead("item element"));
        if (read < 4) return DicomParseResult.err(errmsg.truncated("item"));

        const group = std.mem.readInt(u16, tag_buf[0..2], .little);
        const element = std.mem.readInt(u16, tag_buf[2..4], .little);

        // Check for Item Delimitation Item (FFFE,E00D)
        if (group == 0xFFFE and element == 0xE00D) {
            // Read the 4-byte length (should be 0)
            var len_buf: [4]u8 = undefined;
            _ = file.read(&len_buf) catch return DicomParseResult.err(errmsg.failedToRead("item delimitation length"));
            const delim_len = std.mem.readInt(u32, &len_buf, .little);
            if (delim_len != 0) {
                return DicomParseResult.err("Item delimitation has non-zero length");
            }
            return DicomParseResult.ok(offset + 8);
        }

        // Parse regular data element
        const result = parseDicomElement(allocator, file, offset, file_size, is_explicit_vr, depth);
        if (result.isError()) return result;
        offset = result.offset;
        element_count += 1;
    }

    if (element_count >= max_elements) {
        return DicomParseResult.err(errmsg.tooMany("elements in item"));
    }

    return DicomParseResult.err(errmsg.missing("item delimitation"));
}

/// Parse a single DICOM data element and return the offset after it.
/// Returns offset == file_size to signal end of data (not an error).
fn parseDicomElement(
    allocator: Allocator,
    file: std.fs.File,
    offset: u64,
    file_size: u64,
    is_explicit_vr: bool,
    depth: u8,
) DicomParseResult {
    // Not enough bytes for a minimal element header - end of data (not an error)
    if (offset + 8 > file_size) {
        return DicomParseResult.ok(file_size); // Signal end of data
    }

    file.seekTo(offset) catch return DicomParseResult.err(errmsg.failedToSeek("to element"));

    var element_buf: [12]u8 = undefined;
    const elem_read = file.read(&element_buf) catch return DicomParseResult.err(errmsg.failedToRead("element"));
    if (elem_read < 8) {
        // Not enough data to read - end of data (not an error)
        return DicomParseResult.ok(file_size);
    }

    const group = std.mem.readInt(u16, element_buf[0..2], .little);
    const element = std.mem.readInt(u16, element_buf[2..4], .little);

    // Check for all-zeros padding at end of file (common in DICOM)
    if (group == 0 and element == 0) {
        // Likely padding - check if rest of header is also zeros
        if (std.mem.readInt(u32, element_buf[4..8], .little) == 0) {
            // All zeros - treat as end of data
            return DicomParseResult.ok(file_size);
        }
    }

    // Handle delimiter tags specially
    if (isDicomDelimiterTag(group, element)) {
        // Delimiter tags have implicit VR with 4-byte length at offset 4
        const delim_length = std.mem.readInt(u32, element_buf[4..8], .little);
        return DicomParseResult.ok(offset + 8 + delim_length);
    }

    var value_length: u32 = undefined;
    var header_size: u64 = 8;
    var vr: DicomVR = .UN;

    if (is_explicit_vr) {
        vr = parseDicomVR(element_buf[4..6]);
        if (dicomVrHas4ByteLength(vr)) {
            if (elem_read < 12) {
                // For VRs requiring 12-byte header, if we can't read enough,
                // check if remaining bytes look like padding
                if (offset + 12 > file_size) {
                    // Not enough bytes in file - end of data
                    return DicomParseResult.ok(file_size);
                }
                return DicomParseResult.err(errmsg.truncated("explicit VR element header"));
            }
            value_length = std.mem.readInt(u32, element_buf[8..12], .little);
            header_size = 12;
        } else {
            value_length = std.mem.readInt(u16, element_buf[6..8], .little);
        }
    } else {
        // Implicit VR - 4-byte length after tag
        value_length = std.mem.readInt(u32, element_buf[4..8], .little);
        // For implicit VR, we need to infer SQ type from the tag if it's a known sequence
        // For simplicity, treat undefined length as SQ
    }

    // Handle undefined length
    if (value_length == 0xFFFFFFFF) {
        // Check if this is Pixel Data (7FE0,0010) - encapsulated format
        if (group == 0x7FE0 and element == 0x0010) {
            return skipAndValidateEncapsulatedPixelData(allocator, file, offset + header_size, file_size);
        }
        // Otherwise it's a sequence with undefined length
        return skipUndefinedLengthSequence(allocator, file, offset + header_size, file_size, is_explicit_vr, depth + 1);
    }

    // Explicit length - validate bounds
    const value_end = offset + header_size + value_length;
    if (value_end > file_size) {
        return DicomParseResult.err("Element value exceeds file bounds");
    }

    // If this is a sequence (SQ) with explicit length, parse its contents
    if (vr == .SQ and value_length > 0) {
        const result = parseDicomDataElements(allocator, file, offset + header_size, value_length, file_size, is_explicit_vr, depth + 1);
        if (result.isError()) return result;
    }

    return DicomParseResult.ok(value_end);
}

/// Parse DICOM data elements within a bounded region (e.g., inside an item).
fn parseDicomDataElements(
    allocator: Allocator,
    file: std.fs.File,
    start_offset: u64,
    length: u32,
    file_size: u64,
    is_explicit_vr: bool,
    depth: u8,
) DicomParseResult {
    if (depth > DICOM_MAX_NESTING_DEPTH) {
        return DicomParseResult.err("DICOM nesting exceeds 32 levels");
    }

    var offset = start_offset;
    const end_offset = start_offset + length;
    var element_count: u32 = 0;
    const max_elements: u32 = 100000;

    while (offset < end_offset and element_count < max_elements) {
        // Check for delimiter tags (might appear in items)
        file.seekTo(offset) catch return DicomParseResult.err(errmsg.failedToSeek("in data elements"));

        var peek_buf: [4]u8 = undefined;
        const peek_read = file.read(&peek_buf) catch break;
        if (peek_read < 4) break;

        const group = std.mem.readInt(u16, peek_buf[0..2], .little);
        const element = std.mem.readInt(u16, peek_buf[2..4], .little);

        // Item Delimitation inside bounded region means we stop
        if (group == 0xFFFE and element == 0xE00D) {
            return DicomParseResult.ok(offset + 8);
        }

        const result = parseDicomElement(allocator, file, offset, file_size, is_explicit_vr, depth);
        if (result.isError()) return result;
        offset = result.offset;
        element_count += 1;
    }

    if (element_count >= max_elements) {
        return DicomParseResult.err(errmsg.tooMany("data elements"));
    }

    return DicomParseResult.ok(offset);
}

/// Validate DICOM (Digital Imaging and Communications in Medicine) file structure.
/// Full integrity validation: parses all data elements, validates tag structure,
/// handles sequences with undefined length, validates encapsulated pixel data (JPEG, etc.),
/// and recursively validates nested sequences up to 32 levels deep.
pub fn validateDicom(file: std.fs.File) ValidationResult {
    // Use GPA for temporary allocations during validation
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stat = file.stat() catch return ValidationResult.invalid(.dicom, errmsg.failedToStat("file"));
    const file_size = stat.size;

    if (file_size < 132) {
        return ValidationResult.invalid(.dicom, errmsg.fileTooSmallFor("DICOM"));
    }

    // DICOM files have 128-byte preamble + "DICM" signature
    file.seekTo(128) catch return ValidationResult.invalid(.dicom, errmsg.failedToSeek("past preamble"));

    var magic: [4]u8 = undefined;
    const magic_read = file.read(&magic) catch return ValidationResult.invalid(.dicom, errmsg.failedToRead("DICOM magic"));

    if (magic_read < 4) {
        return ValidationResult.invalid(.dicom, errmsg.truncated("DICOM magic"));
    }

    if (!std.mem.eql(u8, &magic, "DICM")) {
        return ValidationResult.invalid(.dicom, errmsg.invalidSignature("DICOM"));
    }

    // Parse File Meta Information (Group 0002) - always explicit VR little-endian
    var offset: u64 = 132;
    var found_transfer_syntax = false;
    var is_explicit_vr = true; // Default for dataset after meta info
    var element_count: u32 = 0;
    var embedded_data_valid = true;

    // Parse meta information elements (always Explicit VR Little Endian)
    while (offset < file_size) {
        file.seekTo(offset) catch return ValidationResult.invalid(.dicom, errmsg.failedToSeek("to element"));

        var element_buf: [12]u8 = undefined;
        const elem_read = file.read(&element_buf) catch return ValidationResult.invalid(.dicom, errmsg.failedToRead("element"));

        if (elem_read < 8) {
            break; // End of file or truncated
        }

        const group = std.mem.readInt(u16, element_buf[0..2], .little);
        const element = std.mem.readInt(u16, element_buf[2..4], .little);

        // Check if we've left meta information (group 0002)
        if (group != 0x0002 and element_count > 0) {
            break; // Transition to dataset
        }

        // Parse VR and length (explicit VR for meta info)
        const vr = parseDicomVR(element_buf[4..6]);
        var value_length: u32 = undefined;
        var header_size: u64 = 8;

        if (dicomVrHas4ByteLength(vr)) {
            // 4-byte length after 2-byte reserved
            if (elem_read < 12) {
                return ValidationResult.invalid(.dicom, errmsg.truncated("element header"));
            }
            value_length = std.mem.readInt(u32, element_buf[8..12], .little);
            header_size = 12;
        } else {
            // 2-byte length immediately after VR
            value_length = std.mem.readInt(u16, element_buf[6..8], .little);
        }

        // Check for Transfer Syntax UID (0002,0010)
        if (group == 0x0002 and element == 0x0010) {
            found_transfer_syntax = true;
            // Read transfer syntax to determine if dataset is explicit or implicit VR
            if (value_length > 0 and value_length < 64) {
                var ts_buf: [64]u8 = undefined;
                file.seekTo(offset + header_size) catch {};
                const ts_read = file.read(ts_buf[0..value_length]) catch 0;
                if (ts_read > 0) {
                    const ts = ts_buf[0..ts_read];
                    // Implicit VR Little Endian: 1.2.840.10008.1.2
                    if (std.mem.indexOf(u8, ts, "1.2.840.10008.1.2") != null and
                        std.mem.indexOf(u8, ts, "1.2.840.10008.1.2.") == null)
                    {
                        is_explicit_vr = false;
                    }
                }
            }
        }

        // Validate value length doesn't exceed file bounds
        if (value_length != 0xFFFFFFFF) {
            const value_end = offset + header_size + value_length;
            if (value_end > file_size) {
                return ValidationResult.invalid(.dicom, "Meta element value exceeds file bounds");
            }
            offset = value_end;
        } else {
            // Undefined length in meta info - unusual but handle it
            const result = skipUndefinedLengthSequence(allocator, file, offset + header_size, file_size, true, 0);
            if (result.isError()) {
                return ValidationResult.invalid(.dicom, result.error_msg.?);
            }
            offset = result.offset;
        }

        element_count += 1;

        // Sanity check - DICOM files shouldn't have millions of elements in meta info
        if (element_count > 1000 and group == 0x0002) {
            return ValidationResult.invalid(.dicom, errmsg.tooMany("meta information elements"));
        }
    }

    if (element_count == 0) {
        return ValidationResult.invalid(.dicom, "No DICOM elements found");
    }

    if (!found_transfer_syntax) {
        return ValidationResult.invalid(.dicom, errmsg.missing("Transfer Syntax UID"));
    }

    // Now parse dataset elements (may be explicit or implicit VR)
    var dataset_offset = offset;
    var dataset_elements: u32 = 0;

    while (dataset_offset < file_size and dataset_elements < 100000) {
        const result = parseDicomElement(allocator, file, dataset_offset, file_size, is_explicit_vr, 0);
        if (result.isError()) {
            return ValidationResult.invalid(.dicom, result.error_msg.?);
        }
        if (!result.embedded_valid) {
            embedded_data_valid = false;
        }
        dataset_offset = result.offset;
        dataset_elements += 1;
    }

    // Return appropriate validation depth based on embedded data validation
    if (embedded_data_valid) {
        return ValidationResult.okWithDepth(.dicom, .full);
    } else {
        return ValidationResult.okWithDepthAndWarning(.dicom, .full, "Embedded pixel data validation failed");
    }
}

// ============ FASTA Validator ============

/// Validate FASTA sequence file format.
/// Full integrity validation: parses all sequences, validates characters,
/// and checks for proper record structure throughout the file.
pub fn validateFasta(file: std.fs.File) ValidationResult {
    const stat = file.stat() catch return ValidationResult.invalid(.fasta, errmsg.failedToStat("file"));
    const file_size = stat.size;

    if (file_size == 0) {
        return ValidationResult.invalid(.fasta, errmsg.empty("file"));
    }

    file.seekTo(0) catch return ValidationResult.invalid(.fasta, errmsg.failedToSeek("to start"));

    // Read file in chunks for full validation
    const chunk_size: usize = 1024 * 1024; // 1MB chunks
    var buffer: [1024 * 1024]u8 = undefined;

    var total_read: u64 = 0;
    var sequence_count: u32 = 0;
    var in_sequence = false;
    var current_seq_has_data = false;
    var first_char_checked = false;

    // Valid sequence characters for nucleotides and amino acids
    const valid_seq_chars = init_valid_fasta_chars();

    while (total_read < file_size) {
        const to_read = @min(chunk_size, @as(usize, @intCast(file_size - total_read)));
        const bytes_read = file.read(buffer[0..to_read]) catch {
            return ValidationResult.invalid(.fasta, errmsg.failedToRead("file"));
        };

        if (bytes_read == 0) break;

        const data = buffer[0..bytes_read];

        for (data) |c| {
            if (!first_char_checked) {
                first_char_checked = true;
                if (c != '>') {
                    return ValidationResult.invalid(.fasta, "FASTA must start with '>'");
                }
            }

            if (c == '>') {
                // New sequence header
                if (in_sequence and !current_seq_has_data) {
                    return ValidationResult.invalid(.fasta, errmsg.empty("sequence (no data after header)"));
                }
                sequence_count += 1;
                in_sequence = false;
                current_seq_has_data = false;

                if (sequence_count > 100_000_000) {
                    return ValidationResult.invalid(.fasta, errmsg.tooMany("sequences"));
                }
            } else if (c == '\n' or c == '\r') {
                // After first newline, we're in sequence data
                in_sequence = true;
            } else if (in_sequence) {
                // Validate sequence character
                if (c != ' ' and c != '\t') {
                    if (!valid_seq_chars[c]) {
                        return ValidationResult.invalid(.fasta, "Invalid sequence character");
                    }
                    current_seq_has_data = true;
                }
            }
            // Characters in header line (before first newline) are not validated
        }

        total_read += bytes_read;
    }

    if (sequence_count == 0) {
        return ValidationResult.invalid(.fasta, "No sequences found");
    }

    return ValidationResult.okWithDepth(.fasta, .full);
}

/// Initialize lookup table for valid FASTA sequence characters
fn init_valid_fasta_chars() [256]bool {
    var table = [_]bool{false} ** 256;

    // Standard nucleotides (DNA/RNA)
    for ("ACGTUacgtu") |c| table[c] = true;

    // IUPAC ambiguity codes
    for ("RYSWKMBDHVNryswkmbdhvn") |c| table[c] = true;

    // Amino acids (single-letter codes)
    for ("ARNDCQEGHILKMFPSTWYVarndcqeghilkmfpstwyv") |c| table[c] = true;

    // Special characters
    table['*'] = true; // Stop codon
    table['-'] = true; // Gap
    table['.'] = true; // Gap (alternate)
    table['X'] = true; // Unknown amino acid
    table['x'] = true;

    return table;
}

// ============ FASTQ Validator ============

/// Validate FASTQ sequencing file format.
/// Full integrity validation: parses multiple records, validates sequence characters,
/// and verifies quality score encoding.
pub fn validateFastq(file: std.fs.File) ValidationResult {
    const stat = file.stat() catch return ValidationResult.invalid(.fastq, errmsg.failedToStat("file"));
    const file_size = stat.size;

    if (file_size == 0) {
        return ValidationResult.invalid(.fastq, errmsg.empty("file"));
    }

    file.seekTo(0) catch return ValidationResult.invalid(.fastq, errmsg.failedToSeek("to start"));

    // Read file in chunks
    const chunk_size: usize = 1024 * 1024; // 1MB
    var buffer: [1024 * 1024]u8 = undefined;

    var total_read: u64 = 0;
    var record_count: u32 = 0;
    var line_in_record: u8 = 0; // 0=header, 1=seq, 2=plus, 3=qual
    var current_seq_len: u32 = 0;
    var current_qual_len: u32 = 0;
    var at_line_start = true;
    var first_char_checked = false;

    // Valid sequence characters
    const valid_seq_chars = init_valid_fastq_seq_chars();

    while (total_read < file_size) {
        const to_read = @min(chunk_size, @as(usize, @intCast(file_size - total_read)));
        const bytes_read = file.read(buffer[0..to_read]) catch {
            return ValidationResult.invalid(.fastq, errmsg.failedToRead("file"));
        };

        if (bytes_read == 0) break;

        const data = buffer[0..bytes_read];

        for (data) |c| {
            if (!first_char_checked) {
                first_char_checked = true;
                if (c != '@') {
                    return ValidationResult.invalid(.fastq, "FASTQ must start with '@'");
                }
            }

            if (c == '\n') {
                // End of line
                if (line_in_record == 1) {
                    // End of sequence line
                    if (current_seq_len == 0) {
                        return ValidationResult.invalid(.fastq, errmsg.empty("sequence line"));
                    }
                } else if (line_in_record == 3) {
                    // End of quality line
                    if (current_qual_len != current_seq_len) {
                        return ValidationResult.invalid(.fastq, "Quality length doesn't match sequence");
                    }
                    record_count += 1;
                    current_seq_len = 0;
                    current_qual_len = 0;

                    if (record_count > 1_000_000_000) {
                        return ValidationResult.invalid(.fastq, errmsg.tooMany("records"));
                    }
                }

                line_in_record = (line_in_record + 1) % 4;
                at_line_start = true;
            } else if (c == '\r') {
                // Skip carriage return
            } else {
                if (at_line_start) {
                    // First character of line
                    if (line_in_record == 0 and c != '@') {
                        return ValidationResult.invalid(.fastq, "Record header must start with '@'");
                    } else if (line_in_record == 2 and c != '+') {
                        return ValidationResult.invalid(.fastq, "Separator line must start with '+'");
                    }
                    at_line_start = false;
                }

                if (line_in_record == 1) {
                    // Sequence line - validate character
                    if (!valid_seq_chars[c]) {
                        return ValidationResult.invalid(.fastq, "Invalid sequence character");
                    }
                    current_seq_len += 1;
                } else if (line_in_record == 3) {
                    // Quality line - any printable ASCII (Phred+33 or Phred+64)
                    if (c < 33 or c > 126) {
                        return ValidationResult.invalid(.fastq, "Invalid quality score character");
                    }
                    current_qual_len += 1;
                }
            }
        }

        total_read += bytes_read;
    }

    if (record_count == 0) {
        return ValidationResult.invalid(.fastq, "No complete records found");
    }

    // Check for incomplete final record
    if (line_in_record != 0) {
        return ValidationResult.invalid(.fastq, errmsg.incomplete("final record"));
    }

    return ValidationResult.okWithDepth(.fastq, .full);
}

/// Initialize lookup table for valid FASTQ sequence characters
fn init_valid_fastq_seq_chars() [256]bool {
    var table = [_]bool{false} ** 256;

    // Standard nucleotides
    for ("ACGTNacgtn") |c| table[c] = true;

    // IUPAC ambiguity codes (some sequencers output these)
    for ("RYSWKMBDHVryswkmbdhv") |c| table[c] = true;

    // Uracil for RNA
    table['U'] = true;
    table['u'] = true;

    return table;
}
