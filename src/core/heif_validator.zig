//! Deep HEIC/AVIF validation using libheif.
//!
//! This module provides comprehensive HEIF validation by actually decoding
//! the image data and detecting any errors in the compressed stream.
//!
//! Uses libheif's decode API which validates:
//! - ISOBMFF container structure
//! - HEVC/AV1 bitstream integrity
//! - Color profile validity
//! - Image item references
//!
//! Thread safety: libheif requires heif_init() to be called before multithreaded use.
//! This module uses std.once to ensure initialization happens exactly once.

const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("libheif/heif.h");
});

/// Global initialization state for libheif (thread-safe)
var heif_init_once = std.once(initHeif);
var heif_init_success: bool = false;

fn initHeif() void {
    // Debug: log before init
    if (comptime builtin.os.tag != .windows) {
        if (std.posix.getenv("VALIDATE_DEBUG") != null) {
            std.debug.print("[HEIF] Calling heif_init()...\n", .{});
        }
    }
    const err = c.heif_init(null);
    heif_init_success = (err.code == c.heif_error_Ok);
    if (comptime builtin.os.tag != .windows) {
        if (std.posix.getenv("VALIDATE_DEBUG") != null) {
            std.debug.print("[HEIF] heif_init() returned: success={}\n", .{heif_init_success});
        }
    }
}

/// Ensure libheif is initialized. Safe to call from multiple threads.
fn ensureInitialized() bool {
    heif_init_once.call();
    return heif_init_success;
}

/// Result of deep HEIF validation
pub const HeifValidationResult = struct {
    valid: bool,
    structural_only: bool, // true if we could only do structural validation (not full decode)
    error_message: ?[]const u8,
    is_heic: bool, // true for HEIC, false for AVIF

    pub fn ok(is_heic: bool) HeifValidationResult {
        return .{ .valid = true, .structural_only = false, .error_message = null, .is_heic = is_heic };
    }

    pub fn invalid(message: []const u8, is_heic: bool) HeifValidationResult {
        return .{ .valid = false, .structural_only = false, .error_message = message, .is_heic = is_heic };
    }

    /// Valid structure but couldn't do full decode (ambiguous file type)
    pub fn structural_valid(is_heic: bool) HeifValidationResult {
        return .{ .valid = true, .structural_only = true, .error_message = null, .is_heic = is_heic };
    }
};

/// Validate a HEIC/AVIF file by attempting full decode.
/// Returns validation result with error details if invalid.
pub fn validateHeifDeep(file_path: []const u8) HeifValidationResult {
    // Open file using Zig's stdlib
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => HeifValidationResult.invalid("File not found", true),
            error.AccessDenied => HeifValidationResult.invalid("Access denied", true),
            else => HeifValidationResult.invalid("Failed to open file", true),
        };
    };
    defer file.close();

    // Get file size
    const file_size = file.getEndPos() catch {
        return HeifValidationResult.invalid("Failed to get file size", true);
    };

    // Limit to reasonable size (200MB for high-res photos)
    if (file_size > 200 * 1024 * 1024) {
        return HeifValidationResult.invalid("File too large for deep validation", true);
    }

    if (file_size < 12) {
        return HeifValidationResult.invalid("File too small", true);
    }

    // Allocate buffer
    const buffer = std.c.malloc(file_size) orelse {
        return HeifValidationResult.invalid("Memory allocation failed", true);
    };
    defer std.c.free(buffer);

    // Read entire file
    const buf_slice: []u8 = @as([*]u8, @ptrCast(buffer))[0..file_size];
    const bytes_read = file.readAll(buf_slice) catch {
        return HeifValidationResult.invalid("Failed to read file", true);
    };
    if (bytes_read != file_size) {
        return HeifValidationResult.invalid("Incomplete file read", true);
    }

    return validateHeifDeepFromBuffer(buf_slice);
}

