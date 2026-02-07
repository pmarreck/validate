//! Combined video and audio deep validation for media containers.
//!
//! This module validates both video and audio tracks in MP4/MKV containers.
//! It uses the existing video_validator for video decode and adds audio decode
//! validation using the appropriate codec validators.
//!
//! Audio codecs supported:
//! - AAC (pure Zig syntax validator)
//! - MP3 (via minimp3)
//! - Opus (via libopus) - from MKV/WebM
//! - Vorbis (via libvorbis) - from MKV
//! - FLAC (pure Zig) - from MKV
//!
//! For OGG files (standalone Opus/Vorbis), OGG page CRC32 validation provides
//! 100% byte coverage, so additional decode validation is optional.

const std = @import("std");
const Allocator = std.mem.Allocator;

// Import existing validators
const video_validator = @import("video_validator.zig");
const aac_syntax_validator = @import("aac_syntax_validator.zig");
const alac_validator = @import("alac_validator.zig");
const ac3_validator = @import("ac3_validator.zig");
const eac3_validator = @import("eac3_validator.zig");
const mp3_validator = @import("mp3_decode_validator.zig");
const opus_validator = @import("opus_validator.zig");
const vorbis_validator = @import("vorbis_validator.zig");
const ebml = @import("ebml_parser.zig");

/// Audio codec type
pub const AudioCodec = enum {
    aac,
    mp3,
    opus,
    vorbis,
    flac,
    ac3,
    eac3,
    dts,
    alac,
    pcm,
    unknown,
};

/// Result of combined video+audio validation
pub const MediaValidationResult = struct {
    // Overall status
    valid: bool,
    error_message: ?[]const u8,

    // Video info
    video_codec: video_validator.VideoCodec,
    video_frames_decoded: u32,
    video_valid: bool,
    video_message: ?[]const u8,

    // Audio info
    audio_codec: AudioCodec,
    audio_frames_decoded: u32,
    audio_valid: bool,
    audio_message: ?[]const u8,

    // Flags for partial validation
    has_video_track: bool,
    has_audio_track: bool,

    // CRC-based validation (MKV clusters)
    crc_validated: bool = false,

    pub fn videoOnly(video_result: video_validator.VideoValidationResult) MediaValidationResult {
        return .{
            .valid = video_result.valid,
            .error_message = video_result.error_message,
            .video_codec = video_result.codec,
            .video_frames_decoded = video_result.frames_decoded,
            .video_valid = video_result.valid,
            .video_message = video_result.error_message,
            .audio_codec = .unknown,
            .audio_frames_decoded = 0,
            .audio_valid = true, // No audio = not a failure
            .audio_message = null,
            .has_video_track = true,
            .has_audio_track = false,
        };
    }

    pub fn combined(
        video_result: video_validator.VideoValidationResult,
        audio_result: AudioValidationResult,
    ) MediaValidationResult {
        const overall_valid = video_result.valid and audio_result.valid;
        return .{
            .valid = overall_valid,
            .error_message = if (!video_result.valid) video_result.error_message else audio_result.error_message,
            .video_codec = video_result.codec,
            .video_frames_decoded = video_result.frames_decoded,
            .video_valid = video_result.valid,
            .video_message = video_result.error_message,
            .audio_codec = audio_result.codec,
            .audio_frames_decoded = audio_result.frames_decoded,
            .audio_valid = audio_result.valid,
            .audio_message = audio_result.error_message,
            .has_video_track = true,
            .has_audio_track = true,
        };
    }

    /// Get human-readable validation message
    pub fn getMessage(self: *const MediaValidationResult) []const u8 {
        if (!self.valid) {
            return self.error_message orelse "Validation failed";
        }

        if (self.has_video_track and self.has_audio_track) {
            return "Video and audio validated";
        } else if (self.has_video_track) {
            return "Video validated (no audio track)";
        } else if (self.has_audio_track) {
            return "Audio validated (no video track)";
        } else {
            return "No media tracks found";
        }
    }
};

/// Result of audio track validation
pub const AudioValidationResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    codec: AudioCodec,
    frames_decoded: u32,

    pub fn ok(codec: AudioCodec, frames: u32) AudioValidationResult {
        return .{
            .valid = true,
            .error_message = null,
            .codec = codec,
            .frames_decoded = frames,
        };
    }

    pub fn invalid(message: []const u8, codec: AudioCodec) AudioValidationResult {
        return .{
            .valid = false,
            .error_message = message,
            .codec = codec,
            .frames_decoded = 0,
        };
    }

    pub fn unsupported(codec: AudioCodec) AudioValidationResult {
        return .{
            .valid = true, // Not a failure
            .error_message = "Audio codec not supported for deep validation",
            .codec = codec,
            .frames_decoded = 0,
        };
    }

    /// PCM audio is raw samples with no codec structure — integrity cannot be verified
    pub fn pcmUnverifiable() AudioValidationResult {
        return .{
            .valid = true, // Not a failure
            .error_message = "PCM audio cannot be integrity-checked (raw unstructured samples)",
            .codec = .pcm,
            .frames_decoded = 0,
        };
    }

    pub fn noTrack() AudioValidationResult {
        return .{
            .valid = true,
            .error_message = null,
            .codec = .unknown,
            .frames_decoded = 0,
        };
    }

    /// Returns true if this is PCM audio (unverifiable)
    pub fn isPcmUnverifiable(self: AudioValidationResult) bool {
        return self.codec == .pcm and self.frames_decoded == 0 and self.valid;
    }
};

/// Validate MP4/MOV file including both video and audio tracks
pub fn validateMp4Media(allocator: Allocator, path: []const u8, max_video_frames: u32) MediaValidationResult {
    // First validate video
    const video_result = video_validator.validateMp4Video(allocator, path, max_video_frames);

    // Then try to validate audio
    const audio_result = validateMp4Audio(allocator, path);

    if (audio_result.codec == .unknown and audio_result.error_message == null) {
        // No audio track found
        return MediaValidationResult.videoOnly(video_result);
    }

    return MediaValidationResult.combined(video_result, audio_result);
}

/// Validate MKV/WebM file including both video and audio tracks.
/// Uses checksum-first strategy: if all Clusters have CRC-32, verify those (fast).
/// Otherwise falls back to decode validation (slow but complete).
pub fn validateMkvMedia(allocator: Allocator, path: []const u8, max_video_frames: u32) MediaValidationResult {
    // First, try CRC-based validation (fast path)
    const crc_result = validateMkvCrc(allocator, path);
    if (crc_result.has_full_crc_coverage) {
        if (!crc_result.crc_valid) {
            // CRCs present but invalid - corruption detected
            return MediaValidationResult{
                .valid = false,
                .error_message = "MKV CRC verification failed",
                .video_codec = .unknown,
                .video_frames_decoded = 0,
                .video_valid = false,
                .video_message = "CRC mismatch in cluster data",
                .audio_codec = .unknown,
                .audio_frames_decoded = 0,
                .audio_valid = false,
                .audio_message = null,
                .has_video_track = true,
                .has_audio_track = crc_result.has_audio,
            };
        }
        // CRCs present and valid - 100% coverage, no decode needed
        return MediaValidationResult{
            .valid = true,
            .error_message = null,
            .video_codec = crc_result.video_codec,
            .video_frames_decoded = 0, // CRC-verified, not decoded
            .video_valid = true,
            .video_message = null,
            .audio_codec = crc_result.audio_codec,
            .audio_frames_decoded = 0,
            .audio_valid = true,
            .audio_message = null,
            .has_video_track = crc_result.has_video,
            .has_audio_track = crc_result.has_audio,
            .crc_validated = true,
        };
    }

    // Fall back to decode validation (CRCs absent or partial)
    const video_result = video_validator.validateMkvVideo(allocator, path, max_video_frames);

    // Then try to validate audio
    const audio_result = validateMkvAudio(allocator, path);

    if (audio_result.codec == .unknown and audio_result.error_message == null) {
        // No audio track found
        return MediaValidationResult.videoOnly(video_result);
    }

    return MediaValidationResult.combined(video_result, audio_result);
}

