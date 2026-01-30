//! Video stream validation using libde265 (HEVC), dav1d (AV1), OpenH264 (H.264), libjpeg-turbo (MJPEG), and pure Zig (ProRes).
//!
//! This module provides deep validation for video files by actually decoding
//! video frames to verify bitstream integrity. Only keyframes (I-frames) are
//! decoded for efficiency.
//!
//! Supported container formats:
//! - MP4/MOV (ISO Base Media File Format)
//! - MKV/WebM (Matroska/EBML)
//! - AVI (RIFF container)
//!
//! Supported video codecs:
//! - HEVC/H.265 (via libde265)
//! - AV1 (via dav1d)
//! - H.264/AVC (via OpenH264)
//! - Motion JPEG (via libjpeg-turbo)
//! - ProRes (pure Zig structural validation)
//!
//! Thread safety: Video codec operations are serialized via a global mutex to
//! prevent potential thread safety issues with C library global state initialization.
//! C libraries like libde265, dav1d, OpenH264 may not be fully thread-safe for
//! concurrent decoder creation/destruction. This may reduce parallelism but ensures
//! stability across all platforms.

const std = @import("std");
const builtin = @import("builtin");

/// Global mutex for serializing video decoder operations.
/// C libraries like libde265, dav1d, OpenH264 may have thread safety issues
/// with global state initialization that can affect any platform.
var video_decoder_mutex: std.Thread.Mutex = .{};

/// RAII guard for holding the video decoder mutex.
/// Ensures only one thread at a time can use video decoders.
pub const VideoDecoderGuard = struct {
    pub fn acquire() VideoDecoderGuard {
        video_decoder_mutex.lock();
        return .{};
    }

    pub fn release(self: VideoDecoderGuard) void {
        _ = self;
        video_decoder_mutex.unlock();
    }
};
const Allocator = std.mem.Allocator;

/// Minimum required ffmpeg major version
const MIN_FFMPEG_VERSION: u32 = 4;

/// Cached result of ffprobe availability check
var ffprobe_available: ?bool = null;
var ffprobe_check_mutex: std.Thread.Mutex = .{};

/// Parse ffmpeg/ffprobe version from output string
/// Expected format: "ffprobe version N.M ..." or "ffprobe version nN.M ..."
fn parseFfmpegVersion(output: []const u8) ?u32 {
    // Find "version " in output
    const version_prefix = "version ";
    const version_start = std.mem.indexOf(u8, output, version_prefix) orelse return null;
    var pos = version_start + version_prefix.len;

    // Skip optional 'n' prefix (e.g., "n6.1")
    if (pos < output.len and output[pos] == 'n') {
        pos += 1;
    }

    // Parse major version number
    var major: u32 = 0;
    while (pos < output.len and output[pos] >= '0' and output[pos] <= '9') {
        major = major * 10 + (output[pos] - '0');
        pos += 1;
    }

    if (major == 0) return null;
    return major;
}

/// Check if ffprobe/ffmpeg is available on the system PATH with minimum version
fn isFfprobeAvailable() bool {
    ffprobe_check_mutex.lock();
    defer ffprobe_check_mutex.unlock();

    if (ffprobe_available) |available| {
        return available;
    }

    // On Windows, explicitly use .exe extension for reliability
    const ffprobe_cmd = if (comptime builtin.os.tag == .windows) "ffprobe.exe" else "ffprobe";

    // Try to run ffprobe -version
    // Note: ffprobe -version output can be very long due to configuration details
    const result = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &[_][]const u8{ ffprobe_cmd, "-version" },
        .max_output_bytes = 16 * 1024, // 16KB to handle verbose config output
    }) catch {
        ffprobe_available = false;
        return false;
    };
    defer std.heap.page_allocator.free(result.stdout);
    defer std.heap.page_allocator.free(result.stderr);

    // Check exit code
    const exit_ok = switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
    if (!exit_ok) {
        ffprobe_available = false;
        return false;
    }

    // Check version is at least MIN_FFMPEG_VERSION
    const version = parseFfmpegVersion(result.stdout) orelse {
        ffprobe_available = false;
        return false;
    };

    ffprobe_available = (version >= MIN_FFMPEG_VERSION);
    return ffprobe_available.?;
}

/// Result of ffprobe validation
const FfprobeValidationResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    frames_decoded: u32,
};

/// Validate video file using ffprobe/ffmpeg (for unsupported H.264 profiles)
/// This does a full decode check by having ffmpeg decode the video to null output
fn validateWithFfprobe(allocator: Allocator, file_path: []const u8) FfprobeValidationResult {
    // Use ffmpeg to decode video to null - this validates the entire stream
    // ffmpeg -v error -i input.mp4 -f null -
    // If there are decode errors, they'll be in stderr

    const path_z = allocator.dupeZ(u8, file_path) catch {
        return .{ .valid = false, .error_message = "Memory allocation failed", .frames_decoded = 0 };
    };
    defer allocator.free(path_z);

    // On Windows, explicitly use .exe extension for reliability
    const ffmpeg_cmd = if (comptime builtin.os.tag == .windows) "ffmpeg.exe" else "ffmpeg";
    // On Windows, null device is NUL, on Unix it's /dev/null, but -f null - works cross-platform
    const null_output = if (comptime builtin.os.tag == .windows) "NUL" else "-";

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            ffmpeg_cmd,
            "-v", "error",           // Only show errors
            "-i", path_z,            // Input file
            "-f", "null",            // Output format null (discard)
            null_output,             // Output destination
        },
        .max_output_bytes = 64 * 1024, // 64KB for error messages
    }) catch |err| {
        const msg = switch (err) {
            error.FileNotFound => "ffmpeg not found on PATH",
            else => "Failed to run ffmpeg",
        };
        return .{ .valid = false, .error_message = msg, .frames_decoded = 0 };
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Check exit status
    const exit_code = switch (result.term) {
        .Exited => |code| code,
        else => 1,
    };

    if (exit_code == 0 and result.stderr.len == 0) {
        // Success - ffmpeg decoded without errors
        return .{ .valid = true, .error_message = null, .frames_decoded = 1 };
    }

    // There were errors - file is likely corrupt
    return .{ .valid = false, .error_message = "ffmpeg decode failed (video may be corrupt)", .frames_decoded = 0 };
}

/// Cross-platform getenv that returns null on Windows (where std.posix.getenv is unavailable).
fn getenvCrossPlatform(comptime name: []const u8) ?[:0]const u8 {
    if (comptime builtin.os.tag == .windows) {
        return null;
    }
    return std.posix.getenv(name);
}

// Import EBML/Matroska parser
const ebml = @import("ebml_parser.zig");

// Import H.264 validator (uses OpenH264)
const h264 = @import("h264_validator.zig");

// Import JPEG validator (uses libjpeg-turbo)
const jpeg = @import("jpeg_validator.zig");

// Import ProRes validator (pure Zig)
const prores = @import("prores_validator.zig");

// Import MPEG-1/2 validator (pure Zig)
const mpeg12 = @import("mpeg12_validator.zig");

// Import MPEG-4 Part 2 validator (pure Zig)
const mpeg4p2 = @import("mpeg4p2_validator.zig");

// Import Theora validator (pure Zig)
const theora = @import("theora_validator.zig");

// Import VP8 validator (via libvpx)
const vp8 = @import("vp8_validator.zig");

// Import libde265 for HEVC decoding
const de265 = @cImport({
    @cInclude("libde265/de265.h");
});

// Import dav1d for AV1 decoding
const dav1d = @cImport({
    @cInclude("dav1d/dav1d.h");
});

/// Video codec type
pub const VideoCodec = enum {
    hevc, // H.265 (via libde265)
    av1, // AV1 (via dav1d)
    h264, // H.264/AVC (via OpenH264)
    vp9, // VP9 (via libvpx)
    vp8, // VP8 (via libvpx)
    mjpeg, // Motion JPEG (via libjpeg-turbo)
    prores, // ProRes (pure Zig structural validation)
    mpeg1, // MPEG-1 Video (pure Zig)
    mpeg2, // MPEG-2 Video (pure Zig)
    mpeg4p2, // MPEG-4 Part 2 / ASP (pure Zig structural validation)
    theora, // Theora (pure Zig structural validation)
    unknown,
};

/// Result of video stream validation
pub const VideoValidationResult = struct {
	valid: bool,
	error_message: ?[]const u8,
	codec: VideoCodec,
	frames_decoded: u32,
	byte_validated: bool,
	mixed_nal_prefix: bool = false,
	/// Set when H.264 profile is unsupported and ffmpeg is not available
	/// This means only structural validation was performed
	unsupported_profile_no_ffmpeg: bool = false,

	pub fn okDecoded(codec: VideoCodec, frames: u32) VideoValidationResult {
		return .{ .valid = true, .error_message = null, .codec = codec, .frames_decoded = frames, .byte_validated = false, .mixed_nal_prefix = false };
	}

	pub fn okByteValidated(codec: VideoCodec, frames: u32) VideoValidationResult {
		return .{ .valid = true, .error_message = null, .codec = codec, .frames_decoded = frames, .byte_validated = true, .mixed_nal_prefix = false };
	}

	pub fn invalid(message: []const u8, codec: VideoCodec) VideoValidationResult {
		return .{ .valid = false, .error_message = message, .codec = codec, .frames_decoded = 0, .byte_validated = false, .mixed_nal_prefix = false };
	}

	pub fn skipped(message: []const u8) VideoValidationResult {
		return .{ .valid = true, .error_message = message, .codec = .unknown, .frames_decoded = 0, .byte_validated = false, .mixed_nal_prefix = false };
	}

	pub fn structuralOnlyUnsupportedProfile(codec: VideoCodec) VideoValidationResult {
		return .{
			.valid = true,
			.error_message = null,
			.codec = codec,
			.frames_decoded = 0,
			.byte_validated = false,
			.mixed_nal_prefix = false,
			.unsupported_profile_no_ffmpeg = true,
		};
	}
};

/// Validate HEVC bitstream using libde265.
/// Decodes up to max_frames keyframes to verify integrity.
pub fn validateHevcStream(data: []const u8, max_frames: u32) VideoValidationResult {
    if (data.len < 4) {
        return VideoValidationResult.invalid("Data too small for HEVC", .hevc);
    }

    // Acquire mutex to prevent thread safety issues with libde265
    const guard = VideoDecoderGuard.acquire();
    defer guard.release();

    // Create decoder context
    const ctx = de265.de265_new_decoder();
    if (ctx == null) {
        return VideoValidationResult.invalid("Failed to create HEVC decoder", .hevc);
    }
    defer _ = de265.de265_free_decoder(ctx);

    // Start decoder
    _ = de265.de265_start_worker_threads(ctx, 1);

    // Push Annex B data to decoder (data contains start codes 0x00000001)
    const push_err = de265.de265_push_data(ctx, data.ptr, @intCast(data.len), 0, null);
    if (push_err != de265.DE265_OK) {
        return VideoValidationResult.invalid("Failed to push HEVC data", .hevc);
    }

    // Signal end of stream
    _ = de265.de265_flush_data(ctx);

    // Try to decode frames
    var frames_decoded: u32 = 0;
    var more: c_int = 1;

    while (more != 0 and frames_decoded < max_frames) {
        const decode_err = de265.de265_decode(ctx, &more);
        if (decode_err == de265.DE265_ERROR_WAITING_FOR_INPUT_DATA) {
            break; // Normal end of stream
        }
        if (decode_err != de265.DE265_OK) {
            return VideoValidationResult.invalid("HEVC decode error", .hevc);
        }

        // Check for decoded frames
        const img = de265.de265_get_next_picture(ctx);
        if (img != null) {
            frames_decoded += 1;
        }
    }

    if (frames_decoded == 0) {
        return VideoValidationResult.invalid("No frames decoded from HEVC", .hevc);
    }

    return VideoValidationResult.okDecoded(.hevc, frames_decoded);
}

/// Validate AV1 bitstream using dav1d.
/// Decodes up to max_frames to verify integrity.
pub fn validateAv1Stream(allocator: Allocator, data: []const u8, max_frames: u32) VideoValidationResult {
    _ = allocator;
    if (data.len < 4) {
        return VideoValidationResult.invalid("Data too small for AV1", .av1);
    }

    // Acquire mutex to prevent thread safety issues with dav1d
    const guard = VideoDecoderGuard.acquire();
    defer guard.release();

    // Initialize dav1d settings
    var settings: dav1d.Dav1dSettings = undefined;
    dav1d.dav1d_default_settings(&settings);
    settings.n_threads = 1;
    settings.max_frame_delay = 1;

    // Open decoder
    var ctx: ?*dav1d.Dav1dContext = null;
    const open_err = dav1d.dav1d_open(&ctx, &settings);
    if (open_err != 0 or ctx == null) {
        return VideoValidationResult.invalid("Failed to open AV1 decoder", .av1);
    }
    defer dav1d.dav1d_close(&ctx);

    // Create input data packet
    var dav1d_data: dav1d.Dav1dData = undefined;
    const alloc_err = dav1d.dav1d_data_create(&dav1d_data, data.len);
    if (alloc_err != 0) {
        return VideoValidationResult.invalid("Failed to allocate AV1 data", .av1);
    }

    // Copy input data - cast to mutable pointer since dav1d_data_create allocates writable memory
    const mutable_data: [*]u8 = @constCast(dav1d_data.data);
    @memcpy(mutable_data[0..data.len], data);

    // Send data to decoder
    const send_err = dav1d.dav1d_send_data(ctx, &dav1d_data);
    if (send_err != 0 and send_err != -@as(c_int, @intCast(@intFromEnum(std.posix.E.AGAIN)))) {
        dav1d.dav1d_data_unref(&dav1d_data);
        return VideoValidationResult.invalid("Failed to send AV1 data", .av1);
    }

    // Try to get decoded pictures
    var frames_decoded: u32 = 0;
    var pic: dav1d.Dav1dPicture = undefined;

    while (frames_decoded < max_frames) {
        const get_err = dav1d.dav1d_get_picture(ctx, &pic);
        if (get_err == -@as(c_int, @intCast(@intFromEnum(std.posix.E.AGAIN)))) {
            // Need more data - try draining
            _ = dav1d.dav1d_send_data(ctx, null);
            continue;
        }
        if (get_err != 0) {
            break; // No more frames or error
        }

        frames_decoded += 1;
        dav1d.dav1d_picture_unref(&pic);
    }

    _ = allocator;

    if (frames_decoded == 0) {
        return VideoValidationResult.invalid("No frames decoded from AV1", .av1);
    }

    return VideoValidationResult.okDecoded(.av1, frames_decoded);
}

/// MP4 box parsing helpers
const Mp4Box = struct {
    box_type: [4]u8,
    offset: u64,
    size: u64,
    header_size: u8, // 8 for normal, 16 for extended size
};

/// Read MP4 box header at current position
fn readMp4BoxHeader(file: std.fs.File) ?Mp4Box {
    var header: [16]u8 = undefined;
    const bytes_read = file.read(header[0..8]) catch return null;
    if (bytes_read < 8) return null;

    const position = (file.getPos() catch return null) - 8;
    const size = std.mem.readInt(u32, header[0..4], .big);
    const box_type = header[4..8];

    var header_size: u8 = 8;
    var actual_size: u64 = size;

    if (size == 1) {
        // Extended size
        const ext_read = file.read(header[8..16]) catch return null;
        if (ext_read < 8) return null;
        actual_size = std.mem.readInt(u64, header[8..16], .big);
        header_size = 16;
    } else if (size == 0) {
        // Box extends to end of file
        const file_size = file.getEndPos() catch return null;
        actual_size = file_size - position;
    }

    return Mp4Box{
        .box_type = box_type.*,
        .offset = position,
        .size = actual_size,
        .header_size = header_size,
    };
}

/// Find a child box within a container box
fn findChildBox(file: std.fs.File, parent_offset: u64, parent_size: u64, target_type: []const u8) ?Mp4Box {
    const end_offset = parent_offset + parent_size;
    file.seekTo(parent_offset) catch return null;

    while ((file.getPos() catch return null) < end_offset) {
        const box = readMp4BoxHeader(file) orelse return null;
        if (std.mem.eql(u8, &box.box_type, target_type)) {
            return box;
        }
        // Skip to next box
        file.seekTo(box.offset + box.size) catch return null;
    }
    return null;
}

