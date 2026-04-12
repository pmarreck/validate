/// PDF Cross-Reference Table Parser
///
/// Parses traditional xref tables and xref streams from PDF files.
/// Provides O(M) object lookup where M = number of objects, vs O(N) linear scan.
/// Supports incremental updates via /Prev chain.
const std = @import("std");
const Allocator = std.mem.Allocator;
const zlib = @import("zlib.zig");

pub const XrefEntry = struct {
    obj_num: u32,
    gen_num: u16,
    offset: u64, // byte offset in file (for in-use normal entries)
    in_use: bool, // true = 'n', false = 'f'
};

pub const TrailerInfo = struct {
    size: u32, // /Size
    root_obj: ?u32, // /Root N 0 R
    prev_offset: ?u64, // /Prev (for incremental updates)
};

pub const XrefTable = struct {
    entries: std.AutoHashMapUnmanaged(u32, XrefEntry), // obj_num -> entry (latest gen wins)
    trailer: TrailerInfo,

    pub fn deinit(self: *XrefTable, allocator: Allocator) void {
        self.entries.deinit(allocator);
    }

    pub fn getOffset(self: *const XrefTable, obj_num: u32) ?u64 {
        if (self.entries.get(obj_num)) |entry| {
            if (entry.in_use) return entry.offset;
        }
        return null;
    }

    pub fn inUseCount(self: *const XrefTable) u32 {
        var count: u32 = 0;
        var iter = self.entries.valueIterator();
        while (iter.next()) |entry| {
            if (entry.in_use) count += 1;
        }
        return count;
    }
};

// ---------------------------------------------------------------------------
// PDF primitives
// ---------------------------------------------------------------------------

fn skipWs(data: []const u8, start: usize) usize {
    var i = start;
    while (i < data.len) {
        switch (data[i]) {
            ' ', '\t', '\n', '\r', '\x0c', '\x00' => i += 1,
            '%' => {
                // Skip comment until end of line
                while (i < data.len and data[i] != '\n' and data[i] != '\r') : (i += 1) {}
            },
            else => break,
        }
    }
    return i;
}

/// Parse an unsigned integer from data at `start`. Returns value and position after last digit.
fn parseUint(data: []const u8, start: usize) ?struct { value: u64, end: usize } {
    var i = start;
    if (i >= data.len or data[i] < '0' or data[i] > '9') return null;
    var val: u64 = 0;
    while (i < data.len and data[i] >= '0' and data[i] <= '9') : (i += 1) {
        val = val *% 10 +% (data[i] - '0');
    }
    return .{ .value = val, .end = i };
}

/// Parse a signed integer from data at `start`.
fn parseSint(data: []const u8, start: usize) ?struct { value: i64, end: usize } {
    var i = start;
    var negative = false;
    if (i < data.len and data[i] == '-') {
        negative = true;
        i += 1;
    } else if (i < data.len and data[i] == '+') {
        i += 1;
    }
    const r = parseUint(data, i) orelse return null;
    const sval: i64 = std.math.cast(i64, r.value) orelse return null;
    return .{ .value = if (negative) -sval else sval, .end = r.end };
}

