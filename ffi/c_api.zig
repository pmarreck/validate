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
//!   - Works across any FFI boundary (C, LuaJIT FFI, Swift, Rust, etc.)
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
const runtime = core.runtime;

/// 0.16: nanoTimestamp() was removed; clocks moved to std.Io.
inline fn nanoTimestamp() i128 {
    runtime.ensureInit();
    return std.Io.Timestamp.now(runtime.io(), .awake).nanoseconds;
}

inline fn elapsedNanoseconds(start_ns: i128) u64 {
    const end_ns = nanoTimestamp();
    return if (end_ns > start_ns) @intCast(end_ns - start_ns) else 0;
}

/// 0.16: std.fs.cwd() → std.Io.Dir.cwd(). Cwd itself doesn't take io;
/// the io parameter enters at the method calls on the returned Dir
/// (openFile, statFile, etc).
inline fn cwd() std.Io.Dir {
    return std.Io.Dir.cwd();
}

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
        .pdf, .docx, .xlsx, .pptx, .doc, .xls, .ppt, .odt, .ods, .odp, .rtf, .pages, .keynote, .numbers, .wpd, .cwk, .mwd => "document",

        // Archives
        .zip, .gzip, .bzip2, .xz, .zstd, .br, .hqx, .rar, .cpt, .sevenz, .tar, .warc, .ar, .cab, .sit, .sitx, .blar, .mblar => "archive",

        // Disk images
        .iso, .dmg, .vmdk, .toast, .gpt_disk_image => "disk_image",

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
        .unknown, .par2, .beam, .ds_store, .spotlight, .apple_double, .thumbs_db => "other",
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
    try builder.addBool("unknown", result.format == .unknown and result.access == .available);
    try builder.add("access", switch (result.access) {
        .available => "",
        .no_permission => "NOPERM",
    });

    // Messages (translated for current locale)
    try builder.add("err", i18n.translateError(result.error_message orelse ""));
    try builder.add("warn", i18n.translateWarning(result.warning_message orelse ""));
    try builder.add("info", i18n.translateWarning(result.info_message orelse ""));

    // Symbolic error code and detail (for downstream consumers like Entropy Shield)
    if (result.error_code) |code| {
        try builder.add("err_code", @tagName(code));
    } else {
        try builder.add("err_code", "");
    }
    try builder.add("err_detail", result.error_detail orelse "");

    // Depth. Clamp the emitted actual depth to the format's ceiling so the FFI
    // can never report depth > ceiling (the MFIC depth<=ceiling invariant holds
    // at the wire boundary regardless of how the result was constructed).
    const actual_depth_u8: u8 = switch (result.validation_depth) {
        .structural => 0,
        .full => 1,
    };
    const ceiling_depth_u8: u8 = switch (result.format.maxAchievableDepth()) {
        .structural => 0,
        .full => 1,
    };
    try builder.addU8("depth_u8", @min(actual_depth_u8, ceiling_depth_u8));
    try builder.add("depth_desc", result.validation_depth.description());
    try builder.addU8("depth_ceiling_u8", ceiling_depth_u8);
    try builder.add("depth_ceiling_reason", result.format.depthCeilingReason());

    // Malformations split into WARN-tier (deviations) and INFO-tier
    // (noteworthy properties of valid files). See MalformationType.isInfoTier.
    var malform_bits: u64 = 0;
    var info_malform_bits: u64 = 0;
    var iter = result.malformations.iterator();
    while (iter.next()) |m| {
        const bit = @as(u64, 1) << @as(u6, @intCast(@intFromEnum(m)));
        if (m.isInfoTier()) {
            info_malform_bits |= bit;
        } else {
            malform_bits |= bit;
        }
    }
    try builder.addU64("malform_u64", malform_bits);
    try builder.addU64("info_malform_u64", info_malform_bits);

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
    try builder.add("access", "");

    // Error message
    try builder.add("err", result.error_message orelse "");
    try builder.add("warn", result.warning_message orelse "");
    try builder.add("info", "");

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
    try builder.addU64("info_malform_u64", 0);

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

/// Pointer to the active MemoryBudget instance, set while `validate_batch` is
/// running and cleared on exit. Used by `validate_get_memory_usage` to expose
/// snapshot data to FFI consumers (typically a GUI memory meter polling at
/// ~500ms intervals). Atomic for thread-safe read; writes are guarded by
/// validate_batch's lifecycle and only the batch thread touches them.
var g_active_budget: std.atomic.Value(?*core.memory_budget.MemoryBudget) = .init(null);

/// Scheduler wait diagnostics are activated only by the CLI's explicit debug
/// mode. The pointer is valid for one `validate_batch` invocation and lets a
/// concurrent polling consumer observe monotonically increasing wait counters.
var g_scheduler_debug_tracking = std.atomic.Value(bool).init(false);
var g_active_scheduler_debug: std.atomic.Value(?*thread_pool.SchedulerDebugStats) = .init(null);

/// Snapshot of memory budget state. Mirrored to a C struct in
/// validate_core.h. All fields are bytes / counts. `current_rss` is
/// best-effort and may be 0 on platforms where we can't query process RSS.
pub const MemoryUsage = extern struct {
    total_bytes: u64,
    available_bytes: u64,
    active_tasks: u64,
    current_rss: u64,
};

pub const HeapDebugSnapshot = extern struct {
    current_rss: u64,
    vm_size: u64,
    vm_data: u64,
    budget_total_bytes: u64,
    budget_available_bytes: u64,
    active_tasks: u64,
    alloc_current_bytes: u64,
    alloc_peak_bytes: u64,
    small_current_bytes: u64,
    small_peak_bytes: u64,
    big_current_bytes: u64,
    big_peak_bytes: u64,
    total_alloc_bytes: u64,
    total_free_bytes: u64,
    arena_reset_bytes: u64,
    alloc_count: u64,
    free_count: u64,
    resize_count: u64,
    remap_count: u64,
    arena_reset_count: u64,
};

pub const HeapDebugTaskSnapshot = extern struct {
    active: u32,
    slot: u32,
    id: u32,
    index: u64,
    file_size: u64,
    reserved_bytes: u64,
    elapsed_ns: u64,
    phase_elapsed_ns: u64,
    start_rss: u64,
    current_rss: u64,
    path: [*:0]const u8,
    format_hint: [*:0]const u8,
    phase: [*:0]const u8,
};

pub const SchedulerDebugSnapshot = extern struct {
    worker_count: u64,
    queue_empty_wait_ns: u64,
    queue_empty_wait_events: u64,
    queue_empty_waiters: u64,
    memory_budget_wait_ns: u64,
    memory_budget_wait_events: u64,
    memory_budget_waiters: u64,
    rss_pressure_wait_ns: u64,
    rss_pressure_wait_events: u64,
    rss_pressure_waiters: u64,
};

/// Get a snapshot of the current memory budget state.
///
/// Returns 0 (VALIDATE_OK) if a batch is running and `out` was populated;
/// returns non-zero (with `out` zero-cleared) if no batch is active or
/// `out` is null. Cheap (single mutex acquire on the budget + 3 atomic
/// reads + RSS syscall). Safe to call from any thread.
export fn validate_get_memory_usage(out: ?*MemoryUsage) c_int {
    const dst = out orelse return 1;
    dst.* = MemoryUsage{
        .total_bytes = 0,
        .available_bytes = 0,
        .active_tasks = 0,
        .current_rss = 0,
    };
    const budget_ptr = g_active_budget.load(.seq_cst) orelse return 2;
    const snap = budget_ptr.snapshot();
    dst.total_bytes = snap.total;
    dst.available_bytes = snap.available;
    dst.active_tasks = snap.active;
    dst.current_rss = getCurrentRss();
    return 0;
}