/// Detect video codec from MP4 sample description
fn detectMp4VideoCodec(file: std.fs.File, stsd_offset: u64, stsd_size: u64) VideoCodec {
    _ = stsd_size; // Size not needed for basic codec detection
    // Skip stsd header (8 bytes) + version/flags (4 bytes) + entry count (4 bytes)
    file.seekTo(stsd_offset + 16) catch return .unknown;

    // Read first sample entry
    var entry_header: [12]u8 = undefined;
    const bytes = file.read(&entry_header) catch return .unknown;
    if (bytes < 12) return .unknown;

    // entry_size at 0-3, entry_type at 4-7
    const entry_type = entry_header[4..8];

    if (std.mem.eql(u8, entry_type, "hvc1") or std.mem.eql(u8, entry_type, "hev1")) {
        return .hevc;
    } else if (std.mem.eql(u8, entry_type, "av01")) {
        return .av1;
    } else if (std.mem.eql(u8, entry_type, "avc1") or std.mem.eql(u8, entry_type, "avc3")) {
        return .h264;
    } else if (std.mem.eql(u8, entry_type, "vp09")) {
        return .vp9;
    } else if (std.mem.eql(u8, entry_type, "jpeg") or std.mem.eql(u8, entry_type, "mjpa") or
        std.mem.eql(u8, entry_type, "mjpb") or std.mem.eql(u8, entry_type, "dmb1"))
    {
        return .mjpeg;
    } else if (std.mem.eql(u8, entry_type, "apch") or std.mem.eql(u8, entry_type, "apcn") or
        std.mem.eql(u8, entry_type, "apcs") or std.mem.eql(u8, entry_type, "apco") or
        std.mem.eql(u8, entry_type, "ap4h") or std.mem.eql(u8, entry_type, "ap4x"))
    {
        return .prores;
    } else if (std.mem.eql(u8, entry_type, "m1v ") or std.mem.eql(u8, entry_type, "m1v1") or
        std.mem.eql(u8, entry_type, "mpeg"))
    {
        return .mpeg1;
    } else if (std.mem.eql(u8, entry_type, "m2v1") or std.mem.eql(u8, entry_type, "mp2v") or
        std.mem.eql(u8, entry_type, "hdv1") or std.mem.eql(u8, entry_type, "hdv2") or
        std.mem.eql(u8, entry_type, "hdv3") or std.mem.eql(u8, entry_type, "xdv1") or
        std.mem.eql(u8, entry_type, "xdv2") or std.mem.eql(u8, entry_type, "xdv3"))
    {
        return .mpeg2;
    }

    return .unknown;
}

/// Deep validate MP4/MOV video file by decoding keyframes.
pub fn validateMp4Video(allocator: Allocator, path: []const u8, max_frames: u32) VideoValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return VideoValidationResult.invalid("Failed to open file", .unknown);
    };
    defer file.close();

    const file_size = file.getEndPos() catch {
        return VideoValidationResult.invalid("Failed to get file size", .unknown);
    };

    // Find moov box
    var moov_box: ?Mp4Box = null;
    file.seekTo(0) catch return VideoValidationResult.invalid("Seek failed", .unknown);

    while ((file.getPos() catch return VideoValidationResult.invalid("Position failed", .unknown)) < file_size) {
        const box = readMp4BoxHeader(file) orelse break;
        if (std.mem.eql(u8, &box.box_type, "moov")) {
            moov_box = box;
            break;
        }
        file.seekTo(box.offset + box.size) catch break;
    }

    if (moov_box == null) {
        return VideoValidationResult.invalid("No moov box found", .unknown);
    }

    // Find video track (trak with video handler)
    const moov = moov_box.?;
    var trak_offset = moov.offset + moov.header_size;
    const moov_end = moov.offset + moov.size;

    var video_codec: VideoCodec = .unknown;
    var stbl_box: ?Mp4Box = null;

    while (trak_offset < moov_end) {
        file.seekTo(trak_offset) catch break;
        const trak = readMp4BoxHeader(file) orelse break;

        if (!std.mem.eql(u8, &trak.box_type, "trak")) {
            trak_offset = trak.offset + trak.size;
            continue;
        }

        // Look for mdia box inside trak
        const mdia = findChildBox(file, trak.offset + trak.header_size, trak.size - trak.header_size, "mdia");
        if (mdia == null) {
            trak_offset = trak.offset + trak.size;
            continue;
        }

        // Check hdlr for video handler type
        const hdlr = findChildBox(file, mdia.?.offset + mdia.?.header_size, mdia.?.size - mdia.?.header_size, "hdlr");
        if (hdlr != null) {
            // Read handler type (at offset 8 from hdlr data start)
            file.seekTo(hdlr.?.offset + hdlr.?.header_size + 8) catch break;
            var handler_type: [4]u8 = undefined;
            _ = file.read(&handler_type) catch break;

            if (std.mem.eql(u8, &handler_type, "vide")) {
                // Found video track - now find stbl
                const minf = findChildBox(file, mdia.?.offset + mdia.?.header_size, mdia.?.size - mdia.?.header_size, "minf");
                if (minf != null) {
                    stbl_box = findChildBox(file, minf.?.offset + minf.?.header_size, minf.?.size - minf.?.header_size, "stbl");
                    if (stbl_box != null) {
                        // Get codec from stsd
                        const stsd = findChildBox(file, stbl_box.?.offset + stbl_box.?.header_size, stbl_box.?.size - stbl_box.?.header_size, "stsd");
                        if (stsd != null) {
                            video_codec = detectMp4VideoCodec(file, stsd.?.offset, stsd.?.size);
                        }
                        break;
                    }
                }
            }
        }

        trak_offset = trak.offset + trak.size;
    }

    if (stbl_box == null) {
        return VideoValidationResult.invalid("No video track found", .unknown);
    }

    // Check if we support the codec
    if (video_codec != .hevc and video_codec != .av1 and video_codec != .h264 and
        video_codec != .mjpeg and video_codec != .prores and
        video_codec != .mpeg1 and video_codec != .mpeg2)
    {
        // Return success but note we couldn't decode (codec not supported)
        return VideoValidationResult.skipped("Codec not supported for decode validation");
    }

    const stbl = stbl_box.?;

    // For MJPEG, use specialized validation that handles individual JPEG frames
    if (video_codec == .mjpeg) {
        return validateMjpegFromMp4(allocator, file, stbl, max_frames);
    }

    // For ProRes, use specialized structural validation
    if (video_codec == .prores) {
        return validateProResFromMp4(allocator, file, stbl, max_frames);
    }

    // For MPEG-1/2, use pure Zig structural validation
    if (video_codec == .mpeg1 or video_codec == .mpeg2) {
        return validateMpeg12FromMp4(allocator, file, stbl, max_frames, video_codec);
    }

    // Parse sample tables for frame extraction
    var sample_table = parseSampleTable(allocator, file, stbl.offset, stbl.size, stbl.header_size) orelse {
        return VideoValidationResult.invalid("Failed to parse sample tables", video_codec);
    };
    defer sample_table.deinit();

    // Get codec private data (SPS/PPS for H.264/HEVC, sequence header for AV1)
    const stsd = findChildBox(file, stbl.offset + stbl.header_size, stbl.size - stbl.header_size, "stsd");
    var codec_private: ?CodecPrivateData = null;
    var nal_length_size: u8 = 4; // Default for MP4

    if (stsd != null) {
        codec_private = extractCodecPrivate(allocator, file, stsd.?.offset, video_codec);
        if (codec_private != null) {
            nal_length_size = codec_private.?.nal_length_size;
            if (nal_length_size == 0) nal_length_size = 4; // AV1 case
        }
    }
    defer if (codec_private != null) allocator.free(codec_private.?.data);

    // Check for unsupported H.264 profile - use three-tier fallback
    if (video_codec == .h264 and codec_private != null and !codec_private.?.isH264ProfileSupported()) {
        // Tier 2: Try ffprobe/ffmpeg if available
        if (isFfprobeAvailable()) {
            const ffprobe_result = validateWithFfprobe(allocator, path);
            if (ffprobe_result.valid) {
                // ffmpeg performs full decoding, so this is byte-validated
                return VideoValidationResult.okByteValidated(.h264, ffprobe_result.frames_decoded);
            } else {
                return VideoValidationResult.invalid(
                    ffprobe_result.error_message orelse "ffmpeg validation failed",
                    .h264,
                );
            }
        }

        // Tier 3: Structural validation only - set flag for warning message
        return VideoValidationResult.structuralOnlyUnsupportedProfile(.h264);
    }

    var byte_validated = false;

    if (video_codec == .h264 or video_codec == .hevc or video_codec == .av1) {
        const coverage = validateMp4SamplesByteCoverage(
            allocator,
            file,
            sample_table,
            video_codec,
            nal_length_size,
            max_frames,
        );
        switch (coverage) {
            .ok => byte_validated = true,
            .failed => return VideoValidationResult.invalid("Invalid MP4 video sample data", video_codec),
            .unavailable => {},
        }
    }

    // Build combined bitstream: codec private + keyframe samples
    var bitstream: std.ArrayListUnmanaged(u8) = .{};
    defer bitstream.deinit(allocator);

    const max_bitstream_bytes: usize = 256 * 1024 * 1024; // 256MB safety cap

    // Add codec private data first (SPS/PPS must come before frames)
    if (codec_private != null) {
        bitstream.appendSlice(allocator, codec_private.?.data) catch {
            return VideoValidationResult.invalid("Memory allocation failed", video_codec);
        };
    }

    const keyframes_extracted = appendMp4SamplesToBitstream(
        allocator,
        file,
        sample_table,
        video_codec,
        nal_length_size,
        max_frames,
        true,
        &bitstream,
        max_bitstream_bytes,
    );

    if (keyframes_extracted == 0) {
        bitstream.items.len = 0;
        if (codec_private != null) {
            bitstream.appendSlice(allocator, codec_private.?.data) catch {
                return VideoValidationResult.invalid("Memory allocation failed", video_codec);
            };
        }
        const samples_extracted = appendMp4SamplesToBitstream(
            allocator,
            file,
            sample_table,
            video_codec,
            nal_length_size,
            max_frames,
            false,
            &bitstream,
            max_bitstream_bytes,
        );
        if (samples_extracted == 0) {
            const msg = switch (video_codec) {
                .h264 => "No frames decoded from H.264 stream",
                .hevc => "No frames decoded from HEVC",
                .av1 => "No frames decoded from AV1",
                else => "No frames decoded from video stream",
            };
            var no_frames = VideoValidationResult.invalid(msg, video_codec);
            no_frames.byte_validated = byte_validated;
            return no_frames;
        }
    }

    // Decode the combined bitstream
    var result = switch (video_codec) {
        .hevc => validateHevcStream(bitstream.items, max_frames),
        .av1 => validateAv1Stream(allocator, bitstream.items, max_frames),
        .h264 => validateH264Stream(bitstream.items, max_frames),
        else => VideoValidationResult.skipped("Unsupported codec"),
    };

    if (!result.valid and (std.mem.eql(u8, result.error_message orelse "", "No frames decoded from H.264 stream") or
        std.mem.eql(u8, result.error_message orelse "", "No frames decoded from HEVC")))
    {
        bitstream.items.len = 0;
        if (codec_private != null) {
            bitstream.appendSlice(allocator, codec_private.?.data) catch {
                return result;
            };
        }
        const samples_extracted = appendMp4SamplesToBitstream(
            allocator,
            file,
            sample_table,
            video_codec,
            nal_length_size,
            max_frames,
            false,
            &bitstream,
            max_bitstream_bytes,
        );
        if (samples_extracted > 0) {
            result = switch (video_codec) {
                .hevc => validateHevcStream(bitstream.items, max_frames),
                .av1 => validateAv1Stream(allocator, bitstream.items, max_frames),
                .h264 => validateH264Stream(bitstream.items, max_frames),
                else => result,
            };
        }
    }

    result.byte_validated = byte_validated;
    return result;
}

const MkvFrameValidationContext = struct {
	codec: VideoCodec,
	nal_length_size: u8,
	mixed_nal_prefix: bool,
};

fn validateMkvFrameBytes(ctx_ptr: ?*anyopaque, data: []const u8) bool {
	const ctx: *MkvFrameValidationContext = @ptrCast(@alignCast(ctx_ptr orelse return false));
	return switch (ctx.codec) {
		.av1 => validateAv1ObuStream(data),
		.h264, .hevc => validateMkvNalFrame(data, ctx.codec, ctx.nal_length_size, &ctx.mixed_nal_prefix),
		else => false,
	};
}