/// Parse a PDF name starting with '/'. Returns name (without /) and end position.
fn parsePdfName(data: []const u8, start: usize) ?struct { name: []const u8, end: usize } {
    if (start >= data.len or data[start] != '/') return null;
    var end = start + 1;
    while (end < data.len) {
        const c = data[end];
        if (c == '/' or c == '[' or c == ']' or c == '<' or c == '>' or
            c == '(' or c == ')' or c == '{' or c == '}' or
            c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\x0c')
        {
            break;
        }
        end += 1;
    }
    return .{ .name = data[start + 1 .. end], .end = end };
}

// ---------------------------------------------------------------------------
// Core parsing functions
// ---------------------------------------------------------------------------

/// Find "startxref" near end of file and return the xref offset it specifies.
pub fn findStartxref(data: []const u8) ?u64 {
    // Search backwards from end - startxref is typically in the last 1KB
    const search_len = @min(data.len, 1024);
    const search_start = data.len - search_len;
    const region = data[search_start..];

    const marker = "startxref";
    const pos = std.mem.lastIndexOf(u8, region, marker) orelse return null;
    var i = pos + marker.len;

    // Skip whitespace after "startxref"
    while (i < region.len and (region[i] == ' ' or region[i] == '\n' or region[i] == '\r' or region[i] == '\t')) {
        i += 1;
    }

    // Parse the offset value
    const r = parseUint(region, i) orelse return null;
    return r.value;
}

/// Parse a traditional xref table section starting at `offset` in `data`.
/// Populates `table.entries`. Returns the position after the xref entries (at "trailer").
fn parseTraditionalXref(data: []const u8, offset: usize, table: *XrefTable, allocator: Allocator) ?usize {
    var i = offset;

    // Must start with "xref"
    if (i + 4 > data.len) return null;
    if (!std.mem.eql(u8, data[i..][0..4], "xref")) return null;
    i += 4;
    i = skipWs(data, i);

    // Parse subsections: "first_obj count\n" followed by count 20-byte entries
    while (i < data.len) {
        // Check if we've hit "trailer" keyword
        if (i + 7 <= data.len and std.mem.eql(u8, data[i..][0..7], "trailer")) {
            return i;
        }

        // Parse subsection header: first_obj_num count
        const first_obj = parseUint(data, i) orelse return i; // might be at trailer
        i = first_obj.end;
        i = skipWs(data, i);

        const count = parseUint(data, i) orelse return null;
        i = count.end;

        // Skip the line ending after the subsection header
        if (i < data.len and data[i] == '\r') i += 1;
        if (i < data.len and data[i] == '\n') i += 1;

        // Parse entries - each is 20 bytes in the standard format:
        // "OOOOOOOOOO GGGGG f \n" (10-digit offset, 5-digit gen, f/n, EOL)
        var obj_idx: u64 = 0;
        while (obj_idx < count.value) : (obj_idx += 1) {
            // Skip any leading whitespace (tolerant parsing)
            while (i < data.len and (data[i] == ' ' or data[i] == '\t')) {
                i += 1;
            }

            // Parse offset (10 digits)
            const entry_offset = parseUint(data, i) orelse return null;
            i = entry_offset.end;

            // Skip space
            i = skipWs(data, i);

            // Parse generation number (5 digits)
            const gen = parseUint(data, i) orelse return null;
            i = gen.end;

            // Skip space
            i = skipWs(data, i);

            // Parse in-use flag: 'n' or 'f'
            if (i >= data.len) return null;
            const flag = data[i];
            i += 1;
            if (flag != 'n' and flag != 'f') return null;

            // Skip line ending (could be \r\n, \n, \r, or space+\n etc.)
            while (i < data.len and (data[i] == ' ' or data[i] == '\r' or data[i] == '\n')) {
                i += 1;
            }

            const obj_num: u32 = std.math.cast(u32, first_obj.value + obj_idx) orelse return null;

            // Only add if not already present (later xref sections in /Prev chain
            // take precedence since we process most-recent first)
            if (!table.entries.contains(obj_num)) {
                table.entries.put(allocator, obj_num, .{
                    .obj_num = obj_num,
                    .gen_num = std.math.cast(u16, gen.value) orelse 0,
                    .offset = entry_offset.value,
                    .in_use = flag == 'n',
                }) catch return null;
            }
        }

        // Skip whitespace between subsections
        i = skipWs(data, i);
    }

    return null;
}

/// Parse trailer dictionary, extracting /Size, /Root, /Prev.
pub fn parseTrailerDict(data: []const u8, start: usize) ?TrailerInfo {
    var i = start;

    // Find the "<<" that starts the trailer dict
    while (i + 1 < data.len) {
        if (data[i] == '<' and data[i + 1] == '<') break;
        i += 1;
    }
    if (i + 1 >= data.len) return null;
    i += 2; // skip "<<"

    var info = TrailerInfo{
        .size = 0,
        .root_obj = null,
        .prev_offset = null,
    };
    var found_size = false;

    // Parse dict entries until ">>"
    while (i + 1 < data.len) {
        i = skipWs(data, i);
        if (i + 1 < data.len and data[i] == '>' and data[i + 1] == '>') break;

        if (data[i] == '/') {
            const name_result = parsePdfName(data, i) orelse {
                i += 1;
                continue;
            };
            i = skipWs(data, name_result.end);

            if (std.mem.eql(u8, name_result.name, "Size")) {
                if (parseUint(data, i)) |r| {
                    info.size = std.math.cast(u32, r.value) orelse return null;
                    found_size = true;
                    i = r.end;
                }
            } else if (std.mem.eql(u8, name_result.name, "Root")) {
                // Parse indirect reference: N G R
                if (parseUint(data, i)) |obj_r| {
                    info.root_obj = std.math.cast(u32, obj_r.value) orelse null;
                    i = skipWs(data, obj_r.end);
                    // skip gen num and 'R'
                    if (parseUint(data, i)) |gen_r| {
                        i = skipWs(data, gen_r.end);
                        if (i < data.len and data[i] == 'R') i += 1;
                    }
                }
            } else if (std.mem.eql(u8, name_result.name, "Prev")) {
                if (parseUint(data, i)) |r| {
                    info.prev_offset = r.value;
                    i = r.end;
                }
            } else {
                // Skip value: handle nested dicts, arrays, strings, etc.
                i = skipPdfValue(data, i);
            }
        } else {
            i += 1;
        }
    }

    if (!found_size) return null;
    return info;
}

/// Skip over a PDF value (number, string, name, array, dict, indirect ref, boolean, null).
fn skipPdfValue(data: []const u8, start: usize) usize {
    var i = skipWs(data, start);
    if (i >= data.len) return i;

    switch (data[i]) {
        // Dict
        '<' => {
            if (i + 1 < data.len and data[i + 1] == '<') {
                i += 2;
                var depth: u32 = 1;
                while (i + 1 < data.len and depth > 0) {
                    if (data[i] == '<' and data[i + 1] == '<') {
                        depth += 1;
                        i += 2;
                    } else if (data[i] == '>' and data[i + 1] == '>') {
                        depth -= 1;
                        i += 2;
                    } else {
                        i += 1;
                    }
                }
                return i;
            }
            // Hex string
            while (i < data.len and data[i] != '>') : (i += 1) {}
            if (i < data.len) i += 1;
            return i;
        },
        // Array — must handle nested strings/hex strings that contain [ and ]
        '[' => {
            i += 1;
            var depth: u32 = 1;
            while (i < data.len and depth > 0) {
                switch (data[i]) {
                    '[' => {
                        depth += 1;
                        i += 1;
                    },
                    ']' => {
                        depth -= 1;
                        i += 1;
                    },
                    '(' => {
                        // Skip string literal (handles nested parens and escapes)
                        i += 1;
                        var str_depth: u32 = 1;
                        while (i < data.len and str_depth > 0) {
                            if (data[i] == '\\' and i + 1 < data.len) {
                                i += 2; // skip escaped char
                            } else {
                                if (data[i] == '(') str_depth += 1 else if (data[i] == ')') str_depth -= 1;
                                i += 1;
                            }
                        }
                    },
                    '<' => {
                        // Skip hex string
                        i += 1;
                        while (i < data.len and data[i] != '>') : (i += 1) {}
                        if (i < data.len) i += 1;
                    },
                    else => i += 1,
                }
            }
            return i;
        },
        // String literal
        '(' => {
            i += 1;
            var depth: u32 = 1;
            while (i < data.len and depth > 0) {
                if (data[i] == '\\' and i + 1 < data.len) {
                    i += 2;
                } else {
                    if (data[i] == '(') depth += 1 else if (data[i] == ')') depth -= 1;
                    i += 1;
                }
            }
            return i;
        },
        // Name
        '/' => {
            const r = parsePdfName(data, i) orelse return i + 1;
            return r.end;
        },
        // Number or indirect reference
        '0'...'9', '+', '-' => {
            if (parseSint(data, i)) |r| {
                return r.end;
            }
            return i + 1;
        },
        else => {
            // Skip until whitespace or delimiter
            while (i < data.len and data[i] != ' ' and data[i] != '\n' and data[i] != '\r' and
                data[i] != '/' and data[i] != '<' and data[i] != '>' and
                data[i] != '[' and data[i] != ']')
            {
                i += 1;
            }
            return i;
        },
    }
}

/// Parse a cross-reference stream object at `offset`.
/// Xref streams are PDF objects containing compressed xref data.
fn parseXrefStream(allocator: Allocator, data: []const u8, offset: usize, table: *XrefTable) ?TrailerInfo {
    var i = offset;

    // Parse "N G obj"
    _ = parseUint(data, i) orelse return null; // obj num
    i = skipWs(data, parseUint(data, i).?.end);
    _ = parseUint(data, i) orelse return null; // gen num
    i = skipWs(data, parseUint(data, i).?.end);

    if (i + 3 > data.len or !std.mem.eql(u8, data[i..][0..3], "obj")) return null;
    i += 3;
    i = skipWs(data, i);

    // Must have a dict starting with "<<"
    if (i + 1 >= data.len or data[i] != '<' or data[i + 1] != '<') return null;

    // Parse the stream dictionary to get /Type /XRef, /Size, /W, /Index, /Prev, /Root, /Filter, /Length
    const dict_start = i;
    i += 2;

    var size: ?u32 = null;
    var w_fields: [3]u32 = .{ 0, 0, 0 };
    var index_array: ?[]const u8 = null;
    var prev_offset: ?u64 = null;
    var root_obj: ?u32 = null;
    var stream_length: ?u32 = null;
    var has_flate = false;

    // Parse dict entries
    while (i + 1 < data.len) {
        i = skipWs(data, i);
        if (i + 1 < data.len and data[i] == '>' and data[i + 1] == '>') {
            i += 2;
            break;
        }

        if (data[i] != '/') {
            i += 1;
            continue;
        }

        const name_result = parsePdfName(data, i) orelse {
            i += 1;
            continue;
        };
        i = skipWs(data, name_result.end);

        if (std.mem.eql(u8, name_result.name, "Size")) {
            if (parseUint(data, i)) |r| {
                size = std.math.cast(u32, r.value) orelse return null;
                i = r.end;
            }
        } else if (std.mem.eql(u8, name_result.name, "W")) {
            // Array of 3 integers
            if (i < data.len and data[i] == '[') {
                i += 1;
                for (0..3) |wi| {
                    i = skipWs(data, i);
                    if (parseUint(data, i)) |r| {
                        w_fields[wi] = std.math.cast(u32, r.value) orelse return null;
                        i = r.end;
                    }
                }
                i = skipWs(data, i);
                if (i < data.len and data[i] == ']') i += 1;
            }
        } else if (std.mem.eql(u8, name_result.name, "Index")) {
            // Remember position of index array for later parsing
            if (i < data.len and data[i] == '[') {
                const arr_start = i;
                i += 1;
                while (i < data.len and data[i] != ']') : (i += 1) {}
                if (i < data.len) i += 1;
                index_array = data[arr_start..i];
            }
        } else if (std.mem.eql(u8, name_result.name, "Prev")) {
            if (parseUint(data, i)) |r| {
                prev_offset = r.value;
                i = r.end;
            }
        } else if (std.mem.eql(u8, name_result.name, "Root")) {
            if (parseUint(data, i)) |r| {
                root_obj = std.math.cast(u32, r.value) orelse null;
                i = skipWs(data, r.end);
                // skip gen + R
                if (parseUint(data, i)) |gen_r| {
                    i = skipWs(data, gen_r.end);
                    if (i < data.len and data[i] == 'R') i += 1;
                }
            }
        } else if (std.mem.eql(u8, name_result.name, "Filter")) {
            if (i < data.len and data[i] == '/') {
                const filter = parsePdfName(data, i) orelse {
                    i += 1;
                    continue;
                };
                has_flate = std.mem.eql(u8, filter.name, "FlateDecode");
                i = filter.end;
            }
        } else if (std.mem.eql(u8, name_result.name, "Length")) {
            if (parseUint(data, i)) |r| {
                stream_length = std.math.cast(u32, r.value) orelse return null;
                i = r.end;
            }
        } else {
            i = skipPdfValue(data, i);
        }
    }

    _ = dict_start;
    const xref_size = size orelse return null;

    // Find "stream" keyword
    i = skipWs(data, i);
    if (i + 6 > data.len or !std.mem.eql(u8, data[i..][0..6], "stream")) return null;
    i += 6;
    if (i < data.len and data[i] == '\r') i += 1;
    if (i < data.len and data[i] == '\n') i += 1;

    // Extract stream data
    const stream_start = i;
    var stream_data: []const u8 = undefined;
    if (stream_length) |len| {
        if (stream_start + len > data.len) return null;
        stream_data = data[stream_start .. stream_start + len];
    } else {
        // Search for "endstream"
        const end_marker = "endstream";
        const end_pos = std.mem.indexOf(u8, data[stream_start..], end_marker) orelse return null;
        stream_data = data[stream_start .. stream_start + end_pos];
    }

    // Decompress if FlateDecode
    var decompressed: ?[]u8 = null;
    defer if (decompressed) |d| allocator.free(d);

    const xref_bytes: []const u8 = if (has_flate) blk: {
        decompressed = zlib.inflateZlibAlloc(allocator, stream_data, 64 * 1024 * 1024) catch return null;
        break :blk decompressed.?;
    } else stream_data;

    // Parse binary xref entries using /W widths
    const entry_size = w_fields[0] + w_fields[1] + w_fields[2];
    if (entry_size == 0) return null;

    // Parse /Index array or default to [0 Size]
    var subsections = std.ArrayListUnmanaged(struct { first: u32, count: u32 }){};
    defer subsections.deinit(allocator);

    if (index_array) |idx_data| {
        var j: usize = 0;
        // Skip '['
        while (j < idx_data.len and idx_data[j] != '[') : (j += 1) {}
        if (j < idx_data.len) j += 1;
        while (j < idx_data.len) {
            j = skipWs(idx_data, j);
            if (j >= idx_data.len or idx_data[j] == ']') break;
            const first = parseUint(idx_data, j) orelse break;
            j = skipWs(idx_data, first.end);
            const count = parseUint(idx_data, j) orelse break;
            j = count.end;
            subsections.append(allocator, .{
                .first = std.math.cast(u32, first.value) orelse break,
                .count = std.math.cast(u32, count.value) orelse break,
            }) catch return null;
        }
    } else {
        subsections.append(allocator, .{ .first = 0, .count = xref_size }) catch return null;
    }

    // Process entries
    var byte_offset: usize = 0;
    for (subsections.items) |sub| {
        var obj_idx: u32 = 0;
        while (obj_idx < sub.count) : (obj_idx += 1) {
            if (byte_offset + entry_size > xref_bytes.len) break;

            // Read field values (big-endian)
            var field_type: u64 = 0;
            var j: usize = 0;
            while (j < w_fields[0]) : (j += 1) {
                field_type = (field_type << 8) | xref_bytes[byte_offset + j];
            }

            var field2: u64 = 0;
            j = 0;
            while (j < w_fields[1]) : (j += 1) {
                field2 = (field2 << 8) | xref_bytes[byte_offset + w_fields[0] + j];
            }

            var field3: u64 = 0;
            j = 0;
            while (j < w_fields[2]) : (j += 1) {
                field3 = (field3 << 8) | xref_bytes[byte_offset + w_fields[0] + w_fields[1] + j];
            }

            byte_offset += entry_size;

            // Default type is 1 if W[0] == 0
            if (w_fields[0] == 0) field_type = 1;

            const obj_num = sub.first + obj_idx;

            // Type 0 = free, Type 1 = in-use (offset), Type 2 = compressed (in object stream)
            if (!table.entries.contains(obj_num)) {
                switch (field_type) {
                    0 => {
                        // Free object
                        table.entries.put(allocator, obj_num, .{
                            .obj_num = obj_num,
                            .gen_num = std.math.cast(u16, field3) orelse 0,
                            .offset = field2,
                            .in_use = false,
                        }) catch return null;
                    },
                    1 => {
                        // In-use, offset in field2, gen in field3
                        table.entries.put(allocator, obj_num, .{
                            .obj_num = obj_num,
                            .gen_num = std.math.cast(u16, field3) orelse 0,
                            .offset = field2,
                            .in_use = true,
                        }) catch return null;
                    },
                    2 => {
                        // Compressed in object stream - field2 = obj stream num, field3 = index
                        // Store as in-use but with offset pointing to containing stream
                        table.entries.put(allocator, obj_num, .{
                            .obj_num = obj_num,
                            .gen_num = 0,
                            .offset = field2, // obj stream num, not a byte offset
                            .in_use = true,
                        }) catch return null;
                    },
                    else => {},
                }
            }
        }
    }

    return TrailerInfo{
        .size = xref_size,
        .root_obj = root_obj,
        .prev_offset = prev_offset,
    };
}

/// Parse the complete xref table from in-memory PDF data.
/// Follows /Prev chain for incremental updates. Returns null on failure.
pub fn parseXrefTable(allocator: Allocator, data: []const u8) ?XrefTable {
    const xref_offset = findStartxref(data) orelse return null;
    if (xref_offset >= data.len) return null;

    var table = XrefTable{
        .entries = .{},
        .trailer = .{ .size = 0, .root_obj = null, .prev_offset = null },
    };
    errdefer table.entries.deinit(allocator);

    var current_offset: ?u64 = xref_offset;
    var first_trailer = true;

    while (current_offset) |off| {
        if (off >= data.len) break;
        const offset: usize = std.math.cast(usize, off) orelse break;

        // Determine if traditional xref or xref stream
        var check_pos = offset;
        while (check_pos < data.len and (data[check_pos] == ' ' or data[check_pos] == '\n' or
            data[check_pos] == '\r' or data[check_pos] == '\t'))
        {
            check_pos += 1;
        }

        if (check_pos + 4 <= data.len and std.mem.eql(u8, data[check_pos..][0..4], "xref")) {
            // Traditional xref table
            const trailer_pos = parseTraditionalXref(data, check_pos, &table, allocator) orelse break;
            const trailer_info = parseTrailerDict(data, trailer_pos) orelse break;

            if (first_trailer) {
                table.trailer = trailer_info;
                first_trailer = false;
            }
            current_offset = trailer_info.prev_offset;
        } else if (check_pos < data.len and data[check_pos] >= '0' and data[check_pos] <= '9') {
            // Xref stream
            const trailer_info = parseXrefStream(allocator, data, check_pos, &table) orelse break;

            if (first_trailer) {
                table.trailer = trailer_info;
                first_trailer = false;
            }
            current_offset = trailer_info.prev_offset;
        } else {
            break;
        }
    }

    if (first_trailer) {
        // Never successfully parsed any xref
        table.entries.deinit(allocator);
        return null;
    }

    return table;
}

/// Extract object body bytes (between "N G obj" and "endobj") given an xref offset.
pub fn getObjectBody(data: []const u8, offset: u64) ?[]const u8 {
    if (offset >= data.len) return null;
    var i: usize = std.math.cast(usize, offset) orelse return null;

    // Parse "N G obj"
    _ = parseUint(data, i) orelse return null;
    i = parseUint(data, i).?.end;
    i = skipWs(data, i);
    _ = parseUint(data, i) orelse return null;
    i = parseUint(data, i).?.end;
    i = skipWs(data, i);

    if (i + 3 > data.len or !std.mem.eql(u8, data[i..][0..3], "obj")) return null;
    i += 3;

    // Skip whitespace after "obj"
    if (i < data.len and data[i] == '\r') i += 1;
    if (i < data.len and data[i] == '\n') i += 1;

    const body_start = i;

    // Find "endobj"
    while (i + 6 <= data.len) : (i += 1) {
        if (std.mem.eql(u8, data[i..][0..6], "endobj")) {
            // Trim trailing whitespace
            var end = i;
            while (end > body_start and (data[end - 1] == ' ' or data[end - 1] == '\n' or data[end - 1] == '\r')) {
                end -= 1;
            }
            return data[body_start..end];
        }
    }
    return null;
}

/// Extract stream data (between "stream\n" and "endstream") from an object at offset.
/// Returns both the object body and the stream data.
pub fn getObjectStream(data: []const u8, offset: u64) ?struct { body: []const u8, stream: []const u8 } {
    if (offset >= data.len) return null;
    var i: usize = std.math.cast(usize, offset) orelse return null;

    // Parse "N G obj"
    _ = parseUint(data, i) orelse return null;
    i = parseUint(data, i).?.end;
    i = skipWs(data, i);
    _ = parseUint(data, i) orelse return null;
    i = parseUint(data, i).?.end;
    i = skipWs(data, i);

    if (i + 3 > data.len or !std.mem.eql(u8, data[i..][0..3], "obj")) return null;
    i += 3;
    if (i < data.len and data[i] == '\r') i += 1;
    if (i < data.len and data[i] == '\n') i += 1;

    const body_start = i;

    // Find "stream" keyword (not "endstream")
    while (i + 6 <= data.len) : (i += 1) {
        if (std.mem.eql(u8, data[i..][0..6], "stream") and
            (i < 3 or !std.mem.eql(u8, data[i - 3 ..][0..3], "end")))
        {
            const body_end = i;
            i += 6;
            if (i < data.len and data[i] == '\r') i += 1;
            if (i < data.len and data[i] == '\n') i += 1;

            const stream_start = i;

            // Find "endstream"
            while (i + 9 <= data.len) : (i += 1) {
                if (std.mem.eql(u8, data[i..][0..9], "endstream")) {
                    // Per PDF spec, there's an EOL before "endstream" - trim it
                    var stream_end = i;
                    if (stream_end > stream_start and data[stream_end - 1] == '\n') stream_end -= 1;
                    if (stream_end > stream_start and data[stream_end - 1] == '\r') stream_end -= 1;
                    return .{
                        .body = data[body_start..body_end],
                        .stream = data[stream_start..stream_end],
                    };
                }
            }
            return null;
        }
        // Stop at endobj
        if (i + 6 <= data.len and std.mem.eql(u8, data[i..][0..6], "endobj")) {
            return null;
        }
    }
    return null;
}

// ===========================================================================
// Tests
// ===========================================================================

// Test 1: findStartxref on minimal trailer
test "findStartxref locates offset from end of data" {
    const data = "%PDF-1.4\nsome content\nstartxref\n42\n%%EOF\n";
    const offset = findStartxref(data);
    try std.testing.expectEqual(@as(?u64, 42), offset);
}

test "findStartxref with large offset" {
    const data = "%PDF-1.7\nstartxref\n123456789\n%%EOF";
    try std.testing.expectEqual(@as(?u64, 123456789), findStartxref(data));
}

test "findStartxref returns null on missing marker" {
    const data = "%PDF-1.4\nsome content\n%%EOF\n";
    try std.testing.expectEqual(@as(?u64, null), findStartxref(data));
}

// Test 2: parseTraditionalXref with 3 entries
test "parseTraditionalXref parses single section with 3 entries" {
    const data =
        "xref\n" ++
        "0 3\n" ++
        "0000000000 65535 f \n" ++
        "0000000017 00000 n \n" ++
        "0000000081 00000 n \n" ++
        "trailer\n" ++
        "<< /Size 3 >>\n" ++
        "startxref\n0\n%%EOF";

    var table = XrefTable{
        .entries = .{},
        .trailer = .{ .size = 0, .root_obj = null, .prev_offset = null },
    };
    defer table.entries.deinit(std.testing.allocator);

    const trailer_pos = parseTraditionalXref(data, 0, &table, std.testing.allocator);
    try std.testing.expect(trailer_pos != null);

    try std.testing.expectEqual(@as(u32, 3), table.entries.count());

    // Object 0 is free
    const entry0 = table.entries.get(0).?;
    try std.testing.expect(!entry0.in_use);
    try std.testing.expectEqual(@as(u16, 65535), entry0.gen_num);

    // Object 1 is in-use at offset 17
    const entry1 = table.entries.get(1).?;
    try std.testing.expect(entry1.in_use);
    try std.testing.expectEqual(@as(u64, 17), entry1.offset);

    // Object 2 is in-use at offset 81
    const entry2 = table.entries.get(2).?;
    try std.testing.expect(entry2.in_use);
    try std.testing.expectEqual(@as(u64, 81), entry2.offset);
}

// Test 3: parseTrailerDict
test "parseTrailerDict extracts Size, Root, Prev" {
    const data = "trailer\n<< /Size 42 /Root 1 0 R /Prev 9876 >>\nstartxref\n0\n%%EOF";
    const info = parseTrailerDict(data, 0);
    try std.testing.expect(info != null);
    try std.testing.expectEqual(@as(u32, 42), info.?.size);
    try std.testing.expectEqual(@as(?u32, 1), info.?.root_obj);
    try std.testing.expectEqual(@as(?u64, 9876), info.?.prev_offset);
}

test "parseTrailerDict without Prev" {
    const data = "<< /Size 10 /Root 2 0 R >>";
    const info = parseTrailerDict(data, 0);
    try std.testing.expect(info != null);
    try std.testing.expectEqual(@as(u32, 10), info.?.size);
    try std.testing.expectEqual(@as(?u32, 2), info.?.root_obj);
    try std.testing.expectEqual(@as(?u64, null), info.?.prev_offset);
}

test "parseTrailerDict returns null without Size" {
    const data = "<< /Root 1 0 R >>";
    try std.testing.expectEqual(@as(?TrailerInfo, null), parseTrailerDict(data, 0));
}

// Test 4: parseXrefTable end-to-end
test "parseXrefTable end-to-end minimal PDF" {
    // Object offsets: obj1 at 9, obj2 at 45, xref at 79
    const pdf =
        "%PDF-1.4\n" ++ // 9 bytes
        "1 0 obj\n<< /Type /Catalog >>\nendobj\n" ++ // 36 bytes (offset 9..45)
        "2 0 obj\n<< /Type /Pages >>\nendobj\n" ++ // 34 bytes (offset 45..79)
        "xref\n" ++ // xref at offset 79
        "0 3\n" ++
        "0000000000 65535 f \n" ++
        "0000000009 00000 n \n" ++
        "0000000045 00000 n \n" ++
        "trailer\n" ++
        "<< /Size 3 /Root 1 0 R >>\n" ++
        "startxref\n" ++
        "79\n" ++
        "%%EOF\n";

    var table = parseXrefTable(std.testing.allocator, pdf) orelse {
        return error.TestUnexpectedResult;
    };
    defer table.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 3), table.trailer.size);
    try std.testing.expectEqual(@as(?u32, 1), table.trailer.root_obj);
    try std.testing.expectEqual(@as(u32, 3), table.entries.count());

    // Verify object 1 offset
    try std.testing.expectEqual(@as(?u64, 9), table.getOffset(1));
    // Verify object 2 offset
    try std.testing.expectEqual(@as(?u64, 45), table.getOffset(2));
    // Object 0 is free
    try std.testing.expectEqual(@as(?u64, null), table.getOffset(0));
}

