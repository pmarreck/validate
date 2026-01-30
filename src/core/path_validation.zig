//! Parallel path validation utilities.
//!
//! This module validates a file or directory tree, optionally in parallel,
//! and reports per-file results via a callback.

const std = @import("std");
const builtin = @import("builtin");
const format_validation = @import("format_validation.zig");

const Allocator = std.mem.Allocator;
const ValidationResult = format_validation.ValidationResult;
const FormatValidator = format_validation.FormatValidator;

const DEFAULT_MAX_FILES: usize = std.math.maxInt(usize);

/// Cross-platform getenv that returns null on Windows (where std.posix.getenv is unavailable).
fn getenvCrossPlatform(comptime name: []const u8) ?[:0]const u8 {
    if (comptime builtin.os.tag == .windows) {
        return null;
    }
    return std.posix.getenv(name);
}

/// Check if debug tracing is enabled via VALIDATE_DEBUG env var.
/// When set, prints each file path to stderr BEFORE validation starts.
/// This helps identify which file causes hangs or crashes.
fn isDebugTraceEnabled() bool {
    const env = getenvCrossPlatform("VALIDATE_DEBUG") orelse return false;
    return env.len > 0 and env[0] != '0';
}

/// Print debug trace to stderr (thread-safe via stderr's internal locking)
fn debugTrace(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "[DEBUG] " ++ fmt ++ "\n", args) catch return;
    std.fs.File.stderr().writeAll(msg) catch {};
}

pub const ValidationCounts = struct {
	valid: usize = 0,
	invalid: usize = 0,
	unknown: usize = 0,
};

pub const ValidationCallback = *const fn (
	ctx: ?*anyopaque,
	display_path: []const u8,
	result: ValidationResult,
	elapsed_seconds: f64,
) void;

const AtomicUsize = std.atomic.Value(usize);

const SharedCounts = struct {
	valid: AtomicUsize = .init(0),
	invalid: AtomicUsize = .init(0),
	unknown: AtomicUsize = .init(0),

	fn add(self: *SharedCounts, result: ValidationResult) void {
		if (result.format == .unknown) {
			_ = self.unknown.fetchAdd(1, .monotonic);
			return;
		}
		if (result.is_valid) {
			_ = self.valid.fetchAdd(1, .monotonic);
		} else {
			_ = self.invalid.fetchAdd(1, .monotonic);
		}
	}

	fn toCounts(self: *SharedCounts) ValidationCounts {
		return .{
			.valid = self.valid.load(.monotonic),
			.invalid = self.invalid.load(.monotonic),
			.unknown = self.unknown.load(.monotonic),
		};
	}
};

const WorkItem = struct {
	path: []u8,
	display_path: []u8,
};

/// Holds an owned copy of a validation result for the output queue.
/// All string fields are heap-allocated and owned by this struct.
const ResultItem = struct {
	display_path: []u8,
	format: format_validation.FileFormat,
	is_valid: bool,
	error_message: ?[]u8,
	warning_message: ?[]u8,
	malformations: std.EnumSet(format_validation.MalformationType),
	validation_depth: format_validation.ValidationDepth,
	circumvented_trivial_protection: bool,
	validated_via_ffmpeg: bool,
	elapsed_seconds: f64,

	pub fn deinit(self: *ResultItem, allocator: Allocator) void {
		allocator.free(self.display_path);
		if (self.error_message) |msg| allocator.free(msg);
		if (self.warning_message) |msg| allocator.free(msg);
	}
};

const WorkQueue = struct {
	mutex: std.Thread.Mutex = .{},
	cond: std.Thread.Condition = .{},
	items: std.ArrayListUnmanaged(WorkItem) = .{},
	closed: bool = false,
	allocator: Allocator,

	pub fn init(allocator: Allocator) WorkQueue {
		return .{ .allocator = allocator };
	}

	pub fn deinit(self: *WorkQueue) void {
		for (self.items.items) |item| {
			self.allocator.free(item.path);
			self.allocator.free(item.display_path);
		}
		self.items.deinit(self.allocator);
	}

	pub fn push(self: *WorkQueue, item: WorkItem) !void {
		self.mutex.lock();
		defer self.mutex.unlock();
		try self.items.append(self.allocator, item);
		self.cond.signal();
	}

	pub fn pop(self: *WorkQueue) ?WorkItem {
		self.mutex.lock();
		defer self.mutex.unlock();
		while (self.items.items.len == 0 and !self.closed) {
			self.cond.wait(&self.mutex);
		}
		if (self.items.items.len == 0) {
			return null;
		}
		return self.items.pop();
	}

	pub fn close(self: *WorkQueue) void {
		self.mutex.lock();
		self.closed = true;
		self.mutex.unlock();
		self.cond.broadcast();
	}
};