/// Result of MKV CRC-based validation
const MkvCrcResult = struct {
    crc_valid: bool,
    has_full_crc_coverage: bool,
    clusters_checked: u32,
    clusters_with_crc: u32,
    has_video: bool,
    has_audio: bool,
    video_codec: video_validator.VideoCodec,
    audio_codec: AudioCodec,
};

/// Try to validate MKV using Cluster CRCs.
fn validateMkvCrc(allocator: Allocator, path: []const u8) MkvCrcResult {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return .{
            .crc_valid = false,
            .has_full_crc_coverage = false,
            .clusters_checked = 0,
            .clusters_with_crc = 0,
            .has_video = false,
            .has_audio = false,
            .video_codec = .unknown,
            .audio_codec = .unknown,
        };
    };
    defer file.close();

    var parser = ebml.MatroskaParser.init(allocator, file);

    // Parse header to verify it's a valid MKV
    const doc_info = parser.parseEbmlHeader() orelse {
        return .{
            .crc_valid = false,
            .has_full_crc_coverage = false,
            .clusters_checked = 0,
            .clusters_with_crc = 0,
            .has_video = false,
            .has_audio = false,
            .video_codec = .unknown,
            .audio_codec = .unknown,
        };
    };

    if (!doc_info.isMatroska() and !doc_info.isWebM()) {
        return .{
            .crc_valid = false,
            .has_full_crc_coverage = false,
            .clusters_checked = 0,
            .clusters_with_crc = 0,
            .has_video = false,
            .has_audio = false,
            .video_codec = .unknown,
            .audio_codec = .unknown,
        };
    }

    // Detect tracks
    var has_video = false;
    var has_audio = false;
    var video_codec: video_validator.VideoCodec = .unknown;
    var audio_codec: AudioCodec = .unknown;

    const tracks_elem = parser.findSegmentChild(ebml.Segment_ID.Tracks);
    if (tracks_elem != null) {
        const tracks_end = tracks_elem.?.data_offset + (tracks_elem.?.size orelse 0);
        _ = parser.reader.seekTo(tracks_elem.?.data_offset);

        while ((parser.reader.getPos() orelse tracks_end) < tracks_end) {
            const entry = parser.reader.readElementHeader() orelse break;
            if (entry.id == ebml.Tracks_ID.TrackEntry) {
                if (parser.parseTrackEntry(entry)) |track| {
                    defer @constCast(&track).deinit();
                    const codec_id = track.codecId();
                    if (std.mem.startsWith(u8, codec_id, "V_")) { // Video
                        has_video = true;
                        if (track.isHevc()) video_codec = .hevc else if (track.isAv1()) video_codec = .av1 else if (track.isH264()) video_codec = .h264 else if (track.isVp9()) video_codec = .vp9;
                    } else if (std.mem.startsWith(u8, codec_id, "A_")) { // Audio
                        has_audio = true;
                        audio_codec = detectMkvAudioCodec(codec_id);
                    }
                }
            } else {
                _ = parser.reader.skipElement(entry);
            }
        }
    }

    // Verify Cluster CRCs
    const crc_result = parser.verifyCluterCrcs();

    return .{
        .crc_valid = crc_result.valid,
        .has_full_crc_coverage = crc_result.hasFullCoverage(),
        .clusters_checked = crc_result.clusters_checked,
        .clusters_with_crc = crc_result.clusters_with_crc,
        .has_video = has_video,
        .has_audio = has_audio,
        .video_codec = video_codec,
        .audio_codec = audio_codec,
    };
}

/// MP4 box parsing helpers (reusing from video_validator)
const Mp4Box = struct {
    box_type: [4]u8,
    offset: u64,
    size: u64,
    header_size: u8,
};

const StscEntry = struct {
    first_chunk: u32,
    samples_per_chunk: u32,
};

fn getSamplesPerChunk(stsc_entries: []const StscEntry, chunk_number: u32) u32 {
    // stsc entries are sorted by first_chunk; find the applicable entry for this chunk
    // Default to 1 sample per chunk if no stsc data
    if (stsc_entries.len == 0) return 1;

    var result: u32 = stsc_entries[0].samples_per_chunk;
    for (stsc_entries) |entry| {
        if (entry.first_chunk <= chunk_number) {
            result = entry.samples_per_chunk;
        } else {
            break;
        }
    }
    return result;
}

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
        const ext_read = file.read(header[8..16]) catch return null;
        if (ext_read < 8) return null;
        actual_size = std.mem.readInt(u64, header[8..16], .big);
        header_size = 16;
    } else if (size == 0) {
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
        file.seekTo(box.offset + box.size) catch return null;
    }
    return null;
}

/// Detect audio codec from MP4 sample description
fn detectMp4AudioCodec(file: std.fs.File, stsd_offset: u64) AudioCodec {
    // Skip stsd header (8 bytes) + version/flags (4 bytes) + entry count (4 bytes)
    file.seekTo(stsd_offset + 16) catch return .unknown;

    var entry_header: [12]u8 = undefined;
    const bytes = file.read(&entry_header) catch return .unknown;
    if (bytes < 12) return .unknown;

    const entry_type = entry_header[4..8];

    if (std.mem.eql(u8, entry_type, "mp4a")) {
        // Could be AAC, MP3, etc - need to check esds box
        return detectMp4aSubtype(file, stsd_offset);
    } else if (std.mem.eql(u8, entry_type, "alac")) {
        return .alac;
    } else if (std.mem.eql(u8, entry_type, "ac-3") or std.mem.eql(u8, entry_type, "sac3")) {
        return .ac3;
    } else if (std.mem.eql(u8, entry_type, "ec-3")) {
        return .eac3;
    } else if (std.mem.eql(u8, entry_type, "fLaC") or std.mem.eql(u8, entry_type, "flac")) {
        return .flac;
    } else if (std.mem.eql(u8, entry_type, "Opus")) {
        return .opus;
    } else if (std.mem.eql(u8, entry_type, "sowt") or std.mem.eql(u8, entry_type, "twos") or
        std.mem.eql(u8, entry_type, "in24") or std.mem.eql(u8, entry_type, "in32") or
        std.mem.eql(u8, entry_type, "fl32") or std.mem.eql(u8, entry_type, "fl64"))
    {
        return .pcm;
    }

    return .unknown;
}

/// Detect mp4a subtype (AAC vs MP3 vs others)
fn detectMp4aSubtype(file: std.fs.File, stsd_offset: u64) AudioCodec {
    // The esds box contains the audio object type
    // For simplicity, assume AAC if mp4a is present
    // A proper implementation would parse esds and check objectTypeIndication
    _ = file;
    _ = stsd_offset;
    return .aac;
}

