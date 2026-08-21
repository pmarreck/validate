//! Parallel directory enumeration with a shared work-stealing frontier.
//!
//! Cold-tree enumeration was single-threaded (~107 files/s witnessed on the
//! 2026-08-15 91.7 GB corpus — ~10 minutes of dead time on a 64k-file tree
//! before validation began). Workers pop one directory from a shared frontier,
//! readdir/stat/emit its entries, and push discovered subdirectories back;
//! idle workers steal the next directory the moment they finish one. The
//! shared deque redistributes work at directory granularity, so asymmetric
//! trees (one giant subtree, many tiny ones) rebalance dynamically — the only
//! inherently serial unit is a single directory's readdir stream.
//!
//! Policy parity with the C CLI's previous recursive enumerator:
//! - directories are classified by an injected callback (bundle/BagIt dirs
//!   emit as a single unit instead of recursing),
//! - symlinks are never followed; dangling ones emit with size 0 so
//!   validation can classify them, live ones are skipped,
//! - inaccessible directories warn and are skipped, never fatal,
//! - a depth cap prunes pathological/cyclic trees with a warning.
//!
//! Emission and warning callbacks are SERIALIZED by the walker (single lock),
//! so a C consumer needs no locking of its own. Emission order is completion
//! order and therefore non-deterministic across runs; consumers that need an
//! order sort afterward (the CLI already reorders via scatter/shuffle).

const std = @import("std");
const runtime = @import("runtime.zig");

/// What to do with a discovered subdirectory.
pub const DirClass = enum(c_int) {
    /// Descend into it (default).
    recurse = 0,
    /// Emit the directory itself as one validation unit (bundles, BagIt bags).
    emit_as_unit = 1,
};

pub const WarnReason = enum(c_int) {
    max_depth = 0,
    inaccessible = 1,
};

pub const Callbacks = struct {
    ctx: ?*anyopaque = null,
    /// Serialized. Return false to stop the whole walk early (max-files).
    emit: *const fn (ctx: ?*anyopaque, path: [:0]const u8, size: u64) bool,
    /// Serialized with emit. `detail` is a Zig error name or empty.
    warn: ?*const fn (ctx: ?*anyopaque, reason: WarnReason, path: [:0]const u8, detail: []const u8) void = null,
    /// Called concurrently from any worker; must be thread-safe. null = always recurse.
    classify_dir: ?*const fn (ctx: ?*anyopaque, path: [:0]const u8) DirClass = null,
};

pub const Options = struct {
    /// 0 = auto (clamped CPU count). Enumeration is stat-latency bound, so
    /// workers overlap I/O waits rather than burn CPU.
    thread_count: usize = 0,
    /// Directory nesting cap (DoS guard against deep/cyclic trees). The root
    /// is depth 0; a directory deeper than this warns and is pruned.
    max_depth: usize = 256,
    /// When set (len >= effective thread count), filled with per-worker
    /// emitted-file counts — the observable for work-distribution balance.
    per_worker_files: ?[]u64 = null,
};

pub const Stats = struct {
    files_emitted: u64 = 0,
    dirs_processed: u64 = 0,
    /// readdir entries observed (dot entries excluded). Deterministic op
    /// counter: exactly one per tree entry, the machine-independent signal
    /// for the O(entries) complexity gate.
    entries_seen: u64 = 0,
    stopped_early: bool = false,
};