/// Deep validate MKV/WebM video file by decoding keyframes.
pub fn validateMkvVideo(allocator: Allocator, path: []const u8, max_frames: u32) VideoValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return VideoValidationResult.invalid("Failed to open file", .unknown);
    };
    defer file.close();

    // Initialize Matroska parser
    var parser = ebml.MatroskaParser.init(allocator, file);

    // Parse and validate EBML header
    const doc_info = parser.parseEbmlHeader() orelse {
        return VideoValidationResult.invalid("Invalid EBML header", .unknown);
    };

    // Verify it's a Matroska or WebM file
    if (!doc_info.isMatroska() and !doc_info.isWebM()) {
        return VideoValidationResult.invalid("Not a Matroska/WebM file", .unknown);
    }

    // Find and parse video tracks (limited to first 8)
    var video_tracks_buf: [8]ebml.VideoTrackInfo = undefined;
    var video_track_count: usize = 0;

    // Ensure we clean up all parsed tracks when done
    defer {
        for (video_tracks_buf[0..video_track_count]) |*track| {
            track.deinit();
        }
    }

    // Parse tracks manually since ArrayList API changed in Zig 0.15
    const tracks_elem = parser.findSegmentChild(ebml.Segment_ID.Tracks);
    if (tracks_elem == null) {
        return VideoValidationResult.skipped("No tracks element found");
    }

    const tracks_end = tracks_elem.?.data_offset + (tracks_elem.?.size orelse 0);
    _ = parser.reader.seekTo(tracks_elem.?.data_offset);

    while ((parser.reader.getPos() orelse tracks_end) < tracks_end and video_track_count < 8) {
        const entry = parser.reader.readElementHeader() orelse break;
        if (entry.id == ebml.Tracks_ID.TrackEntry) {
            if (parser.parseTrackEntry(entry)) |track| {
                video_tracks_buf[video_track_count] = track;
                video_track_count += 1;
            }
        } else {
            _ = parser.reader.skipElement(entry);
        }
    }

    if (video_track_count == 0) {
        return VideoValidationResult.skipped("No video tracks found");
    }

    // Get the first video track
    const video_track = video_tracks_buf[0];

    // Determine codec
    const video_codec: VideoCodec = if (video_track.isHevc())
        .hevc
    else if (video_track.isAv1())
        .av1
    else if (video_track.isH264())
        .h264
    else if (video_track.isVp9())
        .vp9
    else if (video_track.isVp8())
        .vp8
    else if (video_track.isMjpeg())
        .mjpeg
    else if (video_track.isMpeg1())
        .mpeg1
    else if (video_track.isMpeg2())
        .mpeg2
    else if (video_track.isTheora())
        .theora
    else
        .unknown;

    // Check if we support decoding this codec
    if (video_codec != .hevc and video_codec != .av1 and video_codec != .h264 and
        video_codec != .mjpeg and video_codec != .mpeg1 and video_codec != .mpeg2 and
        video_codec != .theora and video_codec != .vp8)
    {
        // Return success with codec info but note we couldn't decode
        return VideoValidationResult.okDecoded(video_codec, 0);
    }

    // Build combined bitstream: codec private + keyframe samples
    var bitstream: std.ArrayListUnmanaged(u8) = .{};
    defer bitstream.deinit(allocator);

    // Extract codec_private and convert to Annex B format
    // MKV stores codec_private in the same format as MP4 (avcC/hvcC/av1C)
    var nal_length_size: u8 = 0;
    if (video_track.codec_private) |codec_private| {
        if (video_codec == .h264 and codec_private.len >= 6) {
            if (parseMkvAvcC(allocator, codec_private)) |private_data| {
                defer allocator.free(private_data.data);
                nal_length_size = private_data.nal_length_size;
                bitstream.appendSlice(allocator, private_data.data) catch {
                    return VideoValidationResult.invalid("Memory allocation failed", video_codec);
                };
            }
        } else if (video_codec == .hevc and codec_private.len >= 23) {
            if (parseMkvHvcC(allocator, codec_private)) |private_data| {
                defer allocator.free(private_data.data);
                nal_length_size = private_data.nal_length_size;
                bitstream.appendSlice(allocator, private_data.data) catch {
                    return VideoValidationResult.invalid("Memory allocation failed", video_codec);
                };
            }
        } else if (video_codec == .av1 and codec_private.len >= 4) {
            // AV1 config is passed directly
            bitstream.appendSlice(allocator, codec_private) catch {
                return VideoValidationResult.invalid("Memory allocation failed", video_codec);
            };
        }
    }

    var byte_validated = false;
    var mixed_nal_prefix = false;
    if (video_codec == .h264 or video_codec == .hevc or video_codec == .av1) {
        var ctx = MkvFrameValidationContext{
            .codec = video_codec,
            .nal_length_size = nal_length_size,
            .mixed_nal_prefix = false,
        };
        const ok = parser.walkFrames(video_track.track_number, @intCast(max_frames), @ptrCast(&ctx), validateMkvFrameBytes);
        if (!ok) {
            if (builtin.mode == .Debug) {
                if (getenvCrossPlatform("MKV_BYTE_DEBUG")) |env| {
                    if (isTruthy(env)) {
                        const codec_private_len: usize = if (video_track.codec_private) |codec_private| codec_private.len else 0;
                        var frame_dump: ?std.fs.File = null;
                        if (getenvCrossPlatform("MKV_BYTE_DEBUG_FRAME_OUT")) |dump_path| {
                            if (dump_path.len > 0) {
                                if (std.fs.path.isAbsolute(dump_path)) {
                                    if (std.fs.createFileAbsolute(dump_path, .{})) |dump_file| {
                                        frame_dump = dump_file;
                                    } else |_| {}
                                } else {
                                    if (std.fs.cwd().createFile(dump_path, .{})) |dump_file| {
                                        frame_dump = dump_file;
                                    } else |_| {}
                                }
                            }
                        }
                        defer if (frame_dump) |dump_file| dump_file.close();
                        if (getenvCrossPlatform("MKV_BYTE_DEBUG_OUT")) |out_path| {
                            if (out_path.len > 0) {
                                const out_file_result = if (std.fs.path.isAbsolute(out_path))
                                    std.fs.createFileAbsolute(out_path, .{})
                                else
                                    std.fs.cwd().createFile(out_path, .{});
                                if (out_file_result) |out_file| {
                                    defer out_file.close();
                                    writeMkvDebugHeader(out_file, video_codec, nal_length_size, codec_private_len);
                                    parser.debugFirstInvalidFrame(
                                        video_track.track_number,
                                        @intCast(max_frames),
                                        @ptrCast(&ctx),
                                        validateMkvFrameBytes,
                                        out_file,
                                        frame_dump,
                                    );
                                } else |_| {
                                    writeMkvDebugHeader(std.fs.File.stderr(), video_codec, nal_length_size, codec_private_len);
                                    parser.debugFirstInvalidFrame(
                                        video_track.track_number,
                                        @intCast(max_frames),
                                        @ptrCast(&ctx),
                                        validateMkvFrameBytes,
                                        std.fs.File.stderr(),
                                        frame_dump,
                                    );
                                }
                            } else {
                                writeMkvDebugHeader(std.fs.File.stderr(), video_codec, nal_length_size, codec_private_len);
                                parser.debugFirstInvalidFrame(
                                    video_track.track_number,
                                    @intCast(max_frames),
                                    @ptrCast(&ctx),
                                    validateMkvFrameBytes,
                                    std.fs.File.stderr(),
                                    frame_dump,
                                );
                            }
                        } else {
                            writeMkvDebugHeader(std.fs.File.stderr(), video_codec, nal_length_size, codec_private_len);
                            parser.debugFirstInvalidFrame(
                                video_track.track_number,
                                @intCast(max_frames),
                                @ptrCast(&ctx),
                                validateMkvFrameBytes,
                                std.fs.File.stderr(),
                                frame_dump,
                            );
                        }
                    }
                }
            }
        } else {
            byte_validated = true;
            mixed_nal_prefix = ctx.mixed_nal_prefix;
        }
    }

    const decode_frames_limit: usize = if (video_codec == .h264 or video_codec == .hevc or video_codec == .av1)
        @min(@as(usize, max_frames), 64)
    else
        @as(usize, max_frames);

    // Collect ALL frames (or a limited set for decode) for validation
    const all_frames = parser.collectAllFrames(video_track.track_number, decode_frames_limit) orelse {
        if (bitstream.items.len > 0) {
            // We have codec_private but no frames - try decoding just that
            const result = switch (video_codec) {
                .hevc => validateHevcStream(bitstream.items, max_frames),
                .av1 => validateAv1Stream(allocator, bitstream.items, max_frames),
                .h264 => validateH264Stream(bitstream.items, max_frames),
                else => VideoValidationResult.skipped("Unsupported codec"),
            };
            return result;
        }
        return VideoValidationResult.invalid("No frames found", video_codec);
    };
    defer {
        for (all_frames) |*f| {
            var mutable_f = @constCast(f);
            mutable_f.deinit();
        }
        allocator.free(all_frames);
    }

    // For MJPEG, validate each frame individually as JPEG
    if (video_codec == .mjpeg) {
        var frames_validated: u32 = 0;
        for (all_frames) |kf| {
            const jpeg_result = jpeg.validateJpegDeepFromBuffer(kf.data);
            if (!jpeg_result.valid) {
                return VideoValidationResult.invalid(jpeg_result.error_message orelse "Invalid JPEG frame", .mjpeg);
            }
            frames_validated += 1;
        }
        if (frames_validated == 0) {
            return VideoValidationResult.invalid("No valid MJPEG frames found", .mjpeg);
        }
        return VideoValidationResult.okByteValidated(.mjpeg, frames_validated);
    }

    // For MPEG-1/2, collect keyframes and validate the stream
    if (video_codec == .mpeg1 or video_codec == .mpeg2) {
        // MPEG-1/2 in MKV already has start codes
        var mpeg_stream: std.ArrayListUnmanaged(u8) = .{};
        defer mpeg_stream.deinit(allocator);

        for (all_frames) |f| {
            mpeg_stream.appendSlice(allocator, f.data) catch continue;
        }

        if (mpeg_stream.items.len == 0) {
            return VideoValidationResult.invalid("No MPEG data extracted", video_codec);
        }

        // Use deep validation with DCT decode for I-frames
        const mpeg_result = mpeg12.validateMpeg12Deep(mpeg_stream.items, max_frames);
        if (!mpeg_result.valid) {
            return VideoValidationResult.invalid(mpeg_result.error_message orelse "Invalid MPEG video", video_codec);
        }

        // Return with detected version
        const detected_codec: VideoCodec = switch (mpeg_result.structural_result.version) {
            .mpeg1 => .mpeg1,
            .mpeg2 => .mpeg2,
            .unknown => video_codec,
        };
        return VideoValidationResult.okByteValidated(detected_codec, mpeg_result.structural_result.pictures);
    }

    // For Theora, validate packets
    if (video_codec == .theora) {
        // Theora in MKV has headers in codec_private
        if (video_track.codec_private) |codec_private| {
            // Parse info header from codec_private (may be concatenated headers)
            const info = theora.parseInfoHeader(codec_private) orelse {
                return VideoValidationResult.invalid("Invalid Theora info header", .theora);
            };

            // Count frames from collected frames
            var keyframe_count: u32 = 0;
            var inter_count: u32 = 0;
            for (all_frames) |kf| {
                if (theora.isVideoFrame(kf.data)) |is_key| {
                    if (is_key) {
                        keyframe_count += 1;
                    } else {
                        inter_count += 1;
                    }
                }
            }

            _ = info;
            return VideoValidationResult.okByteValidated(.theora, keyframe_count + inter_count);
        } else {
            return VideoValidationResult.invalid("No Theora codec_private", .theora);
        }
    }

    // For VP8, use deep validation with boolean decoder parsing
    // Note: libvpx full decode not available (built with VP9 only)
    // The pure Zig boolean decoder validates arithmetic-coded header structure
    if (video_codec == .vp8) {
        var frames_validated: u32 = 0;
        for (all_frames) |kf| {
            // Use deep validation which parses boolean-coded header
            const vp8_result = vp8.validateVp8Deep(kf.data);
            if (!vp8_result.valid) {
                return VideoValidationResult.invalid(vp8_result.error_message orelse "VP8 decode failed", .vp8);
            }
            frames_validated += 1;
        }
        if (frames_validated == 0) {
            return VideoValidationResult.invalid("No VP8 frames validated", .vp8);
        }
        return VideoValidationResult.okByteValidated(.vp8, frames_validated);
    }

    // Add frame data to bitstream for other codecs
    for (all_frames) |kf| {
        if (video_codec == .av1) {
            // AV1 uses OBUs directly
            bitstream.appendSlice(allocator, kf.data) catch continue;
        } else {
            // H.264/HEVC: Convert length-prefixed NALs to Annex B
            if (convertToAnnexB(allocator, kf.data, nal_length_size)) |annexb_data| {
                defer allocator.free(annexb_data);
                bitstream.appendSlice(allocator, annexb_data) catch continue;
            }
        }
    }

    if (bitstream.items.len == 0) {
        return VideoValidationResult.invalid("No frame data extracted", video_codec);
    }

    // Decode the combined bitstream
    var result = switch (video_codec) {
        .hevc => validateHevcStream(bitstream.items, max_frames),
        .av1 => validateAv1Stream(allocator, bitstream.items, max_frames),
        .h264 => validateH264Stream(bitstream.items, max_frames),
        else => VideoValidationResult.skipped("Unsupported codec"),
    };
    if (byte_validated) {
        result.byte_validated = true;
    }
    result.mixed_nal_prefix = mixed_nal_prefix;
    return result;
}

/// Deep validate AVI video file by decoding keyframes.
/// Parses the RIFF/AVI container to extract video codec and frames,
/// then validates using appropriate decoder.
pub fn validateAviVideo(allocator: Allocator, path: []const u8, max_frames: u32) VideoValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return VideoValidationResult.invalid("Failed to open file", .unknown);
    };
    defer file.close();

    const file_size = file.getEndPos() catch {
        return VideoValidationResult.invalid("Failed to get file size", .unknown);
    };

    // Validate RIFF/AVI header
    var header: [12]u8 = undefined;
    _ = file.read(&header) catch {
        return VideoValidationResult.invalid("Failed to read RIFF header", .unknown);
    };

    if (!std.mem.eql(u8, header[0..4], "RIFF") or !std.mem.eql(u8, header[8..12], "AVI ")) {
        return VideoValidationResult.invalid("Not a valid AVI file", .unknown);
    }

    // Parse AVI structure to find video stream info
    const avi_info = parseAviStructure(file, file_size) orelse {
        return VideoValidationResult.invalid("Failed to parse AVI structure", .unknown);
    };

    const video_codec = detectAviVideoCodec(avi_info.codec_fourcc);

    // Check if we support the codec
    if (video_codec != .mjpeg and video_codec != .h264 and
        video_codec != .mpeg1 and video_codec != .mpeg2 and video_codec != .mpeg4p2)
    {
        return VideoValidationResult.skipped("AVI codec not supported for decode validation");
    }

    // Extract and validate video frames
    if (video_codec == .mjpeg) {
        return validateMjpegFromAvi(allocator, file, avi_info, max_frames);
    }

    if (video_codec == .mpeg1 or video_codec == .mpeg2) {
        return validateMpeg12FromAvi(allocator, file, avi_info, max_frames, video_codec);
    }

    if (video_codec == .h264) {
        return validateH264FromAvi(allocator, file, avi_info, max_frames);
    }

    if (video_codec == .mpeg4p2) {
        return validateMpeg4P2FromAvi(allocator, file, avi_info, max_frames);
    }

    return VideoValidationResult.skipped("Unsupported AVI codec");
}

/// AVI stream information parsed from header
const AviStreamInfo = struct {
    codec_fourcc: [4]u8,
    video_stream_id: u16, // e.g., 0 for "00dc"
    movi_offset: u64,
    movi_size: u64,
    frame_count: u32,
    width: u32,
    height: u32,
};

/// Parse AVI structure to extract video stream info
fn parseAviStructure(file: std.fs.File, file_size: u64) ?AviStreamInfo {
    var info = AviStreamInfo{
        .codec_fourcc = [_]u8{ 0, 0, 0, 0 },
        .video_stream_id = 0,
        .movi_offset = 0,
        .movi_size = 0,
        .frame_count = 0,
        .width = 0,
        .height = 0,
    };

    file.seekTo(12) catch return null; // Skip RIFF header

    var position: u64 = 12;
    var found_video_stream = false;
    var stream_index: u16 = 0;

    while (position < file_size) {
        file.seekTo(position) catch break;

        var chunk_header: [8]u8 = undefined;
        const bytes_read = file.read(&chunk_header) catch break;
        if (bytes_read < 8) break;

        const chunk_id = chunk_header[0..4];
        const chunk_size = std.mem.readInt(u32, chunk_header[4..8], .little);

        if (std.mem.eql(u8, chunk_id, "LIST")) {
            // Read LIST type
            var list_type: [4]u8 = undefined;
            _ = file.read(&list_type) catch break;

            if (std.mem.eql(u8, &list_type, "hdrl")) {
                // Parse header list - look for stream info
                const hdrl_end = position + 8 + chunk_size;
                var hdrl_pos = position + 12; // After LIST header + type

                while (hdrl_pos < hdrl_end) {
                    file.seekTo(hdrl_pos) catch break;
                    var sub_header: [8]u8 = undefined;
                    const sub_read = file.read(&sub_header) catch break;
                    if (sub_read < 8) break;

                    const sub_id = sub_header[0..4];
                    const sub_size = std.mem.readInt(u32, sub_header[4..8], .little);

                    if (std.mem.eql(u8, sub_id, "LIST")) {
                        var sub_type: [4]u8 = undefined;
                        _ = file.read(&sub_type) catch break;

                        if (std.mem.eql(u8, &sub_type, "strl")) {
                            // Stream list - parse strh and strf
                            const strl_end = hdrl_pos + 8 + sub_size;
                            var strl_pos = hdrl_pos + 12;
                            var is_video_stream = false;

                            while (strl_pos < strl_end) {
                                file.seekTo(strl_pos) catch break;
                                var strl_header: [8]u8 = undefined;
                                const strl_read = file.read(&strl_header) catch break;
                                if (strl_read < 8) break;

                                const strl_id = strl_header[0..4];
                                const strl_size = std.mem.readInt(u32, strl_header[4..8], .little);

                                if (std.mem.eql(u8, strl_id, "strh")) {
                                    // Stream header - check if video
                                    var strh_data: [56]u8 = undefined;
                                    const strh_read = file.read(&strh_data) catch break;
                                    if (strh_read >= 4) {
                                        if (std.mem.eql(u8, strh_data[0..4], "vids")) {
                                            is_video_stream = true;
                                            if (!found_video_stream) {
                                                info.video_stream_id = stream_index;
                                            }
                                        }
                                    }
                                } else if (std.mem.eql(u8, strl_id, "strf") and is_video_stream and !found_video_stream) {
                                    // Stream format - BITMAPINFOHEADER for video
                                    // biSize(4) + biWidth(4) + biHeight(4) + biPlanes(2) +
                                    // biBitCount(2) + biCompression(4)
                                    var strf_data: [40]u8 = undefined;
                                    const strf_read = file.read(&strf_data) catch break;
                                    if (strf_read >= 20) {
                                        info.width = std.mem.readInt(u32, strf_data[4..8], .little);
                                        const raw_height = std.mem.readInt(i32, strf_data[8..12], .little);
                                        info.height = @abs(raw_height);
                                        info.codec_fourcc = strf_data[16..20].*;
                                        found_video_stream = true;
                                    }
                                }

                                strl_pos += 8 + ((strl_size + 1) & ~@as(u32, 1)); // Word-aligned
                            }
                            stream_index += 1;
                        }
                    } else if (std.mem.eql(u8, sub_id, "avih")) {
                        // Main AVI header - extract frame count
                        var avih_data: [56]u8 = undefined;
                        const avih_read = file.read(&avih_data) catch break;
                        if (avih_read >= 24) {
                            info.frame_count = std.mem.readInt(u32, avih_data[16..20], .little);
                        }
                    }

                    hdrl_pos += 8 + ((sub_size + 1) & ~@as(u32, 1));
                }
            } else if (std.mem.eql(u8, &list_type, "movi")) {
                // Movie data list
                info.movi_offset = position + 12; // After LIST header + type
                info.movi_size = chunk_size - 4; // Minus type field
            }
        }

        position += 8 + ((chunk_size + 1) & ~@as(u32, 1)); // Word-aligned
    }

    if (!found_video_stream or info.movi_offset == 0) return null;
    return info;
}