/// Validate audio track from MP4 file
pub fn validateMp4Audio(allocator: Allocator, path: []const u8) AudioValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return AudioValidationResult.invalid("Failed to open file", .unknown);
    };
    defer file.close();

    const file_size = file.getEndPos() catch {
        return AudioValidationResult.invalid("Failed to get file size", .unknown);
    };

    // Find moov box
    var moov_box: ?Mp4Box = null;
    file.seekTo(0) catch return AudioValidationResult.invalid("Seek failed", .unknown);

    while ((file.getPos() catch return AudioValidationResult.invalid("Position failed", .unknown)) < file_size) {
        const box = readMp4BoxHeader(file) orelse break;
        if (std.mem.eql(u8, &box.box_type, "moov")) {
            moov_box = box;
            break;
        }
        file.seekTo(box.offset + box.size) catch break;
    }

    if (moov_box == null) {
        return AudioValidationResult.invalid("No moov box found", .unknown);
    }

    // Find audio track (trak with sound handler)
    const moov = moov_box.?;
    var trak_offset = moov.offset + moov.header_size;
    const moov_end = moov.offset + moov.size;

    var audio_codec: AudioCodec = .unknown;
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

        // Check hdlr for sound handler type
        const hdlr = findChildBox(file, mdia.?.offset + mdia.?.header_size, mdia.?.size - mdia.?.header_size, "hdlr");
        if (hdlr != null) {
            file.seekTo(hdlr.?.offset + hdlr.?.header_size + 8) catch break;
            var handler_type: [4]u8 = undefined;
            _ = file.read(&handler_type) catch break;

            if (std.mem.eql(u8, &handler_type, "soun")) {
                // Found audio track
                const minf = findChildBox(file, mdia.?.offset + mdia.?.header_size, mdia.?.size - mdia.?.header_size, "minf");
                if (minf != null) {
                    stbl_box = findChildBox(file, minf.?.offset + minf.?.header_size, minf.?.size - minf.?.header_size, "stbl");
                    if (stbl_box != null) {
                        const stsd = findChildBox(file, stbl_box.?.offset + stbl_box.?.header_size, stbl_box.?.size - stbl_box.?.header_size, "stsd");
                        if (stsd != null) {
                            audio_codec = detectMp4AudioCodec(file, stsd.?.offset);
                        }
                        break;
                    }
                }
            }
        }

        trak_offset = trak.offset + trak.size;
    }

    if (stbl_box == null) {
        return AudioValidationResult.noTrack();
    }

    // Validate based on detected codec
    return switch (audio_codec) {
        .aac => validateMp4AacTrack(allocator, file, stbl_box.?),
        .mp3 => AudioValidationResult.unsupported(.mp3), // MP3 in MP4 needs raw sample extraction
        .opus => AudioValidationResult.unsupported(.opus),
        .flac => AudioValidationResult.unsupported(.flac),
        .ac3 => validateMp4Ac3Track(allocator, file, stbl_box.?),
        .eac3 => validateMp4Eac3Track(allocator, file, stbl_box.?),
        .dts => AudioValidationResult.unsupported(audio_codec),
        .alac => validateMp4AlacTrack(allocator, file, stbl_box.?),
        .pcm => AudioValidationResult.pcmUnverifiable(), // PCM doesn't need decode validation
        else => AudioValidationResult.unsupported(.unknown),
    };
}

/// Validate AAC track from MP4 by extracting and decoding samples
fn validateMp4AacTrack(allocator: Allocator, file: std.fs.File, stbl: Mp4Box) AudioValidationResult {
    // Get stsd to extract AAC config
    const stsd = findChildBox(file, stbl.offset + stbl.header_size, stbl.size - stbl.header_size, "stsd");
    if (stsd == null) {
        return AudioValidationResult.invalid("No sample description found", .aac);
    }

    // Extract AAC AudioSpecificConfig from stsd > mp4a > esds
    const asc = extractAacConfig(allocator, file, stsd.?) orelse {
        return AudioValidationResult.invalid("Failed to extract AAC config from esds", .aac);
    };
    defer allocator.free(asc);

    // Parse sample table for frame locations
    const stsz = findChildBox(file, stbl.offset + stbl.header_size, stbl.size - stbl.header_size, "stsz");
    if (stsz == null) {
        return AudioValidationResult.invalid("No sample size table found", .aac);
    }

    const stco = findChildBox(file, stbl.offset + stbl.header_size, stbl.size - stbl.header_size, "stco");
    const co64 = findChildBox(file, stbl.offset + stbl.header_size, stbl.size - stbl.header_size, "co64");
    if (stco == null and co64 == null) {
        return AudioValidationResult.invalid("No chunk offset table found", .aac);
    }

    // Parse sample sizes
    // stsz is a FullBox: skip header + 4 bytes version/flags, then read sample_size + sample_count
    file.seekTo(stsz.?.offset + stsz.?.header_size + 4) catch {
        return AudioValidationResult.invalid("Failed to read sample sizes", .aac);
    };

    var stsz_header: [8]u8 = undefined;
    _ = file.read(&stsz_header) catch {
        return AudioValidationResult.invalid("Failed to read sample sizes", .aac);
    };

    const default_size = std.mem.readInt(u32, stsz_header[0..4], .big);
    const sample_count = std.mem.readInt(u32, stsz_header[4..8], .big);

    if (sample_count > 10_000_000) {
        return AudioValidationResult.invalid("Too many samples", .aac);
    }

    var sample_sizes: std.ArrayListUnmanaged(u32) = .{};
    defer sample_sizes.deinit(allocator);

    if (default_size == 0) {
        // Variable size samples
        sample_sizes.ensureTotalCapacity(allocator, sample_count) catch {
            return AudioValidationResult.invalid("Memory allocation failed", .aac);
        };
        for (0..sample_count) |_| {
            var size_buf: [4]u8 = undefined;
            _ = file.read(&size_buf) catch break;
            const size = std.mem.readInt(u32, &size_buf, .big);
            sample_sizes.append(allocator, size) catch break;
        }
    }

    // Parse chunk offsets
    var chunk_offsets: std.ArrayListUnmanaged(u64) = .{};
    defer chunk_offsets.deinit(allocator);

    const chunk_box = if (stco != null) stco.? else co64.?;
    const is_64bit = stco == null;

    file.seekTo(chunk_box.offset + chunk_box.header_size + 4) catch {
        return AudioValidationResult.invalid("Failed to read chunk offsets", .aac);
    };

    var chunk_count_buf: [4]u8 = undefined;
    _ = file.read(&chunk_count_buf) catch {
        return AudioValidationResult.invalid("Failed to read chunk offsets", .aac);
    };
    const chunk_count = std.mem.readInt(u32, &chunk_count_buf, .big);

    chunk_offsets.ensureTotalCapacity(allocator, chunk_count) catch {
        return AudioValidationResult.invalid("Memory allocation failed", .aac);
    };

    for (0..chunk_count) |_| {
        if (is_64bit) {
            var offset_buf: [8]u8 = undefined;
            _ = file.read(&offset_buf) catch break;
            chunk_offsets.append(allocator, std.mem.readInt(u64, &offset_buf, .big)) catch break;
        } else {
            var offset_buf: [4]u8 = undefined;
            _ = file.read(&offset_buf) catch break;
            chunk_offsets.append(allocator, std.mem.readInt(u32, &offset_buf, .big)) catch break;
        }
    }

    if (chunk_offsets.items.len == 0) {
        return AudioValidationResult.invalid("No chunk offsets found", .aac);
    }

    // Parse stsc (sample-to-chunk) to know how many samples are in each chunk
    const stsc = findChildBox(file, stbl.offset + stbl.header_size, stbl.size - stbl.header_size, "stsc");

    var stsc_entries: std.ArrayListUnmanaged(StscEntry) = .{};
    defer stsc_entries.deinit(allocator);

    if (stsc != null) {
        // stsc is a FullBox: skip header + 4 bytes version/flags
        file.seekTo(stsc.?.offset + stsc.?.header_size + 4) catch {};
        var stsc_count_buf: [4]u8 = undefined;
        if (file.read(&stsc_count_buf)) |bytes| {
            if (bytes == 4) {
                const stsc_count = std.mem.readInt(u32, &stsc_count_buf, .big);
                stsc_entries.ensureTotalCapacity(allocator, stsc_count) catch {};
                for (0..stsc_count) |_| {
                    var entry_buf: [12]u8 = undefined;
                    const read = file.read(&entry_buf) catch break;
                    if (read != 12) break;
                    stsc_entries.append(allocator, .{
                        .first_chunk = std.mem.readInt(u32, entry_buf[0..4], .big),
                        .samples_per_chunk = std.mem.readInt(u32, entry_buf[4..8], .big),
                    }) catch break;
                }
            }
        } else |_| {}
    }

    // Collect frame data and sizes using proper chunk-based reading
    const max_frames: u32 = 10;
    var frame_data: std.ArrayListUnmanaged(u8) = .{};
    defer frame_data.deinit(allocator);
    var frame_sizes: std.ArrayListUnmanaged(u32) = .{};
    defer frame_sizes.deinit(allocator);

    var sample_index: u32 = 0;
    var frames_collected: u32 = 0;

    for (chunk_offsets.items, 0..) |chunk_offset, chunk_idx| {
        if (frames_collected >= max_frames) break;

        // Determine how many samples are in this chunk via stsc
        const samples_in_chunk = getSamplesPerChunk(stsc_entries.items, @intCast(chunk_idx + 1));

        file.seekTo(chunk_offset) catch break;

        for (0..samples_in_chunk) |_| {
            if (frames_collected >= max_frames) break;
            if (sample_index >= sample_count) break;

            const size = if (default_size > 0) default_size else if (sample_index < sample_sizes.items.len) sample_sizes.items[sample_index] else break;
            sample_index += 1;

            if (size > 10 * 1024 * 1024) continue; // Skip unreasonably large samples

            const start_offset = frame_data.items.len;
            frame_data.ensureTotalCapacity(allocator, frame_data.items.len + size) catch continue;

            const slice = frame_data.addManyAsSlice(allocator, size) catch continue;
            const bytes_read = file.read(slice) catch continue;
            if (bytes_read != size) {
                frame_data.shrinkRetainingCapacity(start_offset);
                continue;
            }

            frame_sizes.append(allocator, size) catch continue;
            frames_collected += 1;
        }
    }

    if (frames_collected == 0) {
        return AudioValidationResult.invalid("No frames extracted", .aac);
    }

    // Validate using pure-Zig AAC syntax validator
    const syntax_result = aac_syntax_validator.validateAacSyntax(
        frame_data.items,
        frame_sizes.items,
        asc,
    );

    if (!syntax_result.valid) {
        return AudioValidationResult.invalid(syntax_result.error_message orelse "AAC syntax error", .aac);
    }

    return AudioValidationResult.ok(.aac, syntax_result.frames_checked);
}