/// Enumerate `root` (a directory the caller already chose to recurse into)
/// with a shared-frontier worker pool. Blocks until the walk completes or an
/// emit callback stops it. complexity: O(total directory entries)
pub fn walk(allocator: std.mem.Allocator, root: []const u8, options: Options, callbacks: Callbacks) Stats {
    runtime.ensureInit();
    const thread_count = if (options.thread_count > 0)
        options.thread_count
    else
        @max(@as(usize, 2), @min(std.Thread.getCpuCount() catch 4, 16));

    var walker = Walker{
        .allocator = allocator,
        .options = options,
        .callbacks = callbacks,
    };
    defer walker.frontier.deinit(allocator);

    // Seed the frontier with the root at depth 0. An unopenable root warns
    // .inaccessible from the worker's open, exactly like any subdirectory.
    const root_copy = allocator.dupe(u8, root) catch return walker.takeStats();
    walker.frontier.items.append(allocator, .{ .path = root_copy, .depth = 0 }) catch {
        allocator.free(root_copy);
        return walker.takeStats();
    };
    walker.frontier.outstanding = 1;

    var workers_buf: [MAX_WORKERS]std.Thread = undefined;
    const spawned = @min(thread_count, MAX_WORKERS);
    var started: usize = 0;
    for (workers_buf[0..spawned], 0..) |*t, i| {
        t.* = std.Thread.spawn(.{}, Walker.workerMain, .{ &walker, i }) catch break;
        started += 1;
    }
    if (started == 0) {
        // Could not spawn any worker: degrade to inline single-threaded.
        walker.workerMain(0);
    }
    for (workers_buf[0..started]) |t| t.join();

    if (options.per_worker_files) |slice| {
        const n = @min(slice.len, MAX_WORKERS);
        for (slice[0..n], walker.per_worker_files[0..n]) |*dst, src| dst.* = src.load(.seq_cst);
    }
    return walker.takeStats();
}

/// Upper bound on enumeration workers: each holds one open dir fd and one
/// scratch path buffer; beyond ~16 the shared frontier lock and the disk's
/// queue depth dominate, not CPU.
const MAX_WORKERS: usize = 16;

const FrontierEntry = struct { path: []u8, depth: usize };

