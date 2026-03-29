//! Deep MIDI validation - parses and validates all track data.
//!
//! Standard MIDI File (SMF) structure:
//! - Header chunk (MThd): signature, format, track count, division
//! - Track chunks (MTrk): delta-time + event pairs
//!
//! Deep validation verifies:
//! - All track chunks have valid signatures and lengths
//! - Delta times use valid variable-length encoding
//! - MIDI events have valid status and data bytes
//! - Each track ends with End of Track meta event (0xFF 0x2F 0x00)
//! - Running status is used correctly

const std = @import("std");
const file_source = @import("file_source.zig");
const FileSource = file_source.FileSource;
const errmsg = @import("error_messages.zig");

pub const MidiValidationResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    format: u16,
    num_tracks: u16,
    tracks_validated: u16,

    pub fn ok(format: u16, num_tracks: u16) MidiValidationResult {
        return .{
            .valid = true,
            .error_message = null,
            .format = format,
            .num_tracks = num_tracks,
            .tracks_validated = num_tracks,
        };
    }

    pub fn invalid(message: []const u8) MidiValidationResult {
        return .{
            .valid = false,
            .error_message = message,
            .format = 0,
            .num_tracks = 0,
            .tracks_validated = 0,
        };
    }

    pub fn partialValid(format: u16, num_tracks: u16, validated: u16, message: []const u8) MidiValidationResult {
        return .{
            .valid = false,
            .error_message = message,
            .format = format,
            .num_tracks = num_tracks,
            .tracks_validated = validated,
        };
    }
};

/// Validate MIDI file deeply by parsing all track data.
pub fn validateMidiDeep(path: []const u8) MidiValidationResult {
    var source = FileSource.open(path) catch |err| {
        return switch (err) {
            error.FileNotFound => MidiValidationResult.invalid("File not found"),
            error.AccessDenied => MidiValidationResult.invalid("Access denied"),
            else => MidiValidationResult.invalid(errmsg.failedToOpen("file")),
        };
    };
    defer source.close();

    // Get file size
    const file_size = source.getEndPos() catch {
        return MidiValidationResult.invalid(errmsg.failedToGet("file size"));
    };

    if (file_size > 100 * 1024 * 1024) { // 100MB limit for MIDI
        return MidiValidationResult.invalid(errmsg.fileTooLargeFor("MIDI"));
    }

    // Read header chunk (14 bytes)
    var header: [14]u8 = undefined;
    const header_read = source.readAll(&header) catch {
        return MidiValidationResult.invalid(errmsg.failedToRead("header"));
    };

    if (header_read < 14) {
        return MidiValidationResult.invalid(errmsg.fileTooSmallFor("MIDI header"));
    }

    // Validate MThd signature
    if (!std.mem.eql(u8, header[0..4], "MThd")) {
        return MidiValidationResult.invalid(errmsg.invalidSignatureExpected("MIDI", "MThd"));
    }

    // Validate header length (must be 6)
    const header_length = std.mem.readInt(u32, header[4..8], .big);
    if (header_length != 6) {
        return MidiValidationResult.invalid("Invalid MIDI header length (must be 6)");
    }

    // Parse format type
    const format = std.mem.readInt(u16, header[8..10], .big);
    if (format > 2) {
        return MidiValidationResult.invalid("Invalid MIDI format type (must be 0, 1, or 2)");
    }

    // Parse track count
    const num_tracks = std.mem.readInt(u16, header[10..12], .big);
    if (num_tracks == 0) {
        return MidiValidationResult.invalid("MIDI file has no tracks");
    }

    // Format 0 must have exactly 1 track
    if (format == 0 and num_tracks != 1) {
        return MidiValidationResult.invalid("Format 0 MIDI must have exactly 1 track");
    }

    // Validate division (timing)
    const division = std.mem.readInt(u16, header[12..14], .big);
    if (division == 0) {
        return MidiValidationResult.invalid("Invalid MIDI division (cannot be 0)");
    }

    // Validate each track
    var tracks_validated: u16 = 0;
    var pos: u64 = 14; // After header

    while (tracks_validated < num_tracks) : (tracks_validated += 1) {
        // Read track header
        var track_header: [8]u8 = undefined;
        source.seekTo(pos) catch {
            return MidiValidationResult.partialValid(format, num_tracks, tracks_validated, errmsg.failedToSeek("to track"));
        };

        const track_header_read = source.readAll(&track_header) catch {
            return MidiValidationResult.partialValid(format, num_tracks, tracks_validated, errmsg.failedToRead("track header"));
        };

        if (track_header_read < 8) {
            return MidiValidationResult.partialValid(format, num_tracks, tracks_validated, errmsg.truncated("track header"));
        }

        // Validate MTrk signature
        if (!std.mem.eql(u8, track_header[0..4], "MTrk")) {
            return MidiValidationResult.partialValid(format, num_tracks, tracks_validated, errmsg.invalidSignatureExpected("track", "MTrk"));
        }

        // Get track length
        const track_length = std.mem.readInt(u32, track_header[4..8], .big);

        // Verify track fits in file
        if (pos + 8 + track_length > file_size) {
            return MidiValidationResult.partialValid(format, num_tracks, tracks_validated, "Track length exceeds file size");
        }

        // Validate track data
        const track_result = validateTrackData(&source, pos + 8, track_length);
        if (!track_result.valid) {
            return MidiValidationResult.partialValid(format, num_tracks, tracks_validated, track_result.error_message.?);
        }

        pos += 8 + track_length;
    }

    return MidiValidationResult.ok(format, num_tracks);
}