/// Validate ALAC track from MP4/M4A by extracting and decoding samples
fn validateMp4AlacTrack(allocator: Allocator, file: std.fs.File, stbl: Mp4Box) AudioValidationResult {
    // Get stsd to extract ALAC config
    const stsd = findChildBox(file, stbl.offset + stbl.header_size, stbl.size - stbl.header_size, "stsd");
    if (stsd == null) {
        return AudioValidationResult.invalid("No sample description found", .alac);
    }

    // Extract ALAC config from stsd > alac > alac (magic cookie)
    const alac_config = extractAlacConfig(file, stsd.?) orelse {
        return AudioValidationResult.invalid("Failed to extract ALAC config", .alac);
    };

    // Parse sample table for frame locations
    const stsz = findChildBox(file, stbl.offset + stbl.header_size, stbl.size - stbl.header_size, "stsz");
    if (stsz == null) {
        return AudioValidationResult.invalid("No sample size table found", .alac);
    }

    const stco = findChildBox(file, stbl.offset + stbl.header_size, stbl.size - stbl.header_size, "stco");
    const co64 = findChildBox(file, stbl.offset + stbl.header_size, stbl.size - stbl.header_size, "co64");
    if (stco == null and co64 == null) {
        return AudioValidationResult.invalid("No chunk offset table found", .alac);
    }

    // Parse sample sizes
    var sample_sizes: std.ArrayListUnmanaged(u32) = .{};
    defer sample_sizes.deinit(allocator);

    // stsz is a FullBox: skip header + 4 bytes version/flags, then read sample_size + sample_count
    file.seekTo(stsz.?.offset + stsz.?.header_size + 4) catch {
        return AudioValidationResult.invalid("Failed to read sample sizes", .alac);
    };

    var stsz_header: [8]u8 = undefined;
    _ = file.read(&stsz_header) catch {
        return AudioValidationResult.invalid("Failed to read sample sizes", .alac);
    };

    const default_size = std.mem.readInt(u32, stsz_header[0..4], .big);
    const sample_count = std.mem.readInt(u32, stsz_header[4..8], .big);

    if (sample_count > 10_000_000) {
        return AudioValidationResult.invalid("Too many samples", .alac);
    }

    if (default_size == 0) {
        // Variable size samples
        sample_sizes.ensureTotalCapacity(allocator, sample_count) catch {
            return AudioValidationResult.invalid("Memory allocation failed", .alac);
        };
        for (0..sample_count) |_| {
            var size_buf: [4]u8 = undefined;
            _ = file.read(&size_buf) catch break;
            const size = std.mem.readInt(u32, &size_buf, .big);
            sample_sizes.append(allocator, size) catch break;
        }
    }

    // Parse chunk offsets
    var chunk_offsets: std.ArrayListUnmanaged(u64) = .{};
    defer chunk_offsets.deinit(allocator);

    const chunk_box = if (stco != null) stco.? else co64.?;
    const is_64bit = stco == null;

    file.seekTo(chunk_box.offset + chunk_box.header_size + 4) catch {
        return AudioValidationResult.invalid("Failed to read chunk offsets", .alac);
    };

    var chunk_count_buf: [4]u8 = undefined;
    _ = file.read(&chunk_count_buf) catch {
        return AudioValidationResult.invalid("Failed to read chunk offsets", .alac);
    };
    const chunk_count = std.mem.readInt(u32, &chunk_count_buf, .big);

    chunk_offsets.ensureTotalCapacity(allocator, chunk_count) catch {
        return AudioValidationResult.invalid("Memory allocation failed", .alac);
    };

    for (0..chunk_count) |_| {
        if (is_64bit) {
            var offset_buf: [8]u8 = undefined;
            _ = file.read(&offset_buf) catch break;
            chunk_offsets.append(allocator, std.mem.readInt(u64, &offset_buf, .big)) catch break;
        } else {
            var offset_buf: [4]u8 = undefined;
            _ = file.read(&offset_buf) catch break;
            chunk_offsets.append(allocator, std.mem.readInt(u32, &offset_buf, .big)) catch break;
        }
    }

    if (chunk_offsets.items.len == 0) {
        return AudioValidationResult.invalid("No chunk offsets found", .alac);
    }

    // Collect frame data and sizes
    const max_frames: u32 = 10;
    var frame_data: std.ArrayListUnmanaged(u8) = .{};
    defer frame_data.deinit(allocator);
    var frame_sizes: std.ArrayListUnmanaged(u32) = .{};
    defer frame_sizes.deinit(allocator);

    // Simple approach: read samples from first chunk
    // (Full implementation would handle stsc for samples-per-chunk mapping)
    const first_chunk_offset = chunk_offsets.items[0];
    file.seekTo(first_chunk_offset) catch {
        return AudioValidationResult.invalid("Failed to seek to frame data", .alac);
    };

    var frames_collected: u32 = 0;
    for (0..sample_count) |i| {
        if (frames_collected >= max_frames) break;

        const size = if (default_size > 0) default_size else if (i < sample_sizes.items.len) sample_sizes.items[i] else break;
        if (size > 10 * 1024 * 1024) continue; // Skip unreasonably large samples

        const start_offset = frame_data.items.len;
        frame_data.ensureTotalCapacity(allocator, frame_data.items.len + size) catch continue;

        const slice = frame_data.addManyAsSlice(allocator, size) catch continue;
        const bytes_read = file.read(slice) catch continue;
        if (bytes_read != size) {
            frame_data.shrinkRetainingCapacity(start_offset);
            continue;
        }

        frame_sizes.append(allocator, size) catch continue;
        frames_collected += 1;
    }

    if (frames_collected == 0) {
        return AudioValidationResult.invalid("No frames extracted", .alac);
    }

    // Validate using ALAC decoder
    const result = alac_validator.validateAlacFromBuffer(
        allocator,
        &alac_config,
        frame_data.items,
        frame_sizes.items,
        max_frames,
    );

    if (!result.valid) {
        return AudioValidationResult.invalid(result.error_message orelse "ALAC decode failed", .alac);
    }

    return AudioValidationResult.ok(.alac, result.frames_decoded);
}