/// Detect video codec from AVI FourCC
fn detectAviVideoCodec(fourcc: [4]u8) VideoCodec {
    // Uppercase for comparison
    var upper: [4]u8 = undefined;
    for (fourcc, 0..) |c, i| {
        upper[i] = if (c >= 'a' and c <= 'z') c - 32 else c;
    }

    // Motion JPEG variants
    if (std.mem.eql(u8, &upper, "MJPG") or std.mem.eql(u8, &upper, "MJPA") or
        std.mem.eql(u8, &upper, "MJPB") or std.mem.eql(u8, &upper, "JPEG") or
        std.mem.eql(u8, &upper, "DMBI"))
    {
        return .mjpeg;
    }

    // H.264 variants
    if (std.mem.eql(u8, &upper, "H264") or std.mem.eql(u8, &upper, "X264") or
        std.mem.eql(u8, &upper, "AVC1") or std.mem.eql(u8, &upper, "DAVC") or
        std.mem.eql(u8, &upper, "VSSH"))
    {
        return .h264;
    }

    // MPEG-1 variants
    if (std.mem.eql(u8, &upper, "MPG1") or std.mem.eql(u8, &upper, "MPEG") or
        std.mem.eql(u8, &upper, "MP1V") or std.mem.eql(u8, &upper, "PIM1"))
    {
        return .mpeg1;
    }

    // MPEG-2 variants
    if (std.mem.eql(u8, &upper, "MPG2") or std.mem.eql(u8, &upper, "MP2V") or
        std.mem.eql(u8, &upper, "MPEG") or std.mem.eql(u8, &upper, "EM2V") or
        std.mem.eql(u8, &upper, "HDMV"))
    {
        return .mpeg2;
    }

    // MPEG-4 Part 2 / ASP variants (DivX, Xvid, etc.)
    if (std.mem.eql(u8, &upper, "DIVX") or std.mem.eql(u8, &upper, "DX50") or
        std.mem.eql(u8, &upper, "XVID") or std.mem.eql(u8, &upper, "MP4V") or
        std.mem.eql(u8, &upper, "MP4S") or std.mem.eql(u8, &upper, "M4S2") or
        std.mem.eql(u8, &upper, "FMP4") or std.mem.eql(u8, &upper, "3IV2") or
        std.mem.eql(u8, &upper, "3IVX") or std.mem.eql(u8, &upper, "BLZ0") or
        std.mem.eql(u8, &upper, "DM4V") or std.mem.eql(u8, &upper, "FFDS") or
        std.mem.eql(u8, &upper, "FVFW") or std.mem.eql(u8, &upper, "DXGM") or
        std.mem.eql(u8, &upper, "HDX4") or std.mem.eql(u8, &upper, "EM4A") or
        std.mem.eql(u8, &upper, "EPHV") or std.mem.eql(u8, &upper, "SEDG") or
        std.mem.eql(u8, &upper, "RMP4") or std.mem.eql(u8, &upper, "SMP4") or
        std.mem.eql(u8, &upper, "UMP4") or std.mem.eql(u8, &upper, "WV1F"))
    {
        return .mpeg4p2;
    }

    return .unknown;
}

/// Validate MJPEG frames from AVI container
fn validateMjpegFromAvi(allocator: Allocator, file: std.fs.File, avi_info: AviStreamInfo, max_frames: u32) VideoValidationResult {
    // Validate video_stream_id is in valid range (0-99 for two-digit chunk IDs)
    if (avi_info.video_stream_id >= 100) {
        return VideoValidationResult.invalid("Video stream ID out of range", .mjpeg);
    }

    // Build the video stream chunk ID (e.g., "00dc" for stream 0)
    var video_chunk_id: [4]u8 = undefined;
    const stream_id: u8 = @truncate(avi_info.video_stream_id);
    video_chunk_id[0] = '0' + (stream_id / 10);
    video_chunk_id[1] = '0' + (stream_id % 10);
    video_chunk_id[2] = 'd';
    video_chunk_id[3] = 'c'; // Compressed video

    // Also check for 'db' (uncompressed video, less common for MJPEG)
    var video_chunk_id_db: [4]u8 = video_chunk_id;
    video_chunk_id_db[3] = 'b';

    var position = avi_info.movi_offset;
    const movi_end = avi_info.movi_offset + avi_info.movi_size;
    var frames_validated: u32 = 0;
    var frame_buffer: []u8 = allocator.alloc(u8, 1024 * 1024) catch {
        return VideoValidationResult.invalid("Memory allocation failed", .mjpeg);
    };
    defer allocator.free(frame_buffer);

    while (position < movi_end and frames_validated < max_frames) {
        file.seekTo(position) catch break;

        var chunk_header: [8]u8 = undefined;
        const bytes_read = file.read(&chunk_header) catch break;
        if (bytes_read < 8) break;

        const chunk_id = chunk_header[0..4];
        const chunk_size = std.mem.readInt(u32, chunk_header[4..8], .little);

        // Check if this is a video frame chunk
        if (std.mem.eql(u8, chunk_id, &video_chunk_id) or std.mem.eql(u8, chunk_id, &video_chunk_id_db)) {
            if (chunk_size > 0 and chunk_size < 50 * 1024 * 1024) { // Max 50MB per frame
                // Resize buffer if needed
                if (chunk_size > frame_buffer.len) {
                    allocator.free(frame_buffer);
                    frame_buffer = allocator.alloc(u8, chunk_size) catch continue;
                }

                // Read frame data
                const frame_read = file.read(frame_buffer[0..chunk_size]) catch continue;
                if (frame_read == chunk_size) {
                    // Validate JPEG frame
                    const jpeg_result = jpeg.validateJpegDeepFromBuffer(frame_buffer[0..chunk_size]);
                    if (jpeg_result.valid) {
                        frames_validated += 1;
                    } else {
                        return VideoValidationResult.invalid("Invalid MJPEG frame", .mjpeg);
                    }
                }
            }
        } else if (std.mem.eql(u8, chunk_id, "LIST")) {
            // Skip nested LIST (like rec chunks)
        }

        position += 8 + ((chunk_size + 1) & ~@as(u32, 1));
    }

    if (frames_validated == 0) {
        return VideoValidationResult.invalid("No MJPEG frames found", .mjpeg);
    }

    return VideoValidationResult.okByteValidated(.mjpeg, frames_validated);
}

/// Validate MPEG-1/2 frames from AVI container
fn validateMpeg12FromAvi(allocator: Allocator, file: std.fs.File, avi_info: AviStreamInfo, max_frames: u32, codec: VideoCodec) VideoValidationResult {
    // Validate video_stream_id is in valid range (0-99 for two-digit chunk IDs)
    if (avi_info.video_stream_id >= 100) {
        return VideoValidationResult.invalid("Video stream ID out of range", codec);
    }

    // Build the video stream chunk ID
    var video_chunk_id: [4]u8 = undefined;
    const stream_id: u8 = @truncate(avi_info.video_stream_id);
    video_chunk_id[0] = '0' + (stream_id / 10);
    video_chunk_id[1] = '0' + (stream_id % 10);
    video_chunk_id[2] = 'd';
    video_chunk_id[3] = 'c';

    var position = avi_info.movi_offset;
    const movi_end = avi_info.movi_offset + avi_info.movi_size;

    // Collect video data into a buffer for MPEG stream validation
    var video_data: std.ArrayListUnmanaged(u8) = .{};
    defer video_data.deinit(allocator);

    var frames_collected: u32 = 0;
    const max_video_size: usize = 100 * 1024 * 1024; // 100MB max
    // Use saturating arithmetic to avoid overflow when max_frames is very large
    const max_chunks = if (max_frames > std.math.maxInt(u32) / 10) std.math.maxInt(u32) else max_frames * 10;

    while (position < movi_end and frames_collected < max_chunks) { // Collect more chunks
        file.seekTo(position) catch break;

        var chunk_header: [8]u8 = undefined;
        const bytes_read = file.read(&chunk_header) catch break;
        if (bytes_read < 8) break;

        const chunk_id = chunk_header[0..4];
        const chunk_size = std.mem.readInt(u32, chunk_header[4..8], .little);

        if (std.mem.eql(u8, chunk_id, &video_chunk_id)) {
            if (chunk_size > 0 and video_data.items.len + chunk_size < max_video_size) {
                const old_len = video_data.items.len;
                video_data.resize(allocator, old_len + chunk_size) catch break;
                const chunk_read = file.read(video_data.items[old_len..]) catch {
                    video_data.shrinkRetainingCapacity(old_len);
                    break;
                };
                if (chunk_read != chunk_size) {
                    video_data.shrinkRetainingCapacity(old_len);
                }
                frames_collected += 1;
            }
        }

        position += 8 + ((chunk_size + 1) & ~@as(u32, 1));
    }

    if (video_data.items.len == 0) {
        return VideoValidationResult.invalid("No MPEG video data found", codec);
    }

    // Validate the MPEG stream with deep DCT decode
    const result = mpeg12.validateMpeg12Deep(video_data.items, max_frames);
    if (result.valid) {
        return VideoValidationResult.okByteValidated(codec, result.structural_result.pictures);
    } else {
        return VideoValidationResult.invalid(result.error_message orelse "MPEG decode failed", codec);
    }
}

/// Validate H.264 frames from AVI container
fn validateH264FromAvi(allocator: Allocator, file: std.fs.File, avi_info: AviStreamInfo, max_frames: u32) VideoValidationResult {
    // Validate video_stream_id is in valid range (0-99 for two-digit chunk IDs)
    if (avi_info.video_stream_id >= 100) {
        return VideoValidationResult.invalid("Video stream ID out of range", .h264);
    }

    // Build the video stream chunk ID
    var video_chunk_id: [4]u8 = undefined;
    const stream_id: u8 = @truncate(avi_info.video_stream_id);
    video_chunk_id[0] = '0' + (stream_id / 10);
    video_chunk_id[1] = '0' + (stream_id % 10);
    video_chunk_id[2] = 'd';
    video_chunk_id[3] = 'c';

    var position = avi_info.movi_offset;
    const movi_end = avi_info.movi_offset + avi_info.movi_size;

    // Collect video data - H.264 in AVI is usually already Annex B format
    var video_data: std.ArrayListUnmanaged(u8) = .{};
    defer video_data.deinit(allocator);

    var frames_collected: u32 = 0;
    const max_video_size: usize = 100 * 1024 * 1024; // 100MB max
    // Use saturating arithmetic to avoid overflow when max_frames is very large
    const max_chunks = if (max_frames > std.math.maxInt(u32) / 10) std.math.maxInt(u32) else max_frames * 10;

    while (position < movi_end and frames_collected < max_chunks) {
        file.seekTo(position) catch break;

        var chunk_header: [8]u8 = undefined;
        const bytes_read = file.read(&chunk_header) catch break;
        if (bytes_read < 8) break;

        const chunk_id = chunk_header[0..4];
        const chunk_size = std.mem.readInt(u32, chunk_header[4..8], .little);

        if (std.mem.eql(u8, chunk_id, &video_chunk_id)) {
            if (chunk_size > 0 and video_data.items.len + chunk_size < max_video_size) {
                const old_len = video_data.items.len;
                video_data.resize(allocator, old_len + chunk_size) catch break;
                const chunk_read = file.read(video_data.items[old_len..]) catch {
                    video_data.shrinkRetainingCapacity(old_len);
                    break;
                };
                if (chunk_read != chunk_size) {
                    video_data.shrinkRetainingCapacity(old_len);
                }
                frames_collected += 1;
            }
        }

        position += 8 + ((chunk_size + 1) & ~@as(u32, 1));
    }

    if (video_data.items.len == 0) {
        return VideoValidationResult.invalid("No H.264 video data found", .h264);
    }

    if (!validateAnnexBStream(video_data.items)) {
        return VideoValidationResult.invalid("Invalid H.264 Annex B stream", .h264);
    }

    // Validate the H.264 stream
    var result = validateH264Stream(video_data.items, max_frames);
    result.byte_validated = true;
    return result;
}

/// Validate MPEG-4 Part 2 frames from AVI container
fn validateMpeg4P2FromAvi(allocator: Allocator, file: std.fs.File, avi_info: AviStreamInfo, max_frames: u32) VideoValidationResult {
    // Validate video_stream_id is in valid range (0-99 for two-digit chunk IDs)
    if (avi_info.video_stream_id >= 100) {
        return VideoValidationResult.invalid("Video stream ID out of range", .mpeg4p2);
    }

    // Build the video stream chunk IDs - both dc (compressed) and db (uncompressed/bitmap)
    // Some encoders use 'db' for compressed video despite the naming convention
    var video_chunk_dc: [4]u8 = undefined;
    var video_chunk_db: [4]u8 = undefined;
    const stream_id: u8 = @truncate(avi_info.video_stream_id);
    video_chunk_dc[0] = '0' + (stream_id / 10);
    video_chunk_dc[1] = '0' + (stream_id % 10);
    video_chunk_dc[2] = 'd';
    video_chunk_dc[3] = 'c';
    video_chunk_db[0] = video_chunk_dc[0];
    video_chunk_db[1] = video_chunk_dc[1];
    video_chunk_db[2] = 'd';
    video_chunk_db[3] = 'b';

    var position = avi_info.movi_offset;
    const movi_end = avi_info.movi_offset + avi_info.movi_size;

    // Collect video data - MPEG-4 Part 2 uses start codes like MPEG-1/2
    var video_data: std.ArrayListUnmanaged(u8) = .{};
    defer video_data.deinit(allocator);

    var frames_collected: u32 = 0;
    const max_video_size: usize = 100 * 1024 * 1024; // 100MB max
    // Use saturating arithmetic to avoid overflow when max_frames is very large
    const max_chunks = if (max_frames > std.math.maxInt(u32) / 10) std.math.maxInt(u32) else max_frames * 10;

    while (position < movi_end and frames_collected < max_chunks) {
        file.seekTo(position) catch break;

        var chunk_header: [8]u8 = undefined;
        const bytes_read = file.read(&chunk_header) catch break;
        if (bytes_read < 8) break;

        const chunk_id = chunk_header[0..4];
        const chunk_size = std.mem.readInt(u32, chunk_header[4..8], .little);

        // Check for both 'dc' (compressed) and 'db' (bitmap) video chunks
        const is_video_chunk = std.mem.eql(u8, chunk_id, &video_chunk_dc) or
            std.mem.eql(u8, chunk_id, &video_chunk_db);

        if (is_video_chunk) {
            if (chunk_size > 0 and video_data.items.len + chunk_size < max_video_size) {
                const old_len = video_data.items.len;
                video_data.resize(allocator, old_len + chunk_size) catch break;
                const chunk_read = file.read(video_data.items[old_len..]) catch {
                    video_data.shrinkRetainingCapacity(old_len);
                    break;
                };
                if (chunk_read != chunk_size) {
                    video_data.shrinkRetainingCapacity(old_len);
                }
                frames_collected += 1;
            }
        }

        position += 8 + ((chunk_size + 1) & ~@as(u32, 1));
    }

    if (video_data.items.len == 0) {
        return VideoValidationResult.invalid("No MPEG-4 Part 2 video data found", .mpeg4p2);
    }

    // Validate the MPEG-4 Part 2 stream
    const result = mpeg4p2.validateMpeg4P2Stream(video_data.items, max_frames);
    if (result.valid) {
        return VideoValidationResult.okByteValidated(.mpeg4p2, result.vop_count);
    } else {
        return VideoValidationResult.invalid(result.error_message orelse "MPEG-4 Part 2 validation failed", .mpeg4p2);
    }
}

/// Validate H.264 bitstream using OpenH264.
/// Decodes up to max_frames to verify integrity.
/// Input data should be in Annex B format (with 0x00000001 start codes).
/// This is a thin wrapper around h264_validator for consistency.
pub fn validateH264Stream(data: []const u8, max_frames: u32) VideoValidationResult {
    const result = h264.validateH264Stream(data, max_frames);
    return .{
        .valid = result.valid,
        .error_message = result.error_message,
        .codec = .h264,
        .frames_decoded = result.frames_decoded,
        .byte_validated = false,
    };
}

/// Codec private data (SPS/PPS for H.264/HEVC, config OBUs for AV1)
pub const CodecPrivateData = struct {
    data: []u8,
    nal_length_size: u8,
    /// H.264 profile indication (from avcC), 0 if not applicable
    h264_profile: u8 = 0,

    /// Check if H.264 profile is supported by OpenH264
    pub fn isH264ProfileSupported(self: @This()) bool {
        return switch (self.h264_profile) {
            66, 77, 100 => true, // Baseline, Main, High
            0 => true, // Not H.264 or unknown
            else => false,
        };
    }

    /// Get H.264 profile description
    pub fn h264ProfileDescription(self: @This()) []const u8 {
        return switch (self.h264_profile) {
            66 => "Baseline",
            77 => "Main",
            88 => "Extended (unsupported)",
            100 => "High",
            110 => "High 10 (unsupported - 10-bit)",
            122 => "High 4:2:2 (unsupported)",
            244 => "High 4:4:4 (unsupported)",
            0 => "unknown",
            else => "unknown/unsupported",
        };
    }
};

/// Sample location (offset and size) for bulk precomputation
const SampleLocation = struct {
    offset: u64,
    size: u32,
};

