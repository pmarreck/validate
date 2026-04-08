//! C API exports for Validate core
//!
//! Returns KV-US-RS formatted strings for maximum FFI flexibility.
//!
//! ============================================================================
//! KV-US-RS Serialization Format Specification
//! ============================================================================
//!
//! A simple, FFI-friendly key-value format using ASCII control characters
//! as delimiters. Designed for easy parsing in any language without escaping.
//!
//! STRUCTURE:
//!   key1<US>value1<RS>key2<US>value2<RS>key3<US>value3
//!
//!   <US> = 0x1F (Unit Separator) - separates key from value within a pair
//!   <RS> = 0x1E (Record Separator) - separates key-value pairs
//!
//! PARSING:
//!   1. Split string on RS (0x1E) to get key-value pairs
//!   2. Split each pair on US (0x1F) to get [key, value]
//!   3. Build a map/dict from the pairs
//!
//! TYPE CONVENTIONS (encoded in key names):
//!   _u8, _u16, _u32, _u64  - Unsigned integers (decimal, 0x hex, or 0b binary)
//!   _i8, _i16, _i32, _i64  - Signed integers
//!   _ns, _ms, _s           - Time units (combined: elapsed_ns_u64)
//!   No suffix              - UTF-8 string or boolean
//!
//! BOOLEAN SEMANTICS:
//!   Falsy:  "F", "0", empty string, or key absent
//!   Truthy: Everything else ("T", "1", "yes", any non-empty non-falsy value)
//!
//! EXAMPLE:
//!   fmt_id<US>png<RS>fmt_cat<US>image<RS>fmt_desc<US>PNG Image<RS>valid<US>T<RS>depth_u8<US>1
//!
//! BENEFITS:
//!   - No escaping needed (US/RS never appear in normal text or file paths)
//!   - Zero-copy parsing possible (just find delimiters)
//!   - Forward compatible (ignore unknown keys)
//!   - Works across any FFI boundary (C, Lua, Python, Swift, etc.)
//!   - Human-debuggable (keys are readable, delimiters are invisible)
//!
//! ============================================================================

const std = @import("std");
const core = @import("core");
const errors = core.errors;
const format_validation = core.format_validation;
const git_validator = core.git_validator;
const thread_pool = core.thread_pool;
const i18n = core.i18n;

// Force progress module exports into the compilation unit (C FFI symbols)
comptime {
    _ = core.progress;
}

// Delimiters
const US: u8 = 0x1F; // Unit Separator: between key and value
const RS: u8 = 0x1E; // Record Separator: between key-value pairs

// Version string
const version_string: [:0]const u8 = core.version.string() ++ "";

// ========== KV-US-RS Builder ==========

const KvBuilder = struct {
    buffer: core.compat.ManagedArrayList(u8),
    first: bool = true,

    fn init(allocator: std.mem.Allocator) KvBuilder {
        return .{
            .buffer = core.compat.ManagedArrayList(u8).init(allocator),
        };
    }

    fn deinit(self: *KvBuilder) void {
        self.buffer.deinit();
    }

    fn add(self: *KvBuilder, key: []const u8, value: []const u8) !void {
        if (!self.first) {
            try self.buffer.append(RS);
        }
        self.first = false;
        try self.buffer.appendSlice(key);
        try self.buffer.append(US);
        try self.buffer.appendSlice(value);
    }

    fn addBool(self: *KvBuilder, key: []const u8, value: bool) !void {
        try self.add(key, if (value) "T" else "F");
    }

    fn addU8(self: *KvBuilder, key: []const u8, value: u8) !void {
        var buf: [4]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
        try self.add(key, slice);
    }

    fn addU32(self: *KvBuilder, key: []const u8, value: u32) !void {
        var buf: [16]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
        try self.add(key, slice);
    }

    fn addU64(self: *KvBuilder, key: []const u8, value: u64) !void {
        var buf: [24]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
        try self.add(key, slice);
    }

    fn addI64(self: *KvBuilder, key: []const u8, value: i64) !void {
        var buf: [24]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
        try self.add(key, slice);
    }

    /// Returns owned null-terminated string. Caller must free with allocator.
    fn toOwnedZ(self: *KvBuilder, allocator: std.mem.Allocator) ![:0]u8 {
        const result = try allocator.allocSentinel(u8, self.buffer.items.len, 0);
        @memcpy(result, self.buffer.items);
        return result;
    }
};