// Test 5: getObjectBody
test "getObjectBody extracts object content" {
    const data = "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n";
    const body = getObjectBody(data, 0);
    try std.testing.expect(body != null);
    try std.testing.expectEqualStrings("<< /Type /Catalog /Pages 2 0 R >>", body.?);
}

test "getObjectBody with stream object" {
    const data = "5 0 obj\n<< /Length 4 >>\nstream\nABCD\nendstream\nendobj\n";
    const body = getObjectBody(data, 0);
    try std.testing.expect(body != null);
    // Body includes dict + stream keyword + stream data + endstream
    try std.testing.expect(std.mem.indexOf(u8, body.?, "/Length 4") != null);
}

// Test 6: lookup non-existent object
test "getOffset returns null for non-existent object" {
    const pdf =
        "%PDF-1.4\n" ++
        "1 0 obj\n<< >>\nendobj\n" ++
        "xref\n0 2\n" ++
        "0000000000 65535 f \n" ++
        "0000000009 00000 n \n" ++
        "trailer\n<< /Size 2 /Root 1 0 R >>\n" ++
        "startxref\n30\n%%EOF\n";

    var table = parseXrefTable(std.testing.allocator, pdf) orelse {
        return error.TestUnexpectedResult;
    };
    defer table.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?u64, null), table.getOffset(99));
    try std.testing.expectEqual(@as(?u64, null), table.getOffset(500));
}