/// MP4 Sample Table structures for frame extraction
const SampleTableInfo = struct {
    /// Sample sizes (from stsz box)
    sample_sizes: []u32,
    /// Default sample size (if all samples same size)
    default_sample_size: u32,
    /// Total sample count
    sample_count: u32,
    /// Sync sample indices (keyframes, from stss box) - 1-indexed!
    sync_samples: []u32,
    /// Chunk offsets (from stco/co64 box)
    chunk_offsets: []u64,
    /// Sample-to-chunk entries (from stsc box)
    stsc_entries: []StscEntry,

    allocator: Allocator,

    const StscEntry = struct {
        first_chunk: u32, // 1-indexed
        samples_per_chunk: u32,
        sample_description_index: u32,
    };

    pub fn deinit(self: *SampleTableInfo) void {
        if (self.sample_sizes.len > 0) self.allocator.free(self.sample_sizes);
        if (self.sync_samples.len > 0) self.allocator.free(self.sync_samples);
        if (self.chunk_offsets.len > 0) self.allocator.free(self.chunk_offsets);
        if (self.stsc_entries.len > 0) self.allocator.free(self.stsc_entries);
    }

    /// Get the file offset and size for a given sample index (0-indexed)
    /// Optimized: O(stsc_entries) instead of O(chunks) - critical for long videos
    pub fn getSampleLocation(self: *const SampleTableInfo, sample_index: u32) ?struct { offset: u64, size: u32 } {
        if (sample_index >= self.sample_count) return null;
        if (self.chunk_offsets.len == 0) return null;
        if (self.stsc_entries.len == 0) return null;

        // Get sample size
        const size = if (self.default_sample_size > 0)
            self.default_sample_size
        else if (sample_index < self.sample_sizes.len)
            self.sample_sizes[sample_index]
        else
            return null;

        // Optimized chunk lookup: iterate through stsc runs, not individual chunks
        // Each stsc entry defines a run of chunks with the same samples_per_chunk
        // This is O(stsc_entries) instead of O(chunks)
        var samples_before_run: u32 = 0;
        var chunk_at_run_start: u32 = 0;
        var samples_per_chunk: u32 = self.stsc_entries[0].samples_per_chunk;

        for (self.stsc_entries, 0..) |entry, i| {
            // Calculate chunks in this run
            const run_start_chunk = entry.first_chunk - 1; // Convert to 0-indexed
            const next_run_start_chunk: u32 = if (i + 1 < self.stsc_entries.len)
                self.stsc_entries[i + 1].first_chunk - 1
            else
                @intCast(self.chunk_offsets.len);

            const chunks_in_run = next_run_start_chunk - run_start_chunk;
            const samples_in_run = chunks_in_run * entry.samples_per_chunk;

            if (samples_before_run + samples_in_run > sample_index) {
                // Sample is in this run - calculate exact chunk
                samples_per_chunk = entry.samples_per_chunk;
                chunk_at_run_start = run_start_chunk;

                // Find which chunk within this run
                const sample_in_run = sample_index - samples_before_run;
                const chunk_in_run = sample_in_run / samples_per_chunk;
                const chunk_index = chunk_at_run_start + chunk_in_run;

                if (chunk_index >= self.chunk_offsets.len) return null;

                // Calculate samples before our chunk (within this run)
                const samples_before_chunk = samples_before_run + chunk_in_run * samples_per_chunk;
                const sample_in_chunk = sample_index - samples_before_chunk;

                // Calculate offset within chunk
                var offset = self.chunk_offsets[chunk_index];
                if (self.default_sample_size > 0) {
                    offset += @as(u64, sample_in_chunk) * @as(u64, self.default_sample_size);
                } else {
                    // Variable sample sizes - need to sum previous samples in chunk
                    var s: u32 = samples_before_chunk;
                    while (s < sample_index) : (s += 1) {
                        if (s < self.sample_sizes.len) {
                            offset += self.sample_sizes[s];
                        }
                    }
                }

                return .{ .offset = offset, .size = size };
            }

            samples_before_run += samples_in_run;
        }

        return null; // Sample not found
    }

    /// Precompute all sample locations in a single O(samples) pass
    /// This is much faster than calling getSampleLocation() for each sample
    /// which would be O(samples × stsc_entries)
    pub fn getAllSampleLocations(self: *const SampleTableInfo, alloc: Allocator) ?[]SampleLocation {
        if (self.sample_count == 0) return null;
        if (self.chunk_offsets.len == 0) return null;
        if (self.stsc_entries.len == 0) return null;

        const locations = alloc.alloc(SampleLocation, self.sample_count) catch return null;
        errdefer alloc.free(locations);

        var sample_idx: u32 = 0;
        var stsc_idx: usize = 0;
        var samples_per_chunk: u32 = self.stsc_entries[0].samples_per_chunk;

        // Iterate through chunks in order
        for (self.chunk_offsets, 0..) |chunk_offset, chunk_idx| {
            // Update samples_per_chunk if we've entered a new stsc run
            while (stsc_idx + 1 < self.stsc_entries.len and
                self.stsc_entries[stsc_idx + 1].first_chunk <= chunk_idx + 1)
            {
                stsc_idx += 1;
                samples_per_chunk = self.stsc_entries[stsc_idx].samples_per_chunk;
            }

            // Process all samples in this chunk
            var offset_in_chunk: u64 = 0;
            var sample_in_chunk: u32 = 0;
            while (sample_in_chunk < samples_per_chunk and sample_idx < self.sample_count) {
                const size = if (self.default_sample_size > 0)
                    self.default_sample_size
                else if (sample_idx < self.sample_sizes.len)
                    self.sample_sizes[sample_idx]
                else {
                    alloc.free(locations);
                    return null;
                };

                locations[sample_idx] = .{
                    .offset = chunk_offset + offset_in_chunk,
                    .size = size,
                };

                offset_in_chunk += size;
                sample_idx += 1;
                sample_in_chunk += 1;
            }
        }

        // Verify we processed all samples
        if (sample_idx != self.sample_count) {
            alloc.free(locations);
            return null;
        }

        return locations;
    }

    /// Check if a sample is a sync sample (keyframe)
    pub fn isSyncSample(self: *const SampleTableInfo, sample_index: u32) bool {
        // If no sync sample table, all samples are sync samples (rare for video)
        if (self.sync_samples.len == 0) return true;

        // stss uses 1-indexed sample numbers
        const sample_number = sample_index + 1;
        for (self.sync_samples) |sync| {
            if (sync == sample_number) return true;
        }
        return false;
    }
};

fn appendMp4SamplesToBitstream(
    allocator: Allocator,
    file: std.fs.File,
    sample_table: SampleTableInfo,
    video_codec: VideoCodec,
    nal_length_size: u8,
    max_frames: u32,
    only_sync_samples: bool,
    bitstream: *std.ArrayListUnmanaged(u8),
    max_bitstream_bytes: usize,
) u32 {
    var samples_appended: u32 = 0;
    const max_sample_size: u32 = 50 * 1024 * 1024; // 50MB max per sample

    var sample_buffer: []u8 = allocator.alloc(u8, 1024 * 1024) catch return 0;
    defer allocator.free(sample_buffer);

    for (0..sample_table.sample_count) |sample_idx| {
        if (samples_appended >= max_frames) break;
        if (only_sync_samples and !sample_table.isSyncSample(@intCast(sample_idx))) continue;
        if (bitstream.items.len >= max_bitstream_bytes) break;

        const location = sample_table.getSampleLocation(@intCast(sample_idx)) orelse continue;
        if (location.size > max_sample_size) continue;

        if (location.size > sample_buffer.len) {
            allocator.free(sample_buffer);
            sample_buffer = allocator.alloc(u8, location.size) catch break;
        }

        file.seekTo(location.offset) catch continue;
        const bytes_read = file.read(sample_buffer[0..location.size]) catch continue;
        if (bytes_read < location.size) continue;

        if (video_codec == .av1) {
            bitstream.appendSlice(allocator, sample_buffer[0..location.size]) catch continue;
        } else {
            if (convertToAnnexB(allocator, sample_buffer[0..location.size], nal_length_size)) |annexb_data| {
                defer allocator.free(annexb_data);
                bitstream.appendSlice(allocator, annexb_data) catch continue;
            } else {
                continue;
            }
        }

        samples_appended += 1;
    }

    return samples_appended;
}

const ByteCoverageResult = enum {
	ok,
	failed,
	unavailable,
};

fn isTruthy(value: []const u8) bool {
	return std.ascii.eqlIgnoreCase(value, "1") or std.ascii.eqlIgnoreCase(value, "true") or
		std.ascii.eqlIgnoreCase(value, "yes") or std.ascii.eqlIgnoreCase(value, "on");
}

fn writeMkvDebugHeader(writer: std.fs.File, codec: VideoCodec, nal_length_size: u8, codec_private_len: usize) void {
	var buf: [256]u8 = undefined;
	const msg = std.fmt.bufPrint(
		&buf,
		"MKV debug context: codec={s} nal_length_size={} codec_private_len={}\n",
		.{ @tagName(codec), nal_length_size, codec_private_len },
	) catch return;
	_ = writer.writeAll(msg) catch {};
}

fn validateLengthPrefixedNals(sample_data: []const u8, nal_length_size: u8) bool {
	if (sample_data.len == 0) return false;

	var pos: usize = 0;
	var saw_nal = false;
	while (pos + nal_length_size <= sample_data.len) {
		var nal_len: u32 = 0;
		if (nal_length_size == 4) {
			nal_len = std.mem.readInt(u32, sample_data[pos..][0..4], .big);
		} else if (nal_length_size == 2) {
			nal_len = std.mem.readInt(u16, sample_data[pos..][0..2], .big);
		} else if (nal_length_size == 3) {
			nal_len = (@as(u32, sample_data[pos]) << 16) |
				(@as(u32, sample_data[pos + 1]) << 8) |
				@as(u32, sample_data[pos + 2]);
		} else if (nal_length_size == 1) {
			nal_len = sample_data[pos];
		} else {
			return false;
		}
		pos += nal_length_size;

		if (nal_len == 0) return false;
		if (pos + nal_len > sample_data.len) return false;

		pos += nal_len;
		saw_nal = true;
	}

	if (!saw_nal) return false;
	if (pos == sample_data.len) return true;
	return std.mem.allEqual(u8, sample_data[pos..], 0);
}

fn readLeb128(data: []const u8, start: usize) ?struct { value: u64, bytes: usize } {
	var value: u64 = 0;
	var shift: u6 = 0;
	var i: usize = start;

	while (i < data.len and shift <= 63) : (i += 1) {
		const byte = data[i];
		value |= (@as(u64, byte & 0x7f) << shift);
		if ((byte & 0x80) == 0) {
			return .{ .value = value, .bytes = (i - start) + 1 };
		}
		shift += 7;
	}
	return null;
}

fn validateAv1ObuStream(data: []const u8) bool {
	if (data.len == 0) return false;

	var pos: usize = 0;
	var saw_obu = false;
	while (pos < data.len) {
		const header = data[pos];
		pos += 1;

		const has_extension = (header & 0x04) != 0;
		const has_size = (header & 0x02) != 0;

		if (has_extension) {
			if (pos >= data.len) return false;
			pos += 1;
		}

		if (has_size) {
			const leb = readLeb128(data, pos) orelse return false;
			pos += leb.bytes;
			if (leb.value > data.len - pos) return false;
			pos += @intCast(leb.value);
		} else {
			// No size field: remainder is the OBU payload
			pos = data.len;
		}

		saw_obu = true;
	}

	return saw_obu;
}

fn validateAnnexBStream(data: []const u8) bool {
	if (data.len < 4) return false;

	var pos: usize = 0;
	var saw_start = false;
	var last_start_end: usize = 0;

	while (pos + 3 <= data.len) {
		var start: ?struct { offset: usize, size: usize } = null;
		var i: usize = pos;
		while (i + 3 <= data.len) : (i += 1) {
			if (i + 4 <= data.len and data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 0 and data[i + 3] == 1) {
				start = .{ .offset = i, .size = 4 };
				break;
			}
			if (data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 1) {
				start = .{ .offset = i, .size = 3 };
				break;
			}
		}
		if (start == null) break;
		if (saw_start and start.?.offset == last_start_end) {
			return false; // empty NAL between start codes
		}
		saw_start = true;
		last_start_end = start.?.offset + start.?.size;
		pos = last_start_end;
	}

	return saw_start and last_start_end < data.len;
}

fn looksValidNalHeader(codec: VideoCodec, header: u8) bool {
	if ((header & 0x80) != 0) return false; // forbidden_zero_bit must be 0
	return switch (codec) {
		.h264 => (header & 0x1f) != 0,
		.hevc => ((header >> 1) & 0x3f) != 0,
		else => true,
	};
}

fn validateLengthPrefixedNalsFlexible(sample_data: []const u8, preferred_size: u8, codec: VideoCodec, mixed_out: *bool) bool {
	if (sample_data.len == 0) return false;

	const sizes = [_]u8{ preferred_size, 4, 3, 2, 1 };
	var pos: usize = 0;
	var saw_nal = false;
	var last_size: ?u8 = null;

	while (pos < sample_data.len) {
		var matched = false;
		for (sizes) |nal_length_size| {
			if (nal_length_size == 0 or nal_length_size > 4) continue;
			if (pos + nal_length_size > sample_data.len) continue;
			var nal_len: u32 = 0;
			if (nal_length_size == 4) {
				nal_len = std.mem.readInt(u32, sample_data[pos..][0..4], .big);
			} else if (nal_length_size == 2) {
				nal_len = std.mem.readInt(u16, sample_data[pos..][0..2], .big);
			} else if (nal_length_size == 3) {
				nal_len = (@as(u32, sample_data[pos]) << 16) |
					(@as(u32, sample_data[pos + 1]) << 8) |
					@as(u32, sample_data[pos + 2]);
			} else if (nal_length_size == 1) {
				nal_len = sample_data[pos];
			} else {
				continue;
			}

			const nal_start = pos + nal_length_size;
			if (nal_len == 0 or nal_start + nal_len > sample_data.len) continue;
			if (!looksValidNalHeader(codec, sample_data[nal_start])) continue;

			if (preferred_size != 0 and nal_length_size != preferred_size) {
				mixed_out.* = true;
			}
			if (last_size) |prev_size| {
				if (prev_size != nal_length_size) {
					mixed_out.* = true;
				}
			}
			last_size = nal_length_size;

			pos = nal_start + nal_len;
			saw_nal = true;
			matched = true;
			break;
		}

		if (!matched) {
			break;
		}
	}

	if (!saw_nal) return false;
	if (pos == sample_data.len) return true;
	return std.mem.allEqual(u8, sample_data[pos..], 0);
}

fn validateMkvNalFrame(data: []const u8, codec: VideoCodec, nal_length_size: u8, mixed_out: *bool) bool {
	if (nal_length_size != 0 and validateLengthPrefixedNals(data, nal_length_size)) return true;

	const fallback_sizes = [_]u8{ 4, 3, 2, 1 };
	for (fallback_sizes) |size| {
		if (size == nal_length_size) continue;
		if (validateLengthPrefixedNals(data, size)) {
			if (nal_length_size != 0 and size != nal_length_size) {
				mixed_out.* = true;
			}
			return true;
		}
	}

	if (codec == .h264 or codec == .hevc) {
		if (validateLengthPrefixedNalsFlexible(data, nal_length_size, codec, mixed_out)) return true;
	}
	return validateAnnexBStream(data);
}

fn validateMp4SamplesByteCoverage(
	allocator: Allocator,
	file: std.fs.File,
	sample_table: SampleTableInfo,
	video_codec: VideoCodec,
	nal_length_size: u8,
	max_frames: u32,
) ByteCoverageResult {
	const max_sample_size: u32 = 50 * 1024 * 1024; // 50MB max per sample

	// Precompute all sample locations in O(n) instead of O(n × stsc_entries)
	const locations = sample_table.getAllSampleLocations(allocator) orelse return .unavailable;
	defer allocator.free(locations);

	var sample_buffer: []u8 = allocator.alloc(u8, 1024 * 1024) catch return .unavailable;
	defer allocator.free(sample_buffer);

	var samples_checked: u32 = 0;
	for (locations) |location| {
		if (samples_checked >= max_frames) break;
		if (location.size == 0) continue;
		if (location.size > max_sample_size) return .unavailable;

		if (location.size > sample_buffer.len) {
			allocator.free(sample_buffer);
			sample_buffer = allocator.alloc(u8, location.size) catch return .unavailable;
		}

		file.seekTo(location.offset) catch return .failed;
		const bytes_read = file.read(sample_buffer[0..location.size]) catch return .failed;
		if (bytes_read < location.size) return .failed;

		const ok = switch (video_codec) {
			.av1 => validateAv1ObuStream(sample_buffer[0..location.size]),
			.h264, .hevc => validateLengthPrefixedNals(sample_buffer[0..location.size], nal_length_size),
			else => true,
		};
		if (!ok) return .failed;

		samples_checked += 1;
	}

	if (samples_checked == 0) return .failed;
	return .ok;
}