/// Validate track data by parsing all events
fn validateTrackData(file: *FileSource, start_pos: u64, length: u32) MidiValidationResult {
    if (length == 0) {
        return MidiValidationResult.invalid(errmsg.empty("track"));
    }

    // Allocate buffer for track data (limit to reasonable size)
    if (length > 10 * 1024 * 1024) { // 10MB per track limit
        return MidiValidationResult.invalid("Track too large");
    }

    // Read track data into buffer
    const data_buf = std.heap.page_allocator.alloc(u8, 65536) catch {
        return MidiValidationResult.invalid("Out of memory for track data buffer");
    };
    defer std.heap.page_allocator.free(data_buf);
    var pos: u32 = 0;
    var running_status: u8 = 0;
    var found_end_of_track = false;

    file.seekTo(start_pos) catch {
        return MidiValidationResult.invalid(errmsg.failedToSeek("to track data"));
    };

    // Process events
    while (pos < length) {
        // Read a chunk of data if needed
        const chunk_start = pos;
        const chunk_size = @min(data_buf.len, length - pos);

        file.seekTo(start_pos + pos) catch {
            return MidiValidationResult.invalid(errmsg.failedToSeek("in track"));
        };

        const bytes_read = file.readAll(data_buf[0..chunk_size]) catch {
            return MidiValidationResult.invalid(errmsg.failedToRead("track data"));
        };

        if (bytes_read == 0) {
            break;
        }

        var buf_pos: usize = 0;

        while (buf_pos < bytes_read) {
            // Parse delta time (variable-length quantity)
            const delta_result = parseVariableLengthQuantity(data_buf[buf_pos..bytes_read]);
            if (delta_result.bytes_consumed == 0) {
                return MidiValidationResult.invalid("Invalid delta time encoding");
            }
            buf_pos += delta_result.bytes_consumed;

            if (buf_pos >= bytes_read) {
                // Need more data
                pos = chunk_start + @as(u32, @intCast(buf_pos));
                break;
            }

            // Parse event
            var status = data_buf[buf_pos];

            // Handle running status
            if (status < 0x80) {
                // Running status - use previous status
                if (running_status == 0) {
                    return MidiValidationResult.invalid("Running status used without prior status");
                }
                status = running_status;
            } else {
                buf_pos += 1;
                // Update running status for channel messages
                if (status >= 0x80 and status < 0xF0) {
                    running_status = status;
                } else if (status >= 0xF0 and status < 0xF8) {
                    // System common messages clear running status
                    running_status = 0;
                }
                // System real-time messages (0xF8-0xFF) don't affect running status
            }

            // Determine event length and validate
            const event_result = validateMidiEvent(status, data_buf[buf_pos..bytes_read]);
            if (!event_result.valid) {
                return MidiValidationResult.invalid(event_result.error_message orelse "MIDI event validation failed");
            }

            buf_pos += event_result.bytes_consumed;

            // Check for End of Track
            if (status == 0xFF and event_result.is_end_of_track) {
                found_end_of_track = true;
            }

            pos = chunk_start + @as(u32, @intCast(buf_pos));

            if (pos >= length) {
                break;
            }
        }

        if (pos >= length) {
            break;
        }
    }

    if (!found_end_of_track) {
        return MidiValidationResult.invalid("Track missing End of Track event");
    }

    return MidiValidationResult.ok(0, 0);
}

