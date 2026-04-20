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
        .png, .jpeg, .jxl, .gif, .bmp, .webp, .tiff, .heic, .avif, .exr, .svg, .psd, .ai, .eps, .sketch, .aep, .dng, .cr2, .cr3, .nef, .arw, .raf, .orf, .rw2, .pef, .jpeg2000, .jbig2, .ico, .icns, .qoi, .pam, .dpx, .tga => "image",

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
        .dwg, .dxf, .step, .stl, .@"3mf", .obj, .ply, .gltf, .glb, .blend, .gcode => "3d",

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
        .pem, .der, .pgp_signed, .ssh_signature => "crypto",

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
    try builder.addU8("depth_ceiling_u8", switch (result.format.maxAchievableDepth()) {
        .structural => 0,
        .full => 1,
    });
    try builder.add("depth_ceiling_reason", result.format.depthCeilingReason());

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

/// Global memory budget (0 = use default)
var g_max_memory: u64 = 0;

/// Get total system memory in bytes. Returns 0 if detection fails.
export fn validate_system_memory() u64 {
    return getSystemMemory();
}

/// Set maximum memory budget for validation in bytes.
/// Pass 0 to reset to default (system_memory / 2).
export fn validate_set_max_memory(bytes: u64) void {
    g_max_memory = bytes;
}

/// Get current maximum memory budget.
export fn validate_get_max_memory() u64 {
    if (g_max_memory != 0) return g_max_memory;
    const sys_mem = getSystemMemory();
    if (sys_mem == 0) return 2 * 1024 * 1024 * 1024; // 2 GiB fallback
    return sys_mem / 2;
}

fn getSystemMemory() u64 {
    if (comptime @import("builtin").os.tag == .macos) {
        // macOS: sysctl hw.memsize
        var mib = [2]c_int{ 6, 24 }; // CTL_HW=6, HW_MEMSIZE=24
        var mem_size: u64 = 0;
        var len: usize = @sizeOf(u64);
        const rc = std.c.sysctl(&mib, 2, @ptrCast(&mem_size), &len, null, 0);
        if (rc == 0) return mem_size;
        return 0;
    } else if (comptime @import("builtin").os.tag == .linux) {
        // Linux: sysinfo syscall (note: struct is Sysinfo, function is sysinfo)
        var info: std.os.linux.Sysinfo = undefined;
        const rc = std.os.linux.sysinfo(&info);
        if (rc == 0) return info.totalram * info.mem_unit;
        return 0;
    } else {
        return 0; // Windows: TODO GlobalMemoryStatusEx
    }
}