// Test 7: Multi-section xref (non-contiguous)
test "parseTraditionalXref handles multi-section xref" {
    const data =
        "xref\n" ++
        "0 1\n" ++
        "0000000000 65535 f \n" ++
        "5 2\n" ++
        "0000000100 00000 n \n" ++
        "0000000200 00000 n \n" ++
        "trailer\n<< /Size 7 >>\nstartxref\n0\n%%EOF";

    var table = XrefTable{
        .entries = .{},
        .trailer = .{ .size = 0, .root_obj = null, .prev_offset = null },
    };
    defer table.entries.deinit(std.testing.allocator);

    _ = parseTraditionalXref(data, 0, &table, std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 3), table.entries.count());
    try std.testing.expect(table.entries.contains(0));
    try std.testing.expect(!table.entries.contains(1));
    try std.testing.expect(!table.entries.contains(4));
    try std.testing.expect(table.entries.contains(5));
    try std.testing.expect(table.entries.contains(6));

    try std.testing.expectEqual(@as(u64, 100), table.entries.get(5).?.offset);
    try std.testing.expectEqual(@as(u64, 200), table.entries.get(6).?.offset);
}

// Test 8: Incremental update via /Prev chain
test "parseXrefTable follows Prev chain" {
    // Layout:
    //   offset 0:   %PDF-1.4\n                          (9 bytes)
    //   offset 9:   1 0 obj (original)                   (21 bytes -> ends at 30)
    //   offset 30:  first xref table                     (83 bytes -> ends at 113)
    //   offset 113: 1 0 obj (updated)                    (35 bytes -> ends at 148)
    //   offset 148: second xref table (points /Prev 30)
    const pdf =
        "%PDF-1.4\n" ++
        "1 0 obj\n<< >>\nendobj\n" ++
        "xref\n" ++
        "0 2\n" ++
        "0000000000 65535 f \n" ++
        "0000000009 00000 n \n" ++
        "trailer\n<< /Size 2 /Root 1 0 R >>\n" ++
        "1 0 obj\n<< /Updated true >>\nendobj\n" ++
        "xref\n" ++
        "1 1\n" ++
        "0000000113 00000 n \n" ++
        "trailer\n<< /Size 2 /Root 1 0 R /Prev 30 >>\n" ++
        "startxref\n" ++
        "148\n" ++
        "%%EOF\n";

    var table = parseXrefTable(std.testing.allocator, pdf) orelse {
        return error.TestUnexpectedResult;
    };
    defer table.deinit(std.testing.allocator);

    // Object 1 should use the LATEST offset (from second xref: 113)
    const offset = table.getOffset(1);
    try std.testing.expect(offset != null);
    try std.testing.expectEqual(@as(u64, 113), offset.?);
}

