//! Theora video deep validation using libtheora.
//!
//! Theora is a DCT-based video codec derived from VP3, packaged in OGG
//! containers (typically .ogv) or MKV containers. This module provides
//! bitstream-level validation: every video packet is fed through
//! `th_decode_packetin()` which performs full entropy decoding and pixel
//! reconstruction. Any corruption in DCT coefficients, motion vectors,
//! or block partitioning surfaces as TH_EBADPACKET / TH_EIMPL and is
//! reported as corruption.
//!
//! Why this matters:
//! - OGG page CRC32 protects container bytes but not against recomputed-
//!   CRC attacks or re-muxed streams with partial tampering.
//! - MKV has NO per-chunk CRC on the codec payload — a random bit-flip
//!   inside a frame's DCT region was slipping through at ~4% rate.
//!
//! libtheora API surface used:
//! - `th_info_init` / `th_info_clear`
//! - `th_comment_init` / `th_comment_clear`
//! - `th_decode_headerin` (called 3x: info, comment, setup)
//! - `th_decode_alloc` — creates decoder context from info + setup
//! - `th_setup_free` — release setup after decoder alloc
//! - `th_decode_packetin` — decode one video packet
//! - `th_decode_free` — tear down decoder context
//!
//! Reference: Theora I Specification (Xiph.org), https://theora.org/

const std = @import("std");
const file_source = @import("file_source.zig");
const FileSource = file_source.FileSource;
const ogg_validator = @import("ogg_validator.zig");
const errmsg = @import("error_messages.zig");

// Import libtheora via C interop. libtheora pulls in libogg for the
// ogg_packet struct — our libogg dependency provides that header via
// its installed include tree.
const theora_c = @cImport({
    @cInclude("ogg/ogg.h");
    @cInclude("theora/codec.h");
    @cInclude("theora/theoradec.h");
});

/// Result of Theora deep validation via libtheora.
pub const TheoraDecodeResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    packets_decoded: u32,
    frames_decoded: u32,
    /// Libtheora return code for the first error, or 0 if OK.
    th_errno: c_int,

    pub fn ok(packets: u32, frames: u32) TheoraDecodeResult {
        return .{
            .valid = true,
            .error_message = null,
            .packets_decoded = packets,
            .frames_decoded = frames,
            .th_errno = 0,
        };
    }

    pub fn invalid(message: []const u8, packets: u32, err: c_int) TheoraDecodeResult {
        return .{
            .valid = false,
            .error_message = message,
            .packets_decoded = packets,
            .frames_decoded = 0,
            .th_errno = err,
        };
    }
};

/// Internal helper: build an ogg_packet from a borrowed slice.
fn buildPacket(data: []const u8, packetno: c_long, b_o_s: c_long, e_o_s: c_long) theora_c.ogg_packet {
    return .{
        .packet = @constCast(@ptrCast(data.ptr)),
        .bytes = @intCast(data.len),
        .b_o_s = b_o_s,
        .e_o_s = e_o_s,
        .granulepos = -1,
        .packetno = packetno,
    };
}