/// Queue for validation results, consumed by a dedicated output thread.
const ResultQueue = struct {
	mutex: std.Thread.Mutex = .{},
	cond: std.Thread.Condition = .{},
	items: std.ArrayListUnmanaged(ResultItem) = .{},
	closed: bool = false,
	allocator: Allocator,

	pub fn init(allocator: Allocator) ResultQueue {
		return .{ .allocator = allocator };
	}

	pub fn deinit(self: *ResultQueue) void {
		for (self.items.items) |*item| {
			item.deinit(self.allocator);
		}
		self.items.deinit(self.allocator);
	}

	pub fn push(self: *ResultQueue, item: ResultItem) !void {
		self.mutex.lock();
		defer self.mutex.unlock();
		try self.items.append(self.allocator, item);
		self.cond.signal();
	}

	pub fn pop(self: *ResultQueue) ?ResultItem {
		self.mutex.lock();
		defer self.mutex.unlock();
		while (self.items.items.len == 0 and !self.closed) {
			self.cond.wait(&self.mutex);
		}
		if (self.items.items.len == 0) {
			return null;
		}
		return self.items.pop();
	}

	pub fn close(self: *ResultQueue) void {
		self.mutex.lock();
		self.closed = true;
		self.mutex.unlock();
		self.cond.signal();
	}
};

const Shared = struct {
	validator_template: FormatValidator,
	queue: *WorkQueue,
	result_queue: *ResultQueue,
	counts: SharedCounts = .{},
	callback: ?ValidationCallback,
	callback_ctx: ?*anyopaque,
	allocator: Allocator,
};

fn shouldValidateFile(kind: std.fs.File.Kind) bool {
	return kind == .file;
}

fn workerMain(shared: *Shared) void {
	var validator = shared.validator_template;
	var arena = std.heap.ArenaAllocator.init(shared.allocator);
	defer arena.deinit();

	const debug_enabled = isDebugTraceEnabled();

	while (true) {
		const item = shared.queue.pop() orelse break;

		// Debug trace: print file path BEFORE validation starts
		// This helps identify which file causes hangs when VALIDATE_DEBUG=1
		if (debug_enabled) {
			debugTrace("START {s}", .{item.path});
		}

		const start_ns = std.time.nanoTimestamp();
		const result = if (validator.deep_validation)
			validator.validateFileDeep(arena.allocator(), item.path)
		else
			validator.validateFile(item.path);
		const elapsed_ns = std.time.nanoTimestamp() - start_ns;
		const elapsed_seconds = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;

		// Debug trace: print completion with timing
		// If you see START without END, that file caused the hang
		if (debug_enabled) {
			debugTrace("END   {s} ({d:.3}s)", .{ item.path, elapsed_seconds });
		}

		shared.counts.add(result);

		// Push result to output queue if callback is registered (no I/O under lock)
		if (shared.callback != null) {
			const display_copy = shared.allocator.dupe(u8, item.display_path) catch {
				shared.allocator.free(item.path);
				shared.allocator.free(item.display_path);
				_ = arena.reset(.free_all);
				continue;
			};
			const result_item = ResultItem{
				.display_path = display_copy,
				.format = result.format,
				.is_valid = result.is_valid,
				.error_message = if (result.error_message) |m| shared.allocator.dupe(u8, m) catch null else null,
				.warning_message = if (result.warning_message) |m| shared.allocator.dupe(u8, m) catch null else null,
				.malformations = result.malformations,
				.validation_depth = result.validation_depth,
				.circumvented_trivial_protection = result.circumvented_trivial_protection,
				.validated_via_ffmpeg = result.validated_via_ffmpeg,
				.elapsed_seconds = elapsed_seconds,
			};
			shared.result_queue.push(result_item) catch {
				var mutable = result_item;
				mutable.deinit(shared.allocator);
			};
		}

		shared.allocator.free(item.path);
		shared.allocator.free(item.display_path);
		_ = arena.reset(.free_all);
	}
}