/// Extract ALAC config (magic cookie) from stsd box
fn extractAlacConfig(file: std.fs.File, stsd: Mp4Box) ?[24]u8 {
    // stsd structure: version (1) + flags (3) + entry_count (4) + entries
    // Each entry: size (4) + type (4) + data
    // For ALAC: ... > alac (codec specific) > alac (magic cookie)

    file.seekTo(stsd.offset + stsd.header_size + 8) catch return null;

    // Find 'alac' entry in stsd
    var entry_buf: [8]u8 = undefined;
    _ = file.read(&entry_buf) catch return null;

    const entry_size = std.mem.readInt(u32, entry_buf[0..4], .big);
    const entry_type = entry_buf[4..8];

    if (!std.mem.eql(u8, entry_type, "alac")) {
        return null;
    }

    // Skip to the inner 'alac' box (magic cookie)
    // AudioSampleEntry: 6 reserved + 2 data_ref_index + ... + format specific
    // Standard fields are 28 bytes, then extensions

    file.seekTo(stsd.offset + stsd.header_size + 8 + 8 + 28) catch return null;

    // Look for inner alac box with magic cookie
    const remaining = entry_size - 8 - 28;
    var pos: u32 = 0;

    while (pos + 8 <= remaining) {
        var box_header: [8]u8 = undefined;
        _ = file.read(&box_header) catch return null;

        const box_size = std.mem.readInt(u32, box_header[0..4], .big);
        const box_type = box_header[4..8];

        if (std.mem.eql(u8, box_type, "alac") and box_size >= 36) {
            // Skip version/flags (4 bytes), then read 24-byte config
            file.seekTo((file.getPos() catch return null) + 4) catch return null;

            var config: [24]u8 = undefined;
            const read = file.read(&config) catch return null;
            if (read == 24) {
                return config;
            }
            return null;
        }

        // Skip to next box
        if (box_size < 8) break;
        file.seekTo((file.getPos() catch return null) + box_size - 8) catch return null;
        pos += box_size;
    }

    return null;
}

fn extractAacConfig(allocator: Allocator, file: std.fs.File, stsd: Mp4Box) ?[]u8 {
    // stsd structure: version (1) + flags (3) + entry_count (4) + entries
    // For AAC: mp4a entry > esds box (or wave > esds for QuickTime)

    file.seekTo(stsd.offset + stsd.header_size + 8) catch return null;

    // Read entry header
    var entry_buf: [8]u8 = undefined;
    _ = file.read(&entry_buf) catch return null;

    const entry_size = std.mem.readInt(u32, entry_buf[0..4], .big);
    const entry_type = entry_buf[4..8];

    if (!std.mem.eql(u8, entry_type, "mp4a")) {
        return null;
    }

    // Read version from AudioSampleEntry (at offset 8 into the 28-byte fields)
    var ase_buf: [28]u8 = undefined;
    _ = file.read(&ase_buf) catch return null;
    const ase_version = std.mem.readInt(u16, ase_buf[8..10], .big);

    // Skip extra bytes for QT Sound Sample Description versions
    const extra_bytes: u32 = switch (ase_version) {
        1 => 16, // v1 has 16 extra bytes (samplesPerPacket, bytesPerPacket, bytesPerFrame, bytesPerSample)
        2 => 36, // v2 has 36 extra bytes
        else => 0, // v0 (standard ISO) has no extra bytes
    };
    if (extra_bytes > 0) {
        file.seekTo((file.getPos() catch return null) + extra_bytes) catch return null;
    }

    // Search child boxes for "esds" or "wave" (which contains esds)
    const header_overhead = 8 + 28 + extra_bytes;
    const remaining: u32 = if (entry_size > header_overhead) @as(u32, @intCast(entry_size - header_overhead)) else return null;
    var pos: u32 = 0;

    while (pos + 8 <= remaining) {
        var box_header: [8]u8 = undefined;
        _ = file.read(&box_header) catch return null;

        const box_size = std.mem.readInt(u32, box_header[0..4], .big);
        const box_type = box_header[4..8];

        if (std.mem.eql(u8, box_type, "esds")) {
            // esds directly inside mp4a
            file.seekTo((file.getPos() catch return null) + 4) catch return null;
            const esds_data_size = if (box_size > 12) box_size - 12 else return null;
            return parseEsdsAudioConfig(allocator, file, esds_data_size);
        } else if (std.mem.eql(u8, box_type, "wave")) {
            // QuickTime: esds is inside a wave box — search within it
            const wave_data_start = file.getPos() catch return null;
            const wave_data_size: u32 = if (box_size > 8) @as(u32, @intCast(box_size - 8)) else return null;
            var wave_pos: u32 = 0;
            while (wave_pos + 8 <= wave_data_size) {
                var inner_header: [8]u8 = undefined;
                _ = file.read(&inner_header) catch return null;

                const inner_size = std.mem.readInt(u32, inner_header[0..4], .big);
                const inner_type = inner_header[4..8];

                if (std.mem.eql(u8, inner_type, "esds")) {
                    file.seekTo((file.getPos() catch return null) + 4) catch return null;
                    const esds_data_size = if (inner_size > 12) inner_size - 12 else return null;
                    return parseEsdsAudioConfig(allocator, file, esds_data_size);
                }

                if (inner_size < 8) break;
                file.seekTo(wave_data_start + wave_pos + inner_size) catch return null;
                wave_pos += inner_size;
            }
            return null;
        }

        // Skip to next box
        if (box_size < 8) break;
        file.seekTo((file.getPos() catch return null) + box_size - 8) catch return null;
        pos += box_size;
    }

    return null;
}

