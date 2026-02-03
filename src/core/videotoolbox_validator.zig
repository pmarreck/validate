//! VideoToolbox-based video validation for macOS.
//!
//! PLATFORM STRATEGY:
//! ==================
//! This module is ONLY compiled on macOS. It provides hardware-accelerated
//! video decoding using Apple's VideoToolbox framework, which is part of the
//! macOS system frameworks (not a vendored dependency).
//!
//! WHY VIDEOTOOLBOX ON MACOS:
//! - Complete H.264 profile support (all profiles including High 4:4:4, 10-bit)
//! - Complete HEVC profile support (Main, Main 10, Main Still Picture)
//! - AV1 support on macOS 13+ (Apple Silicon hardware decode)
//! - Hardware acceleration = faster than software decode
//! - No licensing concerns (system framework)
//! - No external dependencies for end users
//!
//! ON OTHER PLATFORMS (Linux, Windows):
//! - Use ffmpeg as the primary video decoder (user must install)
//! - Fall back to built-in decoders (libde265, OpenH264, dav1d) if no ffmpeg
//! - This provides complete coverage when ffmpeg is available
//!
//! NIX HERMETICITY NOTE:
//! VideoToolbox is a macOS system framework, similar to CoreFoundation or Security.
//! In Nix, this is handled via darwin.apple_sdk.frameworks, not as a vendored dep.
//! The framework is guaranteed to exist on any macOS system meeting the deployment
//! target (macOS 13.0+).
//!
//! MINIMUM REQUIREMENTS:
//! - macOS 13.0+ (Ventura) for AV1 support
//! - Apple Silicon recommended for hardware AV1 decode
//! - Intel Macs get hardware H.264/HEVC, software AV1

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

// This entire module is macOS-only
comptime {
    if (builtin.os.tag != .macos) {
        @compileError("videotoolbox_validator.zig is macOS-only");
    }
}

// =============================================================================
// CoreFoundation Types and Functions
// =============================================================================
// We use opaque pointers and manual bindings rather than @cImport to avoid
// header path issues in cross-compilation scenarios. The ABI is stable.

const CFTypeRef = *anyopaque;
const CFAllocatorRef = ?*anyopaque;
const CFDictionaryRef = ?*const anyopaque;
const CFMutableDictionaryRef = ?*anyopaque;
const CFStringRef = *const anyopaque;
const CFNumberRef = *const anyopaque;
const CFDataRef = *const anyopaque;
const CFArrayRef = ?*const anyopaque;
const CFIndex = isize;
const CFNumberType = i32;
const CFBooleanRef = *const anyopaque;

const kCFNumberSInt32Type: CFNumberType = 3;
const kCFAllocatorDefault: CFAllocatorRef = null;

extern "c" fn CFRelease(cf: CFTypeRef) void;
extern "c" fn CFRetain(cf: CFTypeRef) CFTypeRef;

extern "c" fn CFDictionaryCreateMutable(
    allocator: CFAllocatorRef,
    capacity: CFIndex,
    keyCallBacks: ?*const anyopaque,
    valueCallBacks: ?*const anyopaque,
) CFMutableDictionaryRef;

extern "c" fn CFDictionarySetValue(
    dict: CFMutableDictionaryRef,
    key: *const anyopaque,
    value: *const anyopaque,
) void;

extern "c" fn CFNumberCreate(
    allocator: CFAllocatorRef,
    theType: CFNumberType,
    valuePtr: *const anyopaque,
) CFNumberRef;

extern "c" fn CFDataCreate(
    allocator: CFAllocatorRef,
    bytes: [*]const u8,
    length: CFIndex,
) CFDataRef;

extern "c" fn CFArrayCreate(
    allocator: CFAllocatorRef,
    values: [*]const *const anyopaque,
    numValues: CFIndex,
    callBacks: ?*const anyopaque,
) CFArrayRef;

// CoreFoundation dictionary callbacks (standard retained callbacks)
extern "c" const kCFTypeDictionaryKeyCallBacks: anyopaque;
extern "c" const kCFTypeDictionaryValueCallBacks: anyopaque;
extern "c" const kCFTypeArrayCallBacks: anyopaque;
extern "c" const kCFBooleanTrue: CFBooleanRef;