export fn validate_reset_heap_debug_counters() void {
    core.heap.resetStats();
}

/// Enable or clear DEBUG-only scheduler wait accounting for the next batch.
/// Disabled by default so validation never reads clocks for scheduler metrics.
export fn validate_set_scheduler_debug_tracking(enabled: c_int) void {
    g_scheduler_debug_tracking.store(enabled != 0, .seq_cst);
}

/// Snapshot cumulative scheduler wait counters for the active batch. Counters
/// are nanoseconds and never reset mid-batch, so callers can compute deltas.
export fn validate_get_scheduler_debug_snapshot(out: ?*SchedulerDebugSnapshot) c_int {
    const dst = out orelse return 1;
    dst.* = .{
        .worker_count = 0,
        .queue_empty_wait_ns = 0,
        .queue_empty_wait_events = 0,
        .queue_empty_waiters = 0,
        .memory_budget_wait_ns = 0,
        .memory_budget_wait_events = 0,
        .memory_budget_waiters = 0,
        .rss_pressure_wait_ns = 0,
        .rss_pressure_wait_events = 0,
        .rss_pressure_waiters = 0,
    };
    const stats = g_active_scheduler_debug.load(.seq_cst) orelse return 2;
    const snap = stats.snapshot();
    dst.* = .{
        .worker_count = snap.worker_count,
        .queue_empty_wait_ns = snap.queue_empty_wait_ns,
        .queue_empty_wait_events = snap.queue_empty_wait_events,
        .queue_empty_waiters = snap.queue_empty_waiters,
        .memory_budget_wait_ns = snap.memory_budget_wait_ns,
        .memory_budget_wait_events = snap.memory_budget_wait_events,
        .memory_budget_waiters = snap.memory_budget_waiters,
        .rss_pressure_wait_ns = snap.rss_pressure_wait_ns,
        .rss_pressure_wait_events = snap.rss_pressure_wait_events,
        .rss_pressure_waiters = snap.rss_pressure_waiters,
    };
    return 0;
}

export fn validate_get_heap_debug_snapshot(out: ?*HeapDebugSnapshot) c_int {
    const dst = out orelse return 1;
    dst.* = HeapDebugSnapshot{
        .current_rss = 0,
        .vm_size = 0,
        .vm_data = 0,
        .budget_total_bytes = 0,
        .budget_available_bytes = 0,
        .active_tasks = 0,
        .alloc_current_bytes = 0,
        .alloc_peak_bytes = 0,
        .small_current_bytes = 0,
        .small_peak_bytes = 0,
        .big_current_bytes = 0,
        .big_peak_bytes = 0,
        .total_alloc_bytes = 0,
        .total_free_bytes = 0,
        .arena_reset_bytes = 0,
        .alloc_count = 0,
        .free_count = 0,
        .resize_count = 0,
        .remap_count = 0,
        .arena_reset_count = 0,
    };

    const mem = getProcessMemory();
    dst.current_rss = mem.rss;
    dst.vm_size = mem.vm_size;
    dst.vm_data = mem.vm_data;

    if (g_active_budget.load(.seq_cst)) |budget_ptr| {
        const snap = budget_ptr.snapshot();
        dst.budget_total_bytes = snap.total;
        dst.budget_available_bytes = snap.available;
        dst.active_tasks = snap.active;
    }

    const alloc = core.heap.snapshotStats();
    dst.alloc_current_bytes = alloc.current_bytes;
    dst.alloc_peak_bytes = alloc.peak_bytes;
    dst.small_current_bytes = alloc.small_current_bytes;
    dst.small_peak_bytes = alloc.small_peak_bytes;
    dst.big_current_bytes = alloc.big_current_bytes;
    dst.big_peak_bytes = alloc.big_peak_bytes;
    dst.total_alloc_bytes = alloc.total_alloc_bytes;
    dst.total_free_bytes = alloc.total_free_bytes;
    dst.arena_reset_bytes = alloc.arena_reset_bytes;
    dst.alloc_count = alloc.alloc_count;
    dst.free_count = alloc.free_count;
    dst.resize_count = alloc.resize_count;
    dst.remap_count = alloc.remap_count;
    dst.arena_reset_count = alloc.arena_reset_count;
    return 0;
}

const HEAP_DEBUG_MAX_TASKS: usize = 256;
const empty_cstr: [*:0]const u8 = "";
const phase_start: [*:0]const u8 = "start";
const phase_large_wait: [*:0]const u8 = "large_wait";
const phase_validate: [*:0]const u8 = "validate";
const phase_callback: [*:0]const u8 = "callback";

const HeapDebugTaskSlot = struct {
    active: bool = false,
    id: u32 = 0,
    index: u64 = 0,
    file_size: u64 = 0,
    reserved_bytes: u64 = 0,
    start_ns: u64 = 0,
    phase_start_ns: u64 = 0,
    start_rss: u64 = 0,
    path: [*:0]const u8 = empty_cstr,
    format_hint: [*:0]const u8 = empty_cstr,
    phase: [*:0]const u8 = phase_start,
};

var g_heap_debug_task_tracking = std.atomic.Value(bool).init(false);
var g_heap_debug_tasks_mutex: std.Io.Mutex = .init;
var g_heap_debug_tasks: [HEAP_DEBUG_MAX_TASKS]HeapDebugTaskSlot = .{HeapDebugTaskSlot{}} ** HEAP_DEBUG_MAX_TASKS;

fn heapDebugNowNs() u64 {
    const now = nanoTimestamp();
    return if (now > 0) @intCast(now) else 0;
}

fn heapDebugLock() void {
    g_heap_debug_tasks_mutex.lockUncancelable(runtime.io());
}

fn heapDebugUnlock() void {
    g_heap_debug_tasks_mutex.unlock(runtime.io());
}

export fn validate_set_heap_debug_task_tracking(enabled: c_int) void {
    g_heap_debug_task_tracking.store(enabled != 0, .seq_cst);
    if (enabled == 0) {
        heapDebugLock();
        defer heapDebugUnlock();
        for (&g_heap_debug_tasks) |*slot| {
            slot.* = HeapDebugTaskSlot{};
        }
    }
}

fn heapDebugTaskBegin(
    index: usize,
    id: u32,
    path: [*:0]const u8,
    format_hint: [*:0]const u8,
    file_size: u64,
    reserved_bytes: u64,
) ?usize {
    if (!g_heap_debug_task_tracking.load(.seq_cst)) return null;
    const start_ns = heapDebugNowNs();
    const start_rss = getCurrentRss();
    heapDebugLock();
    defer heapDebugUnlock();
    for (&g_heap_debug_tasks, 0..) |*slot, slot_index| {
        if (!slot.active) {
            slot.* = HeapDebugTaskSlot{
                .active = true,
                .id = id,
                .index = @intCast(index),
                .file_size = file_size,
                .reserved_bytes = reserved_bytes,
                .start_ns = start_ns,
                .phase_start_ns = start_ns,
                .start_rss = start_rss,
                .path = path,
                .format_hint = format_hint,
                .phase = phase_start,
            };
            return slot_index;
        }
    }
    return null;
}

fn heapDebugTaskSetPhase(slot_index: ?usize, phase: [*:0]const u8) void {
    const i = slot_index orelse return;
    if (!g_heap_debug_task_tracking.load(.seq_cst)) return;
    const now_ns = heapDebugNowNs();
    heapDebugLock();
    defer heapDebugUnlock();
    if (i < g_heap_debug_tasks.len and g_heap_debug_tasks[i].active) {
        if (g_heap_debug_tasks[i].phase != phase) {
            g_heap_debug_tasks[i].phase = phase;
            g_heap_debug_tasks[i].phase_start_ns = now_ns;
        }
    }
}