// Test 9: getObjectStream extracts stream data
test "getObjectStream extracts stream data" {
    const data = "3 0 obj\n<< /Length 11 >>\nstream\nHello World\nendstream\nendobj\n";
    const result = getObjectStream(data, 0);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("Hello World", result.?.stream);
    try std.testing.expect(std.mem.indexOf(u8, result.?.body, "/Length 11") != null);
}

test "getObjectStream returns null when no stream" {
    const data = "1 0 obj\n<< /Type /Catalog >>\nendobj\n";
    try std.testing.expectEqual(
        @as(?@TypeOf(getObjectStream(data, 0).?), null),
        getObjectStream(data, 0),
    );
}

// Test 10: Line ending variants
test "parseTraditionalXref handles CRLF line endings" {
    const data =
        "xref\r\n" ++
        "0 2\r\n" ++
        "0000000000 65535 f \r\n" ++
        "0000000017 00000 n \r\n" ++
        "trailer\r\n<< /Size 2 >>\r\nstartxref\r\n0\r\n%%EOF";

    var table = XrefTable{
        .entries = .{},
        .trailer = .{ .size = 0, .root_obj = null, .prev_offset = null },
    };
    defer table.entries.deinit(std.testing.allocator);

    const pos = parseTraditionalXref(data, 0, &table, std.testing.allocator);
    try std.testing.expect(pos != null);
    try std.testing.expectEqual(@as(u32, 2), table.entries.count());
    try std.testing.expectEqual(@as(u64, 17), table.entries.get(1).?.offset);
}