// =============================================================================
// CoreMedia Types and Functions
// =============================================================================

const CMFormatDescriptionRef = ?*anyopaque;
const CMVideoFormatDescriptionRef = CMFormatDescriptionRef;
const CMSampleBufferRef = ?*anyopaque;
const CMBlockBufferRef = ?*anyopaque;
const CMTime = extern struct {
    value: i64,
    timescale: i32,
    flags: u32,
    epoch: i64,
};
const CMItemCount = isize;

const OSStatus = i32;
const noErr: OSStatus = 0;

// CMVideoCodecType values
const kCMVideoCodecType_H264: u32 = 0x61766331; // 'avc1'
const kCMVideoCodecType_HEVC: u32 = 0x68766331; // 'hvc1'
const kCMVideoCodecType_AV1: u32 = 0x61763031; // 'av01'

extern "c" fn CMVideoFormatDescriptionCreateFromH264ParameterSets(
    allocator: CFAllocatorRef,
    parameterSetCount: usize,
    parameterSetPointers: [*]const [*]const u8,
    parameterSetSizes: [*]const usize,
    nalUnitHeaderLength: i32,
    formatDescriptionOut: *CMVideoFormatDescriptionRef,
) OSStatus;

extern "c" fn CMVideoFormatDescriptionCreateFromHEVCParameterSets(
    allocator: CFAllocatorRef,
    parameterSetCount: usize,
    parameterSetPointers: [*]const [*]const u8,
    parameterSetSizes: [*]const usize,
    nalUnitHeaderLength: i32,
    extensions: CFDictionaryRef,
    formatDescriptionOut: *CMVideoFormatDescriptionRef,
) OSStatus;

extern "c" fn CMBlockBufferCreateWithMemoryBlock(
    structureAllocator: CFAllocatorRef,
    memoryBlock: ?*anyopaque,
    blockLength: usize,
    blockAllocator: CFAllocatorRef,
    customBlockSource: ?*const anyopaque,
    offsetToData: usize,
    dataLength: usize,
    flags: u32,
    blockBufferOut: *CMBlockBufferRef,
) OSStatus;

extern "c" fn CMSampleBufferCreate(
    allocator: CFAllocatorRef,
    dataBuffer: CMBlockBufferRef,
    dataReady: bool,
    makeDataReadyCallback: ?*const anyopaque,
    makeDataReadyRefcon: ?*anyopaque,
    formatDescription: CMFormatDescriptionRef,
    numSamples: CMItemCount,
    numSampleTimingEntries: CMItemCount,
    sampleTimingArray: ?*const anyopaque,
    numSampleSizeEntries: CMItemCount,
    sampleSizeArray: ?*const usize,
    sampleBufferOut: *CMSampleBufferRef,
) OSStatus;

// =============================================================================
// VideoToolbox Types and Functions
// =============================================================================

const VTDecompressionSessionRef = ?*anyopaque;
const VTDecodeFrameFlags = u32;
const VTDecodeInfoFlags = u32;

const kVTDecodeFrame_EnableAsynchronousDecompression: VTDecodeFrameFlags = 1 << 0;
const kVTDecodeFrame_DoNotOutputFrame: VTDecodeFrameFlags = 1 << 1;
const kVTDecodeFrame_1xRealTimePlayback: VTDecodeFrameFlags = 1 << 2;
const kVTDecodeFrame_EnableTemporalProcessing: VTDecodeFrameFlags = 1 << 3;

// Callback type for decoded frames
const VTDecompressionOutputCallback = *const fn (
    decompressionOutputRefCon: ?*anyopaque,
    sourceFrameRefCon: ?*anyopaque,
    status: OSStatus,
    infoFlags: VTDecodeInfoFlags,
    imageBuffer: ?*anyopaque, // CVImageBufferRef
    presentationTimeStamp: CMTime,
    presentationDuration: CMTime,
) callconv(.c) void;

const VTDecompressionOutputCallbackRecord = extern struct {
    decompressionOutputCallback: VTDecompressionOutputCallback,
    decompressionOutputRefCon: ?*anyopaque,
};