// ========== Format Category Mapping ==========

fn getFormatCategory(format: format_validation.FileFormat) []const u8 {
    return switch (format) {
        // Images
        .png, .jpeg, .jxl, .gif, .bmp, .webp, .tiff, .heic, .avif, .exr, .svg, .psd, .ai, .eps, .sketch, .aep, .dng, .cr2, .nef, .arw, .jpeg2000, .jbig2, .ico, .icns, .qoi, .pam, .dpx, .tga => "image",

        // Video
        .mp4, .mov, .mkv, .webm, .avi, .swf, .flv, .prores, .av1, .ogv, .mpeg_ps, .mpeg_ts, .mpeg_es, .ivf, .asf, .dv, .rm => "video",

        // Audio
        .mp3, .flac, .wav, .m4a, .alac, .aiff, .ogg, .ape, .wavpack, .midi, .dsf, .dff, .ac3, .dts, .eac3, .amr, .au, .tta, .caf, .aac_adts, .mod, .xm, .it, .s3m, .mp2 => "audio",

        // Documents
        .pdf, .docx, .xlsx, .pptx, .doc, .xls, .ppt, .odt, .ods, .odp, .rtf, .pages, .wpd, .cwk, .mwd => "document",

        // Archives
        .zip, .gzip, .bzip2, .xz, .zstd, .br, .hqx, .rar, .cpt, .sevenz, .tar, .warc, .ar, .cab, .sit, .sitx, .blar, .mblar => "archive",

        // Disk images
        .iso, .dmg, .vmdk, .toast => "disk_image",

        // Windows imaging formats
        .wim, .esd => "disk_image",

        // eBooks
        .epub => "ebook",

        // Code/Data
        .json, .toml, .ini, .xml, .yaml, .erlang_term, .eex, .csv, .msgpack, .sqlite, .plist, .apple_media_db => "data",
        // Fonts
        .ttf, .otf, .woff, .woff2, .type1 => "font",

        // Bundles
        .bagit, .git_repository, .macos_app, .macos_framework, .macos_bundle => "bundle",

        // Executables
        .pe, .elf, .macho, .macho_fat, .coff, .wasm, .java_class, .llvm_pch, .llvm_diag => "executable",

        // Web markup
        .html => "document",

        // 3D/CAD
        .dwg, .dxf, .step, .stl, .@"3mf", .obj, .ply, .gltf, .glb, .blend => "3d",

        // Scientific
        .hdf5, .parquet, .netcdf, .fits, .dicom, .fasta, .fastq, .matlab, .nifti, .pdb_struct, .cif, .shapefile, .kml, .kmz => "scientific",

        // Game data/ROMs
        .wad, .pak, .lspk, .chromium_pak, .bsp, .vpk, .nes, .snes, .n64, .gb, .gba, .nds, .genesis, .chd, .iff, .blorb => "game",

        // Text
        .markdown, .plain_text, .plain_text_utf16, .plain_text_latin1, .plain_text_cp437, .eml, .mbox => "text",

        // DAW/Creative projects
        .als, .rpp, .logicx, .flp, .song, .bwproject, .cpr, .ptx, .band, .reason, .prproj, .indd, .idml, .fcpxml, .drp => "project",

        // Database
        .mdb, .accdb, .dbf => "database",

        // Financial
        .qbw, .qbb, .qdf, .ofx, .qif, .txf, .nacha, .mt940, .bai2, .x12_edi, .edifact => "financial",

        // Crypto/certificates
        .pem, .der => "crypto",

        // PIM (Personal Information Management)
        .icalendar, .vcard => "pim",

        // Windows Installer
        .msi => "archive",

        // Karaoke
        .cdg => "other",

        // Network captures
        .pcap, .pcapng => "network",

        // Package formats
        .rpm => "archive",

        // Other
        .unknown, .par2, .beam, .ds_store, .spotlight, .apple_double => "other",
    };
}