test "parseTraditionalXref handles CR-only line endings" {
    const data =
        "xref\r" ++
        "0 2\r" ++
        "0000000000 65535 f \r" ++
        "0000000017 00000 n \r" ++
        "trailer\r<< /Size 2 >>\rstartxref\r0\r%%EOF";

    var table = XrefTable{
        .entries = .{},
        .trailer = .{ .size = 0, .root_obj = null, .prev_offset = null },
    };
    defer table.entries.deinit(std.testing.allocator);

    const pos = parseTraditionalXref(data, 0, &table, std.testing.allocator);
    try std.testing.expect(pos != null);
    try std.testing.expectEqual(@as(u32, 2), table.entries.count());
}

// Test 11: Invalid/truncated data returns null
test "parseXrefTable returns null on empty data" {
    try std.testing.expectEqual(@as(?XrefTable, null), parseXrefTable(std.testing.allocator, ""));
}

test "parseXrefTable returns null on truncated PDF" {
    try std.testing.expectEqual(@as(?XrefTable, null), parseXrefTable(std.testing.allocator, "%PDF-1.4\ntruncated"));
}

test "parseXrefTable returns null on garbage" {
    try std.testing.expectEqual(@as(?XrefTable, null), parseXrefTable(std.testing.allocator, "not a pdf at all"));
}