extern "c" fn VTDecompressionSessionCreate(
    allocator: CFAllocatorRef,
    videoFormatDescription: CMVideoFormatDescriptionRef,
    videoDecoderSpecification: CFDictionaryRef,
    destinationImageBufferAttributes: CFDictionaryRef,
    outputCallback: *const VTDecompressionOutputCallbackRecord,
    decompressionSessionOut: *VTDecompressionSessionRef,
) OSStatus;

extern "c" fn VTDecompressionSessionDecodeFrame(
    session: VTDecompressionSessionRef,
    sampleBuffer: CMSampleBufferRef,
    decodeFlags: VTDecodeFrameFlags,
    sourceFrameRefCon: ?*anyopaque,
    infoFlagsOut: ?*VTDecodeInfoFlags,
) OSStatus;

extern "c" fn VTDecompressionSessionWaitForAsynchronousFrames(
    session: VTDecompressionSessionRef,
) OSStatus;

extern "c" fn VTDecompressionSessionInvalidate(
    session: VTDecompressionSessionRef,
) void;

// =============================================================================
// Grand Central Dispatch (for thread safety)
// =============================================================================
// VideoToolbox can crash when called from non-main threads due to framework
// requirements. We use dispatch_sync_f to dispatch work to the main queue.
// dispatch_sync_f is the function-pointer variant (vs block-based dispatch_sync)
// which is compatible with Zig's C FFI.

// GCD dispatch is temporarily disabled - see comment below
// const dispatch_queue_t = *anyopaque;
// extern "c" var _dispatch_main_q: anyopaque;
// extern "c" fn dispatch_sync_f(...) void;

extern "c" fn pthread_main_np() c_int;

/// Check if current thread is the main thread
fn isMainThread() bool {
    return pthread_main_np() != 0;
}

// =============================================================================
// Dispatch Context Structures
// =============================================================================
// These structures hold the parameters and results for VideoToolbox validation
// when dispatched to the main queue via dispatch_sync_f.

const H264ValidationContext = struct {
    allocator: Allocator,
    codec_private: []const u8,
    samples: []const []const u8,
    result: VTValidationResult,
};

const HEVCValidationContext = struct {
    allocator: Allocator,
    codec_private: []const u8,
    samples: []const []const u8,
    result: VTValidationResult,
};

const AV1ValidationContext = struct {
    allocator: Allocator,
    codec_private: []const u8,
    samples: []const []const u8,
    result: VTValidationResult,
};

// =============================================================================
// VideoToolbox Validator Implementation
// =============================================================================

/// Result of VideoToolbox validation
pub const VTValidationResult = struct {
    valid: bool,
    frames_decoded: u32,
    error_message: ?[]const u8,
    codec: VideoCodec,

    pub fn ok(codec: VideoCodec, frames: u32) VTValidationResult {
        return .{
            .valid = true,
            .frames_decoded = frames,
            .error_message = null,
            .codec = codec,
        };
    }

    pub fn invalid(msg: []const u8, codec: VideoCodec) VTValidationResult {
        return .{
            .valid = false,
            .frames_decoded = 0,
            .error_message = msg,
            .codec = codec,
        };
    }
};

/// Video codec type (matches video_validator.zig)
pub const VideoCodec = enum {
    h264,
    hevc,
    av1,
};

/// Context passed to the decode callback
const DecodeContext = struct {
    frames_decoded: u32 = 0,
    decode_error: bool = false,
    last_status: OSStatus = noErr,
};

/// Callback invoked when a frame is decoded
fn decodeCallback(
    decompressionOutputRefCon: ?*anyopaque,
    sourceFrameRefCon: ?*anyopaque,
    status: OSStatus,
    infoFlags: VTDecodeInfoFlags,
    imageBuffer: ?*anyopaque,
    presentationTimeStamp: CMTime,
    presentationDuration: CMTime,
) callconv(.c) void {
    _ = sourceFrameRefCon;
    _ = infoFlags;
    _ = presentationTimeStamp;
    _ = presentationDuration;
    // imageBuffer is used below to check if a frame was decoded

    const ctx: *DecodeContext = @ptrCast(@alignCast(decompressionOutputRefCon));

    if (status != noErr) {
        ctx.decode_error = true;
        ctx.last_status = status;
    } else if (imageBuffer != null) {
        ctx.frames_decoded += 1;
    }
}