/// Parse stsz (sample size) box
fn parseStsz(allocator: Allocator, file: std.fs.File, box_offset: u64, box_size: u64) ?struct { sizes: []u32, default_size: u32, count: u32 } {
    _ = box_size;
    // stsz format: version(1) + flags(3) + sample_size(4) + sample_count(4) + [sizes if sample_size==0]
    file.seekTo(box_offset + 8) catch return null; // Skip box header

    var header: [12]u8 = undefined;
    if ((file.read(&header) catch return null) < 12) return null;

    const default_size = std.mem.readInt(u32, header[4..8], .big);
    const sample_count = std.mem.readInt(u32, header[8..12], .big);

    if (default_size > 0) {
        // All samples same size - no need to read individual sizes
        return .{ .sizes = &[_]u32{}, .default_size = default_size, .count = sample_count };
    }

    // Read individual sample sizes
    const sizes = allocator.alloc(u32, sample_count) catch return null;
    errdefer allocator.free(sizes);

    for (0..sample_count) |i| {
        var size_buf: [4]u8 = undefined;
        if ((file.read(&size_buf) catch {
            allocator.free(sizes);
            return null;
        }) < 4) {
            allocator.free(sizes);
            return null;
        }
        sizes[i] = std.mem.readInt(u32, &size_buf, .big);
    }

    return .{ .sizes = sizes, .default_size = 0, .count = sample_count };
}

/// Parse stss (sync sample) box - identifies keyframes
fn parseStss(allocator: Allocator, file: std.fs.File, box_offset: u64, box_size: u64) ?[]u32 {
    _ = box_size;
    // stss format: version(1) + flags(3) + entry_count(4) + entries[]
    file.seekTo(box_offset + 8) catch return null; // Skip box header

    var header: [8]u8 = undefined;
    if ((file.read(&header) catch return null) < 8) return null;

    const entry_count = std.mem.readInt(u32, header[4..8], .big);

    // Sanity check - don't allocate huge arrays
    if (entry_count > 10_000_000) return null;

    const entries = allocator.alloc(u32, entry_count) catch return null;
    errdefer allocator.free(entries);

    for (0..entry_count) |i| {
        var entry_buf: [4]u8 = undefined;
        if ((file.read(&entry_buf) catch {
            allocator.free(entries);
            return null;
        }) < 4) {
            allocator.free(entries);
            return null;
        }
        entries[i] = std.mem.readInt(u32, &entry_buf, .big);
    }

    return entries;
}

/// Parse stco (chunk offset) box - 32-bit offsets
fn parseStco(allocator: Allocator, file: std.fs.File, box_offset: u64, box_size: u64) ?[]u64 {
    _ = box_size;
    // stco format: version(1) + flags(3) + entry_count(4) + entries[]
    file.seekTo(box_offset + 8) catch return null;

    var header: [8]u8 = undefined;
    if ((file.read(&header) catch return null) < 8) return null;

    const entry_count = std.mem.readInt(u32, header[4..8], .big);
    if (entry_count > 10_000_000) return null;

    const entries = allocator.alloc(u64, entry_count) catch return null;
    errdefer allocator.free(entries);

    for (0..entry_count) |i| {
        var entry_buf: [4]u8 = undefined;
        if ((file.read(&entry_buf) catch {
            allocator.free(entries);
            return null;
        }) < 4) {
            allocator.free(entries);
            return null;
        }
        entries[i] = std.mem.readInt(u32, &entry_buf, .big);
    }

    return entries;
}

/// Parse co64 (chunk offset) box - 64-bit offsets
fn parseCo64(allocator: Allocator, file: std.fs.File, box_offset: u64, box_size: u64) ?[]u64 {
    _ = box_size;
    file.seekTo(box_offset + 8) catch return null;

    var header: [8]u8 = undefined;
    if ((file.read(&header) catch return null) < 8) return null;

    const entry_count = std.mem.readInt(u32, header[4..8], .big);
    if (entry_count > 10_000_000) return null;

    const entries = allocator.alloc(u64, entry_count) catch return null;
    errdefer allocator.free(entries);

    for (0..entry_count) |i| {
        var entry_buf: [8]u8 = undefined;
        if ((file.read(&entry_buf) catch {
            allocator.free(entries);
            return null;
        }) < 8) {
            allocator.free(entries);
            return null;
        }
        entries[i] = std.mem.readInt(u64, &entry_buf, .big);
    }

    return entries;
}

/// Parse stsc (sample-to-chunk) box
fn parseStsc(allocator: Allocator, file: std.fs.File, box_offset: u64, box_size: u64) ?[]SampleTableInfo.StscEntry {
    _ = box_size;
    file.seekTo(box_offset + 8) catch return null;

    var header: [8]u8 = undefined;
    if ((file.read(&header) catch return null) < 8) return null;

    const entry_count = std.mem.readInt(u32, header[4..8], .big);
    if (entry_count > 10_000_000) return null;

    const entries = allocator.alloc(SampleTableInfo.StscEntry, entry_count) catch return null;
    errdefer allocator.free(entries);

    for (0..entry_count) |i| {
        var entry_buf: [12]u8 = undefined;
        if ((file.read(&entry_buf) catch {
            allocator.free(entries);
            return null;
        }) < 12) {
            allocator.free(entries);
            return null;
        }
        entries[i] = .{
            .first_chunk = std.mem.readInt(u32, entry_buf[0..4], .big),
            .samples_per_chunk = std.mem.readInt(u32, entry_buf[4..8], .big),
            .sample_description_index = std.mem.readInt(u32, entry_buf[8..12], .big),
        };
    }

    return entries;
}

/// Parse all sample table boxes from stbl container
fn parseSampleTable(allocator: Allocator, file: std.fs.File, stbl_offset: u64, stbl_size: u64, stbl_header_size: u8) ?SampleTableInfo {
    const stbl_data_start = stbl_offset + stbl_header_size;
    const stbl_end = stbl_offset + stbl_size;

    var sample_sizes: []u32 = &[_]u32{};
    var default_sample_size: u32 = 0;
    var sample_count: u32 = 0;
    var sync_samples: []u32 = &[_]u32{};
    var chunk_offsets: []u64 = &[_]u64{};
    var stsc_entries: []SampleTableInfo.StscEntry = &[_]SampleTableInfo.StscEntry{};

    // Iterate through stbl children
    file.seekTo(stbl_data_start) catch return null;

    while ((file.getPos() catch return null) < stbl_end) {
        const box = readMp4BoxHeader(file) orelse break;

        if (std.mem.eql(u8, &box.box_type, "stsz")) {
            if (parseStsz(allocator, file, box.offset, box.size)) |result| {
                sample_sizes = result.sizes;
                default_sample_size = result.default_size;
                sample_count = result.count;
            }
        } else if (std.mem.eql(u8, &box.box_type, "stss")) {
            if (parseStss(allocator, file, box.offset, box.size)) |result| {
                sync_samples = result;
            }
        } else if (std.mem.eql(u8, &box.box_type, "stco")) {
            if (parseStco(allocator, file, box.offset, box.size)) |result| {
                chunk_offsets = result;
            }
        } else if (std.mem.eql(u8, &box.box_type, "co64")) {
            if (parseCo64(allocator, file, box.offset, box.size)) |result| {
                chunk_offsets = result;
            }
        } else if (std.mem.eql(u8, &box.box_type, "stsc")) {
            if (parseStsc(allocator, file, box.offset, box.size)) |result| {
                stsc_entries = result;
            }
        }

        file.seekTo(box.offset + box.size) catch break;
    }

    // Must have at least sample sizes/count and chunk offsets
    if (sample_count == 0 or chunk_offsets.len == 0) {
        if (sample_sizes.len > 0) allocator.free(sample_sizes);
        if (sync_samples.len > 0) allocator.free(sync_samples);
        if (chunk_offsets.len > 0) allocator.free(chunk_offsets);
        if (stsc_entries.len > 0) allocator.free(stsc_entries);
        return null;
    }

    return SampleTableInfo{
        .sample_sizes = sample_sizes,
        .default_sample_size = default_sample_size,
        .sample_count = sample_count,
        .sync_samples = sync_samples,
        .chunk_offsets = chunk_offsets,
        .stsc_entries = stsc_entries,
        .allocator = allocator,
    };
}

/// Extract NAL units from a sample and convert to Annex B format
/// MP4 uses length-prefixed NAL units (usually 4-byte length), Annex B uses start codes
fn convertToAnnexB(allocator: Allocator, sample_data: []const u8, nal_length_size: u8) ?[]u8 {
    if (sample_data.len == 0) return null;

    // Estimate output size (start codes are 4 bytes vs length prefix)
    var output: std.ArrayListUnmanaged(u8) = .{};
    errdefer output.deinit(allocator);

    var pos: usize = 0;
    while (pos + nal_length_size <= sample_data.len) {
        // Read NAL unit length
        var nal_len: u32 = 0;
        if (nal_length_size == 4) {
            nal_len = std.mem.readInt(u32, sample_data[pos..][0..4], .big);
        } else if (nal_length_size == 2) {
            nal_len = std.mem.readInt(u16, sample_data[pos..][0..2], .big);
        } else if (nal_length_size == 3) {
            nal_len = (@as(u32, sample_data[pos]) << 16) |
                (@as(u32, sample_data[pos + 1]) << 8) |
                @as(u32, sample_data[pos + 2]);
        } else if (nal_length_size == 1) {
            nal_len = sample_data[pos];
        } else {
            return null;
        }
        pos += nal_length_size;

        if (pos + nal_len > sample_data.len) break;

        // Write Annex B start code (0x00000001)
        output.appendSlice(allocator, &[_]u8{ 0x00, 0x00, 0x00, 0x01 }) catch return null;
        // Write NAL unit data
        output.appendSlice(allocator, sample_data[pos .. pos + nal_len]) catch return null;

        pos += nal_len;
    }

    if (output.items.len == 0) return null;
    return output.toOwnedSlice(allocator) catch return null;
}

/// Extract codec private data (SPS/PPS for H.264/HEVC) and convert to Annex B
fn extractCodecPrivate(allocator: Allocator, file: std.fs.File, stsd_offset: u64, codec: VideoCodec) ?CodecPrivateData {
    // Skip stsd header (8 bytes) + version/flags (4 bytes) + entry count (4 bytes)
    file.seekTo(stsd_offset + 16) catch return null;

    // Read sample entry header (8 bytes: size + type like "avc1"/"hvc1")
    var entry_header: [8]u8 = undefined;
    if ((file.read(&entry_header) catch return null) < 8) return null;

    const entry_size = std.mem.readInt(u32, entry_header[0..4], .big);
    const entry_end = stsd_offset + 16 + entry_size;

    // Skip to codec-specific box (avcC or hvcC)
    // After the 8-byte entry header, VisualSampleEntry has 78 bytes of data before codec config
    // Total: stsd_offset + 16 (stsd header+ver+count) + 8 (entry header) + 78 (visual sample entry) = stsd_offset + 102
    file.seekTo(stsd_offset + 16 + 8 + 78) catch return null;

    while ((file.getPos() catch return null) < entry_end) {
        const box = readMp4BoxHeader(file) orelse break;

        const is_avc_config = std.mem.eql(u8, &box.box_type, "avcC") and codec == .h264;
        const is_hevc_config = std.mem.eql(u8, &box.box_type, "hvcC") and codec == .hevc;
        const is_av1_config = std.mem.eql(u8, &box.box_type, "av1C") and codec == .av1;

        if (is_avc_config) {
            return parseAvcC(allocator, file, box.offset, box.size);
        } else if (is_hevc_config) {
            return parseHvcC(allocator, file, box.offset, box.size);
        } else if (is_av1_config) {
            // AV1 config sequence header - just return raw data
            return parseAv1C(allocator, file, box.offset, box.size);
        }

        file.seekTo(box.offset + box.size) catch break;
    }

    return null;
}

/// Parse avcC (AVC decoder configuration) and extract SPS/PPS as Annex B
fn parseAvcC(allocator: Allocator, file: std.fs.File, box_offset: u64, box_size: u64) ?CodecPrivateData {
    _ = box_size;
    file.seekTo(box_offset + 8) catch return null; // Skip box header

    // avcC format:
    // configurationVersion (1)
    // AVCProfileIndication (1)
    // profile_compatibility (1)
    // AVCLevelIndication (1)
    // lengthSizeMinusOne (1) - lower 2 bits
    // numOfSequenceParameterSets (1) - lower 5 bits
    // for each SPS: length (2) + data
    // numOfPictureParameterSets (1)
    // for each PPS: length (2) + data

    var header: [6]u8 = undefined;
    if ((file.read(&header) catch return null) < 6) return null;

    const profile_idc: u8 = header[1]; // AVCProfileIndication
    const nal_length_size: u8 = (header[4] & 0x03) + 1;
    const num_sps = header[5] & 0x1F;

    var output: std.ArrayListUnmanaged(u8) = .{};
    errdefer output.deinit(allocator);

    // Read SPS units
    for (0..num_sps) |_| {
        var len_buf: [2]u8 = undefined;
        if ((file.read(&len_buf) catch return null) < 2) return null;
        const sps_len = std.mem.readInt(u16, &len_buf, .big);

        const sps_data = allocator.alloc(u8, sps_len) catch return null;
        defer allocator.free(sps_data);

        if ((file.read(sps_data) catch return null) < sps_len) return null;

        // Write with start code
        output.appendSlice(allocator, &[_]u8{ 0x00, 0x00, 0x00, 0x01 }) catch return null;
        output.appendSlice(allocator, sps_data) catch return null;
    }

    // Read num PPS
    var pps_count_buf: [1]u8 = undefined;
    if ((file.read(&pps_count_buf) catch return null) < 1) return null;
    const num_pps = pps_count_buf[0];

    // Read PPS units
    for (0..num_pps) |_| {
        var len_buf: [2]u8 = undefined;
        if ((file.read(&len_buf) catch return null) < 2) return null;
        const pps_len = std.mem.readInt(u16, &len_buf, .big);

        const pps_data = allocator.alloc(u8, pps_len) catch return null;
        defer allocator.free(pps_data);

        if ((file.read(pps_data) catch return null) < pps_len) return null;

        output.appendSlice(allocator, &[_]u8{ 0x00, 0x00, 0x00, 0x01 }) catch return null;
        output.appendSlice(allocator, pps_data) catch return null;
    }

    return CodecPrivateData{
        .data = output.toOwnedSlice(allocator) catch return null,
        .nal_length_size = nal_length_size,
        .h264_profile = profile_idc,
    };
}

/// Parse hvcC (HEVC decoder configuration) and extract VPS/SPS/PPS as Annex B
fn parseHvcC(allocator: Allocator, file: std.fs.File, box_offset: u64, box_size: u64) ?CodecPrivateData {
    _ = box_size;
    file.seekTo(box_offset + 8) catch return null; // Skip box header

    // hvcC format is more complex - simplified parsing
    // First 22 bytes are configuration, then NAL unit arrays
    var header: [23]u8 = undefined;
    if ((file.read(&header) catch return null) < 23) return null;

    const nal_length_size: u8 = (header[21] & 0x03) + 1;
    const num_arrays = header[22];

    var output: std.ArrayListUnmanaged(u8) = .{};
    errdefer output.deinit(allocator);

    for (0..num_arrays) |_| {
        // Each array: array_completeness(1 bit) + reserved(1 bit) + NAL_unit_type(6 bits) + numNalus(2) + [len(2) + data]
        var array_header: [3]u8 = undefined;
        if ((file.read(&array_header) catch return null) < 3) return null;

        const num_nalus = std.mem.readInt(u16, array_header[1..3], .big);

        for (0..num_nalus) |_| {
            var len_buf: [2]u8 = undefined;
            if ((file.read(&len_buf) catch return null) < 2) return null;
            const nal_len = std.mem.readInt(u16, &len_buf, .big);

            const nal_data = allocator.alloc(u8, nal_len) catch return null;
            defer allocator.free(nal_data);

            if ((file.read(nal_data) catch return null) < nal_len) return null;

            output.appendSlice(allocator, &[_]u8{ 0x00, 0x00, 0x00, 0x01 }) catch return null;
            output.appendSlice(allocator, nal_data) catch return null;
        }
    }

    return CodecPrivateData{
        .data = output.toOwnedSlice(allocator) catch return null,
        .nal_length_size = nal_length_size,
    };
}

/// Parse av1C (AV1 codec configuration) - returns config OBU
fn parseAv1C(allocator: Allocator, file: std.fs.File, box_offset: u64, box_size: u64) ?CodecPrivateData {
    file.seekTo(box_offset + 8) catch return null; // Skip box header

    // av1C has 4 bytes header then optional config OBUs
    const data_size = box_size - 8;
    if (data_size < 4 or data_size > 1024) return null;

    const data = allocator.alloc(u8, data_size) catch return null;
    errdefer allocator.free(data);

    if ((file.read(data) catch return null) < data_size) {
        allocator.free(data);
        return null;
    }

    // AV1 doesn't use length-prefixed NALs
    return CodecPrivateData{ .data = data, .nal_length_size = 0 };
}