const VariableLengthResult = struct {
    value: u32,
    bytes_consumed: usize,
};

/// Parse MIDI variable-length quantity
fn parseVariableLengthQuantity(data: []const u8) VariableLengthResult {
    if (data.len == 0) {
        return .{ .value = 0, .bytes_consumed = 0 };
    }

    var value: u32 = 0;
    var i: usize = 0;

    while (i < data.len and i < 4) { // VLQ is max 4 bytes
        const byte = data[i];
        value = (value << 7) | (byte & 0x7F);
        i += 1;

        if ((byte & 0x80) == 0) {
            return .{ .value = value, .bytes_consumed = i };
        }
    }

    // If we get here, VLQ wasn't terminated (all bytes had MSB set)
    return .{ .value = 0, .bytes_consumed = 0 };
}

const EventValidationResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    bytes_consumed: usize,
    is_end_of_track: bool,

    fn ok(bytes: usize) EventValidationResult {
        return .{ .valid = true, .error_message = null, .bytes_consumed = bytes, .is_end_of_track = false };
    }

    fn endOfTrack(bytes: usize) EventValidationResult {
        return .{ .valid = true, .error_message = null, .bytes_consumed = bytes, .is_end_of_track = true };
    }

    fn invalid(message: []const u8) EventValidationResult {
        return .{ .valid = false, .error_message = message, .bytes_consumed = 0, .is_end_of_track = false };
    }
};

/// Validate a MIDI event and return bytes consumed
fn validateMidiEvent(status: u8, data: []const u8) EventValidationResult {
    const message_type = status & 0xF0;

    switch (message_type) {
        // Channel messages with 2 data bytes
        0x80, 0x90, 0xA0, 0xB0, 0xE0 => {
            // Note Off, Note On, Poly Pressure, Control Change, Pitch Bend
            if (data.len < 2) {
                return EventValidationResult.invalid(errmsg.truncated("channel message"));
            }
            // Validate data bytes (must be 0x00-0x7F)
            if (data[0] > 0x7F or data[1] > 0x7F) {
                return EventValidationResult.invalid("Invalid data byte in channel message");
            }
            return EventValidationResult.ok(2);
        },
        // Channel messages with 1 data byte
        0xC0, 0xD0 => {
            // Program Change, Channel Pressure
            if (data.len < 1) {
                return EventValidationResult.invalid(errmsg.truncated("channel message"));
            }
            if (data[0] > 0x7F) {
                return EventValidationResult.invalid("Invalid data byte in channel message");
            }
            return EventValidationResult.ok(1);
        },
        0xF0 => {
            // System messages
            return validateSystemMessage(status, data);
        },
        else => {
            // Unknown status
            return EventValidationResult.invalid(errmsg.unknown("MIDI status byte"));
        },
    }
}

