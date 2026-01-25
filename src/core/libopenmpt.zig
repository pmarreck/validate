//! libopenmpt Zig bindings for tracker format validation.
//!
//! This module provides Zig bindings for libopenmpt, a library that can decode
//! tracker music formats (MOD, XM, IT, S3M, etc.) into PCM audio.
//!
//! For validation purposes, we:
//! 1. Load the module from memory
//! 2. Extract metadata (channels, patterns, samples, instruments)
//! 3. Optionally render a small amount of audio to verify decode
//!
//! Supported formats: MOD, S3M, XM, IT, MPTM, and many more obscure tracker formats.

const std = @import("std");

const c = @cImport({
    @cInclude("libopenmpt/libopenmpt.h");
});

/// Result of tracker module validation
pub const TrackerValidationResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    /// Module metadata (only set if valid)
    metadata: ?ModuleMetadata,

    pub fn ok(meta: ModuleMetadata) TrackerValidationResult {
        return .{ .valid = true, .error_message = null, .metadata = meta };
    }

    pub fn invalid(message: []const u8) TrackerValidationResult {
        return .{ .valid = false, .error_message = message, .metadata = null };
    }
};

/// Metadata extracted from a tracker module
pub const ModuleMetadata = struct {
    /// Module title
    title: ?[]const u8,
    /// Number of channels used
    num_channels: i32,
    /// Number of patterns
    num_patterns: i32,
    /// Number of orders (song length)
    num_orders: i32,
    /// Number of instruments
    num_instruments: i32,
    /// Number of samples
    num_samples: i32,
    /// Duration in seconds (estimated)
    duration_seconds: f64,
    /// Module type (e.g., "mod", "xm", "it", "s3m")
    module_type: ?[]const u8,
    /// Tracker that created it (if known)
    tracker: ?[]const u8,

    // Internal: strings allocated by libopenmpt that need freeing
    _title_ptr: ?[*:0]const u8 = null,
    _type_ptr: ?[*:0]const u8 = null,
    _tracker_ptr: ?[*:0]const u8 = null,

    pub fn deinit(self: *ModuleMetadata) void {
        if (self._title_ptr) |ptr| c.openmpt_free_string(ptr);
        if (self._type_ptr) |ptr| c.openmpt_free_string(ptr);
        if (self._tracker_ptr) |ptr| c.openmpt_free_string(ptr);
        self._title_ptr = null;
        self._type_ptr = null;
        self._tracker_ptr = null;
        self.title = null;
        self.module_type = null;
        self.tracker = null;
    }
};

/// Opaque handle to a loaded module
pub const Module = struct {
    handle: *c.openmpt_module,

    /// Create a module from memory buffer
    pub fn createFromMemory(data: []const u8) ?Module {
        var error_code: c_int = 0;
        var error_message: ?[*:0]const u8 = null;

        const mod = c.openmpt_module_create_from_memory2(
            data.ptr,
            data.len,
            null, // logfunc
            null, // loguser
            null, // errfunc
            null, // erruser
            &error_code,
            @ptrCast(&error_message),
            null, // ctls
        );

        if (error_message) |msg| {
            c.openmpt_free_string(msg);
        }

        if (mod) |m| {
            return Module{ .handle = m };
        }
        return null;
    }

    /// Destroy the module and free resources
    pub fn destroy(self: *Module) void {
        c.openmpt_module_destroy(self.handle);
    }

    /// Get the number of channels
    pub fn getNumChannels(self: Module) i32 {
        return c.openmpt_module_get_num_channels(self.handle);
    }

    /// Get the number of patterns
    pub fn getNumPatterns(self: Module) i32 {
        return c.openmpt_module_get_num_patterns(self.handle);
    }

    /// Get the number of orders (song length)
    pub fn getNumOrders(self: Module) i32 {
        return c.openmpt_module_get_num_orders(self.handle);
    }

    /// Get the number of instruments
    pub fn getNumInstruments(self: Module) i32 {
        return c.openmpt_module_get_num_instruments(self.handle);
    }

    /// Get the number of samples
    pub fn getNumSamples(self: Module) i32 {
        return c.openmpt_module_get_num_samples(self.handle);
    }

    /// Get the duration in seconds
    pub fn getDurationSeconds(self: Module) f64 {
        return c.openmpt_module_get_duration_seconds(self.handle);
    }

    /// Get metadata by key (caller must free with openmpt_free_string)
    pub fn getMetadata(self: Module, key: [:0]const u8) ?[*:0]const u8 {
        const result = c.openmpt_module_get_metadata(self.handle, key.ptr);
        if (result) |r| {
            // Check if empty string
            if (r[0] == 0) {
                c.openmpt_free_string(r);
                return null;
            }
            return r;
        }
        return null;
    }

    /// Render audio to verify decode works.
    /// Returns the number of frames rendered, or 0 on error.
    pub fn readStereo(self: Module, sample_rate: i32, buffer_left: []f32, buffer_right: []f32) usize {
        const count = @min(buffer_left.len, buffer_right.len);
        return c.openmpt_module_read_float_stereo(
            self.handle,
            sample_rate,
            count,
            buffer_left.ptr,
            buffer_right.ptr,
        );
    }
};

