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

const Shared = struct {
	validator_template: FormatValidator,
	queue: *WorkQueue,
	counts: SharedCounts = .{},
	callback: ?ValidationCallback,
	callback_ctx: ?*anyopaque,
	callback_mutex: std.Thread.Mutex = .{},
	allocator: Allocator,
};

fn shouldValidateFile(kind: std.fs.File.Kind) bool {
	return kind == .file;
}

fn workerMain(shared: *Shared) void {
	var validator = shared.validator_template;
	var arena = std.heap.ArenaAllocator.init(shared.allocator);
	defer arena.deinit();

	while (true) {
		const item = shared.queue.pop() orelse break;
		const start_ns = std.time.nanoTimestamp();
		const result = if (validator.deep_validation)
			validator.validateFileDeep(arena.allocator(), item.path)
		else
			validator.validateFile(item.path);
		const elapsed_ns = std.time.nanoTimestamp() - start_ns;
		const elapsed_seconds = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;

		shared.counts.add(result);

		if (shared.callback) |cb| {
			shared.callback_mutex.lock();
			cb(shared.callback_ctx, item.display_path, result, elapsed_seconds);
			shared.callback_mutex.unlock();
		}

		shared.allocator.free(item.path);
		shared.allocator.free(item.display_path);
		_ = arena.reset(.free_all);
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

fn getMaxFilesLimit() usize {
	if (comptime builtin.os.tag == .windows) return DEFAULT_MAX_FILES;

	const env = std.posix.getenv("MAX_FILES") orelse return DEFAULT_MAX_FILES;
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

pub fn validatePathParallel(
	allocator: Allocator,
	validator_template: FormatValidator,
	path: []const u8,
	jobs: ?usize,
	callback: ?ValidationCallback,
	callback_ctx: ?*anyopaque,
) !ValidationCounts {
	const stat = std.fs.cwd().statFile(path) catch |err| switch (err) {
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

	var shared = Shared{
		.validator_template = validator_template,
		.queue = &queue,
		.callback = callback,
		.callback_ctx = callback_ctx,
		.allocator = allocator,
	};

	const requested_jobs = jobs orelse 0;
	const cpu_count = getDefaultJobCount();
	const job_count = @max(@as(usize, 1), if (requested_jobs == 0) cpu_count else requested_jobs);

	const threads = try allocator.alloc(std.Thread, job_count);
	defer allocator.free(threads);

	for (threads) |*thread| {
		thread.* = try std.Thread.spawn(.{}, workerMain, .{&shared});
	}

	var dir = try openDirForPath(path);
	defer dir.close();

	var walker = try dir.walk(allocator);
	defer walker.deinit();

	var queued_files: usize = 0;

	while (try walker.next()) |entry| {
		if (!shouldValidateFile(entry.kind)) {
			continue;
		}
		if (queued_files >= max_files_limit) {
			break;
		}
		const display_path = try allocator.dupe(u8, entry.path);
		const full_path = try std.fs.path.join(allocator, &.{ path, entry.path });
		try queue.push(.{
			.path = full_path,
			.display_path = display_path,
		});
		queued_files += 1;
	}

	queue.close();

	for (threads) |thread| {
		thread.join();
	}

	return shared.counts.toCounts();
}