fn getFormatId(format: format_validation.FileFormat) []const u8 {
    return @tagName(format);
}

// ========== Result Building ==========

fn buildValidationResult(
    allocator: std.mem.Allocator,
    result: format_validation.ValidationResult,
    elapsed_ns: i64,
) ![:0]u8 {
    var builder = KvBuilder.init(allocator);
    defer builder.deinit();

    // Format info
    try builder.add("fmt_id", getFormatId(result.format));
    try builder.add("fmt_cat", getFormatCategory(result.format));
    try builder.add("fmt_desc", result.format.description());

    // Validation status
    try builder.addBool("valid", result.is_valid);
    try builder.addBool("unknown", result.format == .unknown);

    // Messages (translated for current locale)
    try builder.add("err", i18n.translateError(result.error_message orelse ""));
    try builder.add("warn", i18n.translateWarning(result.warning_message orelse ""));

    // Symbolic error code and detail (for downstream consumers like Entropy Shield)
    if (result.error_code) |code| {
        try builder.add("err_code", @tagName(code));
    } else {
        try builder.add("err_code", "");
    }
    try builder.add("err_detail", result.error_detail orelse "");

    // Depth
    try builder.addU8("depth_u8", switch (result.validation_depth) {
        .structural => 0,
        .full => 1,
    });
    try builder.add("depth_desc", result.validation_depth.description());

    // Malformations as bitset
    var malform_bits: u64 = 0;
    var iter = result.malformations.iterator();
    while (iter.next()) |m| {
        malform_bits |= (@as(u64, 1) << @as(u6, @intCast(@intFromEnum(m))));
    }
    try builder.addU64("malform_u64", malform_bits);

    // Flags as individual booleans
    try builder.addBool("bypass_prot", result.circumvented_trivial_protection);
    try builder.addBool("via_ffmpeg", result.validated_via_ffmpeg);


    // Timing
    try builder.addI64("elapsed_ns_u64", elapsed_ns);

    return builder.toOwnedZ(allocator);
}

fn buildGitResult(
    allocator: std.mem.Allocator,
    result: git_validator.GitValidationResult,
    elapsed_ns: i64,
) ![:0]u8 {
    var builder = KvBuilder.init(allocator);
    defer builder.deinit();

    // Format info
    try builder.add("fmt_id", "git_repository");
    try builder.add("fmt_cat", "bundle");
    try builder.add("fmt_desc", "Git Repository");

    // Validation status
    try builder.addBool("valid", result.is_valid);
    try builder.addBool("unknown", false);

    // Error message
    try builder.add("err", result.error_message orelse "");
    try builder.add("warn", result.warning_message orelse "");

    // Symbolic error code and detail (for downstream consumers like Entropy Shield)
    if (result.error_message != null) {
        try builder.add("err_code", if (result.is_valid) "" else "git_validation_error");
    } else {
        try builder.add("err_code", "");
    }
    try builder.add("err_detail", result.error_message orelse "");

    // Depth
    const depth_val: u8 = switch (result.validation_depth) {
        .full => 1,
        .checksum_only => 0,
    };
    try builder.addU8("depth_u8", depth_val);
    try builder.add("depth_desc", switch (result.validation_depth) {
        .full => i18n.tr().depth_full,
        .checksum_only => i18n.tr().depth_structural,
    });

    // No malformations for git
    try builder.addU64("malform_u64", 0);

    // Flags (git repos don't bypass protection or use ffmpeg)
    try builder.addBool("bypass_prot", false);
    try builder.addBool("via_ffmpeg", false);

    // Git-specific fields
    try builder.addU32("obj_checked_u32", result.objects_checked);
    try builder.addU32("obj_valid_u32", result.objects_valid);
    try builder.addU32("obj_corrupt_u32", result.objects_corrupt);
    try builder.addU32("packs_checked_u32", result.packs_checked);
    try builder.addU32("packs_valid_u32", result.packs_valid);

    // Timing
    try builder.addI64("elapsed_ns_u64", elapsed_ns);

    return builder.toOwnedZ(allocator);
}