/// Probe whether data might be a supported tracker format.
/// Returns true if libopenmpt thinks it can open this file.
pub fn probeFileHeader(data: []const u8, file_size: u64) bool {
    const flags = c.OPENMPT_PROBE_FILE_HEADER_FLAGS_DEFAULT;
    var error_code: c_int = 0;
    var error_message: ?[*:0]const u8 = null;

    const result = c.openmpt_probe_file_header(
        flags,
        data.ptr,
        data.len,
        file_size,
        null, // logfunc
        null, // loguser
        null, // errfunc
        null, // erruser
        &error_code,
        @ptrCast(&error_message),
    );

    if (error_message) |msg| {
        c.openmpt_free_string(msg);
    }

    return result == c.OPENMPT_PROBE_FILE_HEADER_RESULT_SUCCESS;
}

/// Get the recommended probe size in bytes
pub fn getProbeSize() usize {
    return c.openmpt_probe_file_header_get_recommended_size();
}

/// Get a semicolon-separated list of supported extensions
pub fn getSupportedExtensions() ?[]const u8 {
    const result = c.openmpt_get_supported_extensions();
    if (result) |r| {
        const len = std.mem.len(r);
        if (len == 0) {
            c.openmpt_free_string(r);
            return null;
        }
        // Note: This leaks the string, but it's only called once typically
        return r[0..len];
    }
    return null;
}

/// Check if an extension is supported (without leading dot, lowercase)
pub fn isExtensionSupported(ext: [:0]const u8) bool {
    return c.openmpt_is_extension_supported(ext.ptr) != 0;
}

/// Validate a tracker file by loading it and optionally rendering audio.
/// This performs full decode validation.
pub fn validateTrackerFile(data: []const u8, render_audio: bool) TrackerValidationResult {
    // First, try to probe if this looks like a valid tracker file
    if (data.len < getProbeSize()) {
        // Try with what we have
        if (!probeFileHeader(data, data.len)) {
            return TrackerValidationResult.invalid("Not a recognized tracker format");
        }
    } else {
        if (!probeFileHeader(data[0..getProbeSize()], data.len)) {
            return TrackerValidationResult.invalid("Not a recognized tracker format");
        }
    }

    // Try to load the module
    var mod = Module.createFromMemory(data) orelse {
        return TrackerValidationResult.invalid("Failed to load module - file may be corrupted");
    };
    defer mod.destroy();

    // Extract metadata
    var metadata = ModuleMetadata{
        .title = null,
        .num_channels = mod.getNumChannels(),
        .num_patterns = mod.getNumPatterns(),
        .num_orders = mod.getNumOrders(),
        .num_instruments = mod.getNumInstruments(),
        .num_samples = mod.getNumSamples(),
        .duration_seconds = mod.getDurationSeconds(),
        .module_type = null,
        .tracker = null,
    };

    // Get string metadata
    if (mod.getMetadata("title")) |title| {
        metadata._title_ptr = title;
        metadata.title = std.mem.sliceTo(title, 0);
    }

    if (mod.getMetadata("type")) |type_str| {
        metadata._type_ptr = type_str;
        metadata.module_type = std.mem.sliceTo(type_str, 0);
    }

    if (mod.getMetadata("tracker")) |tracker| {
        metadata._tracker_ptr = tracker;
        metadata.tracker = std.mem.sliceTo(tracker, 0);
    }

    // Sanity check - modules should have at least some content
    if (metadata.num_channels <= 0 or metadata.num_patterns <= 0 or metadata.num_orders <= 0) {
        metadata.deinit();
        return TrackerValidationResult.invalid("Module has no playable content");
    }

    // Optionally render some audio to verify decode
    if (render_audio) {
        var left_buf: [1024]f32 = undefined;
        var right_buf: [1024]f32 = undefined;

        const frames = mod.readStereo(48000, &left_buf, &right_buf);
        if (frames == 0) {
            metadata.deinit();
            return TrackerValidationResult.invalid("Failed to render audio - decode error");
        }
    }

    return TrackerValidationResult.ok(metadata);
}

// ============ Tests ============

test "probe size is reasonable" {
    const size = getProbeSize();
    try std.testing.expect(size > 0);
    try std.testing.expect(size < 65536); // Should be well under 64KB
}

test "extension support check" {
    try std.testing.expect(isExtensionSupported("mod"));
    try std.testing.expect(isExtensionSupported("xm"));
    try std.testing.expect(isExtensionSupported("it"));
    try std.testing.expect(isExtensionSupported("s3m"));
    try std.testing.expect(!isExtensionSupported("mp3"));
    try std.testing.expect(!isExtensionSupported("wav"));
}

test "supported extensions list" {
    const exts = getSupportedExtensions();
    try std.testing.expect(exts != null);
    if (exts) |e| {
        try std.testing.expect(e.len > 0);
        // Should contain common formats
        try std.testing.expect(std.mem.indexOf(u8, e, "mod") != null);
        try std.testing.expect(std.mem.indexOf(u8, e, "xm") != null);
    }
}