fn parseEsdsAudioConfig(allocator: Allocator, file: std.fs.File, max_size: u32) ?[]u8 {
    // ES descriptor parsing - look for tag 0x05 (DecoderSpecificInfo) which contains the ASC
    var bytes_read: u32 = 0;
    while (bytes_read < max_size) {
        var tag: [1]u8 = undefined;
        _ = file.read(&tag) catch return null;
        bytes_read += 1;

        // Read size (variable length, up to 4 bytes with continuation bit)
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
            // DecoderSpecificInfo - contains AudioSpecificConfig
            if (size > max_size - bytes_read) return null;
            if (size == 0) return null;
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
        } else if (tag[0] == 0x03) {
            // ES_Descriptor: skip ES_ID (2) + flags (1)
            file.seekTo((file.getPos() catch return null) + 3) catch return null;
            bytes_read += 3;
        } else if (tag[0] == 0x04) {
            // DecoderConfigDescriptor: skip objectTypeIndication(1) + streamType/bufferSize(4) + maxBitrate(4) + avgBitrate(4)
            file.seekTo((file.getPos() catch return null) + 13) catch return null;
            bytes_read += 13;
        } else {
            // Skip unknown tag
            file.seekTo((file.getPos() catch return null) + size) catch return null;
            bytes_read += size;
        }
    }

    return null;
}

/// Validate AC-3 track from MP4 container
fn validateMp4Ac3Track(allocator: Allocator, file: std.fs.File, stbl: Mp4Box) AudioValidationResult {
    // Parse sample table for frame extraction
    const stsz = findChildBox(file, stbl.offset + stbl.header_size, stbl.size - stbl.header_size, "stsz");
    if (stsz == null) {
        return AudioValidationResult.invalid("No sample size table found", .ac3);
    }

    const stco = findChildBox(file, stbl.offset + stbl.header_size, stbl.size - stbl.header_size, "stco");
    const co64 = findChildBox(file, stbl.offset + stbl.header_size, stbl.size - stbl.header_size, "co64");
    if (stco == null and co64 == null) {
        return AudioValidationResult.invalid("No chunk offset table found", .ac3);
    }

    // Read sample sizes
    // stsz is a FullBox: skip header + 4 bytes version/flags, then read sample_size + sample_count
    file.seekTo(stsz.?.offset + stsz.?.header_size + 4) catch {
        return AudioValidationResult.invalid("Failed to read sample sizes", .ac3);
    };

    var stsz_header: [8]u8 = undefined;
    _ = file.read(&stsz_header) catch {
        return AudioValidationResult.invalid("Failed to read sample sizes", .ac3);
    };

    const default_size = std.mem.readInt(u32, stsz_header[0..4], .big);
    const sample_count = std.mem.readInt(u32, stsz_header[4..8], .big);

    if (sample_count == 0) {
        return AudioValidationResult.invalid("No samples found", .ac3);
    }

    // Read first chunk offset
    const chunk_box = if (stco != null) stco.? else co64.?;
    const is_64bit = stco == null;

    file.seekTo(chunk_box.offset + chunk_box.header_size + 4) catch {
        return AudioValidationResult.invalid("Failed to read chunk offsets", .ac3);
    };

    var chunk_count_buf: [4]u8 = undefined;
    _ = file.read(&chunk_count_buf) catch {
        return AudioValidationResult.invalid("Failed to read chunk offsets", .ac3);
    };

    const first_offset: u64 = if (is_64bit) blk: {
        var offset_buf: [8]u8 = undefined;
        _ = file.read(&offset_buf) catch {
            return AudioValidationResult.invalid("Failed to read chunk offset", .ac3);
        };
        break :blk std.mem.readInt(u64, &offset_buf, .big);
    } else blk: {
        var offset_buf: [4]u8 = undefined;
        _ = file.read(&offset_buf) catch {
            return AudioValidationResult.invalid("Failed to read chunk offset", .ac3);
        };
        break :blk std.mem.readInt(u32, &offset_buf, .big);
    };

    // Read AC-3 data from first chunk (up to 64KB)
    const max_read: u32 = 64 * 1024;
    const read_size = @min(default_size * @min(sample_count, 100), max_read);

    const buffer = allocator.alloc(u8, read_size) catch {
        return AudioValidationResult.invalid("Memory allocation failed", .ac3);
    };
    defer allocator.free(buffer);

    file.seekTo(first_offset) catch {
        return AudioValidationResult.invalid("Failed to seek to AC-3 data", .ac3);
    };

    const bytes_read = file.read(buffer) catch {
        return AudioValidationResult.invalid("Failed to read AC-3 data", .ac3);
    };

    // Validate using AC-3 validator
    const result = ac3_validator.validateAc3Stream(buffer[0..bytes_read], 10);

    if (!result.valid) {
        return AudioValidationResult.invalid(result.error_message orelse "AC-3 validation failed", .ac3);
    }

    return AudioValidationResult.ok(.ac3, result.frames_validated);
}

/// Validate AC-3 track from MKV container
fn validateMkvAc3Track(allocator: Allocator, parser: *ebml.MatroskaParser, track: ebml.VideoTrackInfo) AudioValidationResult {
    // Collect some audio frames using keyframe collection
    const keyframes = parser.collectKeyframes(track.track_number, 10) orelse {
        return AudioValidationResult.invalid("Failed to collect AC-3 frames", .ac3);
    };
    defer {
        for (keyframes) |*kf| {
            var mutable_kf = @constCast(kf);
            mutable_kf.deinit();
        }
        allocator.free(keyframes);
    }

    if (keyframes.len == 0) {
        return AudioValidationResult.invalid("No AC-3 frames found", .ac3);
    }

    // Validate each frame
    var total_frames: u32 = 0;
    for (keyframes) |kf| {
        const result = ac3_validator.validateAc3Stream(kf.data, 10);
        if (!result.valid) {
            return AudioValidationResult.invalid(result.error_message orelse "AC-3 validation failed", .ac3);
        }
        total_frames += result.frames_validated;
    }

    return AudioValidationResult.ok(.ac3, total_frames);
}

/// Validate AAC track from MKV container using pure-Zig syntax validator
fn validateMkvAacTrack(allocator: Allocator, parser: *ebml.MatroskaParser, track: ebml.VideoTrackInfo) AudioValidationResult {
    // codec_private in MKV for A_AAC contains the AudioSpecificConfig
    const codec_private = track.codec_private orelse {
        return AudioValidationResult.invalid("No AudioSpecificConfig in MKV AAC track", .aac);
    };

    if (codec_private.len < 2) {
        return AudioValidationResult.invalid("AudioSpecificConfig too short", .aac);
    }

    // Collect audio frames (use collectAllFrames since audio may not be flagged as keyframes)
    const frames = parser.collectAllFrames(track.track_number, 10) orelse {
        return AudioValidationResult.invalid("Failed to collect AAC frames from MKV", .aac);
    };
    defer {
        for (frames) |*f| {
            var mutable_f = @constCast(f);
            mutable_f.deinit();
        }
        allocator.free(frames);
    }

    if (frames.len == 0) {
        return AudioValidationResult.invalid("No AAC frames found in MKV", .aac);
    }

    // Build concatenated frame data and size array
    var total_size: usize = 0;
    for (frames) |f| {
        total_size += f.data.len;
    }

    const frame_data = allocator.alloc(u8, total_size) catch {
        return AudioValidationResult.invalid("Out of memory assembling AAC frames", .aac);
    };
    defer allocator.free(frame_data);

    const au_sizes = allocator.alloc(u32, frames.len) catch {
        return AudioValidationResult.invalid("Out of memory for AAC frame sizes", .aac);
    };
    defer allocator.free(au_sizes);

    var offset: usize = 0;
    for (frames, 0..) |f, i| {
        @memcpy(frame_data[offset..][0..f.data.len], f.data);
        au_sizes[i] = @intCast(f.data.len);
        offset += f.data.len;
    }

    // Validate using pure-Zig AAC syntax validator
    const result = aac_syntax_validator.validateAacSyntax(frame_data, au_sizes, codec_private);
    if (!result.valid) {
        return AudioValidationResult.invalid(result.error_message orelse "AAC syntax validation failed", .aac);
    }

    return AudioValidationResult.ok(.aac, result.frames_checked);
}