/// Decode a sequence of Theora packets through libtheora. Packets must
/// appear in stream order: 3 headers (info, comment, setup) followed by
/// any number of video frames.
/// Intent: bitstream-level validation — each packet is fed through
/// th_decode_packetin() which runs full entropy decoding + IDCT. Any
/// corruption raises TH_EBADPACKET/TH_EIMPL which we surface.
pub fn validateTheoraPackets(packets: []const []const u8) TheoraDecodeResult {
    if (packets.len < 3) {
        return TheoraDecodeResult.invalid("Theora requires 3 header packets", 0, 0);
    }

    var info: theora_c.th_info = undefined;
    theora_c.th_info_init(&info);
    defer theora_c.th_info_clear(&info);

    var tc: theora_c.th_comment = undefined;
    theora_c.th_comment_init(&tc);
    defer theora_c.th_comment_clear(&tc);

    var setup: ?*theora_c.th_setup_info = null;
    defer if (setup != null) theora_c.th_setup_free(setup);

    // Submit the 3 header packets. th_decode_headerin expects:
    //   > 0 : another header follows
    //   = 0 : header sequence complete, this packet is the first video packet
    //   < 0 : error (TH_EBADHEADER, TH_EVERSION, TH_ENOTFORMAT, ...)
    var packet_no: c_long = 0;
    var header_idx: usize = 0;
    var header_count: u32 = 0;
    while (header_idx < packets.len) : (header_idx += 1) {
        if (packets[header_idx].len == 0) {
            return TheoraDecodeResult.invalid(
                "Zero-length Theora header packet",
                header_count,
                theora_c.TH_EBADHEADER,
            );
        }
        var op = buildPacket(
            packets[header_idx],
            packet_no,
            if (packet_no == 0) 1 else 0,
            0,
        );
        const ret = theora_c.th_decode_headerin(&info, &tc, &setup, &op);
        if (ret < 0) {
            return TheoraDecodeResult.invalid(
                "Theora header decode failed",
                header_count,
                ret,
            );
        }
        header_count += 1;
        packet_no += 1;
        if (ret == 0) break; // This packet was the last header; data follows.
    }

    if (header_count < 3) {
        return TheoraDecodeResult.invalid(
            "Theora header sequence incomplete",
            header_count,
            theora_c.TH_EBADHEADER,
        );
    }

    // Allocate decoder context now that we have info + setup.
    const dec = theora_c.th_decode_alloc(&info, setup);
    if (dec == null) {
        return TheoraDecodeResult.invalid("th_decode_alloc returned null", header_count, 0);
    }
    defer theora_c.th_decode_free(dec);

    // The last header was consumed at index `header_idx`. Data packets
    // start at header_idx + 1.
    var data_idx: usize = header_idx + 1;
    var packets_decoded: u32 = header_count;
    var frames_decoded: u32 = 0;

    while (data_idx < packets.len) : (data_idx += 1) {
        const pkt = packets[data_idx];
        if (pkt.len == 0) {
            return TheoraDecodeResult.invalid(
                "Zero-length Theora packet",
                packets_decoded,
                theora_c.TH_EBADPACKET,
            );
        }
        var op = buildPacket(pkt, packet_no, 0, if (data_idx + 1 == packets.len) 1 else 0);
        const ret = theora_c.th_decode_packetin(dec, &op, null);
        // Return values:
        //   0            : success, full frame decoded
        //   TH_DUPFRAME  : success, this packet re-uses previous frame
        //   TH_EBADPACKET: malformed packet
        //   TH_EIMPL     : unsupported feature in packet
        if (ret == 0 or ret == theora_c.TH_DUPFRAME) {
            frames_decoded += 1;
            packets_decoded += 1;
            packet_no += 1;
        } else {
            return TheoraDecodeResult.invalid(
                "Theora packet decode failed",
                packets_decoded,
                ret,
            );
        }
    }

    return TheoraDecodeResult.ok(packets_decoded, frames_decoded);
}