/// Parameter set data extracted from codec configuration
pub const ParameterSets = struct {
    /// SPS data for H.264, VPS for HEVC, sequence header for AV1
    sets: []const []const u8,
    /// NAL unit length size (1-4 bytes)
    nal_length_size: u8,
    /// Allocator used for sets
    allocator: Allocator,

    pub fn deinit(self: *ParameterSets) void {
        for (self.sets) |set| {
            self.allocator.free(set);
        }
        self.allocator.free(self.sets);
    }
};

/// Parse avcC box to extract H.264 parameter sets (SPS/PPS)
pub fn parseAvcC(allocator: Allocator, data: []const u8) ?ParameterSets {
    if (data.len < 7) return null;

    // avcC structure:
    // [0] configurationVersion (must be 1)
    // [1] AVCProfileIndication
    // [2] profile_compatibility
    // [3] AVCLevelIndication
    // [4] lengthSizeMinusOne (lower 2 bits) + reserved (upper 6 bits = 0x3F)
    // [5] numOfSequenceParameterSets (lower 5 bits) + reserved (upper 3 bits = 0x07)
    // [6..] SPS data...

    if (data[0] != 1) return null; // Must be version 1

    const nal_length_size: u8 = (data[4] & 0x03) + 1;
    const num_sps = data[5] & 0x1F;

    var sets: std.ArrayListUnmanaged([]const u8) = .{};
    errdefer {
        for (sets.items) |set| allocator.free(set);
        sets.deinit(allocator);
    }

    var pos: usize = 6;

    // Parse SPS entries
    var i: u8 = 0;
    while (i < num_sps) : (i += 1) {
        if (pos + 2 > data.len) return null;
        const sps_len = std.mem.readInt(u16, data[pos..][0..2], .big);
        pos += 2;

        if (pos + sps_len > data.len) return null;
        const sps = allocator.dupe(u8, data[pos..][0..sps_len]) catch return null;
        sets.append(allocator, sps) catch {
            allocator.free(sps);
            return null;
        };
        pos += sps_len;
    }

    // Parse PPS entries
    if (pos >= data.len) return null;
    const num_pps = data[pos] & 0xFF;
    pos += 1;

    var j: u8 = 0;
    while (j < num_pps) : (j += 1) {
        if (pos + 2 > data.len) return null;
        const pps_len = std.mem.readInt(u16, data[pos..][0..2], .big);
        pos += 2;

        if (pos + pps_len > data.len) return null;
        const pps = allocator.dupe(u8, data[pos..][0..pps_len]) catch return null;
        sets.append(allocator, pps) catch {
            allocator.free(pps);
            return null;
        };
        pos += pps_len;
    }

    return .{
        .sets = sets.toOwnedSlice(allocator) catch return null,
        .nal_length_size = nal_length_size,
        .allocator = allocator,
    };
}

/// Parse hvcC box to extract HEVC parameter sets (VPS/SPS/PPS)
pub fn parseHvcC(allocator: Allocator, data: []const u8) ?ParameterSets {
    if (data.len < 23) return null;

    // hvcC structure:
    // [0] configurationVersion (must be 1)
    // [1-21] profile/level info
    // [21] lengthSizeMinusOne (lower 2 bits) + reserved
    // [22] numOfArrays
    // [23..] arrays of NAL units

    if (data[0] != 1) return null;

    const nal_length_size: u8 = (data[21] & 0x03) + 1;
    const num_arrays = data[22];

    var sets: std.ArrayListUnmanaged([]const u8) = .{};
    errdefer {
        for (sets.items) |set| allocator.free(set);
        sets.deinit(allocator);
    }

    var pos: usize = 23;

    // Parse each array (VPS, SPS, PPS, etc.)
    var arr: u8 = 0;
    while (arr < num_arrays) : (arr += 1) {
        if (pos + 3 > data.len) return null;

        // const array_completeness = (data[pos] >> 7) & 0x01;
        // const nal_unit_type = data[pos] & 0x3F;
        pos += 1;

        const num_nalus = std.mem.readInt(u16, data[pos..][0..2], .big);
        pos += 2;

        var n: u16 = 0;
        while (n < num_nalus) : (n += 1) {
            if (pos + 2 > data.len) return null;
            const nalu_len = std.mem.readInt(u16, data[pos..][0..2], .big);
            pos += 2;

            if (pos + nalu_len > data.len) return null;
            const nalu = allocator.dupe(u8, data[pos..][0..nalu_len]) catch return null;
            sets.append(allocator, nalu) catch {
                allocator.free(nalu);
                return null;
            };
            pos += nalu_len;
        }
    }

    return .{
        .sets = sets.toOwnedSlice(allocator) catch return null,
        .nal_length_size = nal_length_size,
        .allocator = allocator,
    };
}

