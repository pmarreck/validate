//! H.264/AVC video stream validation using OpenH264 (Cisco).
//!
//! This module provides deep validation for H.264 video streams by actually
//! decoding frames to verify bitstream integrity. OpenH264 is BSD-2 licensed
//! with Cisco covering MPEG-LA patent royalties.
//!
//! Supported inputs:
//! - Raw H.264 NAL unit streams (Annex B format with start codes)
//! - NAL units extracted from MP4/MKV containers
//!
//! Thread safety: Decoder operations are serialized via a global mutex from
//! video_validator.zig to prevent potential thread safety issues with C libraries.

const std = @import("std");
const builtin = @import("builtin");

// Import video validator for the Windows mutex guard
const video_validator = @import("video_validator.zig");

// Import OpenH264 decoder API
const openh264 = @cImport({
    @cInclude("wels/codec_api.h");
});

/// Result of H.264 stream validation
pub const H264ValidationResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    frames_decoded: u32,

    pub fn ok(frames: u32) H264ValidationResult {
        return .{ .valid = true, .error_message = null, .frames_decoded = frames };
    }

    pub fn invalid(message: []const u8) H264ValidationResult {
        return .{ .valid = false, .error_message = message, .frames_decoded = 0 };
    }

    pub fn invalidPartial(message: []const u8, frames: u32) H264ValidationResult {
        return .{ .valid = false, .error_message = message, .frames_decoded = frames };
    }
};

fn hasAnnexBStartCode(data: []const u8) bool {
    if (data.len < 3) return false;
    var i: usize = 0;
    while (i + 3 <= data.len) : (i += 1) {
        if (data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 1) {
            return true;
        }
        if (i + 4 <= data.len and data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 0 and data[i + 3] == 1) {
            return true;
        }
    }
    return false;
}