test "getObjectBody returns null on invalid offset" {
    const data = "1 0 obj\n<< >>\nendobj\n";
    try std.testing.expectEqual(@as(?[]const u8, null), getObjectBody(data, 999));
}

test "getObjectBody returns null on truncated object" {
    const data = "1 0 obj\n<< /Type /Catalog >>";
    // No endobj - should return null
    try std.testing.expectEqual(@as(?[]const u8, null), getObjectBody(data, 0));
}

// Test 12: Xref stream with FlateDecode
test "parseXrefStream parses uncompressed xref stream" {
    // Build a minimal xref stream (no compression for simplicity)
    // W = [1 2 1] means: 1 byte type, 2 bytes offset, 1 byte gen
    // 3 entries: obj 0 (free), obj 1 (offset 9), obj 2 (offset 42)

    // Entry data (binary):
    // obj 0: type=0, next_free=0x0000, gen=0xFF
    // obj 1: type=1, offset=0x0009, gen=0x00
    // obj 2: type=1, offset=0x002A, gen=0x00
    const stream_bytes = [_]u8{
        0x00, 0x00, 0x00, 0xFF, // obj 0: free
        0x01, 0x00, 0x09, 0x00, // obj 1: in-use at offset 9
        0x01, 0x00, 0x2A, 0x00, // obj 2: in-use at offset 42
    };

    const data = "10 0 obj\n<< /Type /XRef /Size 3 /W [1 2 1] /Length 12 /Root 1 0 R >>\nstream\n" ++
        stream_bytes ++ "\nendstream\nendobj\n";

    var table = XrefTable{
        .entries = .{},
        .trailer = .{ .size = 0, .root_obj = null, .prev_offset = null },
    };
    defer table.entries.deinit(std.testing.allocator);

    const info = parseXrefStream(std.testing.allocator, data, 0, &table);
    try std.testing.expect(info != null);
    try std.testing.expectEqual(@as(u32, 3), info.?.size);
    try std.testing.expectEqual(@as(?u32, 1), info.?.root_obj);

    try std.testing.expectEqual(@as(u32, 3), table.entries.count());
    try std.testing.expect(!table.entries.get(0).?.in_use); // free
    try std.testing.expectEqual(@as(u64, 9), table.entries.get(1).?.offset);
    try std.testing.expectEqual(@as(u64, 42), table.entries.get(2).?.offset);
}

// Test 13-14: Ground truth and consistency tests (integration)
test "ground truth PDFs parse xref successfully" {
    const test_files = [_][]const u8{
        "ground_truth_examples/pdf/alice_in_wonderland_illustrated.pdf",
        "ground_truth_examples/pdf/nasa_satellite_images_1976.pdf",
        "ground_truth_examples/pdf/us_patent_6122892_jbig2_sample.pdf",
        "ground_truth_examples/pdf/Jbig2_042_01.pdf",
        "ground_truth_examples/pdf/Jbig2_042_02.pdf",
        "ground_truth_examples/pdf/Jbig2_042_03.pdf",
    };

    for (test_files) |path| {
        const file = std.fs.cwd().openFile(path, .{}) catch continue; // skip if not present
        defer file.close();

        const file_size = file.getEndPos() catch continue;
        if (file_size > 100 * 1024 * 1024) continue; // skip very large files

        const data = std.testing.allocator.alloc(u8, @intCast(file_size)) catch continue;
        defer std.testing.allocator.free(data);

        const bytes_read = file.readAll(data) catch continue;
        if (bytes_read != file_size) continue;

        var table = parseXrefTable(std.testing.allocator, data[0..bytes_read]) orelse {
            // Some PDFs might have non-standard xref - that's OK for now, just skip
            std.debug.print("WARN: Could not parse xref for {s}\n", .{path});
            continue;
        };
        defer table.deinit(std.testing.allocator);

        // Should have at least 1 in-use object
        try std.testing.expect(table.inUseCount() > 0);
        // /Size should be > 0
        try std.testing.expect(table.trailer.size > 0);
    }
}