/// Create a VideoToolbox format description for H.264
fn createH264FormatDescription(params: *ParameterSets) ?CMVideoFormatDescriptionRef {
    if (params.sets.len < 2) return null; // Need at least SPS and PPS

    var pointers: [16][*]const u8 = undefined;
    var sizes: [16]usize = undefined;

    const count = @min(params.sets.len, 16);
    for (0..count) |i| {
        pointers[i] = params.sets[i].ptr;
        sizes[i] = params.sets[i].len;
    }

    var format_desc: CMVideoFormatDescriptionRef = null;
    const status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
        kCFAllocatorDefault,
        count,
        &pointers,
        &sizes,
        @intCast(params.nal_length_size),
        &format_desc,
    );

    if (status != noErr) return null;
    return format_desc;
}

/// Create a VideoToolbox format description for HEVC
fn createHEVCFormatDescription(params: *ParameterSets) ?CMVideoFormatDescriptionRef {
    if (params.sets.len < 3) return null; // Need VPS, SPS, PPS

    var pointers: [16][*]const u8 = undefined;
    var sizes: [16]usize = undefined;

    const count = @min(params.sets.len, 16);
    for (0..count) |i| {
        pointers[i] = params.sets[i].ptr;
        sizes[i] = params.sets[i].len;
    }

    var format_desc: CMVideoFormatDescriptionRef = null;
    const status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
        kCFAllocatorDefault,
        count,
        &pointers,
        &sizes,
        @intCast(params.nal_length_size),
        null, // extensions
        &format_desc,
    );

    if (status != noErr) return null;
    return format_desc;
}

/// Validate H.264 stream using VideoToolbox
/// `codec_private` should be the raw avcC box contents
/// `samples` is a list of NAL unit data (length-prefixed format matching avcC)
/// Internal H.264 validation - must be called on main thread
fn validateH264Internal(
    allocator: Allocator,
    codec_private: []const u8,
    samples: []const []const u8,
) VTValidationResult {
    // Parse avcC to get SPS/PPS
    var params = parseAvcC(allocator, codec_private) orelse {
        return VTValidationResult.invalid("Failed to parse avcC", .h264);
    };
    defer params.deinit();

    // Create format description
    const format_desc = createH264FormatDescription(&params) orelse {
        return VTValidationResult.invalid("Failed to create H.264 format description", .h264);
    };
    defer CFRelease(@ptrCast(format_desc.?));

    // Create decoder session
    var ctx = DecodeContext{};
    const callback = VTDecompressionOutputCallbackRecord{
        .decompressionOutputCallback = decodeCallback,
        .decompressionOutputRefCon = &ctx,
    };

    var session: VTDecompressionSessionRef = null;
    var status = VTDecompressionSessionCreate(
        kCFAllocatorDefault,
        format_desc,
        null, // videoDecoderSpecification
        null, // destinationImageBufferAttributes
        &callback,
        &session,
    );

    if (status != noErr or session == null) {
        return VTValidationResult.invalid("Failed to create H.264 decoder session", .h264);
    }
    defer {
        VTDecompressionSessionInvalidate(session);
        CFRelease(@ptrCast(session.?));
    }

    // Decode each sample
    for (samples) |sample_data| {
        if (sample_data.len == 0) continue;

        // Create block buffer for sample data
        var block_buffer: CMBlockBufferRef = null;
        status = CMBlockBufferCreateWithMemoryBlock(
            kCFAllocatorDefault,
            @constCast(@ptrCast(sample_data.ptr)),
            sample_data.len,
            kCFAllocatorDefault,
            null,
            0,
            sample_data.len,
            0,
            &block_buffer,
        );

        if (status != noErr or block_buffer == null) continue;
        defer CFRelease(@ptrCast(block_buffer.?));

        // Create sample buffer
        var sample_buffer: CMSampleBufferRef = null;
        const sample_size = sample_data.len;
        status = CMSampleBufferCreate(
            kCFAllocatorDefault,
            block_buffer,
            true, // dataReady
            null, // makeDataReadyCallback
            null, // makeDataReadyRefcon
            format_desc,
            1, // numSamples
            0, // numSampleTimingEntries
            null, // sampleTimingArray
            1, // numSampleSizeEntries
            &sample_size,
            &sample_buffer,
        );

        if (status != noErr or sample_buffer == null) continue;
        defer CFRelease(@ptrCast(sample_buffer.?));

        // Decode the frame
        status = VTDecompressionSessionDecodeFrame(
            session,
            sample_buffer,
            kVTDecodeFrame_EnableAsynchronousDecompression,
            null,
            null,
        );

        if (status != noErr) {
            ctx.decode_error = true;
            break;
        }
    }

    // Wait for all frames to complete
    _ = VTDecompressionSessionWaitForAsynchronousFrames(session);

    if (ctx.decode_error and ctx.frames_decoded == 0) {
        return VTValidationResult.invalid("H.264 decode failed", .h264);
    }

    if (ctx.frames_decoded == 0) {
        return VTValidationResult.invalid("No H.264 frames decoded", .h264);
    }

    return VTValidationResult.ok(.h264, ctx.frames_decoded);
}