// ========== Exported Functions ==========

/// Returns the library version string.
export fn validate_version() [*:0]const u8 {
    return version_string.ptr;
}

/// Pre-initialize decoder libraries for thread safety.
export fn validate_init() void {
    core.preInit();
}

/// Get recommended thread count for batch validation.
export fn validate_default_threads() c_int {
    return @intCast(thread_pool.getOuterJobCount());
}

/// Validate a single file.
export fn validate(path: ?[*:0]const u8) ?[*:0]u8 {
    const p = path orelse {
        errors.setLastError(.validation_invalid_path, "NULL path", .{});
        return null;
    };

    const path_slice = std.mem.span(p);

    // Use arena for intermediate allocations during validation
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const start_ns = std.time.nanoTimestamp();
    var validator = format_validation.FormatValidator.initDeep();
    const result = validator.validateFileDeep(arena.allocator(), path_slice);
    const elapsed_ns: i64 = @intCast(std.time.nanoTimestamp() - start_ns);

    // Build result string (uses page_allocator for the result itself)
    const result_str = buildValidationResult(std.heap.page_allocator, result, elapsed_ns) catch {
        errors.setLastError(.internal_out_of_memory, "Failed to allocate result", .{});
        return null;
    };

    return result_str.ptr;
}

/// Free a validation result string.
export fn validate_free(result: ?[*:0]u8) void {
    const r = result orelse return;
    const len = std.mem.len(r);
    std.heap.page_allocator.free(r[0 .. len + 1]);
}

/// Validate a Git repository.
export fn validate_git(path: ?[*:0]const u8) ?[*:0]u8 {
    const p = path orelse {
        errors.setLastError(.validation_invalid_path, "NULL path", .{});
        return null;
    };

    const path_slice = std.mem.span(p);

    const start_ns = std.time.nanoTimestamp();
    const result = git_validator.validateRepository(std.heap.page_allocator, path_slice) catch {
        errors.setLastError(.internal_unexpected, "Git validation failed", .{});
        return null;
    };
    const elapsed_ns: i64 = @intCast(std.time.nanoTimestamp() - start_ns);

    const result_str = buildGitResult(std.heap.page_allocator, result, elapsed_ns) catch {
        errors.setLastError(.internal_out_of_memory, "Failed to allocate result", .{});
        return null;
    };

    return result_str.ptr;
}

// ========== Batch Validation ==========

/// C callback type
const ValidateCallback = ?*const fn (
    ctx: ?*anyopaque,
    id: u32,
    path: [*:0]const u8,
    result: [*:0]u8,
) callconv(.c) void;

/// Batch context
const BatchContext = struct {
    callback: ValidateCallback,
    user_ctx: ?*anyopaque,
    paths: [*]const ?[*:0]const u8,
    ids: [*]const u32,
};

/// Task for thread pool
const BatchTask = struct {
    index: usize,
};

/// Global interrupt flag - set by validate_interrupt(), checked by workers
var g_interrupt_flag = std.atomic.Value(bool).init(false);

/// Signal batch validation to stop.
/// Workers will finish their current file and then stop.
/// Call this from signal handlers (async-signal-safe: just sets an atomic flag).
export fn validate_interrupt() void {
    g_interrupt_flag.store(true, .seq_cst);
}

/// Check if interrupt was requested.
export fn validate_is_interrupted() bool {
    return g_interrupt_flag.load(.seq_cst);
}

/// Reset interrupt flag (call before starting a new batch).
export fn validate_reset_interrupt() void {
    g_interrupt_flag.store(false, .seq_cst);
}

/// Begin callback type
const BeginCallback = ?*const fn (
    ctx: ?*anyopaque,
    id: u32,
    path: [*:0]const u8,
) callconv(.c) void;

/// Global begin callback - called when validation of a file starts
var g_begin_callback: BeginCallback = null;
var g_begin_callback_ctx: ?*anyopaque = null;