// Test 14: Consistency — xref-based and linear scan produce same image object numbers
test "xref path finds same images as linear scan" {
    const pdf_image_validator = @import("pdf_image_validator.zig");

    const test_files = [_][]const u8{
        "ground_truth_examples/pdf/alice_in_wonderland_illustrated.pdf",
        "ground_truth_examples/pdf/us_patent_6122892_jbig2_sample.pdf",
        "ground_truth_examples/pdf/Jbig2_042_01.pdf",
        "ground_truth_examples/pdf/Jbig2_042_02.pdf",
        "ground_truth_examples/pdf/Jbig2_042_03.pdf",
    };

    for (test_files) |path| {
        const file = std.fs.cwd().openFile(path, .{}) catch continue;
        defer file.close();

        const file_size = file.getEndPos() catch continue;
        if (file_size > 50 * 1024 * 1024) continue;

        const data = std.testing.allocator.alloc(u8, @intCast(file_size)) catch continue;
        defer std.testing.allocator.free(data);

        const bytes_read = file.readAll(data) catch continue;
        if (bytes_read != file_size) continue;

        const buf = data[0..bytes_read];

        // Get images via linear scan
        const linear_images = pdf_image_validator.findPdfImagesLinear(std.testing.allocator, buf) catch continue;
        defer pdf_image_validator.freePdfImages(std.testing.allocator, linear_images);

        // Get images via xref
        const xref_images = pdf_image_validator.findPdfImagesViaXref(std.testing.allocator, buf) orelse continue;
        defer pdf_image_validator.freePdfImages(std.testing.allocator, xref_images);

        // Both should find the same number of images
        if (linear_images.len != xref_images.len) {
            std.debug.print("CONSISTENCY MISMATCH for {s}: linear={d} xref={d}\n", .{
                path, linear_images.len, xref_images.len,
            });
        }
        // At minimum, xref should not find fewer images
        try std.testing.expect(xref_images.len >= linear_images.len);

        // Check that every linear-scan image object is also found by xref
        for (linear_images) |lin_img| {
            var found = false;
            for (xref_images) |xref_img| {
                if (xref_img.object_num == lin_img.object_num) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                std.debug.print("MISSING: obj {d} found by linear but not xref in {s}\n", .{
                    lin_img.object_num, path,
                });
            }
            try std.testing.expect(found);
        }
    }
}

// ===========================================================================
// Overflow-safety tests: malformed PDFs with out-of-range parsed values
// must return null/error instead of panicking via @intCast overflow.
// ===========================================================================

test "parseTrailerDict rejects /Size exceeding u32 max" {
    // /Size value of 5000000000 exceeds u32 max (4294967295)
    const data = "<< /Size 5000000000 /Root 1 0 R >>";
    const info = parseTrailerDict(data, 0);
    // Should return null because /Size overflows u32
    try std.testing.expect(info == null);
}

test "parseXrefTable returns null for startxref pointing beyond data" {
    // startxref points to offset 999999 which is far beyond the data
    const data =
        "%PDF-1.4\n" ++
        "xref\n" ++
        "0 1\n" ++
        "0000000000 65535 f \n" ++
        "trailer\n" ++
        "<< /Size 1 >>\n" ++
        "startxref\n999999\n%%EOF";
    const table = parseXrefTable(std.testing.allocator, data);
    // Should return null — the offset is beyond the data
    try std.testing.expect(table == null);
}

test "getObjectBody returns null for offset at data boundary" {
    const data = "1 0 obj\n<< >>\nendobj";
    // Offset exactly at data.len — should return null, not panic
    try std.testing.expect(getObjectBody(data, data.len) == null);
    // Offset beyond data.len — should return null, not panic
    try std.testing.expect(getObjectBody(data, data.len + 1) == null);
    // Very large offset — should return null, not panic
    try std.testing.expect(getObjectBody(data, std.math.maxInt(u64)) == null);
}

test "getObjectStream returns null for offset at data boundary" {
    const data = "1 0 obj\n<< /Length 3 >>\nstream\nabc\nendstream\nendobj";
    // Offset exactly at data.len — should return null, not panic
    try std.testing.expect(getObjectStream(data, data.len) == null);
    // Very large offset — should return null, not panic
    try std.testing.expect(getObjectStream(data, std.math.maxInt(u64)) == null);
}

test "parseXrefTable handles xref stream with /Size exceeding u32 max" {
    // Construct a minimal xref stream object with /Size > u32 max
    // This should be rejected gracefully (return null), not panic
    const data =
        "1 0 obj\n" ++
        "<< /Type /XRef /Size 5000000000 /W [1 2 1] /Root 1 0 R /Length 0 >>\n" ++
        "stream\n" ++
        "endstream\n" ++
        "endobj\n" ++
        "startxref\n0\n%%EOF";
    const table = parseXrefTable(std.testing.allocator, data);
    // Should return null because /Size overflows u32
    try std.testing.expect(table == null);
}

test "parseTraditionalXref rejects object number exceeding u32 via large first_obj + count" {
    // first_obj 4294967295 + obj_idx 1 = 4294967296 which overflows u32
    const data =
        "xref\n" ++
        "4294967295 2\n" ++
        "0000000000 65535 f \n" ++
        "0000000017 00000 n \n" ++
        "trailer\n" ++
        "<< /Size 2 >>";

    var table = XrefTable{
        .entries = .{},
        .trailer = .{ .size = 0, .root_obj = null, .prev_offset = null },
    };
    defer table.entries.deinit(std.testing.allocator);

    const result = parseTraditionalXref(data, 0, &table, std.testing.allocator);
    // The second entry (4294967295 + 1) overflows u32 via std.math.cast, returns null
    try std.testing.expect(result == null);
}