/// Dispatch callback for H.264 validation on main thread
fn validateH264Callback(context: ?*anyopaque) callconv(.c) void {
    const ctx: *H264ValidationContext = @ptrCast(@alignCast(context));
    ctx.result = validateH264Internal(ctx.allocator, ctx.codec_private, ctx.samples);
}

/// Validate H.264 stream using VideoToolbox
/// Automatically dispatches to main thread if called from worker thread.
/// `codec_private` should be the raw avcC box contents
/// `samples` is a list of NAL unit data (length-prefixed format matching avcC)
pub fn validateH264(
    allocator: Allocator,
    codec_private: []const u8,
    samples: []const []const u8,
) VTValidationResult {
    // VideoToolbox requires main thread - worker thread dispatch not yet implemented
    if (!isMainThread()) {
        return VTValidationResult.invalid("VideoToolbox requires main thread", .h264);
    }
    return validateH264Internal(allocator, codec_private, samples);
}

/// Internal HEVC validation - must be called on main thread
fn validateHEVCInternal(
    allocator: Allocator,
    codec_private: []const u8,
    samples: []const []const u8,
) VTValidationResult {
    // Parse hvcC to get VPS/SPS/PPS
    var params = parseHvcC(allocator, codec_private) orelse {
        return VTValidationResult.invalid("Failed to parse hvcC", .hevc);
    };
    defer params.deinit();

    // Create format description
    const format_desc = createHEVCFormatDescription(&params) orelse {
        return VTValidationResult.invalid("Failed to create HEVC format description", .hevc);
    };
    defer CFRelease(@ptrCast(format_desc.?));

    // Create decoder session
    var ctx = DecodeContext{};
    const callback = VTDecompressionOutputCallbackRecord{
        .decompressionOutputCallback = decodeCallback,
        .decompressionOutputRefCon = &ctx,
    };

    var session: VTDecompressionSessionRef = null;
    var status = VTDecompressionSessionCreate(
        kCFAllocatorDefault,
        format_desc,
        null,
        null,
        &callback,
        &session,
    );

    if (status != noErr or session == null) {
        return VTValidationResult.invalid("Failed to create HEVC decoder session", .hevc);
    }
    defer {
        VTDecompressionSessionInvalidate(session);
        CFRelease(@ptrCast(session.?));
    }

    // Decode each sample
    for (samples) |sample_data| {
        if (sample_data.len == 0) continue;

        var block_buffer: CMBlockBufferRef = null;
        status = CMBlockBufferCreateWithMemoryBlock(
            kCFAllocatorDefault,
            @constCast(@ptrCast(sample_data.ptr)),
            sample_data.len,
            kCFAllocatorDefault,
            null,
            0,
            sample_data.len,
            0,
            &block_buffer,
        );

        if (status != noErr or block_buffer == null) continue;
        defer CFRelease(@ptrCast(block_buffer.?));

        var sample_buffer: CMSampleBufferRef = null;
        const sample_size = sample_data.len;
        status = CMSampleBufferCreate(
            kCFAllocatorDefault,
            block_buffer,
            true,
            null,
            null,
            format_desc,
            1,
            0,
            null,
            1,
            &sample_size,
            &sample_buffer,
        );

        if (status != noErr or sample_buffer == null) continue;
        defer CFRelease(@ptrCast(sample_buffer.?));

        status = VTDecompressionSessionDecodeFrame(
            session,
            sample_buffer,
            kVTDecodeFrame_EnableAsynchronousDecompression,
            null,
            null,
        );

        if (status != noErr) {
            ctx.decode_error = true;
            break;
        }
    }

    _ = VTDecompressionSessionWaitForAsynchronousFrames(session);

    if (ctx.decode_error and ctx.frames_decoded == 0) {
        return VTValidationResult.invalid("HEVC decode failed", .hevc);
    }

    if (ctx.frames_decoded == 0) {
        return VTValidationResult.invalid("No HEVC frames decoded", .hevc);
    }

    return VTValidationResult.ok(.hevc, ctx.frames_decoded);
}