/// Get current process RSS (resident set size) in bytes.
/// Returns 0 if the OS API fails or is unavailable.
fn getCurrentRss() u64 {
    if (comptime @import("builtin").os.tag == .macos) {
        // macOS: task_info(TASK_BASIC_INFO)
        const mach = struct {
            extern "c" fn mach_task_self() c_uint;
            extern "c" fn task_info(target: c_uint, flavor: c_uint, info: *anyopaque, count: *u32) c_int;
        };
        const TASK_BASIC_INFO_64: c_uint = 5;
        const TaskBasicInfo64 = extern struct {
            suspend_count: i32,
            virtual_size: u64,
            resident_size: u64,
            user_time: extern struct { seconds: i32, microseconds: i32 },
            system_time: extern struct { seconds: i32, microseconds: i32 },
            policy: i32,
        };
        var info: TaskBasicInfo64 = undefined;
        var count: u32 = @sizeOf(TaskBasicInfo64) / @sizeOf(u32);
        const rc = mach.task_info(mach.mach_task_self(), TASK_BASIC_INFO_64, @ptrCast(&info), &count);
        if (rc == 0) return info.resident_size;
        return 0;
    } else if (comptime @import("builtin").os.tag == .linux) {
        // Linux: /proc/self/statm (second field = resident pages)
        var buf: [256]u8 = undefined;
        const file = std.fs.openFileAbsolute("/proc/self/statm", .{}) catch return 0;
        defer file.close();
        const n = file.read(&buf) catch return 0;
        const content = buf[0..n];
        // Skip first field (total pages), read second (resident pages)
        var i: usize = 0;
        while (i < content.len and content[i] != ' ') : (i += 1) {}
        while (i < content.len and content[i] == ' ') : (i += 1) {}
        var rss_pages: u64 = 0;
        while (i < content.len and content[i] >= '0' and content[i] <= '9') : (i += 1) {
            rss_pages = rss_pages * 10 + @as(u64, content[i] - '0');
        }
        return rss_pages * std.heap.page_size_min;
    } else {
        return 0;
    }
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

/// Files larger than this threshold use the large-file semaphore to limit
/// concurrent memory usage. 50 MB is ~1/20th of a typical worker's working set.
const LARGE_FILE_THRESHOLD: u64 = 50 * 1024 * 1024;

/// Semaphore limiting concurrent validation of large files. Small files
/// (under LARGE_FILE_THRESHOLD) bypass this and run full parallel.
/// Default 2 concurrent large files; reconfigured by validate_batch based on
/// thread count and memory budget.
var g_large_file_sem: std.Thread.Semaphore = .{ .permits = 2 };

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

    // Large-file semaphore: files above threshold block until a slot is free,
    // preventing N workers all simultaneously validating huge files.
    const is_large = blk: {
        const stat = std.fs.cwd().statFile(path_slice) catch break :blk false;
        break :blk stat.size > LARGE_FILE_THRESHOLD;
    };
    if (is_large) g_large_file_sem.wait();
    defer if (is_large) g_large_file_sem.post();

    // Memory pressure throttle: if RSS is approaching budget, yield briefly
    // so other workers can finish and free memory. Caps at 500ms total wait
    // to avoid livelock on genuinely tight systems.
    const budget = validate_get_max_memory();
    if (budget > 0) {
        var wait_ms: u64 = 0;
        while (wait_ms < 500) {
            const rss = getCurrentRss();
            if (rss == 0 or rss < budget) break;
            std.Thread.sleep(50 * std.time.ns_per_ms);
            wait_ms += 50;
            if (g_interrupt_flag.load(.seq_cst)) return;
        }
    }
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

    // Configure large-file semaphore: scale with memory budget.
    // Reserve 256MB headroom per large file slot (covers typical decompression peaks).
    const budget = validate_get_max_memory();
    const slots_from_mem: usize = @intCast(@max(@as(u64, 1), budget / (256 * 1024 * 1024)));
    const large_file_slots = @min(@max(@as(usize, 2), slots_from_mem), actual_threads);
    g_large_file_sem = .{ .permits = large_file_slots };

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
        .max_memory => i18n.getEnvLocalized(.max_memory),
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

// ========== Test Coverage (sniper/shotgun corruption testing) ==========

const test_coverage = core.test_coverage;

/// Callback fired during coverage run — arg is (round, total, detected_so_far).
pub const CoverageProgressCallback = ?*const fn (
    ctx: ?*anyopaque,
    round: u32,
    total: u32,
    detected: u32,
) callconv(.c) void;

/// Run corruption coverage test on a file.
/// Returns KV string with results (caller must validate_free).
/// Returns NULL on error (baseline invalid, file read failed, etc.).
export fn validate_test_coverage(
    path: ?[*:0]const u8,
    rounds: u32,
    seed: u64,
    shotgun_bytes: u32,
    modes_bitmask: u32,
    heatmap_width: u32,
    progress_cb: CoverageProgressCallback,
    progress_ctx: ?*anyopaque,
) ?[*:0]u8 {
    const p = path orelse return null;
    const path_slice = std.mem.span(p);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Load the whole file into a reference buffer
    const file = std.fs.cwd().openFile(path_slice, .{}) catch return null;
    defer file.close();
    const file_size = file.getEndPos() catch return null;
    if (file_size == 0 or file_size > 2 * 1024 * 1024 * 1024) return null;

    const original = std.heap.page_allocator.alloc(u8, @intCast(file_size)) catch return null;
    defer std.heap.page_allocator.free(original);
    const bytes_read = file.readAll(original) catch return null;
    const orig_slice = original[0..bytes_read];

    // Baseline validation — must be valid to proceed
    var validator = format_validation.FormatValidator.initDeep();
    defer validator.deinit();
    const baseline = validator.validateFileDeep(alloc, path_slice);
    if (!baseline.is_valid) return null;

    // Orchestration context for the validator callback
    const RunCtx = struct {
        validator: *format_validation.FormatValidator,
        format: format_validation.FileFormat,
        user_cb: CoverageProgressCallback,
        user_ctx: ?*anyopaque,
    };
    var run_ctx = RunCtx{
        .validator = &validator,
        .format = baseline.format,
        .user_cb = progress_cb,
        .user_ctx = progress_ctx,
    };

    const validate_fn = struct {
        fn cb(cb_ctx: *anyopaque, buffer: []const u8) bool {
            const rc: *RunCtx = @ptrCast(@alignCast(cb_ctx));
            var src = core.file_source.FileSource.fromBuffer(buffer);
            defer src.close();
            var inner_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer inner_arena.deinit();
            const r = rc.validator.validateDeepFromSource(inner_arena.allocator(), rc.format, &src);
            return !r.is_valid;
        }
    }.cb;

    const progress_fn_wrapped: ?test_coverage.ProgressFn = if (progress_cb != null) struct {
        fn cb(cb_ctx: *anyopaque, round: u32, total: u32, detected: u32) void {
            const rc: *RunCtx = @ptrCast(@alignCast(cb_ctx));
            if (rc.user_cb) |user_cb| user_cb(rc.user_ctx, round, total, detected);
        }
    }.cb else null;

    // Translate the C bitmask into Zig's EnumSet. 0 means "all default modes"
    // (the six already-shipped modes; boundary and sparse_noise stay opt-in).
    const modes = blk: {
        const CorruptionMode = test_coverage.CorruptionMode;
        var set = std.EnumSet(CorruptionMode).initEmpty();
        const mask = if (modes_bitmask == 0)
            // VALIDATE_COVERAGE_MODES_DEFAULT_ALL (bits 0..5) matches ffi/validate_core.h.
            @as(u32, 0b0011_1111)
        else
            modes_bitmask;
        if (mask & (1 << 0) != 0) set.insert(.sniper);
        if (mask & (1 << 1) != 0) set.insert(.shotgun);
        if (mask & (1 << 2) != 0) set.insert(.header);
        if (mask & (1 << 3) != 0) set.insert(.tail);
        if (mask & (1 << 4) != 0) set.insert(.zeroed);
        if (mask & (1 << 5) != 0) set.insert(.xor);
        break :blk set;
    };

    var result = test_coverage.runCoverage(
        alloc,
        orig_slice,
        .{
            .rounds = rounds,
            .shotgun_bytes = shotgun_bytes,
            .seed = seed,
            .progress = progress_fn_wrapped,
            .progress_ctx = @ptrCast(&run_ctx),
            .enabled_modes = modes,
        },
        @ptrCast(&run_ctx),
        validate_fn,
    ) catch return null;
    defer result.deinit();

    // Build KV result string
    var builder = KvBuilder.init(std.heap.page_allocator);
    defer builder.deinit();
    builder.add("fmt", @tagName(baseline.format)) catch return null;
    {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrintZ(&buf, "{d}", .{result.file_size}) catch return null;
        builder.add("file_size", s) catch return null;
    }
    {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrintZ(&buf, "{d}", .{result.rounds}) catch return null;
        builder.add("rounds", s) catch return null;
    }
    {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrintZ(&buf, "{d}", .{result.totalDetected()}) catch return null;
        builder.add("detected", s) catch return null;
    }
    {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrintZ(&buf, "{d}", .{result.duration_ns}) catch return null;
        builder.add("duration_ns", s) catch return null;
    }
    // Per-mode stats
    const all_modes = [_]test_coverage.CorruptionMode{ .sniper, .shotgun, .header, .tail, .zeroed, .xor };
    for (all_modes) |mode| {
        const stats = result.by_mode.get(mode);
        var keybuf: [32]u8 = undefined;
        var valbuf: [16]u8 = undefined;
        const k_total = std.fmt.bufPrintZ(&keybuf, "mode_{s}_total", .{mode.name()}) catch continue;
        const v_total = std.fmt.bufPrintZ(&valbuf, "{d}", .{stats.total}) catch continue;
        builder.add(k_total, v_total) catch continue;
        var keybuf2: [32]u8 = undefined;
        var valbuf2: [16]u8 = undefined;
        const k_det = std.fmt.bufPrintZ(&keybuf2, "mode_{s}_detected", .{mode.name()}) catch continue;
        const v_det = std.fmt.bufPrintZ(&valbuf2, "{d}", .{stats.detected}) catch continue;
        builder.add(k_det, v_det) catch continue;
    }
    // Heatmap — caller-chosen width. 0 = skip rendering entirely so the CLI
    // can honor --no-heatmap without paying the cost, non-tty output can
    // suppress ANSI noise, and the FFI stays flexible. Clamp to [40, 400] so
    // a renegade width doesn't blow up the row.
    if (heatmap_width > 0) {
        const w = @as(u32, @intCast(@max(@as(u32, 40), @min(@as(u32, 400), heatmap_width))));
        if (test_coverage.renderHeatmap(std.heap.page_allocator, &result, w)) |heat| {
            defer std.heap.page_allocator.free(heat);
            builder.add("heatmap", heat) catch {};
        } else |_| {}
        // Per-mode heatmaps. The CLI only displays these when --per-mode-heatmap
        // is passed; we still always render so that the FFI's output is
        // complete regardless of which UI consumes it. Only the six default
        // modes are emitted here — sparse_noise and boundary render on demand
        // once those ship (opt-in from PLAN.md step 8/9).
        const per_mode = [_]struct { tag: test_coverage.CorruptionMode, key: []const u8 }{
            .{ .tag = .sniper, .key = "heatmap_sniper" },
            .{ .tag = .shotgun, .key = "heatmap_shotgun" },
            .{ .tag = .header, .key = "heatmap_header" },
            .{ .tag = .tail, .key = "heatmap_tail" },
            .{ .tag = .zeroed, .key = "heatmap_zeroed" },
            .{ .tag = .xor, .key = "heatmap_xor" },
        };
        for (per_mode) |pm| {
            if (result.by_mode.get(pm.tag).total == 0) continue;
            if (test_coverage.renderHeatmapFiltered(std.heap.page_allocator, &result, w, pm.tag)) |heat| {
                defer std.heap.page_allocator.free(heat);
                builder.add(pm.key, heat) catch {};
            } else |_| {}
        }
    }

    return builder.toOwnedZ(std.heap.page_allocator) catch null;
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