/// Set the begin callback (called when validation starts for each file)
export fn validate_set_begin_callback(callback: BeginCallback, ctx: ?*anyopaque) void {
    g_begin_callback = callback;
    g_begin_callback_ctx = ctx;
}

/// Execute a single validation task
fn executeBatchTask(task: BatchTask, ctx_ptr: ?*anyopaque) void {
    // Check interrupt flag before starting
    if (g_interrupt_flag.load(.seq_cst)) {
        return; // Don't process this file, just exit
    }

    const ctx: *BatchContext = @ptrCast(@alignCast(ctx_ptr orelse return));
    const callback = ctx.callback orelse return;

    const path_ptr = ctx.paths[task.index] orelse return;
    const id = ctx.ids[task.index];
    const path_slice = std.mem.span(path_ptr);

    // Call begin callback if set (useful for debugging crashes)
    if (g_begin_callback) |begin_cb| {
        begin_cb(g_begin_callback_ctx, id, path_ptr);
    }

    // Validate
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const start_ns = std.time.nanoTimestamp();
    var validator = format_validation.FormatValidator.initDeep();
    const result = validator.validateFileDeep(arena.allocator(), path_slice);
    const elapsed_ns: i64 = @intCast(std.time.nanoTimestamp() - start_ns);

    // Build result string
    const result_str = buildValidationResult(std.heap.page_allocator, result, elapsed_ns) catch return;

    // Call user callback
    callback(ctx.user_ctx, id, path_ptr, result_str.ptr);
}

/// Validate multiple files in parallel.
export fn validate_batch(
    paths: ?[*]const ?[*:0]const u8,
    ids: ?[*]const u32,
    count: usize,
    num_threads: c_int,
    callback: ValidateCallback,
    ctx: ?*anyopaque,
) c_int {
    if (paths == null) {
        errors.setLastError(.validation_invalid_path, "NULL paths array", .{});
        return 1; // VALIDATE_ERR_NULL_PATH
    }

    if (callback == null) {
        errors.setLastError(.internal_unexpected, "NULL callback", .{});
        return 2; // VALIDATE_ERR_NULL_CALLBACK
    }

    if (count == 0) {
        return 0; // VALIDATE_OK
    }

    const actual_threads: usize = if (num_threads <= 0)
        thread_pool.getOuterJobCount()
    else
        @intCast(num_threads);

    // Pre-init decoder libraries
    core.preInit();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var batch_ctx = BatchContext{
        .callback = callback,
        .user_ctx = ctx,
        .paths = paths.?,
        .ids = ids orelse &[_]u32{}, // Use empty array if null, tasks will use index
    };

    // Use ThreadPool for parallel execution
    const Pool = thread_pool.ThreadPool(BatchTask, void);
    const pool = Pool.create(
        allocator,
        actual_threads,
        executeBatchTask,
        @ptrCast(&batch_ctx),
        {},
        {},
    ) catch {
        errors.setLastError(.internal_out_of_memory, "Failed to create thread pool", .{});
        return 3; // VALIDATE_ERR_OUT_OF_MEMORY
    };
    defer pool.destroy();

    // Submit all tasks
    for (0..count) |i| {
        pool.submit(.{ .index = i }) catch {
            pool.shutdown();
            pool.wait();
            errors.setLastError(.internal_out_of_memory, "Failed to submit task", .{});
            return 3; // VALIDATE_ERR_OUT_OF_MEMORY
        };
    }

    pool.shutdown();
    pool.wait();

    return 0; // VALIDATE_OK
}

// ========== Utility Functions ==========

/// Get description for a malformation bit (i18n-aware).
/// Uses MalformationType.description() which goes through the i18n system.
export fn validate_malform_desc(bit: c_int) [*:0]const u8 {
    if (bit < 0 or bit >= @typeInfo(format_validation.MalformationType).@"enum".fields.len) {
        return "unknown malformation";
    }
    const malform: format_validation.MalformationType = @enumFromInt(@as(u5, @intCast(bit)));
    return malform.description().ptr;
}