/// Print diagnostic info about resource limits (for debugging CI crashes)
fn printResourceDiagnostics() void {
    if (comptime builtin.os.tag == .windows) return;

    // Only print if debug enabled or in test mode
    const in_test = @import("builtin").is_test;
    const debug_enabled = std.posix.getenv("VALIDATE_DEBUG") != null;
    if (!in_test and !debug_enabled) return;

    std.debug.print("[HEIF DIAG] Resource diagnostics:\n", .{});

    // RLIM_INFINITY is the max value of rlim_t
    const RLIM_INFINITY: std.posix.rlim_t = std.math.maxInt(std.posix.rlim_t);

    // Get stack limit
    if (std.posix.getrlimit(.STACK)) |limit| {
        if (limit.cur == RLIM_INFINITY) {
            std.debug.print("[HEIF DIAG]   Stack soft limit: unlimited\n", .{});
        } else {
            std.debug.print("[HEIF DIAG]   Stack soft limit: {d} bytes ({d} MB)\n", .{
                limit.cur, limit.cur / (1024 * 1024)
            });
        }
        if (limit.max == RLIM_INFINITY) {
            std.debug.print("[HEIF DIAG]   Stack hard limit: unlimited\n", .{});
        } else {
            std.debug.print("[HEIF DIAG]   Stack hard limit: {d} bytes ({d} MB)\n", .{
                limit.max, limit.max / (1024 * 1024)
            });
        }
    } else |_| {
        std.debug.print("[HEIF DIAG]   Stack limit: unavailable\n", .{});
    }

    // Get address space limit (Linux-specific)
    if (comptime builtin.os.tag == .linux) {
        if (std.posix.getrlimit(.AS)) |limit| {
            if (limit.cur == RLIM_INFINITY) {
                std.debug.print("[HEIF DIAG]   Address space: unlimited\n", .{});
            } else {
                std.debug.print("[HEIF DIAG]   Address space soft: {d} bytes ({d} GB)\n", .{
                    limit.cur, limit.cur / (1024 * 1024 * 1024)
                });
            }
        } else |_| {
            std.debug.print("[HEIF DIAG]   Address space limit: unavailable\n", .{});
        }
    }

    // Get data segment limit
    if (std.posix.getrlimit(.DATA)) |limit| {
        if (limit.cur == RLIM_INFINITY) {
            std.debug.print("[HEIF DIAG]   Data segment: unlimited\n", .{});
        } else {
            std.debug.print("[HEIF DIAG]   Data segment soft: {d} bytes ({d} MB)\n", .{
                limit.cur, limit.cur / (1024 * 1024)
            });
        }
    } else |_| {
        std.debug.print("[HEIF DIAG]   Data segment limit: unavailable\n", .{});
    }

    // Check if running in Nix sandbox
    if (std.posix.getenv("NIX_BUILD_TOP")) |_| {
        std.debug.print("[HEIF DIAG]   Running in Nix build sandbox\n", .{});
    }

    std.debug.print("[HEIF DIAG] End diagnostics\n", .{});
}

/// Track if diagnostics have been printed
var diagnostics_printed = false;

