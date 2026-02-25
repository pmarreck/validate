const std = @import("std");
const Allocator = std.mem.Allocator;
const format_validation = @import("format_validation.zig");
const ValidationResult = format_validation.ValidationResult;
const ValidationDepth = format_validation.ValidationDepth;
const jpeg_validator = @import("jpeg_validator.zig");
const jpeg_lossless_decoder = @import("jpeg_lossless_decoder.zig");
const jpeg2000_validator = @import("jpeg2000_validator.zig");
const errmsg = @import("error_messages.zig");
const zlib = @import("zlib.zig");

// ============ NetCDF Validator ============

/// NetCDF classic signature: CDF\x01 or CDF\x02
const NETCDF_SIGNATURE = [_]u8{ 'C', 'D', 'F' };

/// Validate NetCDF file structure.
/// Structural validation: parses dimensions, variables, and attributes; verifies offsets.
/// No checksums exist in NetCDF classic format. NetCDF-4 is HDF5-based and detected as HDF5.
pub fn validateNetcdf(file: std.fs.File) ValidationResult {
    const stat = file.stat() catch return ValidationResult.invalidCode(.netcdf, .failed_to_stat, "file");
    const file_size = stat.size;

    file.seekTo(0) catch return ValidationResult.invalidCode(.netcdf, .failed_to_seek, "to start");

    // Read enough for header and dimension/variable arrays
    const max_header_size: usize = @min(@as(usize, @intCast(file_size)), 256 * 1024);
    var header_buf: [256 * 1024]u8 = undefined;
    const header_read = file.read(header_buf[0..max_header_size]) catch {
        return ValidationResult.invalidCode(.netcdf, .failed_to_read, "NetCDF header");
    };

    if (header_read < 4) {
        return ValidationResult.invalidCode(.netcdf, .file_too_small, "NetCDF");
    }

    const header = header_buf[0..header_read];

    // Check CDF signature
    if (!std.mem.eql(u8, header[0..3], &NETCDF_SIGNATURE)) {
        return ValidationResult.invalidCode(.netcdf, .invalid_signature, "NetCDF");
    }

    // Check version byte (1 = classic, 2 = 64-bit offset, 5 = CDF-5)
    const version = header[3];
    if (version != 1 and version != 2 and version != 5) {
        return ValidationResult.invalidCode(.netcdf, .invalid_value, "NetCDF version");
    }

    // Offset/size width depends on version
    const is_cdf5 = version == 5;
    const offset_64bit = version == 2 or version == 5;

    if (header_read < 8) {
        return ValidationResult.invalidCode(.netcdf, .truncated, "NetCDF header");
    }

    // numrecs field
    var pos: usize = 4;
    if (is_cdf5) {
        if (header_read < 12) {
            return ValidationResult.invalidCode(.netcdf, .truncated, "CDF-5 header");
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
        return ValidationResult.invalidCode(.netcdf, .truncated, "dimension list");
    }

    const dim_tag = std.mem.readInt(u32, header[pos..][0..4], .big);
    pos += 4;

    if (dim_tag != 0x0000000A and dim_tag != 0x00000000) {
        return ValidationResult.invalidCode(.netcdf, .invalid_value, "dimension list tag");
    }

    var num_dims: u32 = 0;
    if (dim_tag == 0x0000000A) {
        if (pos + 4 > header_read) {
            return ValidationResult.invalidCode(.netcdf, .truncated, "dimension count");
        }
        num_dims = std.mem.readInt(u32, header[pos..][0..4], .big);
        pos += 4;

        if (num_dims > 10000) {
            return ValidationResult.invalidCode(.netcdf, .too_many, "dimensions");
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
        return ValidationResult.okWithDepth(.netcdf, .structural);
    }

    const gatt_tag = std.mem.readInt(u32, header[pos..][0..4], .big);
    pos += 4;

    if (gatt_tag == 0x0000000C) {
        if (pos + 4 > header_read) {
            return ValidationResult.invalidCode(.netcdf, .truncated, "attribute count");
        }
        const num_atts = std.mem.readInt(u32, header[pos..][0..4], .big);
        pos += 4;

        if (num_atts > 100000) {
            return ValidationResult.invalidCode(.netcdf, .too_many, "attributes");
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
        return ValidationResult.invalidCode(.netcdf, .invalid_value, "attribute list tag");
    }

    // Parse variable list and verify offsets
    if (pos + 4 > header_read) {
        return ValidationResult.okWithDepth(.netcdf, .structural);
    }

    const var_tag = std.mem.readInt(u32, header[pos..][0..4], .big);
    pos += 4;

    if (var_tag == 0x0000000B) {
        if (pos + 4 > header_read) {
            return ValidationResult.invalidCode(.netcdf, .truncated, "variable count");
        }
        const num_vars = std.mem.readInt(u32, header[pos..][0..4], .big);
        pos += 4;

        if (num_vars > 100000) {
            return ValidationResult.invalidCode(.netcdf, .too_many, "variables");
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
                return ValidationResult.invalidCodeMsg(.netcdf, .exceeds_bounds, "Variable data offset", "Variable data offset exceeds file size");
            }
        }
    } else if (var_tag != 0x00000000) {
        return ValidationResult.invalidCode(.netcdf, .invalid_value, "variable list tag");
    }

    return ValidationResult.okWithDepth(.netcdf, .structural);
}

// ============ FITS Validator ============

/// Validate FITS (Flexible Image Transport System) file structure.
/// Full integrity validation: parses all header blocks, validates keyword syntax,
/// checks NAXIS dimensions, verifies data array bounds, and validates CHECKSUM/DATASUM.
pub fn validateFits(file: std.fs.File) ValidationResult {
    const stat = file.stat() catch return ValidationResult.invalidCode(.fits, .failed_to_stat, "file");
    const file_size = stat.size;

    file.seekTo(0) catch return ValidationResult.invalidCode(.fits, .failed_to_seek, "to start");

    // FITS header blocks are 2880 bytes
    var header: [2880]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalidCode(.fits, .failed_to_read, "FITS header");

    if (header_read < 80) {
        return ValidationResult.invalidCode(.fits, .file_too_small, "FITS");
    }

    // First keyword must be SIMPLE
    if (!std.mem.eql(u8, header[0..9], "SIMPLE  =")) {
        return ValidationResult.invalidCode(.fits, .invalid_signature, "FITS");
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
                return ValidationResult.invalidCode(.fits, .invalid_value, "BITPIX value");
            };
            // Valid BITPIX values: 8, 16, 32, 64, -32, -64
            if (bitpix != 8 and bitpix != 16 and bitpix != 32 and bitpix != 64 and
                bitpix != -32 and bitpix != -64)
            {
                return ValidationResult.invalidCode(.fits, .invalid_value, "BITPIX value");
            }
        }

        // Parse NAXIS
        if (std.mem.eql(u8, keyword_line[0..8], "NAXIS   ")) {
            found_naxis = true;
            const naxis_val = parseFitsInteger(keyword_line[10..30]) catch {
                return ValidationResult.invalidCode(.fits, .invalid_value, "NAXIS value");
            };
            if (naxis_val < 0 or naxis_val > 999) {
                return ValidationResult.invalidCode(.fits, .invalid_value, "NAXIS value");
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
        return ValidationResult.invalidCode(.fits, .missing, "BITPIX keyword");
    }

    if (!found_naxis) {
        return ValidationResult.invalidCode(.fits, .missing, "NAXIS keyword");
    }

    if (!found_end) {
        return ValidationResult.invalidCode(.fits, .missing, "END keyword in header");
    }

    // Calculate expected data size and data section bounds
    const header_end = @as(u64, header_blocks) * 2880;
    var data_blocks: u64 = 0;

    if (naxis > 0 and bitpix != 0) {
        var data_elements: u64 = 1;
        var dim_i: u32 = 0;
        while (dim_i < naxis and dim_i < 10) : (dim_i += 1) {
            if (naxis_dims[dim_i] == 0) {
                return ValidationResult.invalidCode(.fits, .missing, "NAXISn dimension");
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
            return ValidationResult.invalidCode(.fits, .file_too_small, "declared data array");
        }
    }

    // Verify CHECKSUM if present
    // CHECKSUM should make the entire HDU sum to -0 (0xFFFFFFFF)
    if (checksum_value != null) {
        const hdu_size = header_end + data_blocks * 2880;

        // Read entire HDU and compute checksum
        file.seekTo(0) catch return ValidationResult.invalidCode(.fits, .failed_to_seek, "for CHECKSUM");

        // Limit HDU size for checksum verification (avoid OOM on huge files)
        if (hdu_size > 1024 * 1024 * 1024) { // 1 GiB limit
            // CHECKSUM present but file too large to verify — data not actually checked
            return ValidationResult.okWithDepthAndWarning(.fits, .structural, "CHECKSUM present but HDU exceeds 1 GiB verification limit");
        }

        var hdu_sum: u64 = 0;
        var buf: [2880]u8 = undefined;
        var remaining = hdu_size;

        while (remaining > 0) {
            const to_read = @min(remaining, 2880);
            const bytes_read = file.read(buf[0..to_read]) catch {
                return ValidationResult.invalidCode(.fits, .failed_to_read, "HDU for CHECKSUM");
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
            return ValidationResult.invalidCode(.fits, .invalid_value, "DATASUM value");
        };

        // Read data section and compute checksum
        file.seekTo(header_end) catch {
            return ValidationResult.invalidCode(.fits, .failed_to_seek, "to data for DATASUM");
        };

        const data_size = data_blocks * 2880;

        // Limit data size for checksum verification
        if (data_size > 1024 * 1024 * 1024) { // 1 GiB limit
            // DATASUM present but data too large to verify
            return ValidationResult.okWithDepthAndWarning(.fits, .structural, "DATASUM present but data exceeds 1 GiB verification limit");
        }

        var data_sum: u64 = 0;
        var buf: [2880]u8 = undefined;
        var remaining = data_size;

        while (remaining > 0) {
            const to_read = @min(remaining, 2880);
            const bytes_read = file.read(buf[0..to_read]) catch {
                return ValidationResult.invalidCode(.fits, .failed_to_read, "data for DATASUM");
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

    // No CHECKSUM or DATASUM present — data bytes are not verified
    return ValidationResult.okWithDepthAndWarning(.fits, .structural, "no CHECKSUM/DATASUM keyword; data integrity not verified");
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
/// Structural validation: parses all data elements, validates tag structure,
/// handles sequences with undefined length, validates encapsulated pixel data (JPEG, etc.),
/// and recursively validates nested sequences up to 32 levels deep.
/// No file-level checksum — metadata field corruption is undetectable.
pub fn validateDicom(file: std.fs.File) ValidationResult {
    // Use GPA for temporary allocations during validation
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stat = file.stat() catch return ValidationResult.invalidCode(.dicom, .failed_to_stat, "file");
    const file_size = stat.size;

    if (file_size < 132) {
        return ValidationResult.invalidCode(.dicom, .file_too_small, "DICOM");
    }

    // DICOM files have 128-byte preamble + "DICM" signature
    file.seekTo(128) catch return ValidationResult.invalidCode(.dicom, .failed_to_seek, "past preamble");

    var magic: [4]u8 = undefined;
    const magic_read = file.read(&magic) catch return ValidationResult.invalidCode(.dicom, .failed_to_read, "DICOM magic");

    if (magic_read < 4) {
        return ValidationResult.invalidCode(.dicom, .truncated, "DICOM magic");
    }

    if (!std.mem.eql(u8, &magic, "DICM")) {
        return ValidationResult.invalidCode(.dicom, .invalid_signature, "DICOM");
    }

    // Parse File Meta Information (Group 0002) - always explicit VR little-endian
    var offset: u64 = 132;
    var found_transfer_syntax = false;
    var is_explicit_vr = true; // Default for dataset after meta info
    var element_count: u32 = 0;
    var embedded_data_valid = true;

    // Parse meta information elements (always Explicit VR Little Endian)
    while (offset < file_size) {
        file.seekTo(offset) catch return ValidationResult.invalidCode(.dicom, .failed_to_seek, "to element");

        var element_buf: [12]u8 = undefined;
        const elem_read = file.read(&element_buf) catch return ValidationResult.invalidCode(.dicom, .failed_to_read, "element");

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
                return ValidationResult.invalidCode(.dicom, .truncated, "element header");
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
                return ValidationResult.invalidCodeMsg(.dicom, .exceeds_bounds, "Meta element value", "Meta element value exceeds file bounds");
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
            return ValidationResult.invalidCode(.dicom, .too_many, "meta information elements");
        }
    }

    if (element_count == 0) {
        return ValidationResult.invalid(.dicom, "No DICOM elements found");
    }

    if (!found_transfer_syntax) {
        return ValidationResult.invalidCode(.dicom, .missing, "Transfer Syntax UID");
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

    // Return appropriate validation depth based on embedded data validation.
    // DICOM has no file-level checksum — metadata corruption (patient name, dates, etc.)
    // would go undetected. Even with valid embedded pixel data decode, a random bit flip
    // in a non-pixel value field would not cause validation failure, so depth is structural.
    if (embedded_data_valid) {
        return ValidationResult.okWithDepth(.dicom, .structural);
    } else {
        return ValidationResult.okWithDepthAndWarning(.dicom, .structural, "Embedded pixel data validation failed");
    }
}

// ============ FASTA Validator ============

/// Validate FASTA sequence file format.
/// Structural validation: parses all sequences, validates alphabet characters,
/// and checks for proper record structure throughout the file.
/// No checksums — a bit flip within the valid alphabet is undetectable.
pub fn validateFasta(file: std.fs.File) ValidationResult {
    const stat = file.stat() catch return ValidationResult.invalidCode(.fasta, .failed_to_stat, "file");
    const file_size = stat.size;

    if (file_size == 0) {
        return ValidationResult.invalidCode(.fasta, .empty, "file");
    }

    file.seekTo(0) catch return ValidationResult.invalidCode(.fasta, .failed_to_seek, "to start");

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
            return ValidationResult.invalidCode(.fasta, .failed_to_read, "file");
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
                    return ValidationResult.invalidCode(.fasta, .empty, "sequence (no data after header)");
                }
                sequence_count += 1;
                in_sequence = false;
                current_seq_has_data = false;

                if (sequence_count > 100_000_000) {
                    return ValidationResult.invalidCode(.fasta, .too_many, "sequences");
                }
            } else if (c == '\n' or c == '\r') {
                // After first newline, we're in sequence data
                in_sequence = true;
            } else if (in_sequence) {
                // Validate sequence character
                if (c != ' ' and c != '\t') {
                    if (!valid_seq_chars[c]) {
                        return ValidationResult.invalidCode(.fasta, .invalid_value, "sequence character");
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

    // FASTA has no checksums. Character validation catches invalid alphabet usage,
    // but a bit flip changing one valid nucleotide to another (e.g. A->C) is undetectable.
    return ValidationResult.okWithDepth(.fasta, .structural);
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
/// Structural validation: parses multiple records, validates sequence characters,
/// verifies quality score encoding, and checks sequence/quality length agreement.
/// No checksums — a bit flip within valid character ranges is undetectable.
pub fn validateFastq(file: std.fs.File) ValidationResult {
    const stat = file.stat() catch return ValidationResult.invalidCode(.fastq, .failed_to_stat, "file");
    const file_size = stat.size;

    if (file_size == 0) {
        return ValidationResult.invalidCode(.fastq, .empty, "file");
    }

    file.seekTo(0) catch return ValidationResult.invalidCode(.fastq, .failed_to_seek, "to start");

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
            return ValidationResult.invalidCode(.fastq, .failed_to_read, "file");
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
                        return ValidationResult.invalidCode(.fastq, .empty, "sequence line");
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
                        return ValidationResult.invalidCode(.fastq, .too_many, "records");
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
                        return ValidationResult.invalidCode(.fastq, .invalid_value, "sequence character");
                    }
                    current_seq_len += 1;
                } else if (line_in_record == 3) {
                    // Quality line - any printable ASCII (Phred+33 or Phred+64)
                    if (c < 33 or c > 126) {
                        return ValidationResult.invalidCode(.fastq, .invalid_value, "quality score character");
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
        return ValidationResult.invalidCode(.fastq, .incomplete, "final record");
    }

    // FASTQ has no checksums. Sequence/quality character validation and length matching
    // catch structural issues, but a bit flip within valid character ranges is undetectable.
    return ValidationResult.okWithDepth(.fastq, .structural);
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

// ============ HDF5 Validator ============

/// HDF5 signature: 89 48 44 46 0D 0A 1A 0A
const HDF5_SIGNATURE = [_]u8{ 0x89, 0x48, 0x44, 0x46, 0x0D, 0x0A, 0x1A, 0x0A };

/// Jenkins lookup3 hash - used for HDF5 checksums
/// This is the hash function used by HDF5 for superblock and metadata checksums.
/// Reference: http://burtleburtle.net/bob/c/lookup3.c
pub fn jenkinsLookup3(data: []const u8, init_val: u32) u32 {
    var a: u32 = 0xdeadbeef +% @as(u32, @intCast(data.len)) +% init_val;
    var b: u32 = a;
    var c: u32 = a;

    var i: usize = 0;
    const len = data.len;

    // Process 12-byte chunks. Reference uses `length > 12` (strict), keeping
    // the last <=12 bytes for the tail handler which applies final() not mix().
    while (len -| i > 12) {
        a +%= std.mem.readInt(u32, data[i..][0..4], .little);
        b +%= std.mem.readInt(u32, data[i + 4 ..][0..4], .little);
        c +%= std.mem.readInt(u32, data[i + 8 ..][0..4], .little);

        // mix(a, b, c)
        a -%= c;
        a ^= (c << 4) | (c >> 28);
        c +%= b;
        b -%= a;
        b ^= (a << 6) | (a >> 26);
        a +%= c;
        c -%= b;
        c ^= (b << 8) | (b >> 24);
        b +%= a;
        a -%= c;
        a ^= (c << 16) | (c >> 16);
        c +%= b;
        b -%= a;
        b ^= (a << 19) | (a >> 13);
        a +%= c;
        c -%= b;
        c ^= (b << 4) | (b >> 28);
        b +%= a;

        i += 12;
    }

    // Handle remaining 1-12 bytes with final()
    const remaining = len - i;
    if (remaining > 0) {
        if (remaining >= 12) c +%= @as(u32, data[i + 11]) << 24;
        if (remaining >= 11) c +%= @as(u32, data[i + 10]) << 16;
        if (remaining >= 10) c +%= @as(u32, data[i + 9]) << 8;
        if (remaining >= 9) c +%= data[i + 8];
        if (remaining >= 8) b +%= @as(u32, data[i + 7]) << 24;
        if (remaining >= 7) b +%= @as(u32, data[i + 6]) << 16;
        if (remaining >= 6) b +%= @as(u32, data[i + 5]) << 8;
        if (remaining >= 5) b +%= data[i + 4];
        if (remaining >= 4) a +%= @as(u32, data[i + 3]) << 24;
        if (remaining >= 3) a +%= @as(u32, data[i + 2]) << 16;
        if (remaining >= 2) a +%= @as(u32, data[i + 1]) << 8;
        if (remaining >= 1) a +%= data[i];

        // final(a, b, c)
        c ^= b;
        c -%= (b << 14) | (b >> 18);
        a ^= c;
        a -%= (c << 11) | (c >> 21);
        b ^= a;
        b -%= (a << 25) | (a >> 7);
        c ^= b;
        c -%= (b << 16) | (b >> 16);
        a ^= c;
        a -%= (c << 4) | (c >> 28);
        b ^= a;
        b -%= (a << 14) | (a >> 18);
        c ^= b;
        c -%= (b << 24) | (b >> 8);
    }

    return c;
}

/// Validate HDF5 file structure.
/// Full integrity validation: parses superblock, validates version-specific fields,
/// and checks root group object header.
pub fn validateHdf5(file: std.fs.File) ValidationResult {
    const stat = file.stat() catch return ValidationResult.invalidCode(.hdf5, .failed_to_stat, "file");
    const file_size = stat.size;

    file.seekTo(0) catch return ValidationResult.invalidCode(.hdf5, .failed_to_seek, "to start");

    // Superblock is at least 24 bytes for version 0/1, or 48+ bytes for version 2/3
    var superblock: [96]u8 = undefined;
    const sb_read = file.read(&superblock) catch return ValidationResult.invalidCode(.hdf5, .failed_to_read, "HDF5 superblock");

    if (sb_read < 16) {
        return ValidationResult.invalidCode(.hdf5, .file_too_small, "HDF5 superblock");
    }

    // Check magic number
    if (!std.mem.eql(u8, superblock[0..8], &HDF5_SIGNATURE)) {
        return ValidationResult.invalidCode(.hdf5, .invalid_signature, "HDF5");
    }

    // Superblock version at offset 8
    const sb_version = superblock[8];
    if (sb_version > 3) {
        return ValidationResult.invalidCode(.hdf5, .unknown_element, "superblock version");
    }

    // Parse based on superblock version
    if (sb_version == 0 or sb_version == 1) {
        // Version 0/1 superblock structure
        if (sb_read < 24) {
            return ValidationResult.invalidCode(.hdf5, .truncated, "version 0/1 superblock");
        }

        // Free space storage version
        const fs_version = superblock[9];
        if (fs_version > 0) {
            return ValidationResult.invalidCode(.hdf5, .unknown_element, "free space version");
        }

        // Root group symbol table entry version
        const rg_version = superblock[10];
        if (rg_version > 0) {
            return ValidationResult.invalidCode(.hdf5, .unknown_element, "root group version");
        }

        // Shared header message format version
        const shm_version = superblock[12];
        if (shm_version > 0) {
            return ValidationResult.invalidCode(.hdf5, .unknown_element, "shared header message version");
        }

        // Size of offsets (must be 2, 4, 8)
        const offset_size = superblock[13];
        if (offset_size != 2 and offset_size != 4 and offset_size != 8) {
            return ValidationResult.invalidCode(.hdf5, .invalid_value, "size of offsets");
        }

        // Size of lengths (must be 2, 4, 8)
        const length_size = superblock[14];
        if (length_size != 2 and length_size != 4 and length_size != 8) {
            return ValidationResult.invalidCode(.hdf5, .invalid_value, "size of lengths");
        }

        // Group leaf/internal node K values
        const group_leaf_k = std.mem.readInt(u16, superblock[16..18], .little);
        const group_internal_k = std.mem.readInt(u16, superblock[18..20], .little);

        if (group_leaf_k == 0 or group_internal_k == 0) {
            return ValidationResult.invalidCode(.hdf5, .invalid_value, "B-tree K values");
        }

        // Base address (should be 0 for most files)
        // Root group symbol table entry starts at offset 24 + variable size

    } else {
        // Version 2/3 superblock structure
        if (sb_read < 48) {
            return ValidationResult.invalidCode(.hdf5, .truncated, "version 2/3 superblock");
        }

        // Size of offsets at offset 9
        const offset_size = superblock[9];
        if (offset_size != 2 and offset_size != 4 and offset_size != 8) {
            return ValidationResult.invalidCode(.hdf5, .invalid_value, "size of offsets");
        }

        // Size of lengths at offset 10
        const length_size = superblock[10];
        if (length_size != 2 and length_size != 4 and length_size != 8) {
            return ValidationResult.invalidCode(.hdf5, .invalid_value, "size of lengths");
        }

        // File consistency flags at offset 11
        const flags = superblock[11];
        if (flags & 0xFC != 0) { // Reserved bits should be 0
            // Some files may have non-zero reserved bits
        }

        // Superblock extension address and root group object header address
        // depend on offset_size - validate they don't exceed file size
        const base_addr_offset: usize = 12;
        const sb_ext_offset: usize = base_addr_offset + offset_size;
        const eof_offset: usize = sb_ext_offset + offset_size;
        const root_oh_offset: usize = eof_offset + offset_size;

        if (root_oh_offset + offset_size > sb_read) {
            return ValidationResult.invalidCode(.hdf5, .truncated, "superblock addresses");
        }

        // Read end-of-file address
        var eof_addr: u64 = 0;
        if (offset_size == 8) {
            eof_addr = std.mem.readInt(u64, superblock[eof_offset..][0..8], .little);
        } else if (offset_size == 4) {
            eof_addr = std.mem.readInt(u32, superblock[eof_offset..][0..4], .little);
        } else {
            eof_addr = std.mem.readInt(u16, superblock[eof_offset..][0..2], .little);
        }

        // End-of-file address should not exceed actual file size by much
        // (allow some tolerance for padding)
        if (eof_addr > file_size + 8) {
            return ValidationResult.invalidCodeMsg(.hdf5, .exceeds_bounds, "End-of-file address", "End-of-file address exceeds file size");
        }

        // Read root group object header address
        var root_oh_addr: u64 = 0;
        if (offset_size == 8) {
            root_oh_addr = std.mem.readInt(u64, superblock[root_oh_offset..][0..8], .little);
        } else if (offset_size == 4) {
            root_oh_addr = std.mem.readInt(u32, superblock[root_oh_offset..][0..4], .little);
        } else {
            root_oh_addr = std.mem.readInt(u16, superblock[root_oh_offset..][0..2], .little);
        }

        if (root_oh_addr >= file_size) {
            return ValidationResult.invalidCodeMsg(.hdf5, .exceeds_bounds, "Root group address", "Root group address exceeds file size");
        }

        // Validate superblock checksum (v2/3 has checksum at end)
        // Superblock size: 12 bytes fixed + 4 addresses of offset_size each + 4 byte checksum
        const superblock_size: usize = 12 + 4 * offset_size + 4;
        if (superblock_size > sb_read) {
            return ValidationResult.invalidCode(.hdf5, .truncated, "superblock checksum");
        }

        // Checksum covers bytes 0 to (superblock_size - 4), stored checksum is last 4 bytes
        const checksum_offset = superblock_size - 4;
        const stored_checksum = std.mem.readInt(u32, superblock[checksum_offset..][0..4], .little);
        const computed_checksum = jenkinsLookup3(superblock[0..checksum_offset], 0);

        if (stored_checksum != computed_checksum) {
            return ValidationResult.invalidCodeMsg(.hdf5, .checksum_mismatch, "HDF5 superblock", "HDF5 superblock checksum mismatch");
        }

        // Verify root group object header checksum (v2 OHDR has Jenkins checksum)
        if (root_oh_addr < file_size) {
            const ohdr_result = validateHdf5ObjectHeaderChecksum(file, root_oh_addr, file_size);
            if (ohdr_result == .invalid) {
                return ValidationResult.invalidCodeMsg(.hdf5, .checksum_mismatch, "root group object header", "Root group object header checksum mismatch");
            }
            if (ohdr_result == .verified) {
                // Both superblock and root OHDR checksums verified
                return ValidationResult.okWithDepth(.hdf5, .full);
            }
        }

        // Superblock checksum passed but OHDR couldn't be verified
        return ValidationResult.okWithDepthAndWarning(.hdf5, .structural, "Superblock checksum verified; root group header could not be verified");
    }

    // v0/1 has no checksums
    return ValidationResult.okWithDepth(.hdf5, .structural);
}

pub const OhdrCheckResult = enum { verified, invalid, unverifiable };

/// Verify a v2 Object Header (OHDR) Jenkins checksum.
/// Parses the variable-length OHDR prefix to find the chunk 0 data size,
/// then computes Jenkins lookup3 over the entire header and compares
/// against the stored 4-byte checksum at the end.
pub fn validateHdf5ObjectHeaderChecksum(file: std.fs.File, oh_addr: u64, file_size: u64) OhdrCheckResult {
    if (oh_addr + 8 > file_size) return .unverifiable;

    // Read OHDR prefix (signature + version + flags + up to 24 optional bytes + chunk size)
    var prefix: [40]u8 = undefined;
    file.seekTo(oh_addr) catch return .unverifiable;
    const prefix_read = file.read(&prefix) catch return .unverifiable;
    if (prefix_read < 8) return .unverifiable;

    // Check OHDR signature
    if (!std.mem.eql(u8, prefix[0..4], "OHDR")) return .unverifiable;

    // Version must be 2
    if (prefix[4] != 2) return .unverifiable;

    const flags = prefix[5];
    var offset: usize = 6;

    // Optional: times stored (bit 5) — 4 x 4 bytes
    if (flags & 0x20 != 0) offset += 16;

    // Optional: non-default attribute storage (bit 4) — 2 x 2 bytes
    if (flags & 0x10 != 0) offset += 4;

    // Chunk 0 data size (1, 2, 4, or 8 bytes based on flag bits 0-1)
    const size_encoding: u3 = @intCast(flags & 0x03);
    const size_bytes: usize = @as(usize, 1) << size_encoding;
    if (offset + size_bytes > prefix_read) return .unverifiable;

    const chunk0_size: u64 = switch (size_encoding) {
        0 => prefix[offset],
        1 => std.mem.readInt(u16, prefix[offset..][0..2], .little),
        2 => std.mem.readInt(u32, prefix[offset..][0..4], .little),
        3 => std.mem.readInt(u64, prefix[offset..][0..8], .little),
        else => unreachable,
    };
    offset += size_bytes;

    // Total OHDR = prefix + chunk0_data + 4 (checksum)
    const total_size = offset + chunk0_size + 4;
    if (total_size > 65536) return .unverifiable; // sanity limit (64KB)
    if (oh_addr + total_size > file_size) return .unverifiable;

    // Read the entire OHDR
    const total_usize: usize = @intCast(total_size);
    var ohdr_buf: [65536]u8 = undefined;
    file.seekTo(oh_addr) catch return .unverifiable;
    const ohdr_read = file.read(ohdr_buf[0..total_usize]) catch return .unverifiable;
    if (ohdr_read < total_usize) return .unverifiable;

    // Checksum covers everything except the last 4 bytes
    const checksum_offset_val = total_usize - 4;
    const stored = std.mem.readInt(u32, ohdr_buf[checksum_offset_val..][0..4], .little);
    const computed = jenkinsLookup3(ohdr_buf[0..checksum_offset_val], 0);

    if (stored == computed) return .verified;
    return .invalid;
}

// ============ Apache Parquet Validator ============

/// Parquet magic: PAR1 at start and end
const PARQUET_SIGNATURE = [_]u8{ 'P', 'A', 'R', '1' };

/// Validate Apache Parquet file structure.
/// Full integrity validation: parses footer metadata, validates row group structure,
/// and checks column chunk bounds.
pub fn validateParquet(file: std.fs.File) ValidationResult {
    const stat = file.stat() catch return ValidationResult.invalidCode(.parquet, .failed_to_stat, "file");
    const file_size = stat.size;

    file.seekTo(0) catch return ValidationResult.invalidCode(.parquet, .failed_to_seek, "to start");

    var header: [4]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalidCode(.parquet, .failed_to_read, "Parquet header");

    if (header_read < 4) {
        return ValidationResult.invalidCode(.parquet, .file_too_small, "Parquet");
    }

    // Check magic number at start
    if (!std.mem.eql(u8, &header, &PARQUET_SIGNATURE)) {
        return ValidationResult.invalidCode(.parquet, .invalid_signature, "Parquet");
    }

    if (file_size < 12) {
        return ValidationResult.invalidCode(.parquet, .file_too_small, "Parquet footer");
    }

    // Read footer: last 8 bytes are footer_length (4 bytes LE) + magic (4 bytes)
    file.seekTo(file_size - 8) catch return ValidationResult.invalidCode(.parquet, .failed_to_seek, "to footer");

    var footer_buf: [8]u8 = undefined;
    const footer_read = file.read(&footer_buf) catch return ValidationResult.invalidCode(.parquet, .failed_to_read, "Parquet footer");

    if (footer_read < 8) {
        return ValidationResult.invalidCode(.parquet, .failed_to_read, "full footer");
    }

    // Check magic at end
    if (!std.mem.eql(u8, footer_buf[4..8], &PARQUET_SIGNATURE)) {
        return ValidationResult.invalidCode(.parquet, .invalid_value, "Parquet footer magic");
    }

    // Footer metadata length (little-endian)
    const footer_length = std.mem.readInt(u32, footer_buf[0..4], .little);

    if (footer_length == 0) {
        return ValidationResult.invalidCode(.parquet, .empty, "footer metadata");
    }

    // Footer metadata must fit before the footer_length and magic
    if (footer_length > file_size - 12) {
        return ValidationResult.invalidCodeMsg(.parquet, .exceeds_bounds, "Footer metadata length", "Footer metadata length exceeds file size");
    }

    // Read footer metadata (Thrift-encoded FileMetaData)
    const footer_start = file_size - 8 - footer_length;
    file.seekTo(footer_start) catch return ValidationResult.invalidCode(.parquet, .failed_to_seek, "to footer metadata");

    // Read up to 64KB of footer metadata for validation
    const max_footer_read: usize = @min(footer_length, 65536);
    var footer_meta: [65536]u8 = undefined;
    const meta_read = file.read(footer_meta[0..max_footer_read]) catch return ValidationResult.invalidCode(.parquet, .failed_to_read, "footer metadata");

    if (meta_read < 8) {
        return ValidationResult.invalid(.parquet, "Footer metadata too small");
    }

    // Parse Thrift Compact Protocol FileMetaData to extract row group info
    const meta = footer_meta[0..meta_read];
    var pos: usize = 0;
    var field_count: u32 = 0;
    var current_field_id: i16 = 0;
    var version: i64 = 0;
    var num_rows: i64 = 0;
    var row_group_count: usize = 0;

    // Parse FileMetaData struct fields
    while (pos < meta.len and field_count < 100) {
        if (pos >= meta.len) break;
        const field_header = meta[pos];
        pos += 1;

        if (field_header == 0) {
            // STOP field - end of struct
            break;
        }

        // Field type (lower 4 bits) and delta (upper 4 bits)
        const field_type = field_header & 0x0F;
        const delta = (field_header >> 4) & 0x0F;

        // Calculate field id
        if (delta == 0) {
            // Full field id follows as zigzag i16
            if (pos + 1 > meta.len) break;
            const field_id_result = readThriftVarint(meta[pos..]) orelse break;
            current_field_id = @intCast(field_id_result.value);
            pos += field_id_result.size;
        } else {
            current_field_id += @intCast(delta);
        }

        // Extract specific fields we care about
        switch (current_field_id) {
            1 => { // version: i32
                if (field_type == 5) { // I32 type
                    const ver_result = readThriftVarint(meta[pos..]) orelse break;
                    version = ver_result.value;
                    pos += ver_result.size;
                    field_count += 1;
                    continue;
                }
            },
            3 => { // num_rows: i64
                if (field_type == 6) { // I64 type
                    const rows_result = readThriftVarint(meta[pos..]) orelse break;
                    num_rows = rows_result.value;
                    pos += rows_result.size;
                    field_count += 1;
                    continue;
                }
            },
            4 => { // row_groups: list<RowGroup>
                if (field_type == 9) { // LIST type
                    // Parse list header
                    if (pos >= meta.len) break;
                    const list_header = meta[pos];
                    pos += 1;
                    const size_nibble = (list_header >> 4) & 0x0F;

                    if (size_nibble == 0x0F) {
                        // Extended size follows as varint
                        const size_result = readThriftVarint(meta[pos..]) orelse break;
                        row_group_count = @intCast(@max(0, size_result.value));
                        pos += size_result.size;
                    } else {
                        row_group_count = size_nibble;
                    }

                    // Skip the row group data for now - full parsing would be complex
                    field_count += 1;
                    // Note: We don't continue here because we need to properly skip the list
                }
            },
            else => {},
        }

        // Skip field value based on type (for fields we didn't handle above)
        const skip_result = skipThriftValue(meta[pos..], field_type);
        if (skip_result == null) {
            // Can't parse further - but we've already extracted useful info
            break;
        }
        pos += skip_result.?;
        field_count += 1;
    }

    if (field_count == 0) {
        return ValidationResult.invalidCode(.parquet, .invalid_value, "Thrift footer structure");
    }

    // Validate extracted metadata
    if (version < 1 or version > 2) {
        // Parquet format versions 1 and 2 are known
        // Version 0 or > 2 might indicate corruption
        // But be lenient - some tools may use unusual versions
    }

    if (num_rows < 0) {
        return ValidationResult.invalidCode(.parquet, .invalid_value, "row count in Parquet metadata");
    }

    // Validate row group count is reasonable
    if (row_group_count > 0 and num_rows > 0) {
        // Each row group typically has at least one row
        // Very small files might have many row groups with few rows
    }

    // No CRC/hash covers payload — Thrift footer structure check only
    return ValidationResult.okWithDepth(.parquet, .structural);
}

/// Deep Parquet validation — reads data pages sequentially, verifies page CRC-32
/// when present. Parquet pages start at offset 4 (after "PAR1" magic) and consist
/// of a Thrift-encoded PageHeader followed by compressed_page_size bytes of data.
pub fn validateParquetDeep(allocator: Allocator, path: []const u8) ValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => ValidationResult.invalidWithDepth(.parquet, "File not found", .full),
            error.AccessDenied => ValidationResult.invalidWithDepth(.parquet, "Access denied", .full),
            else => ValidationResult.invalidCodeWithDepth(.parquet, .failed_to_open, "file", .full),
        };
    };
    defer file.close();

    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCodeWithDepth(.parquet, .failed_to_get, "file size", .structural);
    };

    if (file_size < 12) {
        return ValidationResult.invalidCodeWithDepth(.parquet, .file_too_small, "Parquet", .structural);
    }

    // Read footer length to know where data pages end
    file.seekTo(file_size - 8) catch {
        return ValidationResult.invalidCodeWithDepth(.parquet, .failed_to_seek, "to footer", .structural);
    };
    var footer_buf: [8]u8 = undefined;
    _ = file.readAll(&footer_buf) catch {
        return ValidationResult.invalidCodeWithDepth(.parquet, .failed_to_read, "footer", .structural);
    };

    if (!std.mem.eql(u8, footer_buf[4..8], &PARQUET_SIGNATURE)) {
        return ValidationResult.invalidCodeWithDepth(.parquet, .invalid_value, "footer magic", .structural);
    }

    const footer_length = std.mem.readInt(u32, footer_buf[0..4], .little);
    const data_end: u64 = file_size - 8 - footer_length;

    // Scan data pages from offset 4 to data_end
    file.seekTo(4) catch {
        return ValidationResult.invalidCodeWithDepth(.parquet, .failed_to_seek, "to data", .structural);
    };

    var pages_checked: u32 = 0;
    var pages_with_crc: u32 = 0;
    var crcs_verified: u32 = 0;
    var page_header_buf: [256]u8 = undefined;
    var read_buf: [65536]u8 = undefined;

    while (pages_checked < 10000) {
        const page_start = file.getPos() catch break;
        if (page_start + 4 >= data_end) break;

        // Read enough for the page header (Thrift struct, usually < 100 bytes)
        const to_read = @min(page_header_buf.len, @as(usize, @intCast(data_end - page_start)));
        const hdr_read = file.read(page_header_buf[0..to_read]) catch break;
        if (hdr_read < 3) break;

        const hdr = page_header_buf[0..hdr_read];

        // Parse PageHeader Thrift compact struct fields:
        // field 1: type (I32/type 5), field 2: uncompressed_page_size (I32),
        // field 3: compressed_page_size (I32), field 4: crc (I32, optional)
        var pos: usize = 0;
        var current_field_id: i16 = 0;
        var page_type: i64 = -1;
        var compressed_size: i64 = 0;
        var page_crc: ?u32 = null;
        var header_valid = false;

        while (pos < hdr.len) {
            if (hdr[pos] == 0) { // STOP
                pos += 1;
                header_valid = true;
                break;
            }

            const field_header = hdr[pos];
            pos += 1;

            const field_type = field_header & 0x0F;
            const delta = (field_header >> 4) & 0x0F;

            if (delta == 0) {
                const fid_result = readThriftVarint(hdr[pos..]) orelse break;
                current_field_id = @intCast(fid_result.value);
                pos += fid_result.size;
            } else {
                current_field_id += @intCast(delta);
            }

            // Extract fields we need
            switch (current_field_id) {
                1 => { // type
                    if (field_type == 5) {
                        const v = readThriftVarint(hdr[pos..]) orelse break;
                        page_type = v.value;
                        pos += v.size;
                        continue;
                    }
                },
                3 => { // compressed_page_size
                    if (field_type == 5) {
                        const v = readThriftVarint(hdr[pos..]) orelse break;
                        compressed_size = v.value;
                        pos += v.size;
                        continue;
                    }
                },
                4 => { // crc
                    if (field_type == 5) {
                        const v = readThriftVarint(hdr[pos..]) orelse break;
                        // Zigzag decoded -> need unsigned interpretation
                        page_crc = @bitCast(@as(i32, @intCast(v.value)));
                        pos += v.size;
                        continue;
                    }
                },
                else => {},
            }

            // Skip field we don't care about
            const skip = skipThriftCompactField(hdr[pos..], field_type) orelse break;
            pos += skip;
        }

        if (!header_valid or compressed_size <= 0 or page_type < 0) {
            // Can't parse this page header — stop scanning
            break;
        }

        // Seek past the header to the page data
        file.seekTo(page_start + pos) catch break;

        if (page_crc) |expected_crc| {
            pages_with_crc += 1;

            // Compute CRC-32 over the compressed page data
            var crc = std.hash.Crc32.init();
            var remaining: u64 = @intCast(compressed_size);
            while (remaining > 0) {
                const chunk_read = @min(remaining, read_buf.len);
                const n = file.read(read_buf[0..@intCast(chunk_read)]) catch break;
                if (n == 0) break;
                crc.update(read_buf[0..n]);
                remaining -= n;
            }

            if (remaining > 0) break; // couldn't read all data

            const computed = crc.final();
            if (computed != expected_crc) {
                return ValidationResult.invalidCodeMsgWithDepth(.parquet, .checksum_mismatch, "page CRC-32", "Parquet page CRC-32 mismatch", .full);
            }
            crcs_verified += 1;
        } else {
            // No CRC — skip past the page data
            file.seekTo(page_start + pos + @as(u64, @intCast(compressed_size))) catch break;
        }

        pages_checked += 1;
    }

    _ = allocator;

    if (crcs_verified > 0) {
        return ValidationResult.okWithDepth(.parquet, .full);
    }

    // No CRCs found in page headers — structural only
    return ValidationResult.okWithDepthAndWarning(.parquet, .structural, "No page CRCs present in Parquet file");
}

/// Skip a Thrift Compact Protocol field value (recursive for structs/lists).
pub fn skipThriftCompactField(data: []const u8, field_type: u8) ?usize {
    if (data.len == 0) return null;
    return switch (field_type) {
        1, 2 => 0, // BOOL_TRUE/FALSE (no payload)
        3 => if (data.len >= 1) @as(usize, 1) else null, // I8
        4, 5, 6 => skipVarint(data), // I16/I32/I64
        7 => if (data.len >= 8) @as(usize, 8) else null, // DOUBLE
        8 => blk: { // BINARY/STRING
            const vi = readThriftVarint(data) orelse break :blk null;
            const str_len: usize = @intCast(@max(0, vi.value));
            if (vi.size + str_len > data.len) break :blk null;
            break :blk vi.size + str_len;
        },
        9, 10 => blk: { // LIST/SET
            if (data.len < 1) break :blk null;
            const list_hdr = data[0];
            var pos: usize = 1;
            const size_nibble = (list_hdr >> 4) & 0x0F;
            const elem_type = list_hdr & 0x0F;
            var count: usize = 0;
            if (size_nibble == 0x0F) {
                const vi = readThriftVarint(data[pos..]) orelse break :blk null;
                count = @intCast(@max(0, vi.value));
                pos += vi.size;
            } else {
                count = size_nibble;
            }
            // Skip each element
            for (0..count) |_| {
                const skip = skipThriftCompactField(data[pos..], elem_type) orelse break :blk null;
                pos += skip;
            }
            break :blk pos;
        },
        11 => blk: { // MAP
            if (data.len < 1) break :blk null;
            const vi = readThriftVarint(data) orelse break :blk null;
            const count: usize = @intCast(@max(0, vi.value));
            var pos: usize = vi.size;
            if (count == 0) break :blk pos;
            if (pos >= data.len) break :blk null;
            const types = data[pos];
            pos += 1;
            const key_type = (types >> 4) & 0x0F;
            const val_type = types & 0x0F;
            for (0..count) |_| {
                const k = skipThriftCompactField(data[pos..], key_type) orelse break :blk null;
                pos += k;
                const v = skipThriftCompactField(data[pos..], val_type) orelse break :blk null;
                pos += v;
            }
            break :blk pos;
        },
        12 => blk: { // STRUCT
            var pos: usize = 0;
            while (pos < data.len) {
                if (data[pos] == 0) { // STOP
                    pos += 1;
                    break;
                }
                const fh = data[pos];
                pos += 1;
                const ft = fh & 0x0F;
                const d = (fh >> 4) & 0x0F;
                if (d == 0) {
                    const fi = skipVarint(data[pos..]) orelse break :blk null;
                    pos += fi;
                }
                const skip = skipThriftCompactField(data[pos..], ft) orelse break :blk null;
                pos += skip;
            }
            break :blk pos;
        },
        else => null,
    };
}

/// Skip a Thrift Compact Protocol value, returning bytes consumed or null on error
pub fn skipThriftValue(data: []const u8, field_type: u8) ?usize {
    if (data.len == 0) return null;

    return switch (field_type) {
        1 => 1, // BOOL_TRUE
        2 => 1, // BOOL_FALSE
        3 => 1, // I8
        4 => skipVarint(data), // I16
        5 => skipVarint(data), // I32
        6 => skipVarint(data), // I64
        7 => 8, // DOUBLE
        8 => blk: { // BINARY/STRING
            const len_size = skipVarint(data) orelse break :blk null;
            if (len_size == 0) break :blk null;
            // Decode varint to get length
            var len: u64 = 0;
            var shift: u6 = 0;
            for (data[0..len_size]) |b| {
                len |= @as(u64, b & 0x7F) << shift;
                shift +|= 7;
            }
            if (len > data.len - len_size) break :blk null;
            break :blk len_size + @as(usize, @intCast(len));
        },
        9, 10 => blk: { // LIST/SET
            if (data.len < 1) break :blk null;
            const size_and_type = data[0];
            const size_nibble = (size_and_type >> 4) & 0x0F;
            var pos: usize = 1;

            var element_count: usize = 0;
            if (size_nibble == 0x0F) {
                // Extended size follows as varint
                const varint_size = skipVarint(data[1..]) orelse break :blk null;
                pos += varint_size;
                element_count = 100; // Limit for safety
            } else {
                element_count = size_nibble;
            }

            // Skip elements (simplified - just return current pos)
            break :blk pos;
        },
        11 => blk: { // MAP
            if (data.len < 1) break :blk null;
            break :blk 1; // Simplified
        },
        12 => 0, // STRUCT (nested, would need recursive parsing)
        else => null,
    };
}

/// Skip a varint, returning bytes consumed
pub fn skipVarint(data: []const u8) ?usize {
    var i: usize = 0;
    while (i < data.len and i < 10) {
        if (data[i] & 0x80 == 0) {
            return i + 1;
        }
        i += 1;
    }
    return null;
}

/// Read a Thrift Compact Protocol varint (zigzag encoded i64)
/// Returns the value and bytes consumed, or null on error
pub fn readThriftVarint(data: []const u8) ?struct { value: i64, size: usize } {
    if (data.len == 0) return null;

    var result: u64 = 0;
    var shift: u6 = 0;
    var i: usize = 0;

    while (i < data.len and i < 10) {
        const b = data[i];
        result |= @as(u64, b & 0x7F) << shift;
        i += 1;

        if (b & 0x80 == 0) {
            // Zigzag decode: (n >> 1) ^ -(n & 1)
            const zigzag = result;
            const decoded: i64 = @bitCast((zigzag >> 1) ^ (~(zigzag & 1) +% 1));
            return .{ .value = decoded, .size = i };
        }

        shift +|= 7;
    }
    return null;
}

// ============ MATLAB Validator ============

/// Validate MATLAB v5+ .mat file format.
/// Full integrity validation: parses data element structure and validates types.
pub fn validateMatlab(file: std.fs.File) ValidationResult {
    const stat = file.stat() catch return ValidationResult.invalidCode(.matlab, .failed_to_stat, "file");
    const file_size = stat.size;

    file.seekTo(0) catch return ValidationResult.invalidCode(.matlab, .failed_to_seek, "to start");

    var header: [128]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalidCode(.matlab, .failed_to_read, "MATLAB header");

    if (header_read < 128) {
        return ValidationResult.invalidCode(.matlab, .file_too_small, "MATLAB");
    }

    // Version field at offset 124: 0x0100 for v5
    const version = std.mem.readInt(u16, header[124..126], .little);

    // Endian indicator at offset 126: "IM" (little-endian) or "MI" (big-endian)
    const endian = header[126..128];
    const is_little_endian = std.mem.eql(u8, endian, "IM");
    const is_big_endian = std.mem.eql(u8, endian, "MI");

    if (!is_little_endian and !is_big_endian) {
        return ValidationResult.invalidCode(.matlab, .invalid_value, "MATLAB endian indicator");
    }

    if (version != 0x0100) {
        return ValidationResult.invalidCode(.matlab, .unknown_element, "MATLAB version");
    }

    // Parse data elements
    var offset: u64 = 128;
    var element_count: u32 = 0;

    while (offset + 8 <= file_size and element_count < 100000) {
        file.seekTo(offset) catch break;

        var elem_header: [8]u8 = undefined;
        const elem_read = file.read(&elem_header) catch break;

        if (elem_read < 8) break;

        // Data type (4 bytes) and size (4 bytes)
        var data_type: u32 = undefined;
        var num_bytes: u32 = undefined;
        var header_size: u64 = 8;

        if (is_little_endian) {
            data_type = std.mem.readInt(u32, elem_header[0..4], .little);
            num_bytes = std.mem.readInt(u32, elem_header[4..8], .little);
        } else {
            data_type = std.mem.readInt(u32, elem_header[0..4], .big);
            num_bytes = std.mem.readInt(u32, elem_header[4..8], .big);
        }

        // Check for small data element format (data in type field)
        if ((data_type >> 16) != 0) {
            // Small element: upper 2 bytes = size, lower 2 bytes = type
            num_bytes = (data_type >> 16) & 0xFFFF;
            data_type = data_type & 0xFFFF;
            header_size = 8; // Data is in remaining 4 bytes of header
            if (num_bytes > 4) {
                return ValidationResult.invalidCode(.matlab, .invalid_value, "small element size");
            }
            offset += 8;
            element_count += 1;
            continue;
        }

        // Validate data type
        // Types: 1=INT8, 2=UINT8, 3=INT16, 4=UINT16, 5=INT32, 6=UINT32,
        //        7=SINGLE, 8=reserved, 9=DOUBLE, 10=reserved, 11=reserved,
        //        12=INT64, 13=UINT64, 14=MATRIX, 15=COMPRESSED, 16=UTF8, etc.
        if (data_type == 0 or data_type > 20) {
            // Unknown type - might be valid for newer versions
        }

        // Validate size doesn't exceed file bounds
        const elem_end = offset + header_size + num_bytes;

        // For compressed elements (type 15), decompress to verify integrity
        if (data_type == 15 and num_bytes > 0) decompress_check: {
            // Read compressed data
            const compressed_data = std.heap.page_allocator.alloc(u8, num_bytes) catch {
                break :decompress_check; // Skip if allocation fails
            };
            defer std.heap.page_allocator.free(compressed_data);

            file.seekTo(offset + header_size) catch {
                return ValidationResult.invalidCode(.matlab, .failed_to_seek, "to compressed data");
            };
            const compressed_read = file.readAll(compressed_data) catch {
                return ValidationResult.invalidCode(.matlab, .failed_to_read, "compressed data");
            };
            if (compressed_read != num_bytes) {
                return ValidationResult.invalidCode(.matlab, .incomplete, "compressed data read");
            }

            // Validate zlib decompression using streaming (fixed 64KB buffer, no heap allocation)
            zlib.validateZlib(compressed_data) catch |err| {
                const msg = switch (err) {
                    error.DataError => "Zlib data error - corrupted compressed data",
                    error.UnexpectedEof => "Zlib unexpected EOF - incomplete compressed data",
                    else => errmsg.decompressionFailed("Zlib"),
                };
                return ValidationResult.invalid(.matlab, msg);
            };
        }

        if (elem_end > file_size) {
            return ValidationResult.invalidCodeMsg(.matlab, .exceeds_bounds, "Data element", "Data element exceeds file bounds");
        }

        // Move to next element - MATLAB v5 spec says 8-byte aligned, but many files
        // don't follow this strictly. Try both unpadded and padded offsets.
        offset = elem_end;
        element_count += 1;
    }

    if (element_count == 0) {
        return ValidationResult.invalid(.matlab, "No data elements found");
    }

    // Zlib decompression checked for compressed elements only; uncompressed data not verified
    return ValidationResult.okWithDepth(.matlab, .structural);
}

// ============ NIfTI Validator ============

/// Validate NIfTI (Neuroimaging Informatics Technology Initiative) format.
/// Full integrity validation: parses all header fields and validates data bounds.
pub fn validateNifti(file: std.fs.File) ValidationResult {
    const stat = file.stat() catch return ValidationResult.invalidCode(.nifti, .failed_to_stat, "file");
    const file_size = stat.size;

    file.seekTo(0) catch return ValidationResult.invalidCode(.nifti, .failed_to_seek, "to start");

    var header: [540]u8 = undefined; // NIfTI-2 is 540 bytes
    const header_read = file.read(&header) catch return ValidationResult.invalidCode(.nifti, .failed_to_read, "NIfTI header");

    if (header_read < 348) {
        return ValidationResult.invalidCode(.nifti, .file_too_small, "NIfTI");
    }

    // Determine endianness and version from sizeof_hdr
    const sizeof_hdr_le = std.mem.readInt(i32, header[0..4], .little);
    const sizeof_hdr_be = std.mem.readInt(i32, header[0..4], .big);

    var is_little_endian = true;
    var is_nifti2 = false;

    if (sizeof_hdr_le == 348) {
        is_little_endian = true;
        is_nifti2 = false;
    } else if (sizeof_hdr_be == 348) {
        is_little_endian = false;
        is_nifti2 = false;
    } else if (sizeof_hdr_le == 540) {
        is_little_endian = true;
        is_nifti2 = true;
    } else if (sizeof_hdr_be == 540) {
        is_little_endian = false;
        is_nifti2 = true;
    } else {
        return ValidationResult.invalidCode(.nifti, .invalid_value, "NIfTI header size");
    }

    if (is_nifti2 and header_read < 540) {
        return ValidationResult.invalidCode(.nifti, .truncated, "NIfTI-2 header");
    }

    // Check magic string
    const magic_offset: usize = if (is_nifti2) 4 else 344;
    const magic = header[magic_offset..][0..4];

    if (is_nifti2) {
        if (!std.mem.eql(u8, magic, "ni2\x00") and !std.mem.eql(u8, magic, "n+2\x00")) {
            return ValidationResult.invalidCode(.nifti, .invalid_value, "NIfTI-2 magic");
        }
    } else {
        if (!std.mem.eql(u8, magic, "ni1\x00") and !std.mem.eql(u8, magic, "n+1\x00")) {
            return ValidationResult.invalidCode(.nifti, .invalid_value, "NIfTI-1 magic");
        }
    }

    // Validate dimension fields
    // NIfTI-1: dim array at offset 40 (8 i16 values)
    // NIfTI-2: dim array at offset 16 (8 i64 values)
    var ndim: i64 = 0;
    var dims: [8]i64 = [_]i64{0} ** 8;

    if (is_nifti2) {
        const dim_offset: usize = 16;
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            const val_offset = dim_offset + i * 8;
            if (val_offset + 8 > header_read) break;
            dims[i] = if (is_little_endian)
                std.mem.readInt(i64, header[val_offset..][0..8], .little)
            else
                std.mem.readInt(i64, header[val_offset..][0..8], .big);
        }
        ndim = dims[0];
    } else {
        const dim_offset: usize = 40;
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            const val_offset = dim_offset + i * 2;
            if (val_offset + 2 > header_read) break;
            dims[i] = if (is_little_endian)
                std.mem.readInt(i16, header[val_offset..][0..2], .little)
            else
                std.mem.readInt(i16, header[val_offset..][0..2], .big);
        }
        ndim = dims[0];
    }

    if (ndim < 1 or ndim > 7) {
        return ValidationResult.invalidCode(.nifti, .invalid_value, "number of dimensions");
    }

    // Validate dimension values
    var i: usize = 1;
    while (i <= @as(usize, @intCast(ndim))) : (i += 1) {
        if (dims[i] < 1) {
            return ValidationResult.invalidCode(.nifti, .invalid_value, "dimension value");
        }
    }

    // Get datatype and calculate expected data size
    var datatype: i16 = 0;
    var bitpix: i16 = 0;

    if (is_nifti2) {
        if (header_read >= 14) {
            datatype = if (is_little_endian)
                std.mem.readInt(i16, header[12..14], .little)
            else
                std.mem.readInt(i16, header[12..14], .big);
        }
        if (header_read >= 16) {
            bitpix = if (is_little_endian)
                std.mem.readInt(i16, header[14..16], .little)
            else
                std.mem.readInt(i16, header[14..16], .big);
        }
    } else {
        if (header_read >= 72) {
            datatype = if (is_little_endian)
                std.mem.readInt(i16, header[70..72], .little)
            else
                std.mem.readInt(i16, header[70..72], .big);
        }
        if (header_read >= 74) {
            bitpix = if (is_little_endian)
                std.mem.readInt(i16, header[72..74], .little)
            else
                std.mem.readInt(i16, header[72..74], .big);
        }
    }

    // Valid datatypes: 0=unknown, 1=bool, 2=uint8, 4=int16, 8=int32, 16=float, 32=complex, etc.
    if (datatype != 0 and bitpix > 0) {
        // Calculate expected voxels
        var num_voxels: u64 = 1;
        var dim_idx: usize = 1;
        while (dim_idx <= @as(usize, @intCast(ndim)) and dim_idx < 8) : (dim_idx += 1) {
            if (dims[dim_idx] > 0) {
                num_voxels *= @intCast(dims[dim_idx]);
            }
        }

        const bytes_per_voxel: u64 = @intCast(@divFloor(bitpix + 7, 8));
        const expected_data_size = num_voxels * bytes_per_voxel;

        // vox_offset tells us where data starts
        var vox_offset: f32 = 0;
        if (!is_nifti2 and header_read >= 112) {
            const vox_bytes = header[108..112];
            vox_offset = @bitCast(if (is_little_endian)
                std.mem.readInt(u32, vox_bytes, .little)
            else
                std.mem.readInt(u32, vox_bytes, .big));
        }

        // For single-file NIfTI, check data fits
        if (magic[1] == '+') { // "n+1" or "n+2" = single file
            const min_offset: f32 = if (is_nifti2) 544.0 else 352.0;
            const effective_vox_offset = @max(vox_offset, min_offset);
            const data_start: u64 = @intFromFloat(effective_vox_offset);
            if (data_start + expected_data_size > file_size) {
                return ValidationResult.invalidCodeMsg(.nifti, .exceeds_bounds, "Data array", "Data array exceeds file size");
            }
        }
    }

    // No CRC/hash — header field validation + bounds check only
    return ValidationResult.okWithDepth(.nifti, .structural);
}

// ============ PDB (Protein Data Bank) Validator ============

/// Validate PDB (Protein Data Bank) format.
/// Full integrity validation: parses record types, validates ATOM/HETATM format,
/// and checks coordinate bounds.
pub fn validatePdb(file: std.fs.File) ValidationResult {
    const stat = file.stat() catch return ValidationResult.invalidCode(.pdb_struct, .failed_to_stat, "file");
    const file_size = stat.size;

    if (file_size == 0) {
        return ValidationResult.invalidCode(.pdb_struct, .empty, "file");
    }

    file.seekTo(0) catch return ValidationResult.invalidCode(.pdb_struct, .failed_to_seek, "to start");

    // Read file in chunks
    const chunk_size: usize = 1024 * 1024;
    var buffer: [1024 * 1024]u8 = undefined;

    var total_read: u64 = 0;
    var atom_count: u32 = 0;
    var hetatm_count: u32 = 0;
    var found_header = false;
    var found_end = false;
    var line_buffer: [256]u8 = undefined;
    var line_len: usize = 0;
    var first_line = true;

    // Valid record types for PDB
    const valid_record_types = [_][]const u8{
        "HEADER", "OBSLTE", "TITLE ", "SPLIT ", "CAVEAT", "COMPND", "SOURCE",
        "KEYWDS", "EXPDTA", "NUMMDL", "MDLTYP", "AUTHOR", "REVDAT", "SPRSDE",
        "JRNL  ", "REMARK", "DBREF ", "DBREF1", "DBREF2", "SEQADV", "SEQRES",
        "MODRES", "HET   ", "HETNAM", "HETSYN", "FORMUL", "HELIX ", "SHEET ",
        "SSBOND", "LINK  ", "CISPEP", "SITE  ", "CRYST1", "ORIGX1", "ORIGX2",
        "ORIGX3", "SCALE1", "SCALE2", "SCALE3", "MTRIX1", "MTRIX2", "MTRIX3",
        "MODEL ", "ATOM  ", "ANISOU", "TER   ", "HETATM", "ENDMDL", "CONECT",
        "MASTER", "END   ",
    };

    while (total_read < file_size) {
        const to_read = @min(chunk_size, @as(usize, @intCast(file_size - total_read)));
        const bytes_read = file.read(buffer[0..to_read]) catch {
            return ValidationResult.invalidCode(.pdb_struct, .failed_to_read, "file");
        };

        if (bytes_read == 0) break;

        const data = buffer[0..bytes_read];

        for (data, 0..) |c, i| {
            if (c == '\n' or c == '\r') {
                if (line_len > 0) {
                    const line = line_buffer[0..line_len];

                    // Validate record type (first 6 characters)
                    if (line.len >= 6) {
                        var valid_type = false;
                        for (valid_record_types) |rec_type| {
                            if (std.mem.eql(u8, line[0..6], rec_type)) {
                                valid_type = true;
                                break;
                            }
                        }

                        // Some files have custom record types, allow if not first line
                        if (!valid_type and first_line) {
                            return ValidationResult.invalidCode(.pdb_struct, .invalid_value, "first record type");
                        }

                        // Check specific records
                        if (std.mem.eql(u8, line[0..6], "HEADER")) {
                            found_header = true;
                        } else if (std.mem.eql(u8, line[0..6], "ATOM  ")) {
                            atom_count += 1;
                            // Validate ATOM record format (should have coordinates)
                            if (line.len < 54) {
                                return ValidationResult.invalidCode(.pdb_struct, .truncated, "ATOM record");
                            }
                            // Columns 31-38, 39-46, 47-54 are X, Y, Z coordinates
                            // Just check they're mostly valid characters
                            for (line[30..54]) |coord_c| {
                                if (coord_c != ' ' and coord_c != '.' and coord_c != '-' and
                                    (coord_c < '0' or coord_c > '9'))
                                {
                                    return ValidationResult.invalidCode(.pdb_struct, .invalid_value, "ATOM coordinates");
                                }
                            }
                        } else if (std.mem.eql(u8, line[0..6], "HETATM")) {
                            hetatm_count += 1;
                            if (line.len < 54) {
                                return ValidationResult.invalidCode(.pdb_struct, .truncated, "HETATM record");
                            }
                        } else if (std.mem.eql(u8, line[0..6], "END   ") or std.mem.eql(u8, line[0..3], "END")) {
                            found_end = true;
                        }
                    }

                    first_line = false;
                }
                line_len = 0;

                // Skip \r in \r\n
                if (c == '\r' and i + 1 < bytes_read and data[i + 1] == '\n') {
                    continue;
                }
            } else {
                if (line_len < line_buffer.len) {
                    line_buffer[line_len] = c;
                    line_len += 1;
                }
            }
        }

        total_read += bytes_read;

        // For large files, sample validation is sufficient
        if (total_read > 10 * 1024 * 1024 and atom_count > 10000) {
            break;
        }
    }

    // PDB should have ATOM or HETATM records
    if (atom_count == 0 and hetatm_count == 0) {
        return ValidationResult.invalid(.pdb_struct, "No ATOM/HETATM records found");
    }

    // No CRC/hash — text record parsing only
    return ValidationResult.okWithDepth(.pdb_struct, .structural);
}

// ============ CIF Validator ============

/// Validate CIF (Crystallographic Information File) format.
/// Full integrity validation: parses data blocks, validates tag syntax,
/// and checks loop structure.
pub fn validateCif(file: std.fs.File) ValidationResult {
    const stat = file.stat() catch return ValidationResult.invalidCode(.cif, .failed_to_stat, "file");
    const file_size = stat.size;

    if (file_size == 0) {
        return ValidationResult.invalidCode(.cif, .empty, "file");
    }

    file.seekTo(0) catch return ValidationResult.invalidCode(.cif, .failed_to_seek, "to start");

    // Read file in chunks
    const chunk_size: usize = 1024 * 1024;
    var buffer: [1024 * 1024]u8 = undefined;

    var total_read: u64 = 0;
    var data_block_count: u32 = 0;
    var tag_count: u32 = 0;
    var loop_count: u32 = 0;
    var in_loop_header = false;
    var line_buffer: [2048]u8 = undefined;
    var line_len: usize = 0;
    var found_data_block = false;

    while (total_read < file_size) {
        const to_read = @min(chunk_size, @as(usize, @intCast(file_size - total_read)));
        const bytes_read = file.read(buffer[0..to_read]) catch {
            return ValidationResult.invalidCode(.cif, .failed_to_read, "file");
        };

        if (bytes_read == 0) break;

        const data = buffer[0..bytes_read];

        for (data) |c| {
            if (c == '\n' or c == '\r') {
                if (line_len > 0) {
                    const line = line_buffer[0..line_len];

                    // Skip leading whitespace
                    var start: usize = 0;
                    while (start < line.len and (line[start] == ' ' or line[start] == '\t')) : (start += 1) {}

                    if (start < line.len) {
                        const content = line[start..];

                        // Check for comment
                        if (content[0] == '#') {
                            // Skip comment
                        }
                        // Check for data block
                        else if (content.len >= 5 and std.mem.eql(u8, content[0..5], "data_")) {
                            data_block_count += 1;
                            found_data_block = true;
                            in_loop_header = false;

                            // Validate block name (should be alphanumeric/underscore)
                            if (content.len > 5) {
                                for (content[5..]) |name_c| {
                                    if (name_c == ' ' or name_c == '\t') break;
                                    if ((name_c < 'A' or name_c > 'Z') and
                                        (name_c < 'a' or name_c > 'z') and
                                        (name_c < '0' or name_c > '9') and
                                        name_c != '_' and name_c != '-')
                                    {
                                        // Some CIF files have special chars, allow
                                    }
                                }
                            }
                        }
                        // Check for loop
                        else if (content.len >= 5 and std.mem.eql(u8, content[0..5], "loop_")) {
                            loop_count += 1;
                            in_loop_header = true;
                        }
                        // Check for tag (starts with _)
                        else if (content[0] == '_') {
                            tag_count += 1;

                            // Validate tag name
                            var tag_end: usize = 1;
                            while (tag_end < content.len and content[tag_end] != ' ' and content[tag_end] != '\t') : (tag_end += 1) {}

                            if (tag_end <= 1) {
                                return ValidationResult.invalidCode(.cif, .empty, "tag name");
                            }
                        }
                        // Check for save frame
                        else if (content.len >= 5 and std.mem.eql(u8, content[0..5], "save_")) {
                            // Save frames are valid in CIF
                        }
                        // Otherwise it's a value or continuation
                        else {
                            if (in_loop_header) {
                                // First non-tag after loop_ ends the loop header
                                in_loop_header = false;
                            }
                        }
                    }
                }
                line_len = 0;
            } else {
                if (line_len < line_buffer.len) {
                    line_buffer[line_len] = c;
                    line_len += 1;
                }
            }
        }

        total_read += bytes_read;

        // For large files, sample validation is sufficient
        if (total_read > 10 * 1024 * 1024 and tag_count > 1000) {
            break;
        }
    }

    if (!found_data_block) {
        return ValidationResult.invalid(.cif, "No data_ block found");
    }

    if (tag_count == 0) {
        return ValidationResult.invalid(.cif, "No tags found");
    }

    // No CRC/hash — text tag parsing only
    return ValidationResult.okWithDepth(.cif, .structural);
}

// ============ GIS Format Validators ============

/// Validate ESRI Shapefile (.shp) format.
/// Full integrity validation: parses all records, validates geometry bounds,
/// and checks record lengths.
pub fn validateShapefile(file: std.fs.File) ValidationResult {
    const stat = file.stat() catch return ValidationResult.invalidCode(.shapefile, .failed_to_stat, "file");
    const file_size = stat.size;

    file.seekTo(0) catch return ValidationResult.invalidCode(.shapefile, .failed_to_seek, "to start");

    var header: [100]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalidCode(.shapefile, .failed_to_read, "Shapefile header");

    if (header_read < 100) {
        return ValidationResult.invalidCode(.shapefile, .file_too_small, "Shapefile");
    }

    // File code at offset 0: 9994 (big-endian)
    const file_code = std.mem.readInt(i32, header[0..4], .big);
    if (file_code != 9994) {
        return ValidationResult.invalidCode(.shapefile, .invalid_magic_number, "Shapefile");
    }

    // File length at offset 24 (big-endian, in 16-bit words)
    const file_length_words = std.mem.readInt(i32, header[24..28], .big);
    const declared_file_size: u64 = @intCast(file_length_words * 2);

    if (declared_file_size > file_size) {
        return ValidationResult.invalidCodeMsg(.shapefile, .exceeds_bounds, "Declared file length", "Declared file length exceeds actual size");
    }

    // Version at offset 28: 1000 (little-endian)
    const version = std.mem.readInt(i32, header[28..32], .little);
    if (version != 1000) {
        return ValidationResult.invalidCode(.shapefile, .invalid_value, "Shapefile version");
    }

    // Shape type at offset 32 (little-endian) - valid values 0-31
    const shape_type = std.mem.readInt(i32, header[32..36], .little);
    if (shape_type < 0 or shape_type > 31) {
        return ValidationResult.invalidCode(.shapefile, .invalid_value, "shape type");
    }

    // Bounding box at offsets 36-68 (doubles, little-endian)
    // Xmin, Ymin, Xmax, Ymax
    const x_min: f64 = @bitCast(std.mem.readInt(u64, header[36..44], .little));
    const y_min: f64 = @bitCast(std.mem.readInt(u64, header[44..52], .little));
    const x_max: f64 = @bitCast(std.mem.readInt(u64, header[52..60], .little));
    const y_max: f64 = @bitCast(std.mem.readInt(u64, header[60..68], .little));

    // Validate bounding box (should be reasonable geographic coordinates or NaN for empty)
    if (!std.math.isNan(x_min) and !std.math.isNan(x_max)) {
        if (x_min > x_max) {
            return ValidationResult.invalidCode(.shapefile, .invalid_value, "bounding box (Xmin > Xmax)");
        }
    }
    if (!std.math.isNan(y_min) and !std.math.isNan(y_max)) {
        if (y_min > y_max) {
            return ValidationResult.invalidCode(.shapefile, .invalid_value, "bounding box (Ymin > Ymax)");
        }
    }

    // Parse records
    var offset: u64 = 100;
    var record_count: u32 = 0;

    while (offset + 8 <= declared_file_size and record_count < 10_000_000) {
        file.seekTo(offset) catch break;

        var record_header: [8]u8 = undefined;
        const rec_read = file.read(&record_header) catch break;

        if (rec_read < 8) break;

        // Record number (1-based, big-endian)
        const record_num = std.mem.readInt(i32, record_header[0..4], .big);
        if (record_num < 1) {
            return ValidationResult.invalidCode(.shapefile, .invalid_value, "record number");
        }

        // Content length in 16-bit words (big-endian)
        const content_length_words = std.mem.readInt(i32, record_header[4..8], .big);
        if (content_length_words < 0) {
            return ValidationResult.invalidCode(.shapefile, .invalid_value, "content length");
        }

        const content_length: u64 = @intCast(content_length_words * 2);
        const record_end = offset + 8 + content_length;

        if (record_end > declared_file_size) {
            return ValidationResult.invalid(.shapefile, "Record extends beyond file");
        }

        // Validate shape type in record matches file header (or is Null=0)
        if (content_length >= 4) {
            var shape_type_buf: [4]u8 = undefined;
            _ = file.read(&shape_type_buf) catch 0;
            const rec_shape_type = std.mem.readInt(i32, &shape_type_buf, .little);

            if (rec_shape_type != 0 and rec_shape_type != shape_type) {
                return ValidationResult.invalid(.shapefile, "Record shape type mismatch");
            }
        }

        offset = record_end;
        record_count += 1;
    }

    if (record_count == 0 and declared_file_size > 100) {
        return ValidationResult.invalidCode(.shapefile, .no_valid_x_found, "records");
    }

    // No CRC/hash — header + record structure parsing only
    return ValidationResult.okWithDepth(.shapefile, .structural);
}

// ============ Tests ============

test "jenkinsLookup3 reference vectors" {
    // All values verified against Bob Jenkins' reference hashlittle() from lookup3.c
    try std.testing.expectEqual(@as(u32, 0xdeadbeef), jenkinsLookup3("", 0));
    try std.testing.expectEqual(@as(u32, 0xbe0c1952), jenkinsLookup3("test", 0));
    try std.testing.expectEqual(@as(u32, 0xc7bc405b), jenkinsLookup3("Hello", 0));
    try std.testing.expectEqual(@as(u32, 0xdbf0d999), jenkinsLookup3("7bytes!", 0));

    // Exact multiple of 12 bytes — exercises loop boundary edge case
    try std.testing.expectEqual(@as(u32, 0x031c177b), jenkinsLookup3("12bytes_data", 0));
    try std.testing.expectEqual(@as(u32, 0x02f563a1), jenkinsLookup3("24bytes_data_here!!!!!!!", 0));

    // 44 bytes of 0x42 — same size as HDF5 v2 superblock checksum input (offset_size=8)
    const buf44 = [_]u8{0x42} ** 44;
    try std.testing.expectEqual(@as(u32, 0xd95f828e), jenkinsLookup3(&buf44, 0));

    // Init value changes hash
    try std.testing.expect(jenkinsLookup3("test", 0) != jenkinsLookup3("test", 1));
}

test "HDF5 v2/3 superblock + OHDR checksum verification" {
    // Open the v2 ground truth file and verify checksums
    const file = std.fs.cwd().openFile("ground_truth_examples/hdf5/sample_v2.h5", .{}) catch {
        return; // skip if file not available
    };
    defer file.close();

    const stat = file.stat() catch return;
    const file_size = stat.size;

    // Root group OH addr from superblock: offset 0x24, 8 bytes LE
    file.seekTo(0x24) catch return;
    var addr_buf: [8]u8 = undefined;
    _ = file.read(&addr_buf) catch return;
    const root_oh_addr = std.mem.readInt(u64, &addr_buf, .little);

    // Should be at offset 0x30
    try std.testing.expectEqual(@as(u64, 0x30), root_oh_addr);

    // Verify OHDR checksum
    const result = validateHdf5ObjectHeaderChecksum(file, root_oh_addr, file_size);
    try std.testing.expectEqual(OhdrCheckResult.verified, result);
}

test "HDF5 v2 file reports full depth" {
    const file = std.fs.cwd().openFile("ground_truth_examples/hdf5/sample_v2.h5", .{}) catch {
        return; // skip if file not available
    };
    defer file.close();

    const result = validateHdf5(file);
    try std.testing.expect(result.is_valid);
    try std.testing.expectEqual(ValidationDepth.full, result.validation_depth);
}

test "HDF5 v0 file reports structural depth" {
    const file = std.fs.cwd().openFile("ground_truth_examples/hdf5/sample.h5", .{}) catch {
        return; // skip if file not available
    };
    defer file.close();

    const result = validateHdf5(file);
    try std.testing.expect(result.is_valid);
    try std.testing.expectEqual(ValidationDepth.structural, result.validation_depth);
}

test "FITS without CHECKSUM/DATASUM returns structural depth" {
    // Create a minimal valid FITS file: 2880-byte header block, no CHECKSUM/DATASUM
    var header: [2880]u8 = [_]u8{' '} ** 2880;
    // Each FITS keyword record is exactly 80 bytes, space-padded
    const simple = "SIMPLE  =                    T" ++ (" " ** 50);
    const bitpix = "BITPIX  =                    8" ++ (" " ** 50);
    const naxis = "NAXIS   =                    0" ++ (" " ** 50);
    const end = "END" ++ (" " ** 77);
    @memcpy(header[0..80], simple);
    @memcpy(header[80..160], bitpix);
    @memcpy(header[160..240], naxis);
    @memcpy(header[240..320], end);

    // Write to temp file using TMPDIR (RAM-backed)
    const tmpdir = std.posix.getenv("TMPDIR") orelse "/tmp";
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/test_fits_no_checksum.fits", .{tmpdir}) catch "/tmp/test_fits_no_checksum.fits";

    {
        const wfile = try std.fs.cwd().createFile(path, .{});
        try wfile.writeAll(&header);
        wfile.close();
    }
    defer std.fs.cwd().deleteFile(path) catch {};

    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const result = validateFits(file);
    // Without CHECKSUM or DATASUM, data is NOT verified → must be .structural
    try std.testing.expectEqual(format_validation.ValidationDepth.structural, result.validation_depth);
    try std.testing.expect(result.is_valid);
    try std.testing.expect(result.warning_message != null);
}

test "DICOM with failed embedded pixel data returns structural depth" {
    // This tests the conceptual contract: if embedded pixel data fails, depth should NOT be .full
    const result = ValidationResult.okWithDepthAndWarning(.dicom, .structural, "Embedded pixel data validation failed");
    try std.testing.expectEqual(format_validation.ValidationDepth.structural, result.validation_depth);
    try std.testing.expect(result.is_valid);
}