/// Parse avcC from MKV codec_private buffer (same format as MP4 avcC box content)
fn parseMkvAvcC(allocator: Allocator, data: []const u8) ?CodecPrivateData {
    if (data.len < 6) return null;

    // avcC format (without box header):
    // configurationVersion (1) + AVCProfileIndication (1) + profile_compatibility (1)
    // + AVCLevelIndication (1) + lengthSizeMinusOne (1) + numOfSPS (1) + SPS data...

    const nal_length_size: u8 = (data[4] & 0x03) + 1;
    const num_sps = data[5] & 0x1F;

    var output: std.ArrayListUnmanaged(u8) = .{};
    errdefer output.deinit(allocator);

    var pos: usize = 6;

    // Read SPS units
    for (0..num_sps) |_| {
        if (pos + 2 > data.len) break;
        const sps_len = std.mem.readInt(u16, data[pos..][0..2], .big);
        pos += 2;
        if (pos + sps_len > data.len) break;

        output.appendSlice(allocator, &[_]u8{ 0x00, 0x00, 0x00, 0x01 }) catch return null;
        output.appendSlice(allocator, data[pos .. pos + sps_len]) catch return null;
        pos += sps_len;
    }

    if (pos >= data.len) return null;
    const num_pps = data[pos];
    pos += 1;

    // Read PPS units
    for (0..num_pps) |_| {
        if (pos + 2 > data.len) break;
        const pps_len = std.mem.readInt(u16, data[pos..][0..2], .big);
        pos += 2;
        if (pos + pps_len > data.len) break;

        output.appendSlice(allocator, &[_]u8{ 0x00, 0x00, 0x00, 0x01 }) catch return null;
        output.appendSlice(allocator, data[pos .. pos + pps_len]) catch return null;
        pos += pps_len;
    }

    if (output.items.len == 0) return null;

    return CodecPrivateData{
        .data = output.toOwnedSlice(allocator) catch return null,
        .nal_length_size = nal_length_size,
    };
}

/// Parse hvcC from MKV codec_private buffer (same format as MP4 hvcC box content)
fn parseMkvHvcC(allocator: Allocator, data: []const u8) ?CodecPrivateData {
    if (data.len < 23) return null;

    // hvcC format (without box header):
    // First 22 bytes are configuration, then NAL unit arrays
    const nal_length_size: u8 = (data[21] & 0x03) + 1;
    const num_arrays = data[22];

    var output: std.ArrayListUnmanaged(u8) = .{};
    errdefer output.deinit(allocator);

    var pos: usize = 23;

    for (0..num_arrays) |_| {
        if (pos + 3 > data.len) break;

        // NAL unit type (1 byte) + numNalus (2 bytes)
        const num_nalus = std.mem.readInt(u16, data[pos + 1 ..][0..2], .big);
        pos += 3;

        for (0..num_nalus) |_| {
            if (pos + 2 > data.len) break;
            const nal_len = std.mem.readInt(u16, data[pos..][0..2], .big);
            pos += 2;
            if (pos + nal_len > data.len) break;

            output.appendSlice(allocator, &[_]u8{ 0x00, 0x00, 0x00, 0x01 }) catch return null;
            output.appendSlice(allocator, data[pos .. pos + nal_len]) catch return null;
            pos += nal_len;
        }
    }

    if (output.items.len == 0) return null;

    return CodecPrivateData{
        .data = output.toOwnedSlice(allocator) catch return null,
        .nal_length_size = nal_length_size,
    };
}

// ============ Motion JPEG Validation ============

/// Validate Motion JPEG from MP4/MOV container.
/// Each frame in MJPEG is a complete JPEG image.
fn validateMjpegFromMp4(allocator: Allocator, file: std.fs.File, stbl: Mp4Box, max_frames: u32) VideoValidationResult {
    // Parse sample table for frame extraction
    var sample_table = parseSampleTable(allocator, file, stbl.offset, stbl.size, stbl.header_size) orelse {
        return VideoValidationResult.invalid("Failed to parse sample tables", .mjpeg);
    };
    defer sample_table.deinit();

    if (sample_table.sample_count == 0) {
        return VideoValidationResult.invalid("No samples found in MJPEG track", .mjpeg);
    }

    // For MJPEG, every frame is a keyframe (intra-only codec)
    // Validate up to max_frames samples
    var frames_validated: u32 = 0;
    const frames_to_check = @min(sample_table.sample_count, max_frames);

    // Allocate a buffer for reading frames (reuse for efficiency)
    // Find max sample size to allocate buffer
    var max_sample_size: u32 = sample_table.default_sample_size;
    if (max_sample_size == 0 and sample_table.sample_sizes.len > 0) {
        for (sample_table.sample_sizes) |size| {
            if (size > max_sample_size) max_sample_size = size;
        }
    }
    if (max_sample_size == 0 or max_sample_size > 100 * 1024 * 1024) {
        // Sanity check - 100MB max per frame
        return VideoValidationResult.invalid("Invalid sample sizes", .mjpeg);
    }

    const frame_buffer = allocator.alloc(u8, max_sample_size) catch {
        return VideoValidationResult.invalid("Memory allocation failed", .mjpeg);
    };
    defer allocator.free(frame_buffer);

    // Validate frames (sample evenly if more than max_frames)
    const step = if (sample_table.sample_count > max_frames)
        sample_table.sample_count / max_frames
    else
        1;

    var sample_index: u32 = 0;
    while (sample_index < sample_table.sample_count and frames_validated < frames_to_check) {
        const location = sample_table.getSampleLocation(sample_index) orelse {
            sample_index += step;
            continue;
        };

        if (location.size > max_sample_size) {
            sample_index += step;
            continue;
        }

        // Read the frame
        file.seekTo(location.offset) catch {
            return VideoValidationResult.invalid("Failed to seek to frame", .mjpeg);
        };
        const bytes_read = file.read(frame_buffer[0..location.size]) catch {
            return VideoValidationResult.invalid("Failed to read frame", .mjpeg);
        };
        if (bytes_read != location.size) {
            return VideoValidationResult.invalid("Incomplete frame read", .mjpeg);
        }

        // Validate as JPEG
        const jpeg_result = jpeg.validateJpegDeepFromBuffer(frame_buffer[0..location.size]);
        if (!jpeg_result.valid) {
            return VideoValidationResult.invalid(jpeg_result.error_message orelse "Invalid JPEG frame", .mjpeg);
        }

        frames_validated += 1;
        sample_index += step;
    }

    if (frames_validated == 0) {
        return VideoValidationResult.invalid("No valid MJPEG frames found", .mjpeg);
    }

    return VideoValidationResult.okByteValidated(.mjpeg, frames_validated);
}

/// Validate ProRes from MP4/MOV container.
fn validateProResFromMp4(allocator: Allocator, file: std.fs.File, stbl: Mp4Box, max_frames: u32) VideoValidationResult {
    // Parse sample table for frame extraction
    var sample_table = parseSampleTable(allocator, file, stbl.offset, stbl.size, stbl.header_size) orelse {
        return VideoValidationResult.invalid("Failed to parse sample tables", .prores);
    };
    defer sample_table.deinit();

    if (sample_table.sample_count == 0) {
        return VideoValidationResult.invalid("No samples found in ProRes track", .prores);
    }

    // ProRes is intra-frame only, so every frame is a keyframe
    // Validate up to max_frames samples
    var frames_validated: u32 = 0;
    const frames_to_check = @min(sample_table.sample_count, max_frames);

    // Find max sample size to allocate buffer
    var max_sample_size: u32 = sample_table.default_sample_size;
    if (max_sample_size == 0 and sample_table.sample_sizes.len > 0) {
        for (sample_table.sample_sizes) |size| {
            if (size > max_sample_size) max_sample_size = size;
        }
    }
    if (max_sample_size == 0 or max_sample_size > 100 * 1024 * 1024) {
        // Sanity check - 100MB max per frame
        return VideoValidationResult.invalid("Invalid sample sizes", .prores);
    }

    const frame_buffer = allocator.alloc(u8, max_sample_size) catch {
        return VideoValidationResult.invalid("Memory allocation failed", .prores);
    };
    defer allocator.free(frame_buffer);

    // Determine step for evenly distributed sampling
    const step: u32 = if (frames_to_check < sample_table.sample_count)
        sample_table.sample_count / frames_to_check
    else
        1;

    var sample_index: u32 = 0;
    while (sample_index < sample_table.sample_count and frames_validated < frames_to_check) {
        const location = sample_table.getSampleLocation(sample_index) orelse {
            sample_index += step;
            continue;
        };

        if (location.size > max_sample_size or location.size < 28) {
            sample_index += step;
            continue;
        }

        // Read frame data
        file.seekTo(location.offset) catch {
            sample_index += step;
            continue;
        };
        const bytes_read = file.read(frame_buffer[0..location.size]) catch {
            return VideoValidationResult.invalid("Failed to read frame", .prores);
        };
        if (bytes_read != location.size) {
            return VideoValidationResult.invalid("Incomplete frame read", .prores);
        }

        // Validate as ProRes (deep validation with DCT decode)
        const deep_result = prores.validateProResFrameDeep(frame_buffer[0..location.size]);
        if (!deep_result.valid) {
            // Fall back to structural validation for compatibility
            const header = prores.validateProResFrame(frame_buffer[0..location.size]) orelse {
                return VideoValidationResult.invalid("Invalid ProRes frame", .prores);
            };
            _ = header;
        }

        frames_validated += 1;
        sample_index += step;
    }

    if (frames_validated == 0) {
        return VideoValidationResult.invalid("No valid ProRes frames found", .prores);
    }

    return VideoValidationResult.okByteValidated(.prores, frames_validated);
}

/// Validate MPEG-1/2 from MP4/MOV container.
fn validateMpeg12FromMp4(allocator: Allocator, file: std.fs.File, stbl: Mp4Box, max_frames: u32, codec: VideoCodec) VideoValidationResult {
    // Parse sample table for frame extraction
    var sample_table = parseSampleTable(allocator, file, stbl.offset, stbl.size, stbl.header_size) orelse {
        return VideoValidationResult.invalid("Failed to parse sample tables", codec);
    };
    defer sample_table.deinit();

    if (sample_table.sample_count == 0) {
        return VideoValidationResult.invalid("No samples found in MPEG track", codec);
    }

    // For MPEG-1/2 in MP4, each sample is typically a frame with start codes
    // We'll extract keyframes (I-frames) and validate them
    const frames_to_check = @min(sample_table.sample_count, max_frames);

    // Find max sample size to allocate buffer
    var max_sample_size: u32 = sample_table.default_sample_size;
    if (max_sample_size == 0 and sample_table.sample_sizes.len > 0) {
        for (sample_table.sample_sizes) |size| {
            if (size > max_sample_size) max_sample_size = size;
        }
    }
    if (max_sample_size == 0 or max_sample_size > 50 * 1024 * 1024) {
        // Sanity check - 50MB max per frame
        return VideoValidationResult.invalid("Invalid sample sizes", codec);
    }

    const frame_buffer = allocator.alloc(u8, max_sample_size) catch {
        return VideoValidationResult.invalid("Memory allocation failed", codec);
    };
    defer allocator.free(frame_buffer);

    // Collect all sync samples (keyframes) into a buffer for validation
    var bitstream: std.ArrayListUnmanaged(u8) = .{};
    defer bitstream.deinit(allocator);

    var keyframes_extracted: u32 = 0;
    for (0..sample_table.sample_count) |sample_idx| {
        if (keyframes_extracted >= frames_to_check) break;

        if (!sample_table.isSyncSample(@intCast(sample_idx))) continue;

        const location = sample_table.getSampleLocation(@intCast(sample_idx)) orelse continue;
        if (location.size > max_sample_size) continue;

        // Read sample data
        file.seekTo(location.offset) catch continue;
        const bytes_read = file.read(frame_buffer[0..location.size]) catch continue;
        if (bytes_read != location.size) continue;

        // Append to bitstream (MPEG-1/2 samples contain start codes)
        bitstream.appendSlice(allocator, frame_buffer[0..location.size]) catch continue;
        keyframes_extracted += 1;
    }

    if (bitstream.items.len == 0) {
        return VideoValidationResult.invalid("No keyframes extracted", codec);
    }

    // Validate the combined bitstream with deep DCT decode
    const result = mpeg12.validateMpeg12Deep(bitstream.items, max_frames);
    if (!result.valid) {
        return VideoValidationResult.invalid(result.error_message orelse "Invalid MPEG video", codec);
    }

    // Return with appropriate codec based on detection
    const detected_codec: VideoCodec = switch (result.structural_result.version) {
        .mpeg1 => .mpeg1,
        .mpeg2 => .mpeg2,
        .unknown => codec,
    };

    return VideoValidationResult.okByteValidated(detected_codec, result.structural_result.pictures);
}

// Tests
test "HEVC stream validation rejects garbage" {
    const garbage = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22, 0x33 };
    const result = validateHevcStream(&garbage, 1);
    try std.testing.expect(!result.valid or result.frames_decoded == 0);
}

test "AV1 stream validation rejects garbage" {
    const garbage = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22, 0x33 };
    const result = validateAv1Stream(std.testing.allocator, &garbage, 1);
    try std.testing.expect(!result.valid or result.frames_decoded == 0);
}

test "H.264 stream validation rejects garbage" {
    const garbage = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22, 0x33 };
    const result = validateH264Stream(&garbage, 1);
    try std.testing.expect(result.codec == .h264);
    try std.testing.expect(!result.valid or result.frames_decoded == 0);
}

test "parseMkvAvcC extracts SPS/PPS with start codes" {
    // Minimal avcC structure: version(1) + profile(1) + compat(1) + level(1)
    // + lengthSize(1: 0xff=4bytes) + numSPS(1: 0xe1=1) + SPSlen(2) + SPS + numPPS(1) + PPSlen(2) + PPS
    const avcc = [_]u8{
        0x01, // version
        0x64, // profile (High)
        0x00, // compatibility
        0x1f, // level
        0xff, // length size minus 1 = 3, so 4 bytes
        0xe1, // 1 SPS
        0x00, 0x04, // SPS length = 4
        0x67, 0x64, 0x00, 0x1f, // SPS data (fake)
        0x01, // 1 PPS
        0x00, 0x02, // PPS length = 2
        0x68, 0xee, // PPS data (fake)
    };

    const result = parseMkvAvcC(std.testing.allocator, &avcc);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.data);

    try std.testing.expectEqual(@as(u8, 4), result.?.nal_length_size);
    // Should have: start_code(4) + SPS(4) + start_code(4) + PPS(2) = 14 bytes
    try std.testing.expectEqual(@as(usize, 14), result.?.data.len);
    // Verify start codes
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x00, 0x01 }, result.?.data[0..4]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x00, 0x01 }, result.?.data[8..12]);
}

test "convertToAnnexB converts length-prefixed NALs" {
    // 4-byte length prefix format: length(4) + nal_data
    const input = [_]u8{
        0x00, 0x00, 0x00, 0x04, // length = 4
        0x67, 0x64, 0x00, 0x1f, // NAL data
        0x00, 0x00, 0x00, 0x02, // length = 2
        0x68, 0xee, // NAL data
    };

    const result = convertToAnnexB(std.testing.allocator, &input, 4);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?);

    // Should have: start_code(4) + nal(4) + start_code(4) + nal(2) = 14 bytes
    try std.testing.expectEqual(@as(usize, 14), result.?.len);
    // Verify start codes
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x00, 0x01 }, result.?[0..4]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x00, 0x01 }, result.?[8..12]);
}

test "convertToAnnexB converts 3-byte length-prefixed NALs" {
	const input = [_]u8{
		0x00, 0x00, 0x02, // length = 2
		0x65, 0x88, // NAL data
	};

	const result = convertToAnnexB(std.testing.allocator, &input, 3);
	try std.testing.expect(result != null);
	defer std.testing.allocator.free(result.?);

	try std.testing.expectEqual(@as(usize, 6), result.?.len);
	try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x00, 0x01, 0x65, 0x88 }, result.?);
}

test "validateLengthPrefixedNals accepts valid NAL data" {
	const data = [_]u8{
		0x00, 0x00, 0x00, 0x02, 0xAA, 0xBB,
		0x00, 0x00, 0x00, 0x01, 0xCC,
	};
	try std.testing.expect(validateLengthPrefixedNals(&data, 4));
}

test "validateLengthPrefixedNals accepts 3-byte length prefix" {
	const data = [_]u8{
		0x00, 0x00, 0x02, 0x06, 0x05,
	};
	try std.testing.expect(validateLengthPrefixedNals(&data, 3));
}

test "validateLengthPrefixedNalsFlexible accepts mixed prefix sizes" {
	const data = [_]u8{
		0x00, 0x00, 0x02, 0x06, 0x11,
		0x00, 0x00, 0x00, 0x03, 0x65, 0x88, 0x99,
	};
	var mixed = false;
	try std.testing.expect(validateLengthPrefixedNalsFlexible(&data, 4, .h264, &mixed));
	try std.testing.expect(mixed);
}

test "validateLengthPrefixedNalsFlexible respects preferred size without mixed flag" {
	const data = [_]u8{
		0x00, 0x00, 0x00, 0x02, 0x06, 0x11,
		0x00, 0x00, 0x00, 0x03, 0x65, 0x88, 0x99,
	};
	var mixed = false;
	try std.testing.expect(validateLengthPrefixedNalsFlexible(&data, 4, .h264, &mixed));
	try std.testing.expect(!mixed);
}