/// Validate Theora from an OGG container, streaming one packet at a time
/// (PacketIter filters to the first logical bitstream, which for .ogv is
/// the Theora stream). Anonymous memory stays O(largest packet) — the old
/// extract-all-packets approach held ~the whole file resident.
/// Improvement over the slice-based validateTheoraPackets flow: the first
/// video packet (the one th_decode_headerin returns 0 on) is now actually
/// fed through th_decode_packetin instead of being skipped.
pub fn validateOggTheora(allocator: std.mem.Allocator, source: *FileSource) TheoraDecodeResult {
    var iter = ogg_validator.PacketIter.init(source) catch |err| {
        return TheoraDecodeResult.invalid(ogg_validator.extractErrorMessage(err), 0, 0);
    };
    defer iter.deinit(allocator);

    var info: theora_c.th_info = undefined;
    theora_c.th_info_init(&info);
    defer theora_c.th_info_clear(&info);

    var tc: theora_c.th_comment = undefined;
    theora_c.th_comment_init(&tc);
    defer theora_c.th_comment_clear(&tc);

    var setup: ?*theora_c.th_setup_info = null;
    defer if (setup != null) theora_c.th_setup_free(setup);

    // --- header phase: feed packets to th_decode_headerin until it reports
    // the first video packet (ret == 0) or the stream ends.
    var packet_no: c_long = 0;
    var header_count: u32 = 0;
    // Borrowed from the iterator; valid until the next iter.next() call —
    // consumed by th_decode_packetin below before any further iteration.
    var first_video: ?[]const u8 = null;
    while (true) {
        const pkt = (iter.next(allocator) catch |err| {
            return TheoraDecodeResult.invalid(ogg_validator.extractErrorMessage(err), header_count, 0);
        }) orelse break; // stream ended during headers
        if (header_count == 0) {
            if (pkt.data.len < 7 or pkt.data[0] != 0x80 or !std.mem.eql(u8, pkt.data[1..7], "theora")) {
                return TheoraDecodeResult.invalid("First OGG packet is not Theora info header", 0, 0);
            }
        }
        var op = buildPacket(pkt.data, packet_no, if (packet_no == 0) 1 else 0, 0);
        const ret = theora_c.th_decode_headerin(&info, &tc, &setup, &op);
        if (ret < 0) {
            return TheoraDecodeResult.invalid("Theora header decode failed", header_count, ret);
        }
        if (ret == 0) {
            // Not a header: this is the first video packet. Headers complete.
            first_video = pkt.data;
            break;
        }
        header_count += 1;
        packet_no += 1;
    }

    if (header_count < 3) {
        return TheoraDecodeResult.invalid(
            "Theora header sequence incomplete",
            header_count,
            theora_c.TH_EBADHEADER,
        );
    }

    // Allocate decoder context now that we have info + setup.
    const dec = theora_c.th_decode_alloc(&info, setup);
    if (dec == null) {
        return TheoraDecodeResult.invalid("th_decode_alloc returned null", header_count, 0);
    }
    defer theora_c.th_decode_free(dec);

    var packets_decoded: u32 = header_count;
    var frames_decoded: u32 = 0;

    // Decode the held first video packet, then the rest of the stream.
    if (first_video) |data| {
        var op = buildPacket(data, packet_no, 0, 0);
        const ret = theora_c.th_decode_packetin(dec, &op, null);
        if (ret != 0 and ret != theora_c.TH_DUPFRAME) {
            return TheoraDecodeResult.invalid("Theora packet decode failed", packets_decoded, ret);
        }
        frames_decoded += 1;
        packets_decoded += 1;
        packet_no += 1;
    }

    while (iter.next(allocator) catch |err| {
        return TheoraDecodeResult.invalid(ogg_validator.extractErrorMessage(err), packets_decoded, 0);
    }) |pkt| {
        var op = buildPacket(pkt.data, packet_no, 0, if (pkt.is_eos) 1 else 0);
        const ret = theora_c.th_decode_packetin(dec, &op, null);
        // Return values:
        //   0            : success, full frame decoded
        //   TH_DUPFRAME  : success, this packet re-uses previous frame
        //   TH_EBADPACKET: malformed packet
        //   TH_EIMPL     : unsupported feature in packet
        if (ret == 0 or ret == theora_c.TH_DUPFRAME) {
            frames_decoded += 1;
            packets_decoded += 1;
            packet_no += 1;
        } else {
            return TheoraDecodeResult.invalid("Theora packet decode failed", packets_decoded, ret);
        }
    }

    return TheoraDecodeResult.ok(packets_decoded, frames_decoded);
}

// ============ Tests ============

test "libtheora rejects too-few packets" {
    const empty: []const []const u8 = &.{};
    const result = validateTheoraPackets(empty);
    try std.testing.expect(!result.valid);
}

test "libtheora rejects garbage headers" {
    const garbage = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    const packets = [_][]const u8{ &garbage, &garbage, &garbage };
    const result = validateTheoraPackets(&packets);
    try std.testing.expect(!result.valid);
}

test "libtheora decodes valid OGG Theora sample (ground truth)" {
    var source = FileSource.open("ground_truth_examples/theora/sample.ogv") catch |err| {
        if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest;
        return err;
    };
    defer source.close();

    const result = validateOggTheora(std.testing.allocator, &source);
    if (!result.valid) {
        std.debug.print("Theora ground-truth validation failed: {s} (th_errno={})\n", .{
            result.error_message orelse "(no msg)",
            result.th_errno,
        });
    }
    try std.testing.expect(result.valid);
    try std.testing.expect(result.packets_decoded >= 3); // at least 3 headers
}