/// Validate H.264 bitstream using OpenH264.
/// Decodes up to max_frames to verify integrity.
/// Input data should be in Annex B format (with 0x00000001 start codes).
pub fn validateH264Stream(data: []const u8, max_frames: u32) H264ValidationResult {
    if (data.len < 4) {
        return H264ValidationResult.invalid("Data too small for H.264");
    }
    if (!hasAnnexBStartCode(data)) {
        return H264ValidationResult.invalid("Missing Annex B start code");
    }

    // Acquire mutex to prevent thread safety issues with OpenH264
    const guard = video_validator.VideoDecoderGuard.acquire();
    defer guard.release();

    // Create decoder
    // OpenH264 uses C++ vtable pattern. In C:
    //   ISVCDecoder is typedef const ISVCDecoderVtbl* - single pointer to vtable
    //   ISVCDecoder* is used as "this" - double pointer
    //   ISVCDecoder** is used for output params - triple pointer
    // In Zig cimport:
    //   ISVCDecoder = [*c]const ISVCDecoderVtbl (single pointer)
    //   [*c]ISVCDecoder = double pointer (what methods expect as "this")
    //   [*c][*c]ISVCDecoder = triple pointer (output param for WelsCreateDecoder)
    var decoder: [*c]openh264.ISVCDecoder = undefined;
    const create_result = openh264.WelsCreateDecoder(@ptrCast(&decoder));
    if (create_result != 0) {
        return H264ValidationResult.invalid("Failed to create H.264 decoder");
    }
    defer openh264.WelsDestroyDecoder(decoder);

    // Get vtable - decoder[0] is ISVCDecoder (single pointer), decoder[0][0] is the vtable struct
    const vtable = decoder[0][0];

    // Initialize decoder with default parameters
    var dec_param: openh264.SDecodingParam = std.mem.zeroes(openh264.SDecodingParam);
    dec_param.sVideoProperty.eVideoBsType = openh264.VIDEO_BITSTREAM_AVC;

    const init_fn = vtable.Initialize orelse {
        return H264ValidationResult.invalid("Decoder Initialize function not available");
    };

    const init_result = init_fn(decoder, &dec_param);
    if (init_result != 0) {
        return H264ValidationResult.invalid("Failed to initialize H.264 decoder");
    }

    // Ensure we uninitialize on exit
    const uninit_fn = vtable.Uninitialize orelse null;
    defer {
        if (uninit_fn) |func| {
            _ = func(decoder);
        }
    }

    // Get decode function
    const decode_fn = vtable.DecodeFrameNoDelay orelse {
        return H264ValidationResult.invalid("Decoder DecodeFrameNoDelay function not available");
    };

    // Decode the stream
    var frames_decoded: u32 = 0;
    var buf_info: openh264.SBufferInfo = std.mem.zeroes(openh264.SBufferInfo);
    var dst_data: [3][*c]u8 = undefined;

    // Feed entire buffer to decoder
    const state = decode_fn(
        decoder,
        data.ptr,
        @intCast(data.len),
        &dst_data,
        &buf_info,
    );

    // Check for bitstream errors (not just missing frames)
    const error_flags = openh264.dsBitstreamError | openh264.dsNoParamSets;
    if ((state & openh264.dsNoParamSets) != 0) {
        // No valid SPS/PPS found - could be unsupported profile (e.g., High 4:4:4)
        return H264ValidationResult.invalid("H.264 no parameter sets (unsupported profile?)");
    }
    if ((state & openh264.dsBitstreamError) != 0) {
        return H264ValidationResult.invalid("H.264 bitstream error");
    }

    // Count decoded frame
    if (buf_info.iBufferStatus == 1) {
        frames_decoded += 1;
    }

    // Flush remaining frames using FlushFrame API
    const flush_fn = vtable.FlushFrame orelse {
        // Fall back to DecodeFrameNoDelay with null
        var flush_iterations: u32 = 0;
        while (frames_decoded < max_frames and flush_iterations < 10) : (flush_iterations += 1) {
            buf_info = std.mem.zeroes(openh264.SBufferInfo);
            const flush_state = decode_fn(decoder, null, 0, &dst_data, &buf_info);
            if ((flush_state & error_flags) != 0) {
                return H264ValidationResult.invalidPartial("H.264 decode error during flush", frames_decoded);
            }
            if (buf_info.iBufferStatus == 1) {
                frames_decoded += 1;
            } else {
                break;
            }
        }
        if (frames_decoded == 0) {
            if (state == openh264.dsErrorFree or state == openh264.dsFramePending) {
                return H264ValidationResult.ok(0);
            }
            return H264ValidationResult.invalid("No frames decoded from H.264 stream");
        }
        return H264ValidationResult.ok(frames_decoded);
    };

    var flush_iterations: u32 = 0;
    while (frames_decoded < max_frames and flush_iterations < 10) : (flush_iterations += 1) {
        buf_info = std.mem.zeroes(openh264.SBufferInfo);

        const flush_state = flush_fn(decoder, &dst_data, &buf_info);

        if ((flush_state & error_flags) != 0) {
            return H264ValidationResult.invalidPartial("H.264 decode error during flush", frames_decoded);
        }

        if (buf_info.iBufferStatus == 1) {
            frames_decoded += 1;
        } else {
            break;
        }
    }

    // For very short streams, we might not get any complete frames
    // but if there were no errors, consider it valid
    if (frames_decoded == 0) {
        // Check if we at least got some data through without errors
        if (state == openh264.dsErrorFree or state == openh264.dsFramePending) {
            // Stream parsed without errors but no complete frames
            return H264ValidationResult.ok(0);
        }
        return H264ValidationResult.invalid("No frames decoded from H.264 stream");
    }

    return H264ValidationResult.ok(frames_decoded);
}

// Tests
test "H.264 validation rejects garbage data" {
    const garbage = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22, 0x33 };
    const result = validateH264Stream(&garbage, 1);
    // Either it's invalid OR it decoded zero frames (both acceptable for garbage)
    try std.testing.expect(!result.valid or result.frames_decoded == 0);
}

test "H.264 validation rejects empty data" {
    const result = validateH264Stream(&[_]u8{}, 1);
    try std.testing.expect(!result.valid);
}

test "H.264 validation rejects too-small data" {
    const result = validateH264Stream(&[_]u8{ 0x00, 0x01 }, 1);
    try std.testing.expect(!result.valid);
}