/// Validate system messages (0xF0-0xFF)
fn validateSystemMessage(status: u8, data: []const u8) EventValidationResult {
    switch (status) {
        0xF0 => {
            // SysEx start - find end (0xF7)
            for (data, 0..) |byte, i| {
                if (byte == 0xF7) {
                    return EventValidationResult.ok(i + 1);
                }
            }
            return EventValidationResult.invalid("Unterminated SysEx message");
        },
        0xF1 => {
            // MTC Quarter Frame
            if (data.len < 1) return EventValidationResult.invalid(errmsg.truncated("MTC message"));
            return EventValidationResult.ok(1);
        },
        0xF2 => {
            // Song Position Pointer
            if (data.len < 2) return EventValidationResult.invalid(errmsg.truncated("Song Position"));
            return EventValidationResult.ok(2);
        },
        0xF3 => {
            // Song Select
            if (data.len < 1) return EventValidationResult.invalid(errmsg.truncated("Song Select"));
            return EventValidationResult.ok(1);
        },
        0xF6 => {
            // Tune Request (no data)
            return EventValidationResult.ok(0);
        },
        0xF7 => {
            // SysEx end (escaped SysEx)
            // Find the actual end
            for (data, 0..) |byte, i| {
                if (byte == 0xF7) {
                    return EventValidationResult.ok(i + 1);
                }
            }
            return EventValidationResult.invalid("Unterminated escaped SysEx");
        },
        0xF8, 0xFA, 0xFB, 0xFC, 0xFE => {
            // Real-time messages (no data)
            return EventValidationResult.ok(0);
        },
        0xFF => {
            // Meta event
            return validateMetaEvent(data);
        },
        else => {
            // Undefined system messages
            return EventValidationResult.ok(0);
        },
    }
}

/// Validate meta events (0xFF type length data...)
fn validateMetaEvent(data: []const u8) EventValidationResult {
    if (data.len < 2) {
        return EventValidationResult.invalid(errmsg.truncated("meta event"));
    }

    const meta_type = data[0];
    const length_result = parseVariableLengthQuantity(data[1..]);

    if (length_result.bytes_consumed == 0) {
        return EventValidationResult.invalid("Invalid meta event length");
    }

    const total_bytes = 1 + length_result.bytes_consumed + length_result.value;

    if (data.len < total_bytes) {
        return EventValidationResult.invalid(errmsg.truncated("meta event data"));
    }

    // Check for End of Track (0x2F with length 0)
    if (meta_type == 0x2F and length_result.value == 0) {
        return EventValidationResult.endOfTrack(total_bytes);
    }

    return EventValidationResult.ok(total_bytes);
}

/// Validate MIDI from memory buffer
pub fn validateMidiDeepFromBuffer(data: []const u8) MidiValidationResult {
    if (data.len < 14) {
        return MidiValidationResult.invalid(errmsg.fileTooSmallFor("MIDI header"));
    }

    // Validate MThd signature
    if (!std.mem.eql(u8, data[0..4], "MThd")) {
        return MidiValidationResult.invalid(errmsg.invalidSignature("MIDI"));
    }

    // Validate header length
    const header_length = std.mem.readInt(u32, data[4..8], .big);
    if (header_length != 6) {
        return MidiValidationResult.invalid("Invalid MIDI header length");
    }

    // Parse format
    const format = std.mem.readInt(u16, data[8..10], .big);
    if (format > 2) {
        return MidiValidationResult.invalid("Invalid MIDI format type");
    }

    // Parse track count
    const num_tracks = std.mem.readInt(u16, data[10..12], .big);
    if (num_tracks == 0) {
        return MidiValidationResult.invalid("No tracks in MIDI file");
    }

    if (format == 0 and num_tracks != 1) {
        return MidiValidationResult.invalid("Format 0 must have 1 track");
    }

    // Validate each track
    var pos: usize = 14;
    var tracks_validated: u16 = 0;

    while (tracks_validated < num_tracks) : (tracks_validated += 1) {
        if (pos + 8 > data.len) {
            return MidiValidationResult.partialValid(format, num_tracks, tracks_validated, errmsg.truncated("track header"));
        }

        if (!std.mem.eql(u8, data[pos..][0..4], "MTrk")) {
            return MidiValidationResult.partialValid(format, num_tracks, tracks_validated, errmsg.invalidSignature("track"));
        }

        const track_length = std.mem.readInt(u32, data[pos + 4 ..][0..4], .big);

        if (pos + 8 + track_length > data.len) {
            return MidiValidationResult.partialValid(format, num_tracks, tracks_validated, "Track length exceeds file");
        }

        // Validate track data
        const track_result = validateTrackDataFromBuffer(data[pos + 8 ..][0..track_length]);
        if (!track_result.valid) {
            return MidiValidationResult.partialValid(format, num_tracks, tracks_validated, track_result.error_message.?);
        }

        pos += 8 + track_length;
    }

    return MidiValidationResult.ok(format, num_tracks);
}