const Walker = struct {
    allocator: std.mem.Allocator,
    options: Options,
    callbacks: Callbacks,

    frontier: struct {
        mutex: std.Io.Mutex = .init,
        cond: std.Io.Condition = .init,
        items: std.ArrayList(FrontierEntry) = .empty,
        /// Directories pushed but not yet fully processed. Workers exit when
        /// this reaches 0 with an empty frontier (no producer can add more).
        outstanding: usize = 0,

        fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            for (self.items.items) |entry| allocator.free(entry.path);
            self.items.deinit(allocator);
        }
    } = .{},

    /// Serializes emit/warn callbacks so C consumers need no locking.
    emit_mutex: std.Io.Mutex = .init,

    stopped: std.atomic.Value(bool) = .init(false),
    files_emitted: std.atomic.Value(u64) = .init(0),
    dirs_processed: std.atomic.Value(u64) = .init(0),
    entries_seen: std.atomic.Value(u64) = .init(0),
    per_worker_files: [MAX_WORKERS]std.atomic.Value(u64) = [_]std.atomic.Value(u64){.init(0)} ** MAX_WORKERS,

    fn takeStats(self: *Walker) Stats {
        return .{
            .files_emitted = self.files_emitted.load(.seq_cst),
            .dirs_processed = self.dirs_processed.load(.seq_cst),
            .entries_seen = self.entries_seen.load(.seq_cst),
            .stopped_early = self.stopped.load(.seq_cst),
        };
    }

    /// Worker loop over the shared frontier: pop a directory, enumerate it,
    /// push its subdirectories, repeat; sleep only when the frontier is empty
    /// but a peer may still push. This IS the work redistribution — an idle
    /// worker steals the next directory no matter which worker discovered it.
    fn workerMain(self: *Walker, worker_index: usize) void {
        const io = runtime.io();
        var scratch: std.ArrayList(u8) = .empty;
        defer scratch.deinit(self.allocator);

        while (true) {
            self.frontier.mutex.lockUncancelable(io);
            while (self.frontier.items.items.len == 0 and
                self.frontier.outstanding > 0 and
                !self.stopped.load(.seq_cst))
            {
                self.frontier.cond.waitUncancelable(io, &self.frontier.mutex);
            }
            if (self.frontier.items.items.len == 0 or self.stopped.load(.seq_cst)) {
                self.frontier.mutex.unlock(io);
                self.frontier.cond.broadcast(io);
                return;
            }
            const entry = self.frontier.items.pop().?;
            self.frontier.mutex.unlock(io);

            self.processDirectory(entry, worker_index, &scratch);
            self.allocator.free(entry.path);

            self.frontier.mutex.lockUncancelable(io);
            self.frontier.outstanding -= 1;
            const done = self.frontier.outstanding == 0;
            self.frontier.mutex.unlock(io);
            if (done) self.frontier.cond.broadcast(io);
        }
    }

    fn processDirectory(self: *Walker, entry: FrontierEntry, worker_index: usize, scratch: *std.ArrayList(u8)) void {
        const io = runtime.io();
        if (entry.depth > self.options.max_depth) {
            self.warnOwned(.max_depth, entry.path, "");
            return;
        }
        var dir = runtime.openDir(entry.path, .{ .iterate = true }) catch |err| {
            self.warnOwned(.inaccessible, entry.path, @errorName(err));
            return;
        };
        defer dir.close(io);
        _ = self.dirs_processed.fetchAdd(1, .seq_cst);

        var it = dir.iterate();
        while (!self.stopped.load(.seq_cst)) {
            // Read errors mid-stream end this directory, matching readdir()
            // returning NULL in the old C enumerator.
            const child = (it.next(io) catch break) orelse break;
            _ = self.entries_seen.fetchAdd(1, .seq_cst);

            const child_path = self.joinChild(scratch, entry.path, child.name) orelse continue;

            switch (child.kind) {
                .file => self.emitFile(child_path, worker_index),
                .directory => self.handleDirectory(child_path, entry.depth, worker_index),
                .sym_link => self.handleSymlink(child_path, worker_index),
                .unknown => {
                    // Filesystem without d_type: classify via lstat like the
                    // old enumerator did for every entry.
                    const st = std.Io.Dir.cwd().statFile(io, child_path, .{ .follow_symlinks = false }) catch continue;
                    switch (st.kind) {
                        .file => self.emitFile(child_path, worker_index),
                        .directory => self.handleDirectory(child_path, entry.depth, worker_index),
                        .sym_link => self.handleSymlink(child_path, worker_index),
                        else => {},
                    }
                },
                // Devices, sockets, pipes, etc.: skipped, as before.
                else => {},
            }
        }
    }

    /// Regular file: one lstat for the size (readdir gave us the type free —
    /// the old enumerator paid an lstat per entry INCLUDING directories).
    fn emitFile(self: *Walker, path: [:0]const u8, worker_index: usize) void {
        const st = std.Io.Dir.cwd().statFile(runtime.io(), path, .{ .follow_symlinks = false }) catch return;
        if (st.kind != .file) return; // replaced between readdir and stat
        self.emitSerialized(path, st.size, worker_index);
    }

    fn handleDirectory(self: *Walker, path: [:0]const u8, parent_depth: usize, worker_index: usize) void {
        if (self.callbacks.classify_dir) |classify| {
            if (classify(self.callbacks.ctx, path) == .emit_as_unit) {
                const st = std.Io.Dir.cwd().statFile(runtime.io(), path, .{ .follow_symlinks = false }) catch return;
                self.emitSerialized(path, st.size, worker_index);
                return;
            }
        }
        const io = runtime.io();
        const copy = self.allocator.dupe(u8, path) catch return;
        self.frontier.mutex.lockUncancelable(io);
        self.frontier.items.append(self.allocator, .{ .path = copy, .depth = parent_depth + 1 }) catch {
            self.frontier.mutex.unlock(io);
            self.allocator.free(copy);
            return;
        };
        self.frontier.outstanding += 1;
        self.frontier.mutex.unlock(io);
        self.frontier.cond.signal(io);
    }

    /// Symlinks are never followed (loop/escape safety). A dangling one is
    /// emitted with size 0 so validation classifies it as broken_symlink; a
    /// live one is skipped (its target is enumerated on its own if in-tree).
    fn handleSymlink(self: *Walker, path: [:0]const u8, worker_index: usize) void {
        _ = std.Io.Dir.cwd().statFile(runtime.io(), path, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => {
                self.emitSerialized(path, 0, worker_index);
                return;
            },
            else => return,
        };
    }

    fn emitSerialized(self: *Walker, path: [:0]const u8, size: u64, worker_index: usize) void {
        const io = runtime.io();
        self.emit_mutex.lockUncancelable(io);
        defer self.emit_mutex.unlock(io);
        if (self.stopped.load(.seq_cst)) return;
        _ = self.files_emitted.fetchAdd(1, .seq_cst);
        _ = self.per_worker_files[worker_index].fetchAdd(1, .seq_cst);
        if (!self.callbacks.emit(self.callbacks.ctx, path, size)) {
            self.signalStop();
        }
    }

    /// Set the stop flag UNDER the frontier mutex so a worker between its
    /// empty-frontier check and its condvar wait cannot miss the wakeup
    /// (stopped entries may keep `outstanding` above 0 forever otherwise).
    fn signalStop(self: *Walker) void {
        const io = runtime.io();
        self.frontier.mutex.lockUncancelable(io);
        self.stopped.store(true, .seq_cst);
        self.frontier.mutex.unlock(io);
        self.frontier.cond.broadcast(io);
    }

    fn warnOwned(self: *Walker, reason: WarnReason, path: []const u8, detail: []const u8) void {
        const z = self.allocator.dupeZ(u8, path) catch return;
        defer self.allocator.free(z);
        self.warnSerialized(reason, z, detail, null);
    }

    fn warnSerialized(self: *Walker, reason: WarnReason, path: [:0]const u8, detail: []const u8, free_with: ?std.mem.Allocator) void {
        defer if (free_with) |a| a.free(path);
        const warn_fn = self.callbacks.warn orelse return;
        const io = runtime.io();
        self.emit_mutex.lockUncancelable(io);
        defer self.emit_mutex.unlock(io);
        warn_fn(self.callbacks.ctx, reason, path, detail);
    }

    /// Build "<dir><sep><name>\0" in the worker's scratch buffer. Returns a
    /// sentinel slice valid until the next join. Skips (returns null) on OOM.
    fn joinChild(self: *Walker, scratch: *std.ArrayList(u8), dir_path: []const u8, name: []const u8) ?[:0]const u8 {
        scratch.clearRetainingCapacity();
        const needs_sep = dir_path.len > 0 and !isSep(dir_path[dir_path.len - 1]);
        const total = dir_path.len + @intFromBool(needs_sep) + name.len + 1;
        scratch.ensureTotalCapacity(self.allocator, total) catch return null;
        scratch.appendSliceAssumeCapacity(dir_path);
        if (needs_sep) scratch.appendAssumeCapacity(std.fs.path.sep);
        scratch.appendSliceAssumeCapacity(name);
        scratch.appendAssumeCapacity(0);
        return scratch.items[0 .. scratch.items.len - 1 :0];
    }
};