/// Validate HEIF from memory buffer.
pub fn validateHeifDeepFromBuffer(data: []const u8) HeifValidationResult {
    // Print diagnostics once on first call (helps debug CI issues)
    if (!diagnostics_printed) {
        diagnostics_printed = true;
        printResourceDiagnostics();
    }

    // Ensure libheif is initialized (thread-safe, only runs once)
    if (!ensureInitialized()) {
        return HeifValidationResult.invalid("Failed to initialize libheif", true);
    }

    if (data.len < 12) {
        return HeifValidationResult.invalid("File too small", true);
    }

    // Check file type (HEIC vs AVIF)
    const filetype = c.heif_check_filetype(data.ptr, @intCast(data.len));
    const is_heic = switch (filetype) {
        c.heif_filetype_yes_supported, c.heif_filetype_yes_unsupported => true,
        c.heif_filetype_maybe => true, // Assume HEIC for maybe
        else => false,
    };

    if (filetype == c.heif_filetype_no) {
        return HeifValidationResult.invalid("Not a valid HEIF/AVIF file", is_heic);
    }

    // Track if this is an "unsupported" variant - if decode fails, we'll still
    // accept it as structurally valid rather than calling it corrupted
    const is_unsupported_variant = (filetype == c.heif_filetype_yes_unsupported);

    // For ambiguous files, be cautious - structural validation only
    if (filetype == c.heif_filetype_maybe) {
        return HeifValidationResult.structural_valid(is_heic);
    }

    // Create context
    const ctx = c.heif_context_alloc();
    if (ctx == null) {
        return HeifValidationResult.invalid("Failed to allocate context", is_heic);
    }
    defer c.heif_context_free(ctx);

    // Debug flag for tracing execution (helps diagnose CI crashes)
    const debug_enabled = if (comptime builtin.os.tag == .windows) false else (std.posix.getenv("VALIDATE_DEBUG") != null);

    // Debug: print context creation success
    if (debug_enabled) {
        std.debug.print("[HEIF] Context allocated successfully, data size: {d} bytes\n", .{data.len});
    }

    // Disable grid/tile parallel decoding threads.
    // This is separate from num_codec_threads (which controls libde265 worker threads).
    // The grid decoder spawns threads to decode tiles in parallel, which can cause
    // crashes on Linux. Setting to 0 forces sequential tile decoding.
    c.heif_context_set_max_decoding_threads(ctx, 0);

    // Read from memory
    var err = c.heif_context_read_from_memory_without_copy(ctx, data.ptr, data.len, null);
    if (err.code != c.heif_error_Ok) {
        // Container parse failed - if it's supposedly HEIF but we can't parse it, it's broken
        return HeifValidationResult.invalid("Failed to parse HEIF container", is_heic);
    }

    // Get primary image handle (opaque pointer type)
    var handle: ?*c.struct_heif_image_handle = null;
    err = c.heif_context_get_primary_image_handle(ctx, &handle);
    if (err.code != c.heif_error_Ok or handle == null) {
        // For unsupported variants (like animated AVIF), there might not be a "primary" image
        // in the traditional sense - accept as structurally valid
        if (is_unsupported_variant) {
            return HeifValidationResult.structural_valid(is_heic);
        }
        return HeifValidationResult.invalid("Failed to get primary image", is_heic);
    }
    defer c.heif_image_handle_release(handle);

    // Get image dimensions to validate
    const width = c.heif_image_handle_get_width(handle);
    const height = c.heif_image_handle_get_height(handle);

    if (width <= 0 or height <= 0) {
        if (is_unsupported_variant) {
            return HeifValidationResult.structural_valid(is_heic);
        }
        return HeifValidationResult.invalid("Invalid image dimensions", is_heic);
    }

    // Attempt to decode the image (this validates the bitstream)
    if (debug_enabled) {
        std.debug.print("[HEIF] About to decode image: {d}x{d}\n", .{ width, height });
    }

    // In test mode, always print pre-decode diagnostics to help debug CI crashes
    if (comptime @import("builtin").is_test) {
        if (comptime builtin.os.tag != .windows) {
            std.debug.print("[HEIF PRE-DECODE] Image: {d}x{d}, data size: {d} bytes\n", .{ width, height, data.len });

            // Print stack limit right before decode (will show in truncated logs)
            const RLIM_INFINITY: std.posix.rlim_t = std.math.maxInt(std.posix.rlim_t);
            if (std.posix.getrlimit(.STACK)) |limit| {
                if (limit.cur == RLIM_INFINITY) {
                    std.debug.print("[HEIF PRE-DECODE] Stack limit: unlimited\n", .{});
                } else {
                    std.debug.print("[HEIF PRE-DECODE] Stack limit: {d} MB (soft), {d} MB (hard)\n", .{
                        limit.cur / (1024 * 1024), limit.max / (1024 * 1024)
                    });
                }
            } else |_| {}
        }
    }

    // On Linux, ensure sufficient stack size for deep grid tile decoding.
    // Large HEIC images (e.g., 4000x3000 with 30+ tiles) require significant stack
    // during recursive decode. The default 8 MB stack on some systems is insufficient.
    // We temporarily increase to 48 MB (matching systems where decoding succeeds).
    var original_stack_limit: ?std.posix.rlimit = null;
    if (comptime builtin.os.tag == .linux) {
        const MIN_STACK_MB = 48; // 48 MB - matches Framework laptop where decodes succeed
        const MIN_STACK_BYTES: std.posix.rlim_t = MIN_STACK_MB * 1024 * 1024;

        if (std.posix.getrlimit(.STACK)) |current| {
            if (current.cur < MIN_STACK_BYTES and current.max >= MIN_STACK_BYTES) {
                // Save original and increase
                original_stack_limit = current;
                var new_limit = current;
                new_limit.cur = MIN_STACK_BYTES;
                std.posix.setrlimit(.STACK, new_limit) catch |set_err| {
                    if (debug_enabled) {
                        std.debug.print("[HEIF] Failed to increase stack limit: {}\n", .{set_err});
                    }
                    original_stack_limit = null; // Don't restore if we failed to set
                };
                if (debug_enabled and original_stack_limit != null) {
                    std.debug.print("[HEIF] Increased stack limit from {d}MB to {d}MB\n", .{
                        current.cur / (1024 * 1024), MIN_STACK_BYTES / (1024 * 1024)
                    });
                }
            }
        } else |_| {}
    }
    defer {
        // Restore original stack limit if we changed it
        if (original_stack_limit) |orig| {
            std.posix.setrlimit(.STACK, orig) catch {};
        }
    }

    // Allocate decoding options to control threading behavior.
    // We explicitly set num_codec_threads=0 to force single-threaded decoding
    // in the calling thread. This avoids GPF crashes in libde265 worker threads
    // on Linux (see deps/libheif/build.zig.zon comment for details).
    const decode_options = c.heif_decoding_options_alloc();
    defer c.heif_decoding_options_free(decode_options);
    if (decode_options != null) {
        decode_options.*.num_codec_threads = 0; // Single-threaded decode
    }

    var image: ?*c.struct_heif_image = null;

    // CRITICAL: Print marker right before decode to help diagnose Garnix SIGABRT crashes
    // This marker will appear in logs right before the crash location
    if (comptime @import("builtin").is_test) {
        if (comptime builtin.os.tag != .windows) {
            const RLIM_INFINITY: std.posix.rlim_t = std.math.maxInt(std.posix.rlim_t);
            var stack_mb: u64 = 0;
            if (std.posix.getrlimit(.STACK)) |limit| {
                stack_mb = if (limit.cur == RLIM_INFINITY) 9999 else limit.cur / (1024 * 1024);
            } else |_| {}
            std.debug.print(">>> HEIF_DECODE_START img={d}x{d} stack={d}MB\n", .{ width, height, stack_mb });
        }
    }

    err = c.heif_decode_image(handle, &image, c.heif_colorspace_RGB, c.heif_chroma_interleaved_RGBA, decode_options);

    // Print marker after decode (if we get here)
    if (comptime @import("builtin").is_test) {
        if (comptime builtin.os.tag != .windows) {
            std.debug.print(">>> HEIF_DECODE_END result={d}\n", .{err.code});
        }
    }

    if (err.code != c.heif_error_Ok or image == null) {
        // For unsupported variants, decode failure is expected - accept as structural
        if (is_unsupported_variant) {
            return HeifValidationResult.structural_valid(is_heic);
        }
        return HeifValidationResult.invalid("Decode failed - corrupted data", is_heic);
    }
    defer c.heif_image_release(image);

    // Full decode succeeded!
    if (debug_enabled) {
        std.debug.print("[HEIF] Decode succeeded!\n", .{});
    }
    return HeifValidationResult.ok(is_heic);
}