/// Validate track data from buffer
fn validateTrackDataFromBuffer(data: []const u8) MidiValidationResult {
    if (data.len == 0) {
        return MidiValidationResult.invalid(errmsg.empty("track"));
    }

    var pos: usize = 0;
    var running_status: u8 = 0;
    var found_end_of_track = false;

    while (pos < data.len) {
        // Parse delta time
        const delta_result = parseVariableLengthQuantity(data[pos..]);
        if (delta_result.bytes_consumed == 0) {
            return MidiValidationResult.invalid("Invalid delta time");
        }
        pos += delta_result.bytes_consumed;

        if (pos >= data.len) {
            return MidiValidationResult.invalid(errmsg.truncated("after delta time"));
        }

        // Parse status byte
        var status = data[pos];

        if (status < 0x80) {
            // Running status
            if (running_status == 0) {
                return MidiValidationResult.invalid("Running status without prior status");
            }
            status = running_status;
        } else {
            pos += 1;
            if (status >= 0x80 and status < 0xF0) {
                running_status = status;
            } else if (status >= 0xF0 and status < 0xF8) {
                running_status = 0;
            }
        }

        if (pos > data.len) {
            return MidiValidationResult.invalid(errmsg.truncated("event"));
        }

        // Validate event
        const remaining = if (pos < data.len) data[pos..] else &[_]u8{};
        const event_result = validateMidiEvent(status, remaining);
        if (!event_result.valid) {
            return MidiValidationResult.invalid(event_result.error_message.?);
        }

        pos += event_result.bytes_consumed;

        if (status == 0xFF and event_result.is_end_of_track) {
            found_end_of_track = true;
        }
    }

    if (!found_end_of_track) {
        return MidiValidationResult.invalid(errmsg.missing("End of Track"));
    }

    return MidiValidationResult.ok(0, 0);
}

// ============ Tests ============

test "validate minimal valid MIDI" {
    // Format 0, 1 track, 480 ticks per quarter
    // Track: delta=0, End of Track meta event
    const midi_data = [_]u8{
        // Header chunk
        'M', 'T', 'h', 'd', // MThd
        0x00, 0x00, 0x00, 0x06, // length = 6
        0x00, 0x00, // format = 0
        0x00, 0x01, // tracks = 1
        0x01, 0xE0, // division = 480
        // Track chunk
        'M', 'T', 'r', 'k', // MTrk
        0x00, 0x00, 0x00, 0x04, // length = 4
        0x00, // delta = 0
        0xFF, 0x2F, 0x00, // End of Track
    };

    const result = validateMidiDeepFromBuffer(&midi_data);
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(u16, 0), result.format);
    try std.testing.expectEqual(@as(u16, 1), result.num_tracks);
}

test "validate MIDI with note events" {
    // Format 0, 1 track with note on/off
    const midi_data = [_]u8{
        // Header
        'M', 'T', 'h', 'd',
        0x00, 0x00, 0x00, 0x06,
        0x00, 0x00, // format 0
        0x00, 0x01, // 1 track
        0x00, 0x60, // 96 ticks
        // Track
        'M', 'T', 'r', 'k',
        0x00, 0x00, 0x00, 0x0C, // length = 12 (4+4+4 bytes)
        0x00, 0x90, 0x3C, 0x64, // delta=0, Note On C4 vel=100 (4 bytes)
        0x60, 0x80, 0x3C, 0x00, // delta=96, Note Off C4 (4 bytes)
        0x00, 0xFF, 0x2F, 0x00, // delta=0, End of Track (4 bytes)
    };

    const result = validateMidiDeepFromBuffer(&midi_data);
    try std.testing.expect(result.valid);
}