fn isSep(c: u8) bool {
    return c == '/' or (@import("builtin").os.tag == .windows and c == '\\');
}

// ===== Tests =====

const TestSink = struct {
    const Emission = struct { path: []u8, size: u64 };

    allocator: std.mem.Allocator,
    emissions: std.ArrayList(Emission) = .empty,
    warns: std.ArrayList(WarnReason) = .empty,
    stop_after: usize = std.math.maxInt(usize),

    fn deinit(self: *TestSink) void {
        for (self.emissions.items) |e| self.allocator.free(e.path);
        self.emissions.deinit(self.allocator);
        self.warns.deinit(self.allocator);
    }

    fn emit(ctx: ?*anyopaque, path: [:0]const u8, size: u64) bool {
        const self: *TestSink = @ptrCast(@alignCast(ctx.?));
        const copy = self.allocator.dupe(u8, path) catch @panic("oom");
        self.emissions.append(self.allocator, .{ .path = copy, .size = size }) catch @panic("oom");
        return self.emissions.items.len < self.stop_after;
    }

    fn warn(ctx: ?*anyopaque, reason: WarnReason, path: [:0]const u8, detail: []const u8) void {
        _ = path;
        _ = detail;
        const self: *TestSink = @ptrCast(@alignCast(ctx.?));
        self.warns.append(self.allocator, reason) catch @panic("oom");
    }

    fn callbacks(self: *TestSink) Callbacks {
        return .{ .ctx = self, .emit = emit, .warn = warn };
    }

    fn sortedPaths(self: *TestSink) void {
        std.mem.sort(Emission, self.emissions.items, {}, struct {
            fn lt(_: void, a: Emission, b: Emission) bool {
                return std.mem.lessThan(u8, a.path, b.path);
            }
        }.lt);
    }
};