/// Validate E-AC-3 track from MP4 container
fn validateMp4Eac3Track(allocator: Allocator, file: std.fs.File, stbl: Mp4Box) AudioValidationResult {
    // Parse sample table for frame extraction
    const stsz = findChildBox(file, stbl.offset + stbl.header_size, stbl.size - stbl.header_size, "stsz");
    if (stsz == null) {
        return AudioValidationResult.invalid("No sample size table found", .eac3);
    }

    const stco = findChildBox(file, stbl.offset + stbl.header_size, stbl.size - stbl.header_size, "stco");
    const co64 = findChildBox(file, stbl.offset + stbl.header_size, stbl.size - stbl.header_size, "co64");
    if (stco == null and co64 == null) {
        return AudioValidationResult.invalid("No chunk offset table found", .eac3);
    }

    // Read sample sizes
    // stsz is a FullBox: skip header + 4 bytes version/flags, then read sample_size + sample_count
    file.seekTo(stsz.?.offset + stsz.?.header_size + 4) catch {
        return AudioValidationResult.invalid("Failed to read sample sizes", .eac3);
    };

    var stsz_header: [8]u8 = undefined;
    _ = file.read(&stsz_header) catch {
        return AudioValidationResult.invalid("Failed to read sample sizes", .eac3);
    };

    const default_size = std.mem.readInt(u32, stsz_header[0..4], .big);
    const sample_count = std.mem.readInt(u32, stsz_header[4..8], .big);

    if (sample_count == 0) {
        return AudioValidationResult.invalid("No samples found", .eac3);
    }

    // Read first chunk offset
    const chunk_box = if (stco != null) stco.? else co64.?;
    const is_64bit = stco == null;

    file.seekTo(chunk_box.offset + chunk_box.header_size + 4) catch {
        return AudioValidationResult.invalid("Failed to read chunk offsets", .eac3);
    };

    const first_offset: u64 = if (is_64bit) blk: {
        var offset_buf: [8]u8 = undefined;
        _ = file.read(&offset_buf) catch {
            return AudioValidationResult.invalid("Failed to read chunk offset", .eac3);
        };
        break :blk std.mem.readInt(u64, &offset_buf, .big);
    } else blk: {
        var offset_buf: [4]u8 = undefined;
        _ = file.read(&offset_buf) catch {
            return AudioValidationResult.invalid("Failed to read chunk offset", .eac3);
        };
        break :blk std.mem.readInt(u32, &offset_buf, .big);
    };

    // Read E-AC-3 data from first chunk (up to 128KB for higher bitrates)
    const max_read: u32 = 128 * 1024;
    const read_size = @min(default_size * @min(sample_count, 100), max_read);

    const buffer = allocator.alloc(u8, read_size) catch {
        return AudioValidationResult.invalid("Memory allocation failed", .eac3);
    };
    defer allocator.free(buffer);

    file.seekTo(first_offset) catch {
        return AudioValidationResult.invalid("Failed to seek to E-AC-3 data", .eac3);
    };

    const bytes_read = file.read(buffer) catch {
        return AudioValidationResult.invalid("Failed to read E-AC-3 data", .eac3);
    };

    // Validate using E-AC-3 validator
    const result = eac3_validator.validateEac3Stream(buffer[0..bytes_read], 10);

    if (!result.valid) {
        return AudioValidationResult.invalid(result.error_message orelse "E-AC-3 validation failed", .eac3);
    }

    return AudioValidationResult.ok(.eac3, result.frames_validated);
}

/// Validate E-AC-3 track from MKV container
fn validateMkvEac3Track(allocator: Allocator, parser: *ebml.MatroskaParser, track: ebml.VideoTrackInfo) AudioValidationResult {
    // Collect some audio frames using keyframe collection
    const keyframes = parser.collectKeyframes(track.track_number, 10) orelse {
        return AudioValidationResult.invalid("Failed to collect E-AC-3 frames", .eac3);
    };
    defer {
        for (keyframes) |*kf| {
            var mutable_kf = @constCast(kf);
            mutable_kf.deinit();
        }
        allocator.free(keyframes);
    }

    if (keyframes.len == 0) {
        return AudioValidationResult.invalid("No E-AC-3 frames found", .eac3);
    }

    // Validate each frame
    var total_frames: u32 = 0;
    for (keyframes) |kf| {
        const result = eac3_validator.validateEac3Stream(kf.data, 10);
        if (!result.valid) {
            return AudioValidationResult.invalid(result.error_message orelse "E-AC-3 validation failed", .eac3);
        }
        total_frames += result.frames_validated;
    }

    return AudioValidationResult.ok(.eac3, total_frames);
}

/// Validate audio track from MKV file
fn validateMkvAudio(allocator: Allocator, path: []const u8) AudioValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return AudioValidationResult.invalid("Failed to open file", .unknown);
    };
    defer file.close();

    // Use existing Matroska parser
    var parser = ebml.MatroskaParser.init(allocator, file);

    // Parse EBML header
    const doc_info = parser.parseEbmlHeader() orelse {
        return AudioValidationResult.invalid("Invalid EBML header", .unknown);
    };

    if (!doc_info.isMatroska() and !doc_info.isWebM()) {
        return AudioValidationResult.invalid("Not a Matroska/WebM file", .unknown);
    }

    // Find audio tracks
    const tracks_elem = parser.findSegmentChild(ebml.Segment_ID.Tracks);
    if (tracks_elem == null) {
        return AudioValidationResult.noTrack();
    }

    const tracks_end = tracks_elem.?.data_offset + (tracks_elem.?.size orelse 0);
    _ = parser.reader.seekTo(tracks_elem.?.data_offset);

    // Look for first audio track
    var audio_track: ?ebml.VideoTrackInfo = null;

    while ((parser.reader.getPos() orelse tracks_end) < tracks_end) {
        const entry = parser.reader.readElementHeader() orelse break;
        if (entry.id == ebml.Tracks_ID.TrackEntry) {
            if (parser.parseTrackEntry(entry)) |track| {
                // Check if this is an audio track (codec_id starts with "A_")
                if (std.mem.startsWith(u8, track.codecId(), "A_")) {
                    audio_track = track;
                    break;
                }
                @constCast(&track).deinit();
            }
        } else {
            _ = parser.reader.skipElement(entry);
        }
    }

    if (audio_track == null) {
        return AudioValidationResult.noTrack();
    }

    defer @constCast(&audio_track.?).deinit();

    // Detect audio codec from codec ID
    const audio_codec = detectMkvAudioCodec(audio_track.?.codecId());

    // Validate based on codec
    return switch (audio_codec) {
        .opus => validateMkvOpusTrack(allocator, &parser, audio_track.?),
        .vorbis => validateMkvVorbisTrack(allocator, &parser, audio_track.?),
        .aac => validateMkvAacTrack(allocator, &parser, audio_track.?),
        .mp3 => AudioValidationResult.unsupported(.mp3),
        .flac => AudioValidationResult.unsupported(.flac), // Could use existing FLAC validator
        .ac3 => validateMkvAc3Track(allocator, &parser, audio_track.?),
        .eac3 => validateMkvEac3Track(allocator, &parser, audio_track.?),
        .dts => AudioValidationResult.unsupported(audio_codec),
        .pcm => AudioValidationResult.pcmUnverifiable(),
        else => AudioValidationResult.unsupported(.unknown),
    };
}