/// Dedicated output thread - drains result queue and calls callback (all I/O here).
fn outputMain(shared: *Shared) void {
	const callback = shared.callback orelse return;
	while (true) {
		var item = shared.result_queue.pop() orelse break;
		defer item.deinit(shared.allocator);

		const result = ValidationResult{
			.format = item.format,
			.is_valid = item.is_valid,
			.error_message = item.error_message,
			.warning_message = item.warning_message,
			.malformations = item.malformations,
			.validation_depth = item.validation_depth,
			.circumvented_trivial_protection = item.circumvented_trivial_protection,
			.validated_via_ffmpeg = item.validated_via_ffmpeg,
		};
		callback(shared.callback_ctx, item.display_path, result, item.elapsed_seconds);
	}
}

fn validateSingleFile(
	allocator: Allocator,
	validator_template: FormatValidator,
	path: []const u8,
	callback: ?ValidationCallback,
	callback_ctx: ?*anyopaque,
) ValidationCounts {
	var validator = validator_template;
	var arena = std.heap.ArenaAllocator.init(allocator);
	defer arena.deinit();

	const start_ns = std.time.nanoTimestamp();
	const result = if (validator.deep_validation)
		validator.validateFileDeep(arena.allocator(), path)
	else
		validator.validateFile(path);
	const elapsed_ns = std.time.nanoTimestamp() - start_ns;
	const elapsed_seconds = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;

	var counts = ValidationCounts{};
	if (result.format == .unknown) {
		counts.unknown += 1;
	} else if (result.is_valid) {
		counts.valid += 1;
	} else {
		counts.invalid += 1;
	}

	if (callback) |cb| {
		cb(callback_ctx, path, result, elapsed_seconds);
	}

	return counts;
}

fn openDirForPath(path: []const u8) !std.fs.Dir {
	if (std.fs.path.isAbsolute(path)) {
		return std.fs.openDirAbsolute(path, .{ .iterate = true });
	}
	return std.fs.cwd().openDir(path, .{ .iterate = true });
}

/// Stat a path, handling both absolute and relative paths correctly.
/// This is necessary on Windows where absolute paths (e.g., C:\folder) need
/// special handling when the current directory is on a different drive.
/// On Windows, we use GetFileAttributesW for initial type detection since it
/// works for protected folders like Documents without requiring file open permissions.
fn statPath(path: []const u8) !std.fs.File.Stat {
    if (comptime builtin.os.tag == .windows) {
        return statPathWindows(path);
    }
    return statPathPosix(path);
}

/// Windows-specific path stat using GetFileAttributesW for type detection.
/// This avoids the AccessDenied errors that occur when trying to open
/// protected Windows folders (Documents, Downloads, etc.) with Zig's std lib.
fn statPathWindows(path: []const u8) !std.fs.File.Stat {
    const windows = std.os.windows;

    // Convert path to null-terminated wide string
    // Use the Windows path utilities to handle the conversion
    var path_w_buf: [std.fs.max_path_bytes]u16 = undefined;
    const path_w = blk: {
        // For absolute paths, convert directly
        if (std.fs.path.isAbsolute(path)) {
            const len = std.unicode.utf8ToUtf16Le(&path_w_buf, path) catch
                return error.InvalidUtf8;
            if (len >= path_w_buf.len) return error.NameTooLong;
            path_w_buf[len] = 0;
            break :blk @as([*:0]const u16, @ptrCast(&path_w_buf));
        } else {
            // For relative paths, resolve relative to cwd
            const len = std.unicode.utf8ToUtf16Le(&path_w_buf, path) catch
                return error.InvalidUtf8;
            if (len >= path_w_buf.len) return error.NameTooLong;
            path_w_buf[len] = 0;
            break :blk @as([*:0]const u16, @ptrCast(&path_w_buf));
        }
    };

    // Use GetFileAttributesW to check if path exists and get type
    // This works for protected folders without requiring open permissions
    const attrs = windows.kernel32.GetFileAttributesW(path_w);
    if (attrs == windows.INVALID_FILE_ATTRIBUTES) {
        const err = windows.kernel32.GetLastError();
        return switch (err) {
            .FILE_NOT_FOUND, .PATH_NOT_FOUND => error.FileNotFound,
            .ACCESS_DENIED => error.AccessDenied,
            else => error.Unexpected,
        };
    }

    const is_dir = (attrs & windows.FILE_ATTRIBUTE_DIRECTORY) != 0;

    // Return a minimal stat with just the kind field populated
    // On Windows, time fields are i128 FILETIME values
    return std.fs.File.Stat{
        .inode = 0,
        .size = 0,
        .mode = 0,
        .kind = if (is_dir) .directory else .file,
        .atime = 0,
        .mtime = 0,
        .ctime = 0,
    };
}