fn heapDebugTaskEnd(slot_index: ?usize) void {
    const i = slot_index orelse return;
    if (!g_heap_debug_task_tracking.load(.seq_cst)) return;
    heapDebugLock();
    defer heapDebugUnlock();
    if (i < g_heap_debug_tasks.len) {
        g_heap_debug_tasks[i] = HeapDebugTaskSlot{};
    }
}

export fn validate_get_heap_debug_tasks(out: ?[*]HeapDebugTaskSnapshot, capacity: usize) usize {
    const dst = out orelse return 0;
    if (capacity == 0) return 0;
    const now_ns = heapDebugNowNs();
    const current_rss = getCurrentRss();
    var written: usize = 0;

    heapDebugLock();
    defer heapDebugUnlock();

    for (g_heap_debug_tasks, 0..) |slot, slot_index| {
        if (!slot.active) continue;
        if (written >= capacity) break;
        const elapsed_ns = if (now_ns >= slot.start_ns) now_ns - slot.start_ns else 0;
        const phase_elapsed_ns = if (now_ns >= slot.phase_start_ns) now_ns - slot.phase_start_ns else 0;
        dst[written] = HeapDebugTaskSnapshot{
            .active = 1,
            .slot = @intCast(slot_index),
            .id = slot.id,
            .index = slot.index,
            .file_size = slot.file_size,
            .reserved_bytes = slot.reserved_bytes,
            .elapsed_ns = elapsed_ns,
            .phase_elapsed_ns = phase_elapsed_ns,
            .start_rss = slot.start_rss,
            .current_rss = current_rss,
            .path = slot.path,
            .format_hint = slot.format_hint,
            .phase = slot.phase,
        };
        written += 1;
    }
    return written;
}

/// Get total system memory in bytes. Returns 0 if detection fails.
export fn validate_system_memory() u64 {
    return getSystemMemory();
}

/// Set maximum memory budget for validation in bytes.
/// Pass 0 to reset to the clamped default from `validate_get_max_memory`.
export fn validate_set_max_memory(bytes: u64) void {
    g_max_memory = bytes;
}

/// Get current maximum memory budget.
/// Resolution order:
///   1. Explicit `validate_set_max_memory(bytes)` from FFI consumer (e.g. GUI)
///   2. `VALIDATE_MEMORY_BUDGET` env var (e.g. set by CLI flag handling)
///   3. Default: clamp(system_memory / 3, 1 GB, 8 GB)
/// Floor protects very-low-RAM systems; ceiling prevents pathological
/// over-allocation on memory-rich machines (a CLI tool shouldn't quietly
/// eat 32+ GB just because the box has it).
export fn validate_get_max_memory() u64 {
    if (g_max_memory != 0) return g_max_memory;
    if (cross_platform_getenv("VALIDATE_MEMORY_BUDGET")) |env_val| {
        if (core.memory_budget.parseSize(env_val)) |parsed| {
            return @intCast(parsed);
        } else |_| {}
    }
    const sys_mem = getSystemMemory();
    if (sys_mem == 0) return 2 * 1024 * 1024 * 1024; // 2 GiB fallback
    return @intCast(core.memory_budget.defaultBudget(@intCast(sys_mem)));
}

/// Largest file (bytes) coverage can process at `jobs` workers within the
/// current memory budget (budget / (jobs + 1)). Lets a consumer gate or scale
/// a coverage run before calling validate_test_coverage. jobs=0 = single worker.
export fn validate_coverage_max_bytes(jobs: u32) u64 {
    return test_coverage.coverageMaxBytes(jobs, validate_get_max_memory());
}

/// Cross-platform getenv that returns null on Windows.
/// 0.16: std.c.getenv removed; std.c.getenv preserves the borrowed-pointer
/// semantics (no allocator needed).
fn cross_platform_getenv(name: [:0]const u8) ?[]const u8 {
    if (@import("builtin").os.tag == .windows) return null;
    if (std.c.getenv(name.ptr)) |raw| return std.mem.span(raw);
    return null;
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

const ProcessMemory = struct {
    rss: u64 = 0,
    vm_size: u64 = 0,
    vm_data: u64 = 0,
};

fn parseProcStatusKbLine(line: []const u8, key: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, line, key)) return null;
    var i: usize = key.len;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    var kb: u64 = 0;
    var saw_digit = false;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') : (i += 1) {
        saw_digit = true;
        kb = kb * 10 + @as(u64, line[i] - '0');
    }
    return if (saw_digit) kb * 1024 else null;
}

fn getProcessMemory() ProcessMemory {
    if (comptime @import("builtin").os.tag == .macos) {
        return getMacProcessMemory();
    } else if (comptime @import("builtin").os.tag == .linux) {
        var result = ProcessMemory{ .rss = getCurrentRss() };
        var buf: [4096]u8 = undefined;
        const linux = std.os.linux;
        const fd_raw = linux.open("/proc/self/status", .{ .ACCMODE = .RDONLY }, 0);
        const fd_signed: isize = @bitCast(fd_raw);
        if (fd_signed < 0) return result;
        const fd: i32 = @intCast(fd_raw);
        defer _ = linux.close(fd);
        const n_raw = linux.read(fd, &buf, buf.len);
        const n_signed: isize = @bitCast(n_raw);
        if (n_signed <= 0) return result;
        const n: usize = @intCast(n_raw);
        var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
        while (lines.next()) |line| {
            if (parseProcStatusKbLine(line, "VmRSS:")) |v| {
                result.rss = v;
            } else if (parseProcStatusKbLine(line, "VmSize:")) |v| {
                result.vm_size = v;
            } else if (parseProcStatusKbLine(line, "VmData:")) |v| {
                result.vm_data = v;
            }
        }
        return result;
    }
    return .{};
}

fn getMacProcessMemory() ProcessMemory {
    const darwin = struct {
        extern "c" fn getpid() c_int;
        extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: *anyopaque, buffersize: c_int) c_int;
    };
    const PROC_PIDTASKINFO: c_int = 4;
    const ProcTaskInfo = extern struct {
        pti_virtual_size: u64,
        pti_resident_size: u64,
        pti_total_user: u64,
        pti_total_system: u64,
        pti_threads_user: u64,
        pti_threads_system: u64,
        pti_policy: i32,
        pti_faults: i32,
        pti_pageins: i32,
        pti_cow_faults: i32,
        pti_messages_sent: i32,
        pti_messages_received: i32,
        pti_syscalls_mach: i32,
        pti_syscalls_unix: i32,
        pti_csw: i32,
        pti_threadnum: i32,
        pti_numrunning: i32,
        pti_priority: i32,
    };
    var info: ProcTaskInfo = std.mem.zeroes(ProcTaskInfo);
    const expected: c_int = @intCast(@sizeOf(ProcTaskInfo));
    const n = darwin.proc_pidinfo(darwin.getpid(), PROC_PIDTASKINFO, 0, @ptrCast(&info), expected);
    if (n < expected) return .{};
    return .{
        .rss = info.pti_resident_size,
        // Darwin virtual_size is dominated by
        // address-space reservations and is too noisy for these perf logs.
        .vm_size = 0,
        .vm_data = 0,
    };
}

