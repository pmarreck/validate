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

/// Check if a path is a bundle directory that should be validated as a unit.
fn isBundleDirectory(entry_path: []const u8) bool {
	return format_validation.isBundleDirectory(entry_path);
}

/// Check if a subdirectory is a BagIt bag (contains bagit.txt).
fn isBagitDirectory(parent_dir: std.fs.Dir, subdir_name: []const u8) bool {
	var subdir = parent_dir.openDir(subdir_name, .{}) catch return false;
	defer subdir.close();
	subdir.access("bagit.txt", .{}) catch return false;
	return true;
}

/// Recursively enumerate files and bundle directories, adding them to work_items.
/// Bundle directories are added as work items and NOT recursed into.
fn enumerateWithBundles(
	allocator: Allocator,
	dir: std.fs.Dir,
	base_path: []const u8,
	relative_prefix: []const u8,
	work_items: *std.ArrayListUnmanaged(WorkItem),
	max_files_limit: usize,
) !void {
	var iter = dir.iterate();
	while (try iter.next()) |entry| {
		if (work_items.items.len >= max_files_limit) break;

		// Build the relative path for display
		const display_path = if (relative_prefix.len > 0)
			try std.fs.path.join(allocator, &.{ relative_prefix, entry.name })
		else
			try allocator.dupe(u8, entry.name);
		errdefer allocator.free(display_path);

		// Build the full path
		const full_path = try std.fs.path.join(allocator, &.{ base_path, entry.name });
		errdefer allocator.free(full_path);

		if (entry.kind == .file) {
			// Regular file - add to work items
			try work_items.append(allocator, .{
				.path = full_path,
				.display_path = display_path,
			});
		} else if (entry.kind == .directory) {
			// Check if this is a bundle directory
			if (isBundleDirectory(display_path)) {
				// Bundle directory - add as work item, don't recurse
				try work_items.append(allocator, .{
					.path = full_path,
					.display_path = display_path,
				});
			} else if (isBagitDirectory(dir, entry.name)) {
				// BagIt bag (contains bagit.txt) — treat as bundle, don't recurse
				try work_items.append(allocator, .{
					.path = full_path,
					.display_path = display_path,
				});
			} else {
				// Regular directory - recurse into it
				// Free paths since we won't use them (recursion will create new ones)
				allocator.free(full_path);

				var subdir = dir.openDir(entry.name, .{ .iterate = true }) catch {
					allocator.free(display_path);
					continue;
				};
				defer subdir.close();

				enumerateWithBundles(
					allocator,
					subdir,
					try std.fs.path.join(allocator, &.{ base_path, entry.name }),
					display_path,
					work_items,
					max_files_limit,
				) catch {
					allocator.free(display_path);
					continue;
				};
				allocator.free(display_path);
			}
		} else {
			// Other types (symlinks, etc.) - skip
			allocator.free(full_path);
			allocator.free(display_path);
		}
	}
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

	// If the path itself is a bundle directory (e.g., .git), validate it as a single item
	// Don't enumerate its contents - treat the whole bundle as one validation unit
	if (isBundleDirectory(path)) {
		return validateSingleFile(allocator, validator_template, path, callback, callback_ctx);
	}

	// Check if this is a BagIt bag directory (contains bagit.txt)
	{
		var check_dir = std.fs.cwd().openDir(path, .{}) catch null;
		if (check_dir) |*d| {
			defer d.close();
			if (d.access("bagit.txt", .{})) |_| {
				return validateSingleFile(allocator, validator_template, path, callback, callback_ctx);
			} else |_| {}
		}
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
		thread.* = try std.Thread.spawn(.{ .stack_size = 4 * 1024 * 1024 }, workerMain, .{&shared});
	}

	var dir = try openDirForPath(path);
	defer dir.close();

	// Collect files and bundle directories into a list (needed for shuffling)
	// Uses bundle-aware enumeration: .git directories are added as work items
	// and NOT recursed into.
	var work_items: std.ArrayListUnmanaged(WorkItem) = .{};
	defer {
		// Free any items that weren't pushed (e.g., on error)
		for (work_items.items) |item| {
			allocator.free(item.path);
			allocator.free(item.display_path);
		}
		work_items.deinit(allocator);
	}

	try enumerateWithBundles(allocator, dir, path, "", &work_items, max_files_limit);

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

	// Get the absolute path to avoid cwd-relative issues in test environments
	const path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
	defer std.testing.allocator.free(path);

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

test "parallel validation does not recurse into .git directories" {
	// TDD: This test verifies that when validating a directory containing .git,
	// the parallel validator treats .git as a bundle (validates it as a unit)
	// rather than recursing into .git/objects/ and validating individual files.
	//
	// The test creates a minimal git repo structure and validates the parent directory.
	// It tracks which paths are validated via callback and asserts that:
	// 1. The .git directory itself IS validated (as a bundle)
	// 2. Files inside .git/objects/ are NOT individually validated

	const allocator = std.testing.allocator;

	// Create a temp directory
	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	// Get the full path
	const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
	defer allocator.free(tmp_path);

	// Create a minimal .git directory structure
	try tmp_dir.dir.makePath(".git/objects/ab");
	try tmp_dir.dir.makePath(".git/objects/pack");
	try tmp_dir.dir.makePath(".git/refs/heads");

	// Create HEAD file
	const head_file = try tmp_dir.dir.createFile(".git/HEAD", .{});
	try head_file.writeAll("ref: refs/heads/master\n");
	head_file.close();

	// Create a fake loose object file (to test that we DON'T recurse into it)
	const object_file = try tmp_dir.dir.createFile(".git/objects/ab/cdef1234567890", .{});
	try object_file.writeAll("fake object content");
	object_file.close();

	// Create a regular file outside .git
	const regular_file = try tmp_dir.dir.createFile("README.md", .{});
	try regular_file.writeAll("# Test\n");
	regular_file.close();

	// Track validated paths
	const TrackingContext = struct {
		validated_paths: std.ArrayListUnmanaged([]u8),
		allocator: std.mem.Allocator,

		fn callback(ctx: ?*anyopaque, display_path: []const u8, _: ValidationResult, _: f64) void {
			const self: *@This() = @ptrCast(@alignCast(ctx.?));
			const path_copy = self.allocator.dupe(u8, display_path) catch return;
			self.validated_paths.append(self.allocator, path_copy) catch {
				self.allocator.free(path_copy);
			};
		}

		fn deinit(self: *@This()) void {
			for (self.validated_paths.items) |p| {
				self.allocator.free(p);
			}
			self.validated_paths.deinit(self.allocator);
		}

		fn containsPath(self: *@This(), needle: []const u8) bool {
			for (self.validated_paths.items) |p| {
				if (std.mem.indexOf(u8, p, needle) != null) return true;
			}
			return false;
		}
	};

	var tracking_ctx = TrackingContext{
		.validated_paths = .{},
		.allocator = allocator,
	};
	defer tracking_ctx.deinit();

	// Create a validator and run parallel validation on the temp directory
	const validator = FormatValidator.initDeep();

	_ = try validatePathParallel(
		allocator,
		validator,
		tmp_path,
		1, // Single thread for determinism
		TrackingContext.callback,
		&tracking_ctx,
	);

	// Check assertions:
	// 1. Should validate .git as a bundle (the path ".git" should appear)
	const validated_git_bundle = tracking_ctx.containsPath(".git");
	try std.testing.expect(validated_git_bundle);

	// 2. Should NOT have recursed into .git/objects/ (no paths containing ".git/objects/ab")
	const recursed_into_objects = tracking_ctx.containsPath(".git/objects/ab");
	try std.testing.expect(!recursed_into_objects);

	// 3. Should have validated regular files (README.md)
	const validated_readme = tracking_ctx.containsPath("README.md");
	try std.testing.expect(validated_readme);
}
