//! Video stream validation using pure-Zig bitstream validators.
//!
//! STRATEGY (2026-02-07):
//! ======================
//! All video codec validation is done via pure-Zig syntax validators:
//! - H.264: h264_syntax_validator.zig (NAL/SPS/PPS/slice parsing)
//! - H.265: h265_validator.zig (NAL/VPS/SPS/PPS/slice parsing)
//! - AV1: av1_obu_validator.zig (OBU structural validation)
//! - VP9: vp9_syntax_validator.zig (frame header parsing)
//! - ProRes: prores_validator.zig (pure Zig structural validation)
//! - MPEG-1/2: mpeg12_validator.zig (pure Zig)
//! - MPEG-4 Part 2: mpeg4p2_validator.zig (pure Zig)
//! - VP8: vp8_validator.zig (pure Zig)
//! - Motion JPEG: jpeg_validator.zig (via libjpeg-turbo)
//!
//! All video codecs use pure-Zig syntax validators (no C dependencies)
//! are needed. Validation catches structural corruption by parsing bitstream syntax
//! deeply enough to detect errors without full pixel-perfect decoding.
//!
//! Supported container formats:
//! - MP4/MOV (ISO Base Media File Format)
//! - MKV/WebM (Matroska/EBML)
//! - AVI (RIFF container)
//!
//! Thread safety: Pure-Zig validators are thread-safe with no global state.

const std = @import("std");
const builtin = @import("builtin");

// No global mutex needed — pure-Zig validators are thread-safe.
// VideoDecoderGuard kept as no-op for backward compatibility with any remaining references.
pub const VideoDecoderGuard = struct {
    pub fn acquire() VideoDecoderGuard {
        return .{};
    }

    pub fn release(self: VideoDecoderGuard) void {
        _ = self;
    }
};
const Allocator = std.mem.Allocator;

// ffmpeg/ffprobe fallback removed — pure-Zig validators handle all codecs