test "validateLengthPrefixedNals rejects truncated NAL data" {
	const data = [_]u8{
		0x00, 0x00, 0x00, 0x03, 0xAA, 0xBB,
	};
	try std.testing.expect(!validateLengthPrefixedNals(&data, 4));
}

test "validateAv1ObuStream accepts sized OBU" {
	const data = [_]u8{ 0x02, 0x01, 0x00 };
	try std.testing.expect(validateAv1ObuStream(&data));
}

test "validateAv1ObuStream rejects oversized OBU" {
	const data = [_]u8{ 0x02, 0x05, 0x00 };
	try std.testing.expect(!validateAv1ObuStream(&data));
}

test "validateAnnexBStream accepts start codes" {
	const data = [_]u8{ 0x00, 0x00, 0x00, 0x01, 0x67, 0x11, 0x22 };
	try std.testing.expect(validateAnnexBStream(&data));
}

test "validateAnnexBStream accepts multiple NALs" {
	const data = [_]u8{ 0x00, 0x00, 0x00, 0x01, 0x67, 0x11, 0x22, 0x00, 0x00, 0x01, 0x68, 0x33 };
	try std.testing.expect(validateAnnexBStream(&data));
}

test "validateAnnexBStream rejects missing start codes" {
	const data = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
	try std.testing.expect(!validateAnnexBStream(&data));
}

test "validateAnnexBStream rejects empty NAL" {
	const data = [_]u8{ 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x01, 0x67 };
	try std.testing.expect(!validateAnnexBStream(&data));
}

// ============ SampleTableInfo.getSampleLocation Tests ============
// These tests verify correct sample-to-file-offset mapping for MP4/MOV containers.
// Critical for validating video frame extraction from containers.

test "getSampleLocation: uniform samples per chunk" {
    // Simple case: 3 chunks, 2 samples per chunk, fixed sample size
    // Chunk 0: samples 0,1 at offset 1000
    // Chunk 1: samples 2,3 at offset 2000
    // Chunk 2: samples 4,5 at offset 3000
    const allocator = std.testing.allocator;

    var stsc_entries = try allocator.alloc(SampleTableInfo.StscEntry, 1);
    defer allocator.free(stsc_entries);
    stsc_entries[0] = .{ .first_chunk = 1, .samples_per_chunk = 2, .sample_description_index = 1 };

    var chunk_offsets = try allocator.alloc(u64, 3);
    defer allocator.free(chunk_offsets);
    chunk_offsets[0] = 1000;
    chunk_offsets[1] = 2000;
    chunk_offsets[2] = 3000;

    const table = SampleTableInfo{
        .sample_sizes = &[_]u32{},
        .default_sample_size = 100, // Each sample is 100 bytes
        .sample_count = 6,
        .sync_samples = &[_]u32{},
        .chunk_offsets = chunk_offsets,
        .stsc_entries = stsc_entries,
        .allocator = allocator,
    };

    // Sample 0: chunk 0, offset 0 within chunk
    const loc0 = table.getSampleLocation(0).?;
    try std.testing.expectEqual(@as(u64, 1000), loc0.offset);
    try std.testing.expectEqual(@as(u32, 100), loc0.size);

    // Sample 1: chunk 0, offset 100 within chunk
    const loc1 = table.getSampleLocation(1).?;
    try std.testing.expectEqual(@as(u64, 1100), loc1.offset);

    // Sample 2: chunk 1, offset 0 within chunk
    const loc2 = table.getSampleLocation(2).?;
    try std.testing.expectEqual(@as(u64, 2000), loc2.offset);

    // Sample 3: chunk 1, offset 100 within chunk
    const loc3 = table.getSampleLocation(3).?;
    try std.testing.expectEqual(@as(u64, 2100), loc3.offset);

    // Sample 4: chunk 2, offset 0 within chunk
    const loc4 = table.getSampleLocation(4).?;
    try std.testing.expectEqual(@as(u64, 3000), loc4.offset);

    // Sample 5: chunk 2, offset 100 within chunk
    const loc5 = table.getSampleLocation(5).?;
    try std.testing.expectEqual(@as(u64, 3100), loc5.offset);

    // Out of bounds
    try std.testing.expect(table.getSampleLocation(6) == null);
}

test "getSampleLocation: variable samples per chunk" {
    // More complex: stsc changes samples_per_chunk mid-stream
    // Chunk 0 (first_chunk=1): 1 sample per chunk -> sample 0
    // Chunk 1 (first_chunk=2): 3 samples per chunk -> samples 1,2,3
    // Chunk 2: 3 samples per chunk -> samples 4,5,6
    const allocator = std.testing.allocator;

    var stsc_entries = try allocator.alloc(SampleTableInfo.StscEntry, 2);
    defer allocator.free(stsc_entries);
    stsc_entries[0] = .{ .first_chunk = 1, .samples_per_chunk = 1, .sample_description_index = 1 };
    stsc_entries[1] = .{ .first_chunk = 2, .samples_per_chunk = 3, .sample_description_index = 1 };

    var chunk_offsets = try allocator.alloc(u64, 3);
    defer allocator.free(chunk_offsets);
    chunk_offsets[0] = 1000;
    chunk_offsets[1] = 2000;
    chunk_offsets[2] = 5000;

    const table = SampleTableInfo{
        .sample_sizes = &[_]u32{},
        .default_sample_size = 500,
        .sample_count = 7,
        .sync_samples = &[_]u32{},
        .chunk_offsets = chunk_offsets,
        .stsc_entries = stsc_entries,
        .allocator = allocator,
    };

    // Sample 0: chunk 0 (1 sample)
    const loc0 = table.getSampleLocation(0).?;
    try std.testing.expectEqual(@as(u64, 1000), loc0.offset);

    // Sample 1: chunk 1 (3 samples), first sample
    const loc1 = table.getSampleLocation(1).?;
    try std.testing.expectEqual(@as(u64, 2000), loc1.offset);

    // Sample 2: chunk 1, second sample
    const loc2 = table.getSampleLocation(2).?;
    try std.testing.expectEqual(@as(u64, 2500), loc2.offset);

    // Sample 3: chunk 1, third sample
    const loc3 = table.getSampleLocation(3).?;
    try std.testing.expectEqual(@as(u64, 3000), loc3.offset);

    // Sample 4: chunk 2, first sample
    const loc4 = table.getSampleLocation(4).?;
    try std.testing.expectEqual(@as(u64, 5000), loc4.offset);

    // Sample 6: chunk 2, third sample
    const loc6 = table.getSampleLocation(6).?;
    try std.testing.expectEqual(@as(u64, 6000), loc6.offset);
}

test "getSampleLocation: variable sample sizes" {
    // Test with individual sample sizes instead of default
    const allocator = std.testing.allocator;

    var stsc_entries = try allocator.alloc(SampleTableInfo.StscEntry, 1);
    defer allocator.free(stsc_entries);
    stsc_entries[0] = .{ .first_chunk = 1, .samples_per_chunk = 3, .sample_description_index = 1 };

    var chunk_offsets = try allocator.alloc(u64, 2);
    defer allocator.free(chunk_offsets);
    chunk_offsets[0] = 1000;
    chunk_offsets[1] = 2000;

    var sample_sizes = try allocator.alloc(u32, 6);
    defer allocator.free(sample_sizes);
    sample_sizes[0] = 100;
    sample_sizes[1] = 200;
    sample_sizes[2] = 150;
    sample_sizes[3] = 300;
    sample_sizes[4] = 250;
    sample_sizes[5] = 175;

    const table = SampleTableInfo{
        .sample_sizes = sample_sizes,
        .default_sample_size = 0, // Use individual sizes
        .sample_count = 6,
        .sync_samples = &[_]u32{},
        .chunk_offsets = chunk_offsets,
        .stsc_entries = stsc_entries,
        .allocator = allocator,
    };

    // Sample 0: chunk 0, offset 0
    const loc0 = table.getSampleLocation(0).?;
    try std.testing.expectEqual(@as(u64, 1000), loc0.offset);
    try std.testing.expectEqual(@as(u32, 100), loc0.size);

    // Sample 1: chunk 0, offset = size of sample 0 = 100
    const loc1 = table.getSampleLocation(1).?;
    try std.testing.expectEqual(@as(u64, 1100), loc1.offset);
    try std.testing.expectEqual(@as(u32, 200), loc1.size);

    // Sample 2: chunk 0, offset = 100 + 200 = 300
    const loc2 = table.getSampleLocation(2).?;
    try std.testing.expectEqual(@as(u64, 1300), loc2.offset);
    try std.testing.expectEqual(@as(u32, 150), loc2.size);

    // Sample 3: chunk 1, first sample
    const loc3 = table.getSampleLocation(3).?;
    try std.testing.expectEqual(@as(u64, 2000), loc3.offset);
    try std.testing.expectEqual(@as(u32, 300), loc3.size);
}

test "getSampleLocation: single chunk with many samples" {
    // Edge case: all samples in one chunk
    const allocator = std.testing.allocator;

    var stsc_entries = try allocator.alloc(SampleTableInfo.StscEntry, 1);
    defer allocator.free(stsc_entries);
    stsc_entries[0] = .{ .first_chunk = 1, .samples_per_chunk = 1000, .sample_description_index = 1 };

    var chunk_offsets = try allocator.alloc(u64, 1);
    defer allocator.free(chunk_offsets);
    chunk_offsets[0] = 5000;

    const table = SampleTableInfo{
        .sample_sizes = &[_]u32{},
        .default_sample_size = 50,
        .sample_count = 1000,
        .sync_samples = &[_]u32{},
        .chunk_offsets = chunk_offsets,
        .stsc_entries = stsc_entries,
        .allocator = allocator,
    };

    // First sample
    const loc0 = table.getSampleLocation(0).?;
    try std.testing.expectEqual(@as(u64, 5000), loc0.offset);

    // Sample 500
    const loc500 = table.getSampleLocation(500).?;
    try std.testing.expectEqual(@as(u64, 5000 + 500 * 50), loc500.offset);

    // Last sample
    const loc999 = table.getSampleLocation(999).?;
    try std.testing.expectEqual(@as(u64, 5000 + 999 * 50), loc999.offset);
}

test "getSampleLocation: many chunks one sample each" {
    // Edge case: 1000 chunks, 1 sample each (like some audio tracks)
    const allocator = std.testing.allocator;

    var stsc_entries = try allocator.alloc(SampleTableInfo.StscEntry, 1);
    defer allocator.free(stsc_entries);
    stsc_entries[0] = .{ .first_chunk = 1, .samples_per_chunk = 1, .sample_description_index = 1 };

    var chunk_offsets = try allocator.alloc(u64, 1000);
    defer allocator.free(chunk_offsets);
    for (0..1000) |i| {
        chunk_offsets[i] = 1000 + i * 200; // Chunks at 1000, 1200, 1400, ...
    }

    const table = SampleTableInfo{
        .sample_sizes = &[_]u32{},
        .default_sample_size = 100,
        .sample_count = 1000,
        .sync_samples = &[_]u32{},
        .chunk_offsets = chunk_offsets,
        .stsc_entries = stsc_entries,
        .allocator = allocator,
    };

    // Sample 0 -> chunk 0
    const loc0 = table.getSampleLocation(0).?;
    try std.testing.expectEqual(@as(u64, 1000), loc0.offset);

    // Sample 500 -> chunk 500
    const loc500 = table.getSampleLocation(500).?;
    try std.testing.expectEqual(@as(u64, 1000 + 500 * 200), loc500.offset);

    // Sample 999 -> chunk 999
    const loc999 = table.getSampleLocation(999).?;
    try std.testing.expectEqual(@as(u64, 1000 + 999 * 200), loc999.offset);
}

test "getSampleLocation: performance with movie-sized sample table" {
    // Performance test: simulate a 2.5 hour movie at 24fps = 216,000 frames
    // With 10,000 chunks (typical), old O(chunks) would do 216K * 10K = 2.16B iterations
    // New O(stsc_entries) does 216K * ~3 = 648K iterations (3333x faster)
    const allocator = std.testing.allocator;

    const num_chunks: u32 = 10_000;

    // Typical movie has 2-3 stsc entries
    var stsc_entries = try allocator.alloc(SampleTableInfo.StscEntry, 3);
    defer allocator.free(stsc_entries);
    stsc_entries[0] = .{ .first_chunk = 1, .samples_per_chunk = 20, .sample_description_index = 1 };
    stsc_entries[1] = .{ .first_chunk = 1001, .samples_per_chunk = 22, .sample_description_index = 1 };
    stsc_entries[2] = .{ .first_chunk = 5001, .samples_per_chunk = 24, .sample_description_index = 1 };

    var chunk_offsets = try allocator.alloc(u64, num_chunks);
    defer allocator.free(chunk_offsets);
    for (0..num_chunks) |i| {
        chunk_offsets[i] = 1000 + i * 50000; // Each chunk ~50KB apart
    }

    // Recalculate actual total samples based on stsc entries
    // First 1000 chunks: 20 samples each = 20,000
    // Next 4000 chunks: 22 samples each = 88,000
    // Last 5000 chunks: 24 samples each = 120,000
    // Total: 228,000 samples
    const actual_total: u32 = 1000 * 20 + 4000 * 22 + 5000 * 24;

    const table = SampleTableInfo{
        .sample_sizes = &[_]u32{},
        .default_sample_size = 2000, // ~2KB per frame
        .sample_count = actual_total,
        .sync_samples = &[_]u32{},
        .chunk_offsets = chunk_offsets,
        .stsc_entries = stsc_entries,
        .allocator = allocator,
    };

    // Time lookups for all samples (or a representative subset)
    const start = std.time.nanoTimestamp();

    // Look up every 100th sample to keep test fast but representative
    var lookups: u32 = 0;
    var sample_idx: u32 = 0;
    while (sample_idx < actual_total) : (sample_idx += 100) {
        const loc = table.getSampleLocation(sample_idx);
        try std.testing.expect(loc != null);
        lookups += 1;
    }

    const elapsed = std.time.nanoTimestamp() - start;
    const elapsed_ms = @as(f64, @floatFromInt(elapsed)) / 1_000_000.0;

    // With optimized O(stsc_entries), this should complete in <100ms
    // Old O(chunks) version would take several seconds
    // We're doing ~2280 lookups; each should be O(3) not O(10000)
    try std.testing.expect(lookups > 2000); // Sanity check we did lookups
    try std.testing.expect(elapsed_ms < 500); // Should complete in <500ms

    // Verify correctness at boundaries
    // Sample 0 is in first chunk (stsc entry 0)
    const loc0 = table.getSampleLocation(0).?;
    try std.testing.expectEqual(@as(u64, 1000), loc0.offset);

    // Sample 20,000 is first sample of second stsc run (chunk 1001)
    const loc_run2 = table.getSampleLocation(20_000).?;
    try std.testing.expectEqual(@as(u64, 1000 + 1000 * 50000), loc_run2.offset);

    // Sample in third stsc run (after 20000 + 88000 = 108000)
    const loc_run3 = table.getSampleLocation(108_000).?;
    try std.testing.expectEqual(@as(u64, 1000 + 5000 * 50000), loc_run3.offset);
}

test "getAllSampleLocations matches getSampleLocation" {
    // Verify bulk computation matches individual lookups
    const allocator = std.testing.allocator;

    var stsc_entries = try allocator.alloc(SampleTableInfo.StscEntry, 2);
    defer allocator.free(stsc_entries);
    stsc_entries[0] = .{ .first_chunk = 1, .samples_per_chunk = 3, .sample_description_index = 1 };
    stsc_entries[1] = .{ .first_chunk = 3, .samples_per_chunk = 2, .sample_description_index = 1 };

    var chunk_offsets = try allocator.alloc(u64, 4);
    defer allocator.free(chunk_offsets);
    chunk_offsets[0] = 1000;
    chunk_offsets[1] = 2000;
    chunk_offsets[2] = 3000;
    chunk_offsets[3] = 4000;

    // Chunk 0: 3 samples, Chunk 1: 3 samples, Chunk 2: 2 samples, Chunk 3: 2 samples = 10 samples
    const table = SampleTableInfo{
        .sample_sizes = &[_]u32{},
        .default_sample_size = 100,
        .sample_count = 10,
        .sync_samples = &[_]u32{},
        .chunk_offsets = chunk_offsets,
        .stsc_entries = stsc_entries,
        .allocator = allocator,
    };

    const bulk_locations = table.getAllSampleLocations(allocator).?;
    defer allocator.free(bulk_locations);

    // Verify each bulk location matches individual lookup
    for (0..table.sample_count) |i| {
        const individual = table.getSampleLocation(@intCast(i)).?;
        try std.testing.expectEqual(individual.offset, bulk_locations[i].offset);
        try std.testing.expectEqual(individual.size, bulk_locations[i].size);
    }
}