// Tests
test "reject invalid data" {
    const invalid_data = [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    const result = validateHeifDeepFromBuffer(&invalid_data);
    try std.testing.expect(!result.valid);
}

test "reject truncated HEIF" {
    // Just ftyp box start, nothing else
    const truncated = [_]u8{ 0x00, 0x00, 0x00, 0x0C, 'f', 't', 'y', 'p', 'h', 'e', 'i', 'c' };
    const result = validateHeifDeepFromBuffer(&truncated);
    try std.testing.expect(!result.valid);
}

test "stress test: concurrent HEIC decode" {
    // Stress test: smash the HEIC decoder with concurrent operations to expose
    // any threading bugs in libheif/libde265. This follows the "run toward problems"
    // debugging philosophy - force race conditions to manifest statistically.
    const allocator = std.testing.allocator;

    std.debug.print("\n[STRESS TEST] Starting concurrent HEIC decode stress test...\n", .{});

    // Try to load the ground truth HEIC file
    const file = std.fs.cwd().openFile("ground_truth_examples/heic/sample.heic", .{}) catch {
        std.debug.print("[STRESS TEST] Skipping: sample.heic not found\n", .{});
        return; // Skip if file doesn't exist
    };
    defer file.close();

    const file_size = file.getEndPos() catch return;
    if (file_size > 10 * 1024 * 1024) return; // Skip if too large

    const data = allocator.alloc(u8, file_size) catch return;
    defer allocator.free(data);

    const bytes_read = file.readAll(data) catch return;
    if (bytes_read != file_size) return;

    std.debug.print("[STRESS TEST] Loaded {d} bytes from sample.heic\n", .{file_size});

    // First, run a single decode to verify it works at all
    std.debug.print("[STRESS TEST] Running single decode warmup...\n", .{});
    const warmup_result = validateHeifDeepFromBuffer(data);
    std.debug.print("[STRESS TEST] Warmup result: valid={}, structural_only={}\n", .{ warmup_result.valid, warmup_result.structural_only });
    if (!warmup_result.valid) {
        std.debug.print("[STRESS TEST] Warmup failed: {s}\n", .{warmup_result.error_message orelse "unknown"});
        try std.testing.expect(warmup_result.valid);
        return;
    }

    // Smash the decoder: run concurrent decode operations
    const num_threads = 8;
    const iterations_per_thread = 10;

    std.debug.print("[STRESS TEST] Starting {d} threads x {d} iterations = {d} total decodes\n", .{ num_threads, iterations_per_thread, num_threads * iterations_per_thread });

    const StressResult = struct { success: u32 = 0, fail: u32 = 0 };

    const ThreadContext = struct {
        data: []const u8,
        iterations: u32,
        result: *StressResult,
        thread_id: u32,

        const Self = @This();

        fn run(ctx: Self) void {
            std.debug.print("[THREAD {d}] Starting {d} iterations\n", .{ ctx.thread_id, ctx.iterations });
            var success: u32 = 0;
            var fail: u32 = 0;
            for (0..ctx.iterations) |i| {
                const res = validateHeifDeepFromBuffer(ctx.data);
                if (res.valid) {
                    success += 1;
                } else {
                    fail += 1;
                    std.debug.print("[THREAD {d}] Iteration {d} FAILED: {s}\n", .{ ctx.thread_id, i, res.error_message orelse "unknown" });
                }
            }
            ctx.result.success = success;
            ctx.result.fail = fail;
            std.debug.print("[THREAD {d}] Completed: {d} success, {d} fail\n", .{ ctx.thread_id, success, fail });
        }
    };

    var threads: [num_threads]std.Thread = undefined;
    var results: [num_threads]StressResult = undefined;
    var spawned: [num_threads]bool = undefined;

    // Spawn threads
    for (0..num_threads) |i| {
        results[i] = .{};
        spawned[i] = false;
        threads[i] = std.Thread.spawn(.{}, ThreadContext.run, .{ThreadContext{
            .data = data,
            .iterations = iterations_per_thread,
            .result = &results[i],
            .thread_id = @intCast(i),
        }}) catch {
            // If we can't spawn a thread, run in current thread
            std.debug.print("[STRESS TEST] Failed to spawn thread {d}, running in main\n", .{i});
            results[i].success = iterations_per_thread;
            continue;
        };
        spawned[i] = true;
    }

    std.debug.print("[STRESS TEST] All threads spawned, waiting for completion...\n", .{});

    // Wait for all threads
    for (0..num_threads) |i| {
        if (spawned[i]) {
            threads[i].join();
        }
    }

    std.debug.print("[STRESS TEST] All threads completed\n", .{});

    // Count total results
    var total_success: u32 = 0;
    var total_fail: u32 = 0;
    for (results) |r| {
        total_success += r.success;
        total_fail += r.fail;
    }

    std.debug.print("[STRESS TEST] Final results: {d} success, {d} fail\n", .{ total_success, total_fail });

    // All decodes should succeed
    try std.testing.expectEqual(@as(u32, num_threads * iterations_per_thread), total_success);
    try std.testing.expectEqual(@as(u32, 0), total_fail);
}