test "validate MIDI with running status" {
    // Using running status for consecutive Note Ons
    const midi_data = [_]u8{
        'M', 'T', 'h', 'd',
        0x00, 0x00, 0x00, 0x06,
        0x00, 0x00,
        0x00, 0x01,
        0x00, 0x60,
        'M', 'T', 'r', 'k',
        0x00, 0x00, 0x00, 0x0E, // length = 14 (4+3+3+4 bytes)
        0x00, 0x90, 0x3C, 0x64, // delta=0, Note On C4 (4 bytes)
        0x00, 0x3E, 0x64, // delta=0, Running status: Note On D4 (3 bytes)
        0x00, 0x40, 0x64, // delta=0, Running status: Note On E4 (3 bytes)
        0x00, 0xFF, 0x2F, 0x00, // delta=0, End of Track (4 bytes)
    };

    const result = validateMidiDeepFromBuffer(&midi_data);
    try std.testing.expect(result.valid);
}

test "reject MIDI missing end of track" {
    const midi_data = [_]u8{
        'M', 'T', 'h', 'd',
        0x00, 0x00, 0x00, 0x06,
        0x00, 0x00,
        0x00, 0x01,
        0x00, 0x60,
        'M', 'T', 'r', 'k',
        0x00, 0x00, 0x00, 0x04, // length = 4
        0x00, 0x90, 0x3C, 0x64, // Note On, no End of Track
    };

    const result = validateMidiDeepFromBuffer(&midi_data);
    try std.testing.expect(!result.valid);
    try std.testing.expect(std.mem.indexOf(u8, result.error_message.?, "End of Track") != null);
}

test "reject invalid data byte" {
    const midi_data = [_]u8{
        'M', 'T', 'h', 'd',
        0x00, 0x00, 0x00, 0x06,
        0x00, 0x00,
        0x00, 0x01,
        0x00, 0x60,
        'M', 'T', 'r', 'k',
        0x00, 0x00, 0x00, 0x07,
        0x00, 0x90, 0x3C, 0x80, // Invalid: velocity > 0x7F
        0x00, 0xFF, 0x2F, 0x00,
    };

    const result = validateMidiDeepFromBuffer(&midi_data);
    try std.testing.expect(!result.valid);
    try std.testing.expect(std.mem.indexOf(u8, result.error_message.?, "Invalid data byte") != null);
}

test "reject running status without prior status" {
    const midi_data = [_]u8{
        'M', 'T', 'h', 'd',
        0x00, 0x00, 0x00, 0x06,
        0x00, 0x00,
        0x00, 0x01,
        0x00, 0x60,
        'M', 'T', 'r', 'k',
        0x00, 0x00, 0x00, 0x06,
        0x00, 0x3C, 0x64, // Starts with data byte (no prior status)
        0x00, 0xFF, 0x2F, 0x00,
    };

    const result = validateMidiDeepFromBuffer(&midi_data);
    try std.testing.expect(!result.valid);
    try std.testing.expect(std.mem.indexOf(u8, result.error_message.?, "Running status") != null);
}

test "validate format 1 multi-track" {
    const midi_data = [_]u8{
        'M', 'T', 'h', 'd',
        0x00, 0x00, 0x00, 0x06,
        0x00, 0x01, // format 1
        0x00, 0x02, // 2 tracks
        0x00, 0x60,
        // Track 1
        'M', 'T', 'r', 'k',
        0x00, 0x00, 0x00, 0x04,
        0x00, 0xFF, 0x2F, 0x00,
        // Track 2
        'M', 'T', 'r', 'k',
        0x00, 0x00, 0x00, 0x04,
        0x00, 0xFF, 0x2F, 0x00,
    };

    const result = validateMidiDeepFromBuffer(&midi_data);
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(u16, 1), result.format);
    try std.testing.expectEqual(@as(u16, 2), result.num_tracks);
}