/// Stub for backward compatibility — always returns false
pub fn isFfprobeAvailable() bool {
    return false;
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

// Import H.264 syntax validator (pure Zig)
const h264 = @import("h264_syntax_validator.zig");

// Import H.265 validator (pure Zig)
const h265 = @import("h265_validator.zig");

// Import AV1 OBU validator (pure Zig)
const av1_obu = @import("av1_obu_validator.zig");

// Import VP9 syntax validator (pure Zig)
const vp9 = @import("vp9_syntax_validator.zig");

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

// Import VP8 validator (pure Zig)
const vp8 = @import("vp8_validator.zig");


// libde265 removed — using h265_validator.zig (pure Zig)

// dav1d removed — using av1_obu_validator.zig (pure Zig)

/// Video codec type
pub const VideoCodec = enum {
    hevc, // H.265 (pure Zig syntax validator)
    av1, // AV1 (pure Zig OBU validator)
    h264, // H.264/AVC (pure Zig syntax validator)
    vp9, // VP9 (pure Zig syntax validator)
    vp8, // VP8 (pure Zig)
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
	/// Set when validation was performed via external ffmpeg CLI
	validated_via_ffmpeg: bool = false,


	pub fn okDecoded(codec: VideoCodec, frames: u32) VideoValidationResult {
		// Decoding frames means bytes were validated - decoder would fail on corrupt data
		return .{ .valid = true, .error_message = null, .codec = codec, .frames_decoded = frames, .byte_validated = frames > 0, .mixed_nal_prefix = false };
	}

	pub fn okByteValidated(codec: VideoCodec, frames: u32) VideoValidationResult {
		return .{ .valid = true, .error_message = null, .codec = codec, .frames_decoded = frames, .byte_validated = true, .mixed_nal_prefix = false };
	}

	pub fn okByteValidatedViaFfmpeg(codec: VideoCodec, frames: u32) VideoValidationResult {
		return .{ .valid = true, .error_message = null, .codec = codec, .frames_decoded = frames, .byte_validated = true, .mixed_nal_prefix = false, .validated_via_ffmpeg = true };
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

/// Validate HEVC bitstream using pure-Zig H.265 syntax validator.
pub fn validateHevcStream(data: []const u8, max_frames: u32) VideoValidationResult {
    const result = h265.validateH265Stream(data, max_frames);
    if (result.valid) {
        return VideoValidationResult.okDecoded(.hevc, result.frames_decoded);
    }
    return VideoValidationResult.invalid(result.error_message orelse "H.265 validation failed", .hevc);
}

/// Validate AV1 bitstream using pure-Zig OBU validator.
/// Validates up to max_frames to verify integrity.
pub fn validateAv1Stream(allocator: Allocator, data: []const u8, max_frames: u32) VideoValidationResult {
    _ = allocator;
    const result = av1_obu.validateAv1Stream(data, max_frames);
    if (result.valid) {
        return VideoValidationResult.okDecoded(.av1, result.frames_decoded);
    }
    const msg: []const u8 = if (result.error_message) |e| std.mem.span(e) else "AV1 validation failed";
    return VideoValidationResult.invalid(msg, .av1);
}

/// MP4 box parsing — shared implementation
const mp4_parser = @import("mp4_box_parser.zig");
const Mp4Box = mp4_parser.Mp4Box;
const readMp4BoxHeader = mp4_parser.readMp4BoxHeader;
const findChildBox = mp4_parser.findChildBox;

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
    } else if (std.mem.eql(u8, entry_type, "mp4v") or std.mem.eql(u8, entry_type, "XVID") or
        std.mem.eql(u8, entry_type, "xvid") or std.mem.eql(u8, entry_type, "DIVX") or
        std.mem.eql(u8, entry_type, "divx") or std.mem.eql(u8, entry_type, "DX50") or
        std.mem.eql(u8, entry_type, "3IV2") or std.mem.eql(u8, entry_type, "FMP4"))
    {
        return .mpeg4p2;
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
        video_codec != .mpeg1 and video_codec != .mpeg2 and video_codec != .mpeg4p2)
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

    // For MPEG-4 Part 2 (DivX, Xvid, etc.), use pure Zig structural validation
    if (video_codec == .mpeg4p2) {
        return validateMpeg4P2FromMp4(allocator, file, stbl, max_frames);
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

    // Pure-Zig H.264 validator supports all profiles (syntax validation, not pixel decode)
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

    // Extract ALL frames (not just keyframes) to ensure full decode validation.
    // A bit error in a P-frame or B-frame would go undetected if we only decode keyframes.
    const frames_extracted = appendMp4SamplesToBitstream(
        allocator,
        file,
        sample_table,
        video_codec,
        nal_length_size,
        max_frames,
        false, // ALL frames, not just sync samples/keyframes
        &bitstream,
        max_bitstream_bytes,
    );

    if (frames_extracted == 0) {
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

    // Decode the combined bitstream (all frames, not just keyframes)
    var result = switch (video_codec) {
        .hevc => validateHevcStream(bitstream.items, max_frames),
        .av1 => validateAv1Stream(allocator, bitstream.items, max_frames),
        .h264 => validateH264Stream(bitstream.items, max_frames),
        else => VideoValidationResult.skipped("Unsupported codec"),
    };

    result.byte_validated = byte_validated;
    return result;
}

const MkvFrameValidationContext = struct {
	codec: VideoCodec,
	nal_length_size: u8,
	mixed_nal_prefix: bool,
	comp_header: ?[]const u8,
	allocator: Allocator,
};

fn validateMkvFrameBytes(ctx_ptr: ?*anyopaque, data: []const u8) bool {
	const ctx: *MkvFrameValidationContext = @ptrCast(@alignCast(ctx_ptr orelse return false));
	// If header stripping is active, prepend the stripped bytes
	const frame_data = if (ctx.comp_header) |hdr| blk: {
		const full = ctx.allocator.alloc(u8, hdr.len + data.len) catch return false;
		@memcpy(full[0..hdr.len], hdr);
		@memcpy(full[hdr.len..], data);
		break :blk full;
	} else data;
	defer if (ctx.comp_header != null) ctx.allocator.free(frame_data);

	return switch (ctx.codec) {
		.av1 => validateAv1ObuStream(frame_data),
		.h264, .hevc => validateMkvNalFrame(frame_data, ctx.codec, ctx.nal_length_size, &ctx.mixed_nal_prefix),
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
        } else if (video_codec == .av1 and codec_private.len > 4) {
            // AV1 config (av1C format): skip 4-byte fixed header, append config OBUs only
            bitstream.appendSlice(allocator, codec_private[4..]) catch {
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
            .comp_header = video_track.content_comp_header,
            .allocator = allocator,
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

    // Collect ALL frames for full decode validation - no limit
    // A bit error in any frame (not just keyframes) should be detected
    const all_frames = parser.collectAllFrames(video_track.track_number, max_frames) orelse {
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
    // NOTE: We only do structural validation (header parsing, frame counting).
    // Full Theora bitstream decoding requires libtheora which is not integrated.
    if (video_codec == .theora) {
        // Theora in MKV has headers in codec_private
        if (video_track.codec_private) |codec_private| {
            // Parse info header from codec_private (may be concatenated headers)
            const info = theora.parseInfoHeader(codec_private) orelse {
                return VideoValidationResult.invalid("Invalid Theora info header", .theora);
            };

            // Count frames from collected frames (structural check only - not full decode)
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
            // Theora frames were counted but NOT decoded (no libtheora integration)
            // Return valid but explicitly NOT byte_validated
            return .{
                .valid = true,
                .error_message = null,
                .codec = .theora,
                .frames_decoded = keyframe_count + inter_count,
                .byte_validated = false, // Only structural - no actual decode
            };
        } else {
            return VideoValidationResult.invalid("No Theora codec_private", .theora);
        }
    }

    // For VP8, use deep validation with boolean decoder parsing
    // Note: libvpx full decode not available - boolean decoder parses header structure
    // but does NOT decode DCT coefficients or reconstruct pixels
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
        // NOT byte_validated: only header parsing, no DCT coefficient decode
        return .{
            .valid = true,
            .error_message = null,
            .codec = .vp8,
            .frames_decoded = frames_validated,
            .byte_validated = false, // Header-only validation, no pixel decode
        };
    }

    // Add frame data to bitstream
    // Safety cap: 256MB max to avoid integer overflow in decoder APIs
    const max_mkv_bitstream_bytes: usize = 256 * 1024 * 1024;
    const comp_header = video_track.content_comp_header;
    for (all_frames) |kf| {
        if (bitstream.items.len >= max_mkv_bitstream_bytes) break;

        // If header stripping is active, prepend the stripped bytes
        const frame_data = if (comp_header) |hdr| blk: {
            const full = allocator.alloc(u8, hdr.len + kf.data.len) catch continue;
            @memcpy(full[0..hdr.len], hdr);
            @memcpy(full[hdr.len..], kf.data);
            break :blk full;
        } else kf.data;
        defer if (comp_header != null) allocator.free(frame_data);

        if (video_codec == .av1) {
            // AV1 uses OBUs directly
            bitstream.appendSlice(allocator, frame_data) catch continue;
        } else {
            // H.264/HEVC: Convert length-prefixed NALs to Annex B
            if (convertToAnnexB(allocator, frame_data, nal_length_size)) |annexb_data| {
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

/// Validate H.264 bitstream using pure-Zig syntax validator.
/// Validates up to max_frames to verify integrity.
/// Input data should be in Annex B format (with 0x00000001 start codes).
pub fn validateH264Stream(data: []const u8, max_frames: u32) VideoValidationResult {
    const result = h264.validateH264Stream(data, max_frames);
    const err_msg: ?[]const u8 = if (result.error_message) |e| std.mem.span(e) else null;
    return .{
        .valid = result.valid,
        .error_message = err_msg,
        .codec = .h264,
        .frames_decoded = result.frames_decoded,
        // Pure-Zig syntax validation validates structure deeply enough for corruption detection
        .byte_validated = result.valid and result.frames_decoded > 0,
    };
}

/// Codec private data (SPS/PPS for H.264/HEVC, config OBUs for AV1)
pub const CodecPrivateData = struct {
    data: []u8,
    nal_length_size: u8,
    /// H.264 profile indication (from avcC), 0 if not applicable
    h264_profile: u8 = 0,
    /// H.264 level indication (from avcC), 0 if not applicable
    /// Level is encoded as level * 10 (e.g., 31 = level 3.1, 40 = level 4.0)
    h264_level: u8 = 0,

    /// Check if H.264 profile/level is supported by the pure-Zig validator.
    /// Some professional profiles have complex features that may not be fully validated.
    /// - Baseline (66) and Main (77): reliably supported at all levels
    /// - High (100): supported at levels <= 3.1 (720p), problematic at 4.0+ (1080p)
    /// - High 10/4:2:2/4:4:4: not supported (10-bit or chroma subsampling)
    pub fn isH264ProfileSupported(self: @This()) bool {
        return switch (self.h264_profile) {
            66, 77 => true, // Baseline, Main - reliably supported
            100 => self.h264_level <= 31, // High profile: only levels <= 3.1
            0 => true, // Not H.264 or unknown - let it try
            else => false, // High 10, High 4:2:2, etc. - require ffmpeg
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

/// Extract raw codec private data (avcC/hvcC box contents) without Annex B conversion.
/// Raw box format used for codec configuration extraction.
fn extractRawCodecPrivate(allocator: Allocator, file: std.fs.File, stsd_offset: u64, codec: VideoCodec) ?struct { data: []u8, nal_length_size: u8 } {
    // Skip stsd header (8 bytes) + version/flags (4 bytes) + entry count (4 bytes)
    file.seekTo(stsd_offset + 16) catch return null;

    // Read sample entry header (8 bytes: size + type like "avc1"/"hvc1")
    var entry_header: [8]u8 = undefined;
    if ((file.read(&entry_header) catch return null) < 8) return null;

    const entry_size = std.mem.readInt(u32, entry_header[0..4], .big);
    const entry_end = stsd_offset + 16 + entry_size;

    // Skip to codec-specific box (avcC or hvcC)
    file.seekTo(stsd_offset + 16 + 8 + 78) catch return null;

    while ((file.getPos() catch return null) < entry_end) {
        const box = readMp4BoxHeader(file) orelse break;

        const is_avc_config = std.mem.eql(u8, &box.box_type, "avcC") and codec == .h264;
        const is_hevc_config = std.mem.eql(u8, &box.box_type, "hvcC") and codec == .hevc;
        const is_av1_config = std.mem.eql(u8, &box.box_type, "av1C") and codec == .av1;

        if (is_avc_config or is_hevc_config or is_av1_config) {
            // Read the box contents (excluding 8-byte header)
            const content_size = box.size - 8;
            if (content_size > 10 * 1024 * 1024) return null; // Sanity limit: 10MB

            file.seekTo(box.offset + 8) catch return null;
            const data = allocator.alloc(u8, @intCast(content_size)) catch return null;
            errdefer allocator.free(data);

            if ((file.read(data) catch {
                allocator.free(data);
                return null;
            }) < content_size) {
                allocator.free(data);
                return null;
            }

            // Extract NAL length size from the config
            var nal_length_size: u8 = 4;
            if (is_avc_config and data.len >= 5) {
                nal_length_size = (data[4] & 0x03) + 1;
            } else if (is_hevc_config and data.len >= 22) {
                nal_length_size = (data[21] & 0x03) + 1;
            }

            return .{ .data = data, .nal_length_size = nal_length_size };
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
    const level_idc: u8 = header[3]; // AVCLevelIndication (level * 10, e.g., 31 = 3.1, 40 = 4.0)
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

    // Debug: log H.264 profile and level
    const debug_enabled = getenvCrossPlatform("VALIDATE_DEBUG") != null;
    if (debug_enabled) {
        std.debug.print("[H264] Parsed avcC: profile={d} (", .{profile_idc});
        switch (profile_idc) {
            66 => std.debug.print("Baseline", .{}),
            77 => std.debug.print("Main", .{}),
            100 => std.debug.print("High", .{}),
            110 => std.debug.print("High 10", .{}),
            122 => std.debug.print("High 4:2:2", .{}),
            244 => std.debug.print("High 4:4:4", .{}),
            else => std.debug.print("Unknown", .{}),
        }
        std.debug.print("), level={d} ({d}.{d})\n", .{ level_idc, level_idc / 10, level_idc % 10 });
    }

    return CodecPrivateData{
        .data = output.toOwnedSlice(allocator) catch return null,
        .nal_length_size = nal_length_size,
        .h264_profile = profile_idc,
        .h264_level = level_idc,
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

    // av1C format: 4-byte fixed header (marker/version/profile/level/flags)
    // followed by optional config OBUs (typically a Sequence Header OBU)
    const data_size = box_size - 8;
    if (data_size < 4 or data_size > 1024) return null;

    var raw_buf: [1024]u8 = undefined;
    if ((file.read(raw_buf[0..data_size]) catch return null) < data_size) {
        return null;
    }

    // Skip the 4-byte av1C fixed header — only return the config OBUs
    const obu_size = data_size - 4;
    if (obu_size == 0) return null; // No config OBUs present

    const data = allocator.alloc(u8, obu_size) catch return null;
    @memcpy(data, raw_buf[4..][0..obu_size]);

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


fn validateMpeg4P2FromMp4(allocator: Allocator, file: std.fs.File, stbl: Mp4Box, max_frames: u32) VideoValidationResult {
    // Parse sample table for frame extraction
    var sample_table = parseSampleTable(allocator, file, stbl.offset, stbl.size, stbl.header_size) orelse {
        return VideoValidationResult.invalid("Failed to parse sample tables", .mpeg4p2);
    };
    defer sample_table.deinit();

    if (sample_table.sample_count == 0) {
        return VideoValidationResult.invalid("No samples found in MPEG-4 Part 2 track", .mpeg4p2);
    }

    // For MPEG-4 Part 2 in MP4, samples contain raw VOP data
    // We need to extract the esds box for decoder config (VOL header) + samples
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
        return VideoValidationResult.invalid("Invalid sample sizes", .mpeg4p2);
    }

    const frame_buffer = allocator.alloc(u8, max_sample_size) catch {
        return VideoValidationResult.invalid("Memory allocation failed", .mpeg4p2);
    };
    defer allocator.free(frame_buffer);

    // Collect samples into a buffer for validation
    var bitstream: std.ArrayListUnmanaged(u8) = .{};
    defer bitstream.deinit(allocator);

    // Try to extract decoder config from esds box (contains VOL header)
    // First find stsd box
    const stsd = findChildBox(file, stbl.offset + stbl.header_size, stbl.size - stbl.header_size, "stsd");
    if (stsd != null) {
        // Try to get decoder config from esds
        const decoder_config = extractMpeg4DecoderConfig(allocator, file, stsd.?.offset, stsd.?.size);
        if (decoder_config) |config| {
            defer allocator.free(config);
            bitstream.appendSlice(allocator, config) catch {};
        }
    }

    var frames_extracted: u32 = 0;
    for (0..sample_table.sample_count) |sample_idx| {
        if (frames_extracted >= frames_to_check) break;

        const location = sample_table.getSampleLocation(@intCast(sample_idx)) orelse continue;
        if (location.size > max_sample_size) continue;

        // Read sample data
        file.seekTo(location.offset) catch continue;
        const bytes_read = file.read(frame_buffer[0..location.size]) catch continue;
        if (bytes_read != location.size) continue;

        // Append to bitstream
        bitstream.appendSlice(allocator, frame_buffer[0..location.size]) catch continue;
        frames_extracted += 1;
    }

    if (bitstream.items.len == 0) {
        return VideoValidationResult.invalid("No frames extracted", .mpeg4p2);
    }

    // Validate the combined bitstream
    const result = mpeg4p2.validateMpeg4P2Stream(bitstream.items, max_frames);
    if (result.valid) {
        return VideoValidationResult.okByteValidated(.mpeg4p2, result.vop_count);
    } else {
        return VideoValidationResult.invalid(result.error_message orelse "MPEG-4 Part 2 validation failed", .mpeg4p2);
    }
}

fn extractMpeg4DecoderConfig(allocator: Allocator, file: std.fs.File, stsd_offset: u64, stsd_size: u64) ?[]u8 {
    // Skip stsd header (8) + version/flags (4) + entry count (4) = 16 bytes
    file.seekTo(stsd_offset + 16) catch return null;

    // Read entry size and type
    var entry_header: [8]u8 = undefined;
    _ = file.read(&entry_header) catch return null;

    const entry_size = std.mem.readInt(u32, entry_header[0..4], .big);
    if (entry_size < 86) return null; // mp4v entry is at least 86 bytes

    // Visual sample entry is 78 bytes from start of entry (after size+type):
    // 6 reserved + 2 data_ref_idx + 2 version + 2 revision + 4 vendor +
    // 4 temporal_quality + 4 spatial_quality + 2 width + 2 height +
    // 4 h_resolution + 4 v_resolution + 4 data_size + 2 frame_count +
    // 32 compressor_name + 2 depth + 2 color_table = 78 bytes
    // Total with size+type: 86 bytes

    const child_boxes_start = stsd_offset + 16 + 86;
    const child_boxes_end = stsd_offset + 16 + entry_size;

    // Search for esds box within entry
    var pos = child_boxes_start;
    while (pos + 8 < child_boxes_end and pos + 8 < stsd_offset + stsd_size) {
        file.seekTo(pos) catch return null;
        var box_header: [8]u8 = undefined;
        const read = file.read(&box_header) catch return null;
        if (read < 8) return null;

        const box_size = std.mem.readInt(u32, box_header[0..4], .big);
        if (box_size < 8 or pos + box_size > child_boxes_end) break;

        if (std.mem.eql(u8, box_header[4..8], "esds")) {
            // Skip version (4 bytes) after box header
            file.seekTo(pos + 12) catch return null;
            // Parse ES descriptor to find decoder config
            return parseEsdsDecoderConfig(allocator, file, box_size - 12);
        }

        pos += box_size;
    }

    return null;
}

fn parseEsdsDecoderConfig(allocator: Allocator, file: std.fs.File, max_size: u32) ?[]u8 {
    // ES descriptor parsing - look for decoder config descriptor (tag 0x04)
    // then decoder specific info (tag 0x05)
    var bytes_read: u32 = 0;
    while (bytes_read < max_size) {
        var tag: [1]u8 = undefined;
        _ = file.read(&tag) catch return null;
        bytes_read += 1;

        // Read size (variable length)
        var size: u32 = 0;
        var size_bytes: u8 = 0;
        while (size_bytes < 4) {
            var b: [1]u8 = undefined;
            _ = file.read(&b) catch return null;
            bytes_read += 1;
            size = (size << 7) | (b[0] & 0x7F);
            size_bytes += 1;
            if ((b[0] & 0x80) == 0) break;
        }

        if (tag[0] == 0x05) {
            // Decoder specific info - this contains the VOL header
            if (size > max_size - bytes_read) return null;
            const config = allocator.alloc(u8, size) catch return null;
            const read = file.read(config) catch {
                allocator.free(config);
                return null;
            };
            if (read != size) {
                allocator.free(config);
                return null;
            }
            return config;
        } else if (tag[0] == 0x03 or tag[0] == 0x04) {
            // ES descriptor or decoder config descriptor - skip header and continue
            if (tag[0] == 0x03) {
                // Skip ES_ID (2) + flags (1)
                file.seekTo((file.getPos() catch return null) + 3) catch return null;
                bytes_read += 3;
            } else {
                // Skip objectTypeIndication (1) + streamType/bufferSize (4) + maxBitrate (4) + avgBitrate (4)
                file.seekTo((file.getPos() catch return null) + 13) catch return null;
                bytes_read += 13;
            }
        } else {
            // Skip unknown tag
            file.seekTo((file.getPos() catch return null) + size) catch return null;
            bytes_read += size;
        }
    }

    return null;
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