/// Set the global locale for translated strings.
export fn validate_set_locale(lang: ?[*:0]const u8) void {
    if (lang) |l| {
        const slice = std.mem.span(l);
        _ = i18n.setLocaleFromString(slice);
    } else {
        // NULL = detect from environment
        i18n.setLocale(i18n.detectFromEnv());
    }
}

/// Check if the current locale is a right-to-left language.
export fn validate_is_rtl() bool {
    return i18n.getLocale().isRtl();
}

/// Get a translated string by numeric ID.
/// Returns NULL for invalid IDs.
export fn validate_tr(string_id: u32) ?[*:0]const u8 {
    if (i18n.getStringById(string_id)) |s| {
        return s.ptr;
    }
    return null;
}

// ========== CLI Alias Functions ==========

/// Match a CLI argument keyword (without --/-/ prefix) against all locale aliases.
/// Returns the CliArg enum value (u8) if found, or 255 if not recognized.
export fn validate_match_arg(keyword: ?[*:0]const u8) u8 {
    const k = keyword orelse return 255;
    const slice = std.mem.span(k);
    if (i18n.matchCliArg(slice)) |arg| {
        return @intFromEnum(arg);
    }
    return 255;
}

/// Look up an environment variable by checking all locale aliases.
/// env_id is a validate_env_t value.
/// Returns the env var value (from whichever alias matched), or NULL if none set.
export fn validate_getenv(env_id: u8) ?[*:0]const u8 {
    return switch (@as(i18n.EnvVar, @enumFromInt(env_id))) {
        .ok_out => i18n.getEnvLocalized(.ok_out),
        .warn_out => i18n.getEnvLocalized(.warn_out),
        .fail_out => i18n.getEnvLocalized(.fail_out),
        .unknown_out => i18n.getEnvLocalized(.unknown_out),
        .slow_out => i18n.getEnvLocalized(.slow_out),
        .debug_out => i18n.getEnvLocalized(.debug_out),
        .begin_out => i18n.getEnvLocalized(.begin_out),
        .max_files => i18n.getEnvLocalized(.max_files),
        .validate_debug => i18n.getEnvLocalized(.validate_debug),
        .no_bidi => i18n.getEnvLocalized(.no_bidi),
    };
}

/// Get the last error message (thread-local).
export fn validate_last_error() ?[*:0]const u8 {
    if (errors.last_error) |err| {
        return err.message;
    }
    return null;
}

/// Clear the last error (thread-local).
export fn validate_clear_error() void {
    errors.clearLastError();
}

// ========== Tests ==========

test "validate_version" {
    const v = validate_version();
    const version_slice = std.mem.span(v);
    try std.testing.expectEqualStrings(core.version.string(), version_slice);
}

test "validate single file returns KV-US-RS format" {
    const result = validate("/nonexistent/path/test.txt");
    if (result) |r| {
        defer validate_free(r);
        const result_slice = std.mem.span(r);

        // Should contain our delimiters
        try std.testing.expect(std.mem.indexOf(u8, result_slice, &[_]u8{US}) != null);
        try std.testing.expect(std.mem.indexOf(u8, result_slice, &[_]u8{RS}) != null);

        // Should contain expected keys
        try std.testing.expect(std.mem.indexOf(u8, result_slice, "fmt_id") != null);
        try std.testing.expect(std.mem.indexOf(u8, result_slice, "valid") != null);
    }
}

test "validate_default_threads" {
    const threads = validate_default_threads();
    try std.testing.expect(threads >= 1);
}

test "KvBuilder produces correct format" {
    const allocator = std.testing.allocator;
    var builder = KvBuilder.init(allocator);
    defer builder.deinit();

    try builder.add("key1", "value1");
    try builder.addBool("flag", true);
    try builder.addU64("num_u64", 42);

    const result = try builder.toOwnedZ(allocator);
    defer allocator.free(result[0 .. result.len + 1]);

    // Expected: key1<US>value1<RS>flag<US>T<RS>num_u64<US>42
    try std.testing.expect(std.mem.indexOf(u8, result, "key1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "value1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "flag") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "num_u64") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "42") != null);
}