/// POSIX path stat - works on macOS, Linux, etc.
fn statPathPosix(path: []const u8) !std.fs.File.Stat {
    if (std.fs.path.isAbsolute(path)) {
        // For absolute paths, open the file directly with absolute path
        var file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
            // Directory - try opening as directory to stat it
            error.IsDir => {
                var dir = std.fs.openDirAbsolute(path, .{}) catch |dir_err| {
                    return dir_err;
                };
                defer dir.close();
                return dir.stat();
            },
            else => return err,
        };
        defer file.close();
        return file.stat();
    }
    // For relative paths, try as file first, then as directory
    return std.fs.cwd().statFile(path) catch |err| switch (err) {
        error.IsDir => {
            var dir = std.fs.cwd().openDir(path, .{}) catch |dir_err| {
                return dir_err;
            };
            defer dir.close();
            return dir.stat();
        },
        else => return err,
    };
}

fn getMaxFilesLimit() usize {
	const env = getenvCrossPlatform("MAX_FILES") orelse return DEFAULT_MAX_FILES;
	const parsed = std.fmt.parseInt(usize, env, 10) catch return DEFAULT_MAX_FILES;
	if (parsed == 0) return DEFAULT_MAX_FILES;
	return parsed;
}

fn getDefaultJobCount() usize {
	if (comptime builtin.os.tag == .macos) {
		var count: c_int = 0;
		var size: usize = @sizeOf(c_int);
		if (std.c.sysctlbyname("hw.logicalcpu", @ptrCast(&count), &size, null, 0) == 0 and count > 0) {
			return @intCast(count);
		}
	}
	return std.Thread.getCpuCount() catch 1;
}

test "default job count is at least 1" {
	try std.testing.expect(getDefaultJobCount() >= 1);
}

/// Options for parallel path validation
pub const ValidationOptions = struct {
	/// Number of worker threads (0 = auto-detect based on CPU count)
	jobs: usize = 0,
	/// Shuffle file order before validation (helps expose race conditions)
	shuffle: bool = false,
	/// Random seed for shuffling (0 = use system time)
	seed: u64 = 0,
};

/// Fisher-Yates shuffle for work items
fn shuffleWorkItems(items: []WorkItem, seed: u64) void {
	if (items.len <= 1) return;

	// Use provided seed or generate from timestamp
	const actual_seed = if (seed != 0) seed else blk: {
		const ts = std.time.nanoTimestamp();
		// Truncate i128 to u64 - we only need entropy, not the full value
		break :blk @as(u64, @truncate(@as(u128, @bitCast(ts))));
	};

	var prng = std.Random.DefaultPrng.init(actual_seed);
	const random = prng.random();

	var i: usize = items.len - 1;
	while (i > 0) : (i -= 1) {
		const j = random.uintLessThan(usize, i + 1);
		const tmp = items[i];
		items[i] = items[j];
		items[j] = tmp;
	}
}

/// Backwards-compatible wrapper for validatePathParallelEx
pub fn validatePathParallel(
	allocator: Allocator,
	validator_template: FormatValidator,
	path: []const u8,
	jobs: ?usize,
	callback: ?ValidationCallback,
	callback_ctx: ?*anyopaque,
) !ValidationCounts {
	return validatePathParallelEx(allocator, validator_template, path, .{
		.jobs = jobs orelse 0,
		.shuffle = false,
		.seed = 0,
	}, callback, callback_ctx);
}