/// Get current process RSS (resident set size) in bytes.
/// Returns 0 if the OS API fails or is unavailable.
fn getCurrentRss() u64 {
    if (comptime @import("builtin").os.tag == .macos) {
        return getMacProcessMemory().rss;
    } else if (comptime @import("builtin").os.tag == .linux) {
        // Linux: /proc/self/statm (second field = resident pages)
        // 0.16: std.fs.openFileAbsolute moved to std.Io.Dir and requires an io
        // param + lots of ceremony for a tiny /proc peek. Raw syscalls match
        // the macOS branch's std.c.sysctl style and avoid the std.Io stack.
        var buf: [256]u8 = undefined;
        const linux = std.os.linux;
        const fd_raw = linux.open("/proc/self/statm", .{ .ACCMODE = .RDONLY }, 0);
        const fd_signed: isize = @bitCast(fd_raw);
        if (fd_signed < 0) return 0;
        const fd: i32 = @intCast(fd_raw);
        defer _ = linux.close(fd);
        const n_raw = linux.read(fd, &buf, buf.len);
        const n_signed: isize = @bitCast(n_raw);
        if (n_signed <= 0) return 0;
        const n: usize = @intCast(n_raw);
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

    const start_ns = nanoTimestamp();
    var validator = format_validation.FormatValidator.initDeep();
    const result = validator.validateFileDeep(arena.allocator(), path_slice);
    const elapsed_ns: i64 = @intCast(nanoTimestamp() - start_ns);

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

    const start_ns = nanoTimestamp();
    const result = git_validator.validateRepository(std.heap.page_allocator, path_slice) catch {
        errors.setLastError(.internal_unexpected, "Git validation failed", .{});
        return null;
    };
    const elapsed_ns: i64 = @intCast(nanoTimestamp() - start_ns);

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
    outer_job_count: usize,
};

/// Task for thread pool
const BatchTask = struct {
    index: usize,
};

/// Global interrupt flag - set by validate_interrupt(), checked by workers
var g_interrupt_flag = std.atomic.Value(bool).init(false);

/// Conservative working-set allowance per newly admitted outer task. The first
/// heavy wave uses 1 GiB/task; after pressure proves the feedback loop is active,
/// 256 MiB recovery units restore throughput without waking every worker.
const RSS_ADMISSION_INITIAL_RESERVE_BYTES: u64 = 1024 * 1024 * 1024;
const RSS_ADMISSION_RECOVERY_RESERVE_BYTES: u64 = 256 * 1024 * 1024;

/// Polling cadence for the single RSS sampler. Only the sampling leader reads
/// process RSS; the other workers sleep on a condition variable.
const RSS_ADMISSION_SAMPLE_NS: u64 = 50 * std.time.ns_per_ms;

extern fn malloc_trim(pad: usize) c_int;
extern fn malloc_zone_pressure_relief(zone: ?*anyopaque, goal: usize) usize;

/// Ask the platform allocator to return free arenas after RSS closes admission.
/// This targets resident-but-unused codec allocations; unsupported allocators
/// fall back to the policy's single-task forward-progress escape.
fn releaseUnusedProcessMemory() void {
    const builtin = @import("builtin");
    if (comptime builtin.os.tag == .linux and builtin.abi.isGnu()) {
        _ = malloc_trim(0);
    } else if (comptime builtin.os.tag == .macos) {
        _ = malloc_zone_pressure_relief(null, 0);
    }
}

/// Pure hysteretic policy for process-RSS backpressure. Crossing the high
/// watermark closes admission until RSS reaches 75% of budget, then releases a
/// bounded batch sized from measured headroom rather than waking every worker.
const RssAdmissionPolicy = struct {
    pressured: bool = false,
    has_seen_pressure: bool = false,

    fn admissionCount(
        self: *RssAdmissionPolicy,
        rss: u64,
        budget: u64,
        max_admissions: usize,
        active_tasks: usize,
    ) usize {
        if (max_admissions == 0) return 0;
        if (rss == 0 or budget == 0) {
            self.pressured = false;
            return max_admissions -| active_tasks;
        }

        const low_watermark = budget - budget / 4;
        if (self.pressured) {
            if (rss > low_watermark) return @intFromBool(active_tasks == 0);
            self.pressured = false;
        }

        if (rss >= budget) {
            self.pressured = true;
            self.has_seen_pressure = true;
            return @intFromBool(active_tasks == 0);
        }

        const headroom = budget - rss;
        const reserve_bytes = if (self.has_seen_pressure)
            RSS_ADMISSION_RECOVERY_RESERVE_BYTES
        else
            RSS_ADMISSION_INITIAL_RESERVE_BYTES;
        const headroom_admissions = @max(@as(u64, 1), headroom / reserve_bytes);
        const target_active = @min(max_admissions, @as(usize, @intCast(headroom_admissions)));
        return target_active -| active_tasks;
    }
};

/// Central RSS admission gate. A single leader samples process RSS while all
/// other workers sleep; each sample creates only as many permits as conservative
/// headroom can support. Admission happens before dequeue and memory reservation.
const RssAdmissionGate = struct {
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    budget: u64,
    max_admissions: usize,
    memory_budget: *core.memory_budget.MemoryBudget,
    scheduler_debug: ?*thread_pool.SchedulerDebugStats,
    policy: RssAdmissionPolicy = .{},
    available_admissions: usize = 0,
    sampling_leader: bool = false,
    sampled_once: bool = false,

    fn init(
        budget: u64,
        max_admissions: usize,
        memory_budget: *core.memory_budget.MemoryBudget,
        scheduler_debug: ?*thread_pool.SchedulerDebugStats,
    ) RssAdmissionGate {
        return .{
            .budget = budget,
            .max_admissions = max_admissions,
            .memory_budget = memory_budget,
            .scheduler_debug = scheduler_debug,
        };
    }

    fn wait(context: ?*anyopaque) void {
        const self: *RssAdmissionGate = @ptrCast(@alignCast(context orelse return));
        self.waitForAdmission();
    }

    fn waitForAdmission(self: *RssAdmissionGate) void {
        var debug_wait_start_ns: ?i128 = null;
        defer if (debug_wait_start_ns) |start_ns| {
            if (self.scheduler_debug) |stats| stats.endRssPressureWait(elapsedNanoseconds(start_ns));
        };

        self.mutex.lockUncancelable(runtime.io());
        while (true) {
            if (g_interrupt_flag.load(.seq_cst)) {
                self.mutex.unlock(runtime.io());
                return;
            }
            if (self.available_admissions > 0) {
                self.available_admissions -= 1;
                self.mutex.unlock(runtime.io());
                return;
            }
            if (!self.sampling_leader) {
                self.sampling_leader = true;
                const delay_first_sample = self.sampled_once;
                self.mutex.unlock(runtime.io());
                self.pollAsLeader(delay_first_sample, &debug_wait_start_ns);
                return;
            }

            self.beginDebugWait(&debug_wait_start_ns);
            self.cond.waitUncancelable(runtime.io(), &self.mutex);
        }
    }

    fn pollAsLeader(self: *RssAdmissionGate, delay_first_sample: bool, debug_wait_start_ns: *?i128) void {
        var should_delay = delay_first_sample;
        while (true) {
            if (should_delay) {
                self.beginDebugWait(debug_wait_start_ns);
                runtime.sleep(RSS_ADMISSION_SAMPLE_NS);
            }

            if (g_interrupt_flag.load(.seq_cst)) {
                self.releaseLeader();
                return;
            }

            const rss = getCurrentRss();
            const active_tasks = self.memory_budget.snapshot().active;
            self.mutex.lockUncancelable(runtime.io());
            self.sampled_once = true;
            const admissions = self.policy.admissionCount(rss, self.budget, self.max_admissions, active_tasks);
            if (admissions > 0) {
                self.available_admissions = admissions - 1;
                self.sampling_leader = false;
                self.cond.broadcast(runtime.io());
                self.mutex.unlock(runtime.io());
                return;
            }
            self.mutex.unlock(runtime.io());

            if (self.policy.pressured) releaseUnusedProcessMemory();
            self.beginDebugWait(debug_wait_start_ns);
            should_delay = true;
        }
    }

    fn beginDebugWait(self: *RssAdmissionGate, start_ns: *?i128) void {
        if (start_ns.* != null) return;
        if (self.scheduler_debug) |stats| {
            stats.beginRssPressureWait();
            start_ns.* = nanoTimestamp();
        }
    }

    fn releaseLeader(self: *RssAdmissionGate) void {
        self.mutex.lockUncancelable(runtime.io());
        self.sampling_leader = false;
        self.cond.broadcast(runtime.io());
        self.mutex.unlock(runtime.io());
    }
};

/// Signal batch validation to stop.
/// Workers will finish their current file and then stop.
/// Call this from signal handlers (async-signal-safe: just sets an atomic flag).
export fn validate_interrupt() void {
    g_interrupt_flag.store(true, .seq_cst);
}

/// Check if interrupt was requested.
/// Returns `c_int` (0/1) to match the C header's `int` prototype — see
/// `validate_is_rtl` for why a Zig `bool` return across this ABI is unsafe.
export fn validate_is_interrupted() c_int {
    return @intFromBool(g_interrupt_flag.load(.seq_cst));
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
var g_large_file_sem: std.Io.Semaphore = .{ .permits = 2 };

/// Set the begin callback (called when validation starts for each file)
export fn validate_set_begin_callback(callback: BeginCallback, ctx: ?*anyopaque) void {
    g_begin_callback = callback;
    g_begin_callback_ctx = ctx;
}

/// Execute a single validation task
/// Estimate per-task memory footprint for the budget gate.
/// Uses stat.size as a baseline (caller's working-set proxy). Files we
/// can't stat get a conservative 1 MB estimate so they don't escape the
/// gate. The estimate is intentionally simple — it caps *intent*, not
/// *fact*. Real usage may be smaller (mmap'd zero-copy paths) or larger
/// (PDF stream blowup, libavif internal threading); the large-file semaphore
/// and centralized RSS admission gate remain as guards against the upside.
fn statFileSize(path_slice: []const u8) ?u64 {
    const stat = runtime.statFile(path_slice) catch return null;
    return @intCast(stat.size);
}

fn estimatePathBudget(path_slice: []const u8) usize {
    const size = statFileSize(path_slice) orelse return 1024 * 1024;
    return @intCast(size);
}

fn pathEndsWithCaseless(path_slice: []const u8, suffix: []const u8) bool {
    if (path_slice.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(path_slice[path_slice.len - suffix.len ..], suffix);
}

fn heapDebugFormatHint(path_slice: []const u8) [*:0]const u8 {
    if (pathEndsWithCaseless(path_slice, ".heic")) return "heic";
    if (pathEndsWithCaseless(path_slice, ".heif")) return "heif";
    if (pathEndsWithCaseless(path_slice, ".avif")) return "avif";
    if (pathEndsWithCaseless(path_slice, ".7z")) return "7z";
    if (pathEndsWithCaseless(path_slice, ".zip")) return "zip";
    if (pathEndsWithCaseless(path_slice, ".flac")) return "flac";
    if (pathEndsWithCaseless(path_slice, ".tar")) return "tar";
    return @tagName(format_validation.detectFormatFromExtension(path_slice)).ptr;
}

fn estimateBatchTask(task: BatchTask, ctx_ptr: ?*anyopaque) usize {
    const ctx: *BatchContext = @ptrCast(@alignCast(ctx_ptr orelse return 1024 * 1024));
    const path_ptr = ctx.paths[task.index] orelse return 1024 * 1024;
    const path_slice = std.mem.span(path_ptr);
    return estimatePathBudget(path_slice);
}
fn executeBatchTask(task: BatchTask, ctx_ptr: ?*anyopaque) void {
    // Check interrupt flag before starting
    if (g_interrupt_flag.load(.seq_cst)) {
        return; // Don't process this file, just exit
    }

    const ctx: *BatchContext = @ptrCast(@alignCast(ctx_ptr orelse return));
    const callback = ctx.callback orelse return;
    thread_pool.setBatchOuterJobCount(ctx.outer_job_count);
    defer thread_pool.clearBatchOuterJobCount();

    const path_ptr = ctx.paths[task.index] orelse return;
    const id = ctx.ids[task.index];
    const path_slice = std.mem.span(path_ptr);
    const file_size_opt = statFileSize(path_slice);
    const file_size: u64 = file_size_opt orelse 0;
    const reserved_bytes: u64 = @intCast(file_size_opt orelse 1024 * 1024);
    const format_hint = heapDebugFormatHint(path_slice);
    const heap_task_slot = heapDebugTaskBegin(task.index, id, path_ptr, format_hint, file_size, reserved_bytes);
    defer heapDebugTaskEnd(heap_task_slot);

    // Large-file semaphore: files above threshold block until a slot is free,
    // preventing N workers all simultaneously validating huge files.
    const is_large = if (file_size_opt) |size| size > LARGE_FILE_THRESHOLD else false;
    if (is_large) heapDebugTaskSetPhase(heap_task_slot, phase_large_wait);
    if (is_large) g_large_file_sem.wait(runtime.io()) catch |err| std.debug.panic("sem wait failed: {s}", .{@errorName(err)});
    defer if (is_large) g_large_file_sem.post(runtime.io());

    // Call begin callback if set (useful for debugging crashes)
    if (g_begin_callback) |begin_cb| {
        begin_cb(g_begin_callback_ctx, id, path_ptr);
    }

    // Per-task arena: every Zig-side allocation under this task flows
    // through this arena (small allocs) or directly to page_allocator/mmap
    // (large allocs >= 16 MB) via the diverting wrapper. `arena.deinit()`
    // reclaims small allocs wholesale on task end; large diverted allocs
    // are returned to the OS the moment their owner frees them, so a task
    // that briefly slurps a large file no longer holds that memory until
    // task exit.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var diverter = core.heap.DivertingAllocator.init(arena.allocator(), 16 * 1024 * 1024);
    defer diverter.finishTask();
    const task_alloc = diverter.allocator();
    core.heap.setThreadArena(task_alloc);
    defer core.heap.clearThreadArena();

    heapDebugTaskSetPhase(heap_task_slot, phase_validate);
    const start_ns = nanoTimestamp();
    var validator = format_validation.FormatValidator.initDeep();
    const result = validator.validateFileDeep(task_alloc, path_slice);
    const elapsed_ns: i64 = @intCast(nanoTimestamp() - start_ns);

    // Build result string
    const result_str = buildValidationResult(std.heap.page_allocator, result, elapsed_ns) catch return;

    // Call user callback
    heapDebugTaskSetPhase(heap_task_slot, phase_callback);
    callback(ctx.user_ctx, id, path_ptr, result_str.ptr);
}

/// Avoid idle outer workers and preserve standalone nested parallelism when a
/// batch contains fewer files than the caller's requested thread count.
fn capBatchThreadCount(queued_tasks: usize, requested_threads: usize) usize {
    return @max(@as(usize, 1), @min(queued_tasks, requested_threads));
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

    core.heap.resetStats();

    const requested_threads: usize = if (num_threads <= 0)
        thread_pool.getOuterJobCount()
    else
        @intCast(num_threads);
    const actual_threads = capBatchThreadCount(count, requested_threads);

    // Configure large-file semaphore: scale with memory budget.
    // Reserve 256MB headroom per large file slot (covers typical decompression peaks).
    const budget = validate_get_max_memory();
    const slots_from_mem: usize = @intCast(@max(@as(u64, 1), budget / (256 * 1024 * 1024)));
    const large_file_slots = @min(@max(@as(usize, 2), slots_from_mem), actual_threads);
    g_large_file_sem = std.Io.Semaphore{ .permits = large_file_slots };

    // Pre-init decoder libraries
    core.preInit();

    // 0.16: GeneralPurposeAllocator renamed to DebugAllocator (the latter
    // signals more honestly that its leak-tracking overhead is for Debug).
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var batch_ctx = BatchContext{
        .callback = callback,
        .user_ctx = ctx,
        .paths = paths.?,
        .ids = ids orelse &[_]u32{}, // Use empty array if null, tasks will use index
        .outer_job_count = actual_threads,
    };

    // Memory budget: gates worker dequeue. estimate_fn returns stat.size,
    // budget admits up to total bytes worth of work concurrently. Single
    // file > total budget gets admitted alone (starvation rule).
    var mem_budget = core.memory_budget.MemoryBudget.init(@intCast(validate_get_max_memory()));
    g_active_budget.store(&mem_budget, .seq_cst);
    defer g_active_budget.store(null, .seq_cst);

    var scheduler_debug = thread_pool.SchedulerDebugStats.init();
    scheduler_debug.setWorkerCount(actual_threads);
    const scheduler_debug_ptr: ?*thread_pool.SchedulerDebugStats = if (g_scheduler_debug_tracking.load(.seq_cst)) &scheduler_debug else null;
    g_active_scheduler_debug.store(scheduler_debug_ptr, .seq_cst);
    defer g_active_scheduler_debug.store(null, .seq_cst);

    // Use ThreadPool for parallel execution
    const Pool = thread_pool.ThreadPool(BatchTask, void);
    var rss_admission_gate = RssAdmissionGate.init(budget, actual_threads, &mem_budget, scheduler_debug_ptr);
    const admission_gate = Pool.AdmissionGate{
        .context = @ptrCast(&rss_admission_gate),
        .wait = RssAdmissionGate.wait,
    };
    const pool = Pool.createWithBudgetAndDebugAndAdmission(
        allocator,
        actual_threads,
        executeBatchTask,
        @ptrCast(&batch_ctx),
        {},
        {},
        &mem_budget,
        estimateBatchTask,
        scheduler_debug_ptr,
        admission_gate,
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
/// Returns `c_int` (0/1) — NOT Zig `bool` — because the C header prototypes this
/// as `int`. A 1-byte Zig `bool` return leaves the upper bytes of the return
/// register undefined; a C caller reading a full `int` then saw stale nonzero
/// garbage and treated every locale as RTL. Match the C ABI exactly.
export fn validate_is_rtl() c_int {
    return @intFromBool(i18n.getLocale().isRtl());
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
        .no_perm_out => i18n.getEnvLocalized(.no_perm_out),
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
    jobs: u32,
    early_stop_radius: f64,
    progress_cb: CoverageProgressCallback,
    progress_ctx: ?*anyopaque,
    /// If true, treat any validator-emitted warning_message as "detected"
    /// (i.e. WARN counts the same as FAIL). Default in the C CLI is true
    /// for --test-coverage because the harness asks "did the validator
    /// notice ANY deviation?" — clean is_valid is the only correct answer.
    /// Pass false to preserve the old "FAIL only" semantics.
    strict: bool,
) ?[*:0]u8 {
    const p = path orelse return null;
    const path_slice = std.mem.span(p);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Load the whole file into a reference buffer
    const file = runtime.openFile(path_slice, .{}) catch return null;
    defer file.close(runtime.io());
    const file_size = file.length(runtime.io()) catch return null;
    if (file_size == 0 or file_size > 2 * 1024 * 1024 * 1024) return null;

    const original = std.heap.page_allocator.alloc(u8, @intCast(file_size)) catch return null;
    defer std.heap.page_allocator.free(original);
    const bytes_read = file.readPositionalAll(runtime.io(), original, 0) catch return null;
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
        strict: bool,
    };

    const validate_fn = struct {
        fn cb(cb_ctx: *anyopaque, buffer: []const u8) bool {
            const rc: *RunCtx = @ptrCast(@alignCast(cb_ctx));
            var src = core.file_source.FileSource.fromBuffer(buffer);
            defer src.close();
            var inner_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer inner_arena.deinit();
            const r = rc.validator.validateDeepFromSource(inner_arena.allocator(), rc.format, &src);
            // "Detected" = the validator noticed a deviation. In non-strict
            // mode, only FAIL (is_valid = false) counts. In strict mode,
            // any warning_message ALSO counts — closes the
            // shotgun-vs-bolter detection paradox where shotgun's 4 KB
            // overwrite sometimes produces a depth-degraded WARN instead
            // of FAIL (e.g., deflate-last-strip.tiff: 26% of shotgun
            // outcomes are WARN-routed-as-undetected in non-strict mode).
            if (rc.strict) {
                return !r.is_valid or r.warning_message != null;
            }
            return !r.is_valid;
        }
    }.cb;

    const progress_fn_wrapped: ?test_coverage.ProgressFn = if (progress_cb != null) struct {
        fn cb(cb_ctx: *anyopaque, round: u32, total: u32, detected: u32) void {
            const rc: *RunCtx = @ptrCast(@alignCast(cb_ctx));
            if (rc.user_cb) |user_cb| user_cb(rc.user_ctx, round, total, detected);
        }
    }.cb else null;

    // Translate the C bitmask into Zig's EnumSet. 0 means "the default modes":
    // sniper + shotgun. These are the two modes that give statistically
    // meaningful per-byte and per-region coverage; the other four (header,
    // tail, zeroed, xor) test specific structural regions and stay opt-in.
    // boundary and sparse_noise also stay opt-in. Pass an explicit bitmask
    // to override.
    const modes = blk: {
        const CorruptionMode = test_coverage.CorruptionMode;
        var set = std.EnumSet(CorruptionMode).initEmpty();
        const mask = if (modes_bitmask == 0)
            @as(u32, 0b0000_0011) // sniper + shotgun
        else
            modes_bitmask;
        if (mask & (1 << 0) != 0) set.insert(.sniper);
        if (mask & (1 << 1) != 0) set.insert(.shotgun);
        if (mask & (1 << 2) != 0) set.insert(.header);
        if (mask & (1 << 3) != 0) set.insert(.tail);
        if (mask & (1 << 4) != 0) set.insert(.zeroed);
        if (mask & (1 << 5) != 0) set.insert(.xor);
        if (mask & (1 << 6) != 0) set.insert(.sparse_noise);
        if (mask & (1 << 7) != 0) set.insert(.boundary);
        if (mask & (1 << 8) != 0) set.insert(.bolter);
        break :blk set;
    };

    // Resolve early-stop policy. The C ABI uses a single f64 to encode three
    // states so the C CLI can pass through `--early-stop-radius`,
    // `--no-early-stop`, and the implicit "use default" behavior without a
    // second flag. The mapping is:
    //   - 0.0      → use default radius (0.025 = ±2.5%, well-suited to extreme
    //                bimodal cases like PNG=100% / BMP=0%)
    //   - negative → explicitly disabled (run all `rounds`)
    //   - positive → use as the threshold directly
    const early_stop_radius_resolved: f64 = blk: {
        if (early_stop_radius == 0.0) break :blk @as(f64, 0.025);
        if (early_stop_radius < 0.0) break :blk @as(f64, 0.0); // disabled
        break :blk early_stop_radius;
    };

    // Determine worker count: memory-proportional — coverage holds ~(jobs+1)
    // file copies in RAM, so cap by the memory budget, not an arbitrary flat
    // 16 (which throttled wide hosts). See test_coverage.computeCoverageJobs.
    const nworkers: u32 = test_coverage.computeCoverageJobs(
        jobs,
        @intCast(std.Thread.getCpuCount() catch 1),
        validate_get_max_memory(),
        file_size,
    );

    // Shared state merged-result containers. We build a synthesized
    // CoverageResult after workers join so the KV/heatmap code below stays
    // the same whether we ran one thread or many.
    var merged_by_mode = std.EnumArray(test_coverage.CorruptionMode, test_coverage.ModeStats).initFill(.{});
    const merged_events = std.heap.page_allocator.alloc(test_coverage.CorruptionEvent, rounds) catch return null;
    // We'll own/free merged_events via the synthesized result's .deinit at function end.
    var merged_duration_ns: u64 = 0;
    var merged_file_size: u64 = 0;
    // Actual round count after the (potentially adaptive) early-stop. In the
    // single-threaded path this is `sub.rounds`; in the multi-threaded path
    // it's the sum across workers, since each worker may early-stop on its
    // own slice of the round budget.
    var merged_actual_rounds: u32 = 0;

    if (nworkers == 1) {
        // Single-threaded path — unchanged from step 4.
        var run_ctx = RunCtx{
            .validator = &validator,
            .format = baseline.format,
            .user_cb = progress_cb,
            .user_ctx = progress_ctx,
            .strict = strict,
        };
        var sub = test_coverage.runCoverage(
            alloc,
            orig_slice,
            .{
                .rounds = rounds,
                .shotgun_bytes = shotgun_bytes,
                .seed = seed,
                .progress = progress_fn_wrapped,
                .progress_ctx = @ptrCast(&run_ctx),
                .enabled_modes = modes,
                .early_stop_radius = early_stop_radius_resolved,
            },
            @ptrCast(&run_ctx),
            validate_fn,
        ) catch {
            std.heap.page_allocator.free(merged_events);
            return null;
        };
        defer sub.deinit();
        @memcpy(merged_events[0..sub.events.len], sub.events);
        var mit = sub.by_mode.iterator();
        while (mit.next()) |entry| merged_by_mode.set(entry.key, entry.value.*);
        merged_duration_ns = sub.duration_ns;
        merged_file_size = sub.file_size;
        merged_actual_rounds = sub.rounds;
    } else {
        // Multi-threaded path: each worker gets its own FormatValidator, its
        // own RunCtx, its own arena, its own slice of rounds, and a distinct
        // PRNG seed (base seed + worker id) so two workers don't explore the
        // same corruption space.
        const Worker = struct {
            orig: []const u8,
            my_rounds: u32,
            my_seed: u64,
            shotgun_bytes: u32,
            strict: bool,
            enabled: std.EnumSet(test_coverage.CorruptionMode),
            early_stop_radius: f64,
            baseline_format: format_validation.FileFormat,
            // Output
            result: ?test_coverage.CoverageResult = null,
            spawn_error: ?anyerror = null,

            fn run(self: *@This()) void {
                // Per-thread allocator — ArenaAllocator is fine because we
                // free at join via the result.deinit() we also emit.
                var wvalidator = format_validation.FormatValidator.initDeep();
                defer wvalidator.deinit();
                var rc = RunCtx{
                    .validator = &wvalidator,
                    .format = self.baseline_format,
                    .user_cb = null,
                    .user_ctx = null,
                    .strict = self.strict,
                };
                // Heap-backed events/work. Using page_allocator avoids
                // carrying a cross-thread arena.
                const r = test_coverage.runCoverage(
                    std.heap.page_allocator,
                    self.orig,
                    .{
                        .rounds = self.my_rounds,
                        .shotgun_bytes = self.shotgun_bytes,
                        .seed = self.my_seed,
                        .enabled_modes = self.enabled,
                        .early_stop_radius = self.early_stop_radius,
                    },
                    @ptrCast(&rc),
                    validate_fn,
                ) catch |e| {
                    self.spawn_error = e;
                    return;
                };
                self.result = r;
            }
        };

        const workers = std.heap.page_allocator.alloc(Worker, nworkers) catch {
            std.heap.page_allocator.free(merged_events);
            return null;
        };
        defer std.heap.page_allocator.free(workers);
        const threads = std.heap.page_allocator.alloc(std.Thread, nworkers) catch {
            std.heap.page_allocator.free(merged_events);
            return null;
        };
        defer std.heap.page_allocator.free(threads);

        // Distribute rounds as evenly as possible (last worker absorbs the
        // remainder). Each worker runs on the full original buffer.
        const base = rounds / nworkers;
        const rem = rounds % nworkers;
        var spawned: u32 = 0;
        const t_start = nanoTimestamp();
        errdefer {
            // Join whatever we've already spawned before returning.
            for (0..spawned) |i| threads[i].join();
            for (0..spawned) |i| if (workers[i].result) |*r| r.deinit();
            std.heap.page_allocator.free(merged_events);
        }
        for (0..nworkers) |i| {
            const my_rounds = base + (if (i == nworkers - 1) rem else 0);
            workers[i] = Worker{
                .orig = orig_slice,
                .my_rounds = my_rounds,
                .my_seed = seed +% @as(u64, i),
                .shotgun_bytes = shotgun_bytes,
                .strict = strict,
                .enabled = modes,
                .early_stop_radius = early_stop_radius_resolved,
                .baseline_format = baseline.format,
            };
            threads[i] = std.Thread.spawn(.{}, Worker.run, .{&workers[i]}) catch {
                for (0..i) |j| threads[j].join();
                for (0..i) |j| if (workers[j].result) |*r| r.deinit();
                std.heap.page_allocator.free(merged_events);
                return null;
            };
            spawned += 1;
        }
        for (0..nworkers) |i| threads[i].join();
        const t_end = nanoTimestamp();

        // Merge: concat events, sum by_mode, take max duration (wall-clock).
        var offset: usize = 0;
        var any_err: bool = false;
        for (workers) |*w| {
            if (w.spawn_error != null or w.result == null) {
                any_err = true;
                continue;
            }
            const r = &w.result.?;
            merged_file_size = r.file_size;
            @memcpy(merged_events[offset .. offset + r.events.len], r.events);
            offset += r.events.len;
            merged_actual_rounds += r.rounds;
            var mit = r.by_mode.iterator();
            while (mit.next()) |entry| {
                const cur = merged_by_mode.get(entry.key);
                merged_by_mode.set(entry.key, .{
                    .total = cur.total + entry.value.total,
                    .detected = cur.detected + entry.value.detected,
                });
            }
            r.deinit();
        }
        if (any_err) {
            std.heap.page_allocator.free(merged_events);
            return null;
        }
        merged_duration_ns = @intCast(t_end - t_start);
    }

    // Shrink merged_events to its actual size so the synthesized result's
    // events slice length matches the allocation length (required by
    // page_allocator.free in result.deinit()). If the realloc fails — which
    // shouldn't happen when shrinking — fall back to copying into a fresh
    // buffer.
    var final_events: []test_coverage.CorruptionEvent = merged_events;
    if (merged_actual_rounds < rounds) {
        if (std.heap.page_allocator.realloc(merged_events, merged_actual_rounds)) |shrunk| {
            final_events = shrunk;
        } else |_| {
            const fresh = std.heap.page_allocator.alloc(test_coverage.CorruptionEvent, merged_actual_rounds) catch {
                std.heap.page_allocator.free(merged_events);
                return null;
            };
            @memcpy(fresh, merged_events[0..merged_actual_rounds]);
            std.heap.page_allocator.free(merged_events);
            final_events = fresh;
        }
    }

    var result = test_coverage.CoverageResult{
        .file_size = merged_file_size,
        .rounds = merged_actual_rounds,
        .duration_ns = merged_duration_ns,
        .by_mode = merged_by_mode,
        .events = final_events,
        .allocator = std.heap.page_allocator,
    };
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
        // Surface the originally-requested round cap separately so callers
        // can tell at a glance when early-stop kicked in (rounds < requested).
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrintZ(&buf, "{d}", .{rounds}) catch return null;
        builder.add("requested_rounds", s) catch return null;
    }
    {
        // Effective early-stop threshold (0.0 = disabled). Lets the CLI tell
        // users which radius was used so the printed "Early stop" message
        // names a real number.
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrintZ(&buf, "{d:.4}", .{early_stop_radius_resolved}) catch return null;
        builder.add("early_stop_radius", s) catch return null;
    }
    {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrintZ(&buf, "{s}", .{if (merged_actual_rounds < rounds) "1" else "0"}) catch return null;
        builder.add("early_stopped", s) catch return null;
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
    // Per-mode stats — emit for EVERY CorruptionMode, exhaustively over the enum.
    // A hand-maintained list previously omitted `bolter` (added out-of-sequence),
    // so bolter ran but was never reported and the CLI silently dropped its row
    // (it skips modes whose total==0). Iterating the enum makes that class of
    // bug impossible: any future mode is reported automatically. (#bolter-2026-06-12)
    for (std.enums.values(test_coverage.CorruptionMode)) |mode| {
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
            .{ .tag = .sparse_noise, .key = "heatmap_sparse_noise" },
            .{ .tag = .boundary, .key = "heatmap_boundary" },
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

test "FFI result carries NOPERM without corrupting Boolean status fields" {
    var result = format_validation.ValidationResult.invalidCode(.unknown, .failed_to_open, "file");
    result.access = .no_permission;

    const encoded = try buildValidationResult(std.testing.allocator, result, 0);
    defer std.testing.allocator.free(encoded);
    const result_slice = encoded[0..encoded.len];

    try std.testing.expect(std.mem.indexOf(u8, result_slice, "access\x1fNOPERM") != null);
    try std.testing.expect(std.mem.indexOf(u8, result_slice, "valid\x1fF") != null);
    try std.testing.expect(std.mem.indexOf(u8, result_slice, "unknown\x1fF") != null);
}

test "validate_default_threads" {
    const threads = validate_default_threads();
    try std.testing.expect(threads >= 1);
}

test "scheduler debug snapshot is unavailable without an active batch" {
    var snapshot: SchedulerDebugSnapshot = undefined;
    try std.testing.expectEqual(@as(c_int, 2), validate_get_scheduler_debug_snapshot(&snapshot));
    try std.testing.expectEqual(@as(u64, 0), snapshot.queue_empty_wait_ns);
    try std.testing.expectEqual(@as(u64, 0), snapshot.memory_budget_wait_ns);
    try std.testing.expectEqual(@as(u64, 0), snapshot.rss_pressure_wait_ns);
}

test "RSS admission policy holds pressure until the low watermark" {
    const gib: u64 = 1024 * 1024 * 1024;
    var policy = RssAdmissionPolicy{};

    try std.testing.expectEqual(@as(usize, 1), policy.admissionCount(7 * gib, 8 * gib, 85, 0));
    try std.testing.expectEqual(@as(usize, 0), policy.admissionCount(7 * gib, 8 * gib, 85, 1));
    try std.testing.expectEqual(@as(usize, 0), policy.admissionCount(8 * gib, 8 * gib, 85, 1));
    try std.testing.expectEqual(@as(usize, 0), policy.admissionCount(7 * gib, 8 * gib, 85, 1));
    try std.testing.expectEqual(@as(usize, 1), policy.admissionCount(7 * gib, 8 * gib, 85, 0));
    try std.testing.expectEqual(@as(usize, 8), policy.admissionCount(6 * gib, 8 * gib, 85, 0));
}

test "batch worker count never exceeds queued work" {
    const cases = [_]struct {
        queued_tasks: usize,
        requested_threads: usize,
        expected: usize,
    }{
        .{ .queued_tasks = 1, .requested_threads = 85, .expected = 1 },
        .{ .queued_tasks = 3, .requested_threads = 12, .expected = 3 },
        .{ .queued_tasks = 42, .requested_threads = 12, .expected = 12 },
        .{ .queued_tasks = 42, .requested_threads = 85, .expected = 42 },
    };

    for (cases) |case| {
        try std.testing.expectEqual(
            case.expected,
            capBatchThreadCount(case.queued_tasks, case.requested_threads),
        );
    }
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

/// Extract the u64 value of `mode_<mode>_<field>` from a KV-US-RS result.
fn kvModeU64(kv: []const u8, mode: []const u8, field: []const u8) ?u64 {
    var keybuf: [48]u8 = undefined;
    const key = std.fmt.bufPrint(&keybuf, "mode_{s}_{s}", .{ mode, field }) catch return null;
    const idx = std.mem.indexOf(u8, kv, key) orelse return null;
    var p = idx + key.len;
    if (p >= kv.len or kv[p] != US) return null; // must be the key→value boundary
    p += 1;
    const end = std.mem.indexOfScalarPos(u8, kv, p, RS) orelse kv.len;
    return std.fmt.parseInt(u64, kv[p..end], 10) catch null;
}

test "test-coverage reports EVERY requested mode (regression: bolter was dropped)" {
    // Regression guard for the bolter-omission bug: bolter (CorruptionMode bit
    // 1<<8, added out-of-sequence after the original 8 modes) was *run* but its
    // per-mode stats were never emitted by the FFI — the emission used a
    // hardcoded mode list that omitted it. The CLI then silently dropped the
    // bolter row (it skips modes whose total==0). This asserts that every mode
    // the caller requests actually runs AND is reported (total > 0), as a SET —
    // not just the default sniper/shotgun pair.
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var data: [8192]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i);
    {
        const wf = tmp.dir.createFile(runtime.io(), "cov.bin", .{}) catch unreachable;
        defer wf.close(runtime.io());
        wf.writePositionalAll(runtime.io(), &data, 0) catch unreachable;
    }
    const path = runtime.tmpRealpathAlloc(&tmp, allocator, "cov.bin") catch unreachable;
    defer allocator.free(path);
    const pathz = allocator.dupeZ(u8, path) catch unreachable;
    defer allocator.free(pathz);

    // sniper(1<<0) | shotgun(1<<1) | bolter(1<<8) = 0x103 — exactly Peter's repro.
    const mask: u32 = (1 << 0) | (1 << 1) | (1 << 8);
    // 30 rounds / 3 modes = 10 each; negative early-stop radius disables early
    // stop so all rounds run deterministically; single-threaded for determinism.
    const result = validate_test_coverage(pathz.ptr, 30, 42, 4096, mask, 0, 1, -1.0, null, null, true) orelse return error.NullCoverageResult;
    defer validate_free(result);
    const kv = std.mem.span(result);

    for ([_][]const u8{ "sniper", "shotgun", "bolter" }) |m| {
        const total = kvModeU64(kv, m, "total") orelse {
            std.debug.print("coverage KV is missing mode_{s}_total — requested mode not reported\n", .{m});
            return error.RequestedModeNotReported;
        };
        try std.testing.expect(total > 0); // the mode actually ran
    }
}