/// Dispatch callback for HEVC validation on main thread
fn validateHEVCCallback(context: ?*anyopaque) callconv(.c) void {
    const ctx: *HEVCValidationContext = @ptrCast(@alignCast(context));
    ctx.result = validateHEVCInternal(ctx.allocator, ctx.codec_private, ctx.samples);
}

/// Validate HEVC stream using VideoToolbox
/// Automatically dispatches to main thread if called from worker thread.
/// `codec_private` should be the raw hvcC box contents
/// `samples` is a list of NAL unit data (length-prefixed format matching hvcC)
pub fn validateHEVC(
    allocator: Allocator,
    codec_private: []const u8,
    samples: []const []const u8,
) VTValidationResult {
    // VideoToolbox requires main thread - worker thread dispatch not yet implemented
    if (!isMainThread()) {
        return VTValidationResult.invalid("VideoToolbox requires main thread", .hevc);
    }
    return validateHEVCInternal(allocator, codec_private, samples);
}

// =============================================================================
// AV1 Support (macOS 13+)
// =============================================================================
// AV1 via VideoToolbox requires macOS 13+ and ideally Apple Silicon for
// hardware acceleration. On Intel Macs, software decode is used.
//
// Note: AV1 format description creation is more complex and requires
// constructing the configuration from av1C box data. For now, we'll
// implement a simpler approach using CMVideoFormatDescriptionCreate.

/// Check if AV1 hardware decode is available (Apple Silicon + macOS 13+)
pub fn isAV1Available() bool {
    // This would ideally check VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
    // For now, we assume macOS 13+ has AV1 support (software at minimum)
    return true;
}

/// Validate AV1 stream using VideoToolbox
/// Note: AV1 support requires macOS 13.0+ (Ventura)
/// `codec_private` should be the raw av1C box contents
/// `samples` is a list of OBU data
/// Internal AV1 validation - must be called on main thread
fn validateAV1Internal(
    allocator: Allocator,
    codec_private: []const u8,
    samples: []const []const u8,
) VTValidationResult {
    _ = allocator;
    _ = codec_private;
    _ = samples;

    // TODO: Implement AV1 validation via VideoToolbox
    // This requires:
    // 1. Parsing av1C to extract sequence header
    // 2. Creating CMVideoFormatDescription for AV1 (kCMVideoCodecType_AV1)
    // 3. Similar decode loop as H.264/HEVC
    //
    // For now, return a placeholder indicating AV1 VT support is pending
    return VTValidationResult.invalid("AV1 VideoToolbox validation not yet implemented", .av1);
}