/// Validates a file or directory tree using parallel workers with extended options.
pub fn validatePathParallelEx(
	allocator: Allocator,
	validator_template: FormatValidator,
	path: []const u8,
	options: ValidationOptions,
	callback: ?ValidationCallback,
	callback_ctx: ?*anyopaque,
) !ValidationCounts {
	const stat = statPath(path) catch |err| switch (err) {
		error.FileNotFound => return error.FileNotFound,
		error.AccessDenied => return error.AccessDenied,
		else => return err,
	};

	if (stat.kind == .file) {
		return validateSingleFile(allocator, validator_template, path, callback, callback_ctx);
	}
	if (stat.kind != .directory) {
		return error.Unsupported;
	}

	const max_files_limit = getMaxFilesLimit();

	var queue = WorkQueue.init(allocator);
	defer queue.deinit();

	var result_queue = ResultQueue.init(allocator);
	defer result_queue.deinit();

	var shared = Shared{
		.validator_template = validator_template,
		.queue = &queue,
		.result_queue = &result_queue,
		.callback = callback,
		.callback_ctx = callback_ctx,
		.allocator = allocator,
	};

	const cpu_count = getDefaultJobCount();
	const job_count = @max(@as(usize, 1), if (options.jobs == 0) cpu_count else options.jobs);

	// Spawn output thread first (if callback is provided)
	const output_thread: ?std.Thread = if (callback != null)
		try std.Thread.spawn(.{}, outputMain, .{&shared})
	else
		null;

	const threads = try allocator.alloc(std.Thread, job_count);
	defer allocator.free(threads);

	for (threads) |*thread| {
		thread.* = try std.Thread.spawn(.{}, workerMain, .{&shared});
	}

	var dir = try openDirForPath(path);
	defer dir.close();

	var walker = try dir.walk(allocator);
	defer walker.deinit();

	// Collect files into a list first (needed for shuffling)
	var work_items: std.ArrayListUnmanaged(WorkItem) = .{};
	defer {
		// Free any items that weren't pushed (e.g., on error)
		for (work_items.items) |item| {
			allocator.free(item.path);
			allocator.free(item.display_path);
		}
		work_items.deinit(allocator);
	}

	while (try walker.next()) |entry| {
		if (!shouldValidateFile(entry.kind)) {
			continue;
		}
		if (work_items.items.len >= max_files_limit) {
			break;
		}
		const display_path = try allocator.dupe(u8, entry.path);
		const full_path = try std.fs.path.join(allocator, &.{ path, entry.path });
		try work_items.append(allocator, .{
			.path = full_path,
			.display_path = display_path,
		});
	}

	// Shuffle if requested
	if (options.shuffle and work_items.items.len > 1) {
		shuffleWorkItems(work_items.items, options.seed);
	}

	// Push all items to the work queue
	for (work_items.items) |item| {
		try queue.push(item);
	}
	// Clear the list so we don't double-free in defer
	work_items.clearRetainingCapacity();

	// Close work queue - workers exit when empty
	queue.close();

	// Wait for all workers to finish
	for (threads) |thread| {
		thread.join();
	}

	// Close result queue - output thread exits when empty
	result_queue.close();

	// Wait for output thread to finish (all I/O complete)
	if (output_thread) |ot| {
		ot.join();
	}

	return shared.counts.toCounts();
}

test "statPath handles current directory" {
	// "." should work as a directory path
	const stat = statPath(".") catch |err| {
		std.debug.print("statPath(\".\") failed with: {}\n", .{err});
		return err;
	};
	try std.testing.expectEqual(std.fs.File.Kind.directory, stat.kind);
}

test "statPath handles relative directory" {
	// Create a temp directory to test
	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	// Get the relative path name
	const path = tmp_dir.sub_path[0..];

	// stat should return directory
	const stat = statPath(path) catch |err| {
		std.debug.print("statPath relative dir failed with: {}\n", .{err});
		return err;
	};
	try std.testing.expectEqual(std.fs.File.Kind.directory, stat.kind);
}

test "statPath handles files" {
	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	// Create a test file
	const file = try tmp_dir.dir.createFile("test.txt", .{});
	file.close();

	// Build the path
	const full_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, "test.txt");
	defer std.testing.allocator.free(full_path);

	const stat = statPath(full_path) catch |err| {
		std.debug.print("statPath file failed with: {}\n", .{err});
		return err;
	};
	try std.testing.expectEqual(std.fs.File.Kind.file, stat.kind);
}