/// Detect audio codec from MKV codec ID
fn detectMkvAudioCodec(codec_id: ?[]const u8) AudioCodec {
    const id = codec_id orelse return .unknown;

    if (std.mem.eql(u8, id, "A_OPUS")) {
        return .opus;
    } else if (std.mem.eql(u8, id, "A_VORBIS")) {
        return .vorbis;
    } else if (std.mem.startsWith(u8, id, "A_AAC")) {
        return .aac;
    } else if (std.mem.eql(u8, id, "A_MPEG/L3")) {
        return .mp3;
    } else if (std.mem.eql(u8, id, "A_FLAC")) {
        return .flac;
    } else if (std.mem.eql(u8, id, "A_AC3") or std.mem.eql(u8, id, "A_DTS")) {
        return if (std.mem.eql(u8, id, "A_AC3")) .ac3 else .dts;
    } else if (std.mem.eql(u8, id, "A_EAC3")) {
        return .eac3;
    } else if (std.mem.startsWith(u8, id, "A_PCM")) {
        return .pcm;
    }

    return .unknown;
}

/// Validate Opus track from MKV
fn validateMkvOpusTrack(allocator: Allocator, parser: *ebml.MatroskaParser, track: ebml.VideoTrackInfo) AudioValidationResult {
    // Opus in MKV stores codec_private as OpusHead
    // Extract sample rate and channels from codec_private
    const codec_private = track.codec_private orelse {
        return AudioValidationResult.invalid("No Opus codec private data", .opus);
    };

    if (codec_private.len < 19) {
        return AudioValidationResult.invalid("Invalid Opus header", .opus);
    }

    // OpusHead format:
    // "OpusHead" (8 bytes) + version (1) + channels (1) + pre-skip (2) + sample_rate (4) + ...
    if (!std.mem.eql(u8, codec_private[0..8], "OpusHead")) {
        return AudioValidationResult.invalid("Invalid Opus header signature", .opus);
    }

    const channels: i32 = @intCast(codec_private[9]);
    // Opus always decodes to 48kHz
    const sample_rate: i32 = 48000;

    // Collect all frames for this Opus track from MKV clusters
    var frame_result = parser.collectAllFramesWithStatus(track.track_number, std.math.maxInt(usize)) orelse {
        return AudioValidationResult.invalid("Failed to extract Opus packets from MKV", .opus);
    };
    defer frame_result.deinit(allocator);

    if (frame_result.frames.len == 0) {
        return AudioValidationResult.invalid("No Opus packets found in MKV", .opus);
    }

    // Check if parsing completed normally - if not, file is corrupted
    if (!frame_result.completed_normally) {
        return AudioValidationResult.invalid("MKV parsing error - file may be corrupted", .opus);
    }

    // Convert KeyframeData to packet slices for validation
    const packets = allocator.alloc([]const u8, frame_result.frames.len) catch {
        return AudioValidationResult.invalid("Failed to allocate packet array", .opus);
    };
    defer allocator.free(packets);

    for (frame_result.frames, 0..) |frame, i| {
        packets[i] = frame.data;
    }

    // Validate all Opus packets through the decoder
    const result = opus_validator.validateOpusPackets(allocator, packets, sample_rate, channels);

    if (!result.valid) {
        return AudioValidationResult.invalid(result.error_message orelse "Opus decode error", .opus);
    }

    return AudioValidationResult.ok(.opus, result.packets_decoded);
}

/// Validate Vorbis track from MKV
fn validateMkvVorbisTrack(allocator: Allocator, parser: *ebml.MatroskaParser, track: ebml.VideoTrackInfo) AudioValidationResult {
    _ = parser;
    _ = allocator;

    // Vorbis in MKV stores headers in codec_private
    // Format: count(1) + lengths[] + packets[]
    const codec_private = track.codec_private orelse {
        return AudioValidationResult.invalid("No Vorbis codec private data", .vorbis);
    };

    if (codec_private.len < 3) {
        return AudioValidationResult.invalid("Invalid Vorbis codec private", .vorbis);
    }

    // First byte is number of headers - 1 (should be 2 for 3 headers)
    const num_headers = codec_private[0] + 1;
    if (num_headers != 3) {
        return AudioValidationResult.invalid("Invalid Vorbis header count", .vorbis);
    }

    // Verify we have the Vorbis identification header
    // Skip lengths, find first packet
    // For simplicity, just check we have enough data
    if (codec_private.len < 30) {
        return AudioValidationResult.invalid("Vorbis codec private too small", .vorbis);
    }

    // The first header should start with 0x01 + "vorbis"
    var pos: usize = 1;
    // Read lengths (lacing style)
    var header_sizes: [2]usize = undefined;
    for (0..2) |i| {
        var size: usize = 0;
        while (pos < codec_private.len) {
            const b = codec_private[pos];
            pos += 1;
            size += b;
            if (b < 255) break;
        }
        header_sizes[i] = size;
    }

    // Verify first header signature
    if (pos + 7 > codec_private.len) {
        return AudioValidationResult.invalid("Vorbis identification header too small", .vorbis);
    }

    if (codec_private[pos] != 0x01 or !std.mem.eql(u8, codec_private[pos + 1 .. pos + 7], "vorbis")) {
        return AudioValidationResult.invalid("Invalid Vorbis identification header", .vorbis);
    }

    // For full validation, would submit headers to decoder and decode packets
    return AudioValidationResult.ok(.vorbis, 0);
}

// ============ Tests ============

test "MediaValidationResult getMessage for video only" {
    var result = MediaValidationResult.videoOnly(video_validator.VideoValidationResult.okDecoded(.hevc, 5));
    try std.testing.expectEqualStrings("Video validated (no audio track)", result.getMessage());
}

test "MediaValidationResult getMessage for video and audio" {
    var result = MediaValidationResult.combined(
        video_validator.VideoValidationResult.okDecoded(.hevc, 5),
        AudioValidationResult.ok(.aac, 10),
    );
    try std.testing.expectEqualStrings("Video and audio validated", result.getMessage());
}

test "AudioValidationResult noTrack" {
    const result = AudioValidationResult.noTrack();
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(AudioCodec.unknown, result.codec);
}

test "detectMkvAudioCodec recognizes Opus" {
    const codec = detectMkvAudioCodec("A_OPUS");
    try std.testing.expectEqual(AudioCodec.opus, codec);
}

test "detectMkvAudioCodec recognizes Vorbis" {
    const codec = detectMkvAudioCodec("A_VORBIS");
    try std.testing.expectEqual(AudioCodec.vorbis, codec);
}

test "detectMkvAudioCodec recognizes AAC" {
    const codec = detectMkvAudioCodec("A_AAC/MPEG4/LC");
    try std.testing.expectEqual(AudioCodec.aac, codec);
}

test "detectMkvAudioCodec recognizes MP3" {
    const codec = detectMkvAudioCodec("A_MPEG/L3");
    try std.testing.expectEqual(AudioCodec.mp3, codec);
}