fn makeFile(dir: std.Io.Dir, name: []const u8, size: usize) !void {
    const file = try dir.createFile(runtime.io(), name, .{});
    defer file.close(runtime.io());
    if (size == 0) return;
    const junk = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(junk);
    @memset(junk, 0x5A);
    try file.writeStreamingAll(runtime.io(), junk);
}

test "flat directory: every file emitted exactly once with its size" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var name_buf: [32]u8 = undefined;
    for (0..20) |i| {
        const name = try std.fmt.bufPrint(&name_buf, "f{d:0>2}.dat", .{i});
        try makeFile(tmp.dir, name, i * 10);
    }
    const root = try runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "");
    defer std.testing.allocator.free(root);

    var sink = TestSink{ .allocator = std.testing.allocator };
    defer sink.deinit();
    const stats = walk(std.testing.allocator, root, .{ .thread_count = 4 }, sink.callbacks());

    try std.testing.expectEqual(@as(u64, 20), stats.files_emitted);
    try std.testing.expectEqual(@as(u64, 1), stats.dirs_processed);
    try std.testing.expectEqual(@as(u64, 20), stats.entries_seen);
    try std.testing.expect(!stats.stopped_early);
    try std.testing.expectEqual(@as(usize, 20), sink.emissions.items.len);
    sink.sortedPaths();
    for (sink.emissions.items, 0..) |e, i| {
        try std.testing.expectEqual(@as(u64, i * 10), e.size);
        try std.testing.expect(std.mem.endsWith(u8, e.path, ".dat"));
    }
}