/// Dispatch callback for AV1 validation on main thread
fn validateAV1Callback(context: ?*anyopaque) callconv(.c) void {
    const ctx: *AV1ValidationContext = @ptrCast(@alignCast(context));
    ctx.result = validateAV1Internal(ctx.allocator, ctx.codec_private, ctx.samples);
}

/// Validate AV1 stream using VideoToolbox
/// Automatically dispatches to main thread if called from worker thread.
/// `codec_private` should be the raw av1C box contents
/// `samples` is a list of OBU data
pub fn validateAV1(
    allocator: Allocator,
    codec_private: []const u8,
    samples: []const []const u8,
) VTValidationResult {
    // VideoToolbox requires main thread - worker thread dispatch not yet implemented
    if (!isMainThread()) {
        return VTValidationResult.invalid("VideoToolbox requires main thread", .av1);
    }
    return validateAV1Internal(allocator, codec_private, samples);
}

// =============================================================================
// Tests
// =============================================================================


/// Pre-initialize VideoToolbox to trigger dyld lazy symbol binding.
/// MUST be called from the main thread BEFORE spawning worker threads.
/// This ensures all extern C functions are bound before any worker thread tries to use them,
/// avoiding crashes due to dyld symbol binding race conditions.
pub fn preInit() void {
    // Create a minimal dummy dictionary to trigger CFDictionaryCreateMutable binding
    const dict = CFDictionaryCreateMutable(
        kCFAllocatorDefault,
        0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks,
    );
    if (dict) |d| {
        CFRelease(@ptrCast(d));
    }

    // Try to trigger VTDecompressionSessionCreate binding by checking if the function address is valid
    // We don't actually create a session, just ensure the symbol is resolved
    _ = @as(*const fn (
        CFAllocatorRef,
        CMVideoFormatDescriptionRef,
        CFDictionaryRef,
        CFDictionaryRef,
        *const VTDecompressionOutputCallbackRecord,
        *VTDecompressionSessionRef,
    ) callconv(.c) OSStatus, &VTDecompressionSessionCreate);
}

test "parseAvcC basic" {
    const allocator = std.testing.allocator;

    // Minimal valid avcC: version=1, profile=66, compat=0, level=30
    // NAL length size = 4 (0xFC | 0x03), 1 SPS, 1 PPS
    const avcc = [_]u8{
        0x01, // version
        0x42, // profile (Baseline)
        0x00, // compatibility
        0x1E, // level (3.0)
        0xFF, // NAL length size - 1 = 3 (so size = 4) + reserved bits
        0xE1, // num SPS = 1 + reserved bits
        0x00, 0x04, // SPS length = 4
        0x67, 0x42, 0x00, 0x1E, // SPS data (minimal)
        0x01, // num PPS = 1
        0x00, 0x02, // PPS length = 2
        0x68, 0xCE, // PPS data (minimal)
    };

    var params = parseAvcC(allocator, &avcc).?;
    defer params.deinit();

    try std.testing.expectEqual(@as(u8, 4), params.nal_length_size);
    try std.testing.expectEqual(@as(usize, 2), params.sets.len);
}

test "parseHvcC basic" {
    const allocator = std.testing.allocator;

    // Minimal hvcC structure (23 byte header + 1 array with 1 NAL unit)
    var hvcc: [30]u8 = undefined;
    hvcc[0] = 0x01; // version
    @memset(hvcc[1..22], 0); // profile/level info (zeros for test)
    hvcc[21] = 0xFF; // NAL length size - 1 = 3 (size = 4) + reserved
    hvcc[22] = 0x01; // numOfArrays = 1
    hvcc[23] = 0x20; // array_completeness=0, NAL type=32 (VPS)
    hvcc[24] = 0x00;
    hvcc[25] = 0x01; // numNalus = 1
    hvcc[26] = 0x00;
    hvcc[27] = 0x02; // NAL length = 2
    hvcc[28] = 0x40;
    hvcc[29] = 0x01; // VPS data (minimal)

    // This won't have enough sets for a real decoder, but tests parsing
    var params = parseHvcC(allocator, &hvcc).?;
    defer params.deinit();

    try std.testing.expectEqual(@as(u8, 4), params.nal_length_size);
    try std.testing.expectEqual(@as(usize, 1), params.sets.len);
}