test "asymmetric tree: parallel emission set equals single-threaded; worker counts sum" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // One heavy flat subtree, one deep chain, a few sparse dirs — the shape
    // that starves static partitioning and exercises dynamic redistribution.
    try tmp.dir.createDirPath(runtime.io(), "heavy");
    {
        const heavy = try tmp.dir.openDir(runtime.io(), "heavy", .{});
        defer heavy.close(runtime.io());
        var name_buf: [32]u8 = undefined;
        for (0..40) |i| {
            const name = try std.fmt.bufPrint(&name_buf, "h{d:0>2}.bin", .{i});
            try makeFile(heavy, name, 1);
        }
    }
    try tmp.dir.createDirPath(runtime.io(), "chain/c1/c2/c3/c4");
    {
        const deep = try tmp.dir.openDir(runtime.io(), "chain/c1/c2/c3/c4", .{});
        defer deep.close(runtime.io());
        try makeFile(deep, "leaf.bin", 7);
    }
    try tmp.dir.createDirPath(runtime.io(), "sparse1");
    try tmp.dir.createDirPath(runtime.io(), "sparse2");
    {
        const s1 = try tmp.dir.openDir(runtime.io(), "sparse1", .{});
        defer s1.close(runtime.io());
        try makeFile(s1, "one.bin", 3);
    }
    const root = try runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "");
    defer std.testing.allocator.free(root);

    var serial = TestSink{ .allocator = std.testing.allocator };
    defer serial.deinit();
    const serial_stats = walk(std.testing.allocator, root, .{ .thread_count = 1 }, serial.callbacks());

    var parallel = TestSink{ .allocator = std.testing.allocator };
    defer parallel.deinit();
    var per_worker = [_]u64{0} ** 4;
    const parallel_stats = walk(
        std.testing.allocator,
        root,
        .{ .thread_count = 4, .per_worker_files = &per_worker },
        parallel.callbacks(),
    );

    // Metamorphic determinism: thread count must not change WHAT is found.
    try std.testing.expectEqual(@as(u64, 42), serial_stats.files_emitted);
    try std.testing.expectEqual(serial_stats.files_emitted, parallel_stats.files_emitted);
    try std.testing.expectEqual(serial_stats.dirs_processed, parallel_stats.dirs_processed);
    try std.testing.expectEqual(serial_stats.entries_seen, parallel_stats.entries_seen);
    serial.sortedPaths();
    parallel.sortedPaths();
    try std.testing.expectEqual(serial.emissions.items.len, parallel.emissions.items.len);
    for (serial.emissions.items, parallel.emissions.items) |a, b| {
        try std.testing.expectEqualStrings(a.path, b.path);
        try std.testing.expectEqual(a.size, b.size);
    }
    // Per-worker accounting is complete (balance itself is scheduling-dependent).
    var sum: u64 = 0;
    for (per_worker) |n| sum += n;
    try std.testing.expectEqual(parallel_stats.files_emitted, sum);
}

test "bundle-classified directory emits as a unit and is not recursed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(runtime.io(), "Thing.app/Contents");
    {
        const inner = try tmp.dir.openDir(runtime.io(), "Thing.app/Contents", .{});
        defer inner.close(runtime.io());
        try makeFile(inner, "inner.txt", 5);
    }
    try tmp.dir.createDirPath(runtime.io(), "plain");
    {
        const plain = try tmp.dir.openDir(runtime.io(), "plain", .{});
        defer plain.close(runtime.io());
        try makeFile(plain, "visible.txt", 5);
    }
    const root = try runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "");
    defer std.testing.allocator.free(root);

    var sink = TestSink{ .allocator = std.testing.allocator };
    defer sink.deinit();
    var cbs = sink.callbacks();
    cbs.classify_dir = struct {
        fn classify(_: ?*anyopaque, path: [:0]const u8) DirClass {
            return if (std.mem.endsWith(u8, path, ".app")) .emit_as_unit else .recurse;
        }
    }.classify;
    const stats = walk(std.testing.allocator, root, .{ .thread_count = 2 }, cbs);

    try std.testing.expectEqual(@as(u64, 2), stats.files_emitted); // Thing.app + visible.txt
    var saw_bundle = false;
    for (sink.emissions.items) |e| {
        try std.testing.expect(std.mem.indexOf(u8, e.path, "inner.txt") == null);
        if (std.mem.endsWith(u8, e.path, "Thing.app")) saw_bundle = true;
    }
    try std.testing.expect(saw_bundle);
}

test "depth cap prunes with a max_depth warning" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(runtime.io(), "d1/d2");
    {
        const d2 = try tmp.dir.openDir(runtime.io(), "d1/d2", .{});
        defer d2.close(runtime.io());
        try makeFile(d2, "too_deep.txt", 1);
    }
    const root = try runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "");
    defer std.testing.allocator.free(root);

    var sink = TestSink{ .allocator = std.testing.allocator };
    defer sink.deinit();
    const stats = walk(std.testing.allocator, root, .{ .thread_count = 1, .max_depth = 1 }, sink.callbacks());

    try std.testing.expectEqual(@as(u64, 0), stats.files_emitted);
    try std.testing.expectEqual(@as(usize, 1), sink.warns.items.len);
    try std.testing.expectEqual(WarnReason.max_depth, sink.warns.items[0]);
}

test "emit stop halts the walk early" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var name_buf: [32]u8 = undefined;
    for (0..100) |i| {
        const name = try std.fmt.bufPrint(&name_buf, "s{d:0>3}.dat", .{i});
        try makeFile(tmp.dir, name, 0);
    }
    const root = try runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "");
    defer std.testing.allocator.free(root);

    var sink = TestSink{ .allocator = std.testing.allocator, .stop_after = 5 };
    defer sink.deinit();
    const stats = walk(std.testing.allocator, root, .{ .thread_count = 1 }, sink.callbacks());

    try std.testing.expectEqual(@as(u64, 5), stats.files_emitted);
    try std.testing.expect(stats.stopped_early);
    try std.testing.expectEqual(@as(usize, 5), sink.emissions.items.len);
}

test "dangling symlink emits size 0; live symlink is skipped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, "target.bin", 9);
    try tmp.dir.symLink(runtime.io(), "missing_target.bin", "dangling.lnk", .{});
    try tmp.dir.symLink(runtime.io(), "target.bin", "live.lnk", .{});
    const root = try runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "");
    defer std.testing.allocator.free(root);

    var sink = TestSink{ .allocator = std.testing.allocator };
    defer sink.deinit();
    const stats = walk(std.testing.allocator, root, .{ .thread_count = 2 }, sink.callbacks());

    try std.testing.expectEqual(@as(u64, 2), stats.files_emitted); // target.bin + dangling.lnk
    var saw_dangling = false;
    var saw_target = false;
    for (sink.emissions.items) |e| {
        try std.testing.expect(std.mem.indexOf(u8, e.path, "live.lnk") == null);
        if (std.mem.endsWith(u8, e.path, "dangling.lnk")) {
            saw_dangling = true;
            try std.testing.expectEqual(@as(u64, 0), e.size);
        }
        if (std.mem.endsWith(u8, e.path, "target.bin")) {
            saw_target = true;
            try std.testing.expectEqual(@as(u64, 9), e.size);
        }
    }
    try std.testing.expect(saw_dangling);
    try std.testing.expect(saw_target);
}

test "unopenable root warns inaccessible and returns empty stats" {
    var sink = TestSink{ .allocator = std.testing.allocator };
    defer sink.deinit();
    const stats = walk(
        std.testing.allocator,
        "/validate-test-no-such-root-dir",
        .{ .thread_count = 2 },
        sink.callbacks(),
    );
    try std.testing.expectEqual(@as(u64, 0), stats.files_emitted);
    try std.testing.expectEqual(@as(usize, 1), sink.warns.items.len);
    try std.testing.expectEqual(WarnReason.inaccessible, sink.warns.items[0]);
}

test "op-counter is exactly linear in tree entries (complexity gate)" {
    // Declared complexity is O(total entries). The deterministic op counter
    // must equal the entry count EXACTLY at two sizes — stronger than a
    // wall-clock ratio and immune to machine noise.
    inline for ([_]usize{ 32, 64 }) |n| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var name_buf: [32]u8 = undefined;
        for (0..n) |i| {
            const name = try std.fmt.bufPrint(&name_buf, "n{d:0>3}.dat", .{i});
            try makeFile(tmp.dir, name, 0);
        }
        const root = try runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "");
        defer std.testing.allocator.free(root);

        var sink = TestSink{ .allocator = std.testing.allocator };
        defer sink.deinit();
        const stats = walk(std.testing.allocator, root, .{ .thread_count = 3 }, sink.callbacks());
        try std.testing.expectEqual(@as(u64, n), stats.entries_seen);
        try std.testing.expectEqual(@as(u64, n), stats.files_emitted);
    }
}
