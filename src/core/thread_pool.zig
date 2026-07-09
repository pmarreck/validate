//! Generic Thread Pool
//!
//! A reusable thread pool that can execute arbitrary tasks.
//! Designed to centralize thread-safety logic and allow nested task submission
//! (workers can submit sub-tasks without deadlock).
//!
//! The pool is heap-allocated internally to avoid stack overflow and dangling
//! pointer issues when threads reference the pool state.
//!
//! Usage:
//! ```zig
//! const Pool = ThreadPool(MyTask, MyResult);
//! var pool = try Pool.create(allocator, job_count, myTaskFn, context, callback, ctx);
//! defer pool.destroy();
//!
//! try pool.submit(task1);
//! try pool.submit(task2);
//! pool.shutdown();  // Signal no more tasks
//! pool.wait();      // Wait for completion
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const runtime = @import("runtime.zig");

/// Generic thread pool for parallel task execution.
/// TaskData: The input type for each task
/// ResultData: The output type for each task (use void if no results needed)
pub fn ThreadPool(comptime TaskData: type, comptime ResultData: type) type {
    const has_results = ResultData != void;

    return struct {
        const Self = @This();

        /// Task function signature - takes task data and context, returns result
        pub const TaskFn = *const fn (TaskData, ?*anyopaque) ResultData;

        /// Result callback signature - called for each completed task (only when ResultData != void)
        pub const ResultCallback = if (has_results) *const fn (ResultData, ?*anyopaque) void else void;

        /// Optional estimator: returns expected memory cost for this task in bytes.
        /// Used by the budget gate (if set) to admit/defer tasks. nullable —
        /// when null, the queue ignores memory budgeting entirely.
        pub const EstimateFn = *const fn (TaskData, ?*anyopaque) usize;

        // Internal queues
        work_queue: WorkQueue,
        result_queue: if (has_results) ResultQueue else void,

        // Worker threads
        workers: []std.Thread,

        // Synchronization
        pending_count: std.atomic.Value(usize),
        shutdown_flag: std.atomic.Value(bool),

        // Task execution
        task_fn: TaskFn,
        task_context: ?*anyopaque,

        // Optional memory budget gate. When `budget` and `estimate_fn` are
        // both set, workers acquire bytes before task_fn and release after.
        budget: ?*@import("memory_budget.zig").MemoryBudget,
        estimate_fn: ?EstimateFn,

        // Result handling (only when has_results)
        result_callback: if (has_results) ?ResultCallback else void,
        result_context: if (has_results) ?*anyopaque else void,
        result_thread: if (has_results) ?std.Thread else void,

        // Memory
        allocator: Allocator,

        // ============ Work Queue ============

        /// Ring-buffer FIFO queue. O(1) push and pop (amortised O(1) with
        /// grow), preserving submission order for frontloading strategy.
        const WorkQueue = struct {
            mutex: std.Io.Mutex = .init,
            cond: std.Io.Condition = .init,
            buf: []TaskData = &.{},
            head: usize = 0, // index of next item to dequeue
            len: usize = 0, // number of items currently in the queue
            closed: bool = false,
            alloc: Allocator,

            pub fn init(allocator: Allocator) WorkQueue {
                return .{ .alloc = allocator };
            }

            pub fn deinit(self: *WorkQueue) void {
                if (self.buf.len > 0) {
                    self.alloc.free(self.buf);
                }
            }

            pub fn push(self: *WorkQueue, item: TaskData) !void {
                self.mutex.lockUncancelable(runtime.io());
                defer self.mutex.unlock(runtime.io());
                if (self.len == self.buf.len) {
                    try self.growLocked();
                }
                const tail = (self.head + self.len) % self.buf.len;
                self.buf[tail] = item;
                self.len += 1;
                self.cond.signal(runtime.io());
            }

            pub fn pop(self: *WorkQueue) ?TaskData {
                self.mutex.lockUncancelable(runtime.io());
                defer self.mutex.unlock(runtime.io());
                while (self.len == 0 and !self.closed) {
                    self.cond.waitUncancelable(runtime.io(), &self.mutex);
                }
                if (self.len == 0) {
                    return null;
                }
                const item = self.buf[self.head];
                self.head = (self.head + 1) % self.buf.len;
                self.len -= 1;
                return item;
            }

            pub fn close(self: *WorkQueue) void {
                self.mutex.lockUncancelable(runtime.io());
                self.closed = true;
                self.mutex.unlock(runtime.io());
                self.cond.broadcast(runtime.io());
            }

            /// Double buffer capacity (or allocate initial 16 slots).
            /// Caller must hold mutex.
            fn growLocked(self: *WorkQueue) !void {
                const new_cap = if (self.buf.len == 0) 16 else self.buf.len * 2;
                const new_buf = try self.alloc.alloc(TaskData, new_cap);
                // Copy existing items into contiguous region at start of new buffer
                if (self.len > 0) {
                    const first_part = self.buf.len - self.head;
                    if (first_part >= self.len) {
                        // No wrap-around
                        @memcpy(new_buf[0..self.len], self.buf[self.head .. self.head + self.len]);
                    } else {
                        // Wrapped: copy tail portion then head portion
                        @memcpy(new_buf[0..first_part], self.buf[self.head..self.buf.len]);
                        const second_part = self.len - first_part;
                        @memcpy(new_buf[first_part .. first_part + second_part], self.buf[0..second_part]);
                    }
                }
                if (self.buf.len > 0) {
                    self.alloc.free(self.buf);
                }
                self.buf = new_buf;
                self.head = 0;
            }
        };

        // ============ Result Queue (only when ResultData != void) ============

        const ResultQueue = if (has_results) struct {
            mutex: std.Io.Mutex = .init,
            cond: std.Io.Condition = .init,
            items: std.ArrayListUnmanaged(ResultData) = .empty,
            closed: bool = false,
            alloc: Allocator,

            pub fn init(allocator: Allocator) @This() {
                return .{ .alloc = allocator };
            }

            pub fn deinit(self: *@This()) void {
                self.items.deinit(self.alloc);
            }

            pub fn push(self: *@This(), item: ResultData) !void {
                self.mutex.lockUncancelable(runtime.io());
                defer self.mutex.unlock(runtime.io());
                try self.items.append(self.alloc, item);
                self.cond.signal(runtime.io());
            }

            pub fn pop(self: *@This()) ?ResultData {
                self.mutex.lockUncancelable(runtime.io());
                defer self.mutex.unlock(runtime.io());
                while (self.items.items.len == 0 and !self.closed) {
                    self.cond.waitUncancelable(runtime.io(), &self.mutex);
                }
                if (self.items.items.len == 0) {
                    return null;
                }
                return self.items.pop();
            }

            pub fn close(self: *@This()) void {
                self.mutex.lockUncancelable(runtime.io());
                self.closed = true;
                self.mutex.unlock(runtime.io());
                self.cond.broadcast(runtime.io());
            }
        } else void;

        // ============ Public API ============

        /// Create a thread pool and start workers.
        /// Returns a pointer to heap-allocated pool (avoids stack overflow and dangling pointers).
        /// task_fn: Function to execute for each task
        /// task_context: Optional context passed to task_fn
        /// result_callback: Optional callback for each result (only when ResultData != void)
        /// result_context: Optional context passed to result_callback
        pub fn create(
            allocator: Allocator,
            job_count: usize,
            task_fn: TaskFn,
            task_context: ?*anyopaque,
            result_callback: if (has_results) ?ResultCallback else void,
            result_context: if (has_results) ?*anyopaque else void,
        ) !*Self {
            return createWithBudget(allocator, job_count, task_fn, task_context, result_callback, result_context, null, null);
        }

        /// Same as `create`, plus an optional memory-budget gate. When both
        /// `budget` and `estimate_fn` are set, workers acquire `estimate_fn(task)`
        /// bytes from `budget` before task_fn and release after. When either is
        /// null, no gating happens.
        pub fn createWithBudget(
            allocator: Allocator,
            job_count: usize,
            task_fn: TaskFn,
            task_context: ?*anyopaque,
            result_callback: if (has_results) ?ResultCallback else void,
            result_context: if (has_results) ?*anyopaque else void,
            budget: ?*@import("memory_budget.zig").MemoryBudget,
            estimate_fn: ?EstimateFn,
        ) !*Self {
            const actual_jobs = @max(@as(usize, 1), job_count);

            // Allocate pool on heap
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            self.* = Self{
                .work_queue = WorkQueue.init(allocator),
                .result_queue = if (has_results) ResultQueue.init(allocator) else {},
                .workers = try allocator.alloc(std.Thread, actual_jobs),
                .pending_count = std.atomic.Value(usize).init(0),
                .shutdown_flag = std.atomic.Value(bool).init(false),
                .task_fn = task_fn,
                .task_context = task_context,
                .budget = budget,
                .estimate_fn = estimate_fn,
                .result_callback = if (has_results) result_callback else {},
                .result_context = if (has_results) result_context else {},
                .result_thread = if (has_results) null else {},
                .allocator = allocator,
            };

            // Start result processing thread if callback provided (only when has_results)
            if (has_results) {
                if (result_callback != null) {
                    self.result_thread = try std.Thread.spawn(.{}, resultMain, .{self});
                }
            }

            // Start worker threads
            for (self.workers) |*worker| {
                worker.* = try std.Thread.spawn(.{}, workerMain, .{self});
            }

            return self;
        }

        /// Submit a task for execution.
        /// Can be called from any thread, including worker threads (for sub-tasks).
        pub fn submit(self: *Self, task: TaskData) !void {
            _ = self.pending_count.fetchAdd(1, .seq_cst);
            try self.work_queue.push(task);
        }

        /// Submit multiple tasks at once.
        pub fn submitBatch(self: *Self, tasks: []const TaskData) !void {
            for (tasks) |task| {
                try self.submit(task);
            }
        }

        /// Signal that no more tasks will be submitted.
        /// Workers will exit after processing remaining tasks.
        pub fn shutdown(self: *Self) void {
            self.shutdown_flag.store(true, .seq_cst);
            self.work_queue.close();
        }

        /// Wait for all workers to complete.
        /// Must call shutdown() first.
        pub fn wait(self: *Self) void {
            // Wait for all workers
            for (self.workers) |worker| {
                worker.join();
            }

            // Close result queue and wait for result thread (only when has_results)
            if (has_results) {
                self.result_queue.close();
                if (self.result_thread) |rt| {
                    rt.join();
                }
            }
        }

        /// Get the current number of pending tasks.
        pub fn pendingCount(self: *Self) usize {
            return self.pending_count.load(.seq_cst);
        }

        /// Check if shutdown has been requested.
        pub fn isShuttingDown(self: *Self) bool {
            return self.shutdown_flag.load(.seq_cst);
        }

        /// Destroy the pool and free resources.
        /// Must call shutdown() and wait() first.
        pub fn destroy(self: *Self) void {
            const allocator = self.allocator;
            allocator.free(self.workers);
            self.work_queue.deinit();
            if (has_results) {
                self.result_queue.deinit();
            }
            allocator.destroy(self);
        }

        // ============ Internal ============

        fn workerMain(self: *Self) void {
            while (true) {
                const task = self.work_queue.pop() orelse break;

                // Optional budget gate: estimate, then acquire before task_fn.
                // Released after task_fn returns regardless of how it exited.
                const reserved: usize = if (self.budget != null and self.estimate_fn != null)
                    self.estimate_fn.?(task, self.task_context)
                else
                    0;
                if (self.budget) |b| {
                    if (reserved > 0) b.acquire(reserved);
                }
                defer if (self.budget) |b| {
                    if (reserved > 0) b.release(reserved);
                };

                // Execute task
                if (has_results) {
                    const result = self.task_fn(task, self.task_context);

                    // Push result (if we have a result callback)
                    if (self.result_callback != null) {
                        self.result_queue.push(result) catch {
                            // If we can't push result, still decrement pending
                        };
                    }
                } else {
                    // void result - just execute the task
                    self.task_fn(task, self.task_context);
                }

                // Decrement pending count
                _ = self.pending_count.fetchSub(1, .seq_cst);
            }
        }

        fn resultMain(self: *Self) void {
            if (!has_results) return;

            const callback = self.result_callback orelse return;

            while (true) {
                const result = self.result_queue.pop() orelse break;
                callback(result, self.result_context);
            }
        }
    };
}

// ============ Utility Functions ============

/// Get the total CPU count.
pub fn getCpuCount() usize {
    return std.Thread.getCpuCount() catch 4;
}

/// Get the default number of jobs based on CPU count.
/// Returns full CPU count for backwards compatibility.
pub fn getDefaultJobCount() usize {
    return getCpuCount();
}

/// Get the recommended job count for the outer/batch level.
/// Uses 2/3 of CPUs to leave room for inner parallelism (e.g., PDF image
/// validation). Memory admission is handled by MemoryBudget; do not cap
/// workers here or CPU-heavy batches will leave cores idle even when memory
/// is available. `--jobs N` remains the explicit override.
pub fn getOuterJobCount() usize {
    const cpus = getCpuCount();
    return @max(2, (cpus * 2) / 3);
}

/// Get the recommended job count for inner/nested parallelism.
///
/// Resolution order:
///   1. `VALIDATE_INNER_JOBS` env var (when set to a positive integer) wins —
///      lets a top-level CLI flag (e.g. `--coverage-jobs 1`) cap the budget
///      that nested decoders (PDF image fan-out, libwebp, etc.) consume so
///      `outer × inner` doesn't explode past total CPU count.
///   2. Otherwise: 1/3 of CPUs (min 2), designed so outer + inner ≈ total CPUs.
pub fn getInnerJobCount() usize {
    if (comptime @import("builtin").os.tag != .windows) {
        if (std.c.getenv("VALIDATE_INNER_JOBS")) |s| {
            const slice = std.mem.span(s);
            if (std.fmt.parseInt(usize, slice, 10)) |n| {
                if (n > 0) return n;
            } else |_| {}
        }
    }
    const cpus = getCpuCount();
    // 1/3 of CPUs, minimum 2
    return @max(2, cpus / 3);
}

// ============ Tests ============

test "ThreadPool basic functionality" {
    const Task = struct { value: u32 };
    const Result = struct { doubled: u32 };

    const Pool = ThreadPool(Task, Result);

    var results_collected: usize = 0;
    var results_mutex: std.Io.Mutex = .init;

    const Context = struct {
        results: *usize,
        mutex: *std.Io.Mutex,
    };

    var ctx = Context{
        .results = &results_collected,
        .mutex = &results_mutex,
    };

    const pool = try Pool.create(
        std.testing.allocator,
        2,
        struct {
            fn exec(task: Task, _: ?*anyopaque) Result {
                return .{ .doubled = task.value * 2 };
            }
        }.exec,
        null,
        struct {
            fn callback(_: Result, context: ?*anyopaque) void {
                const c: *Context = @ptrCast(@alignCast(context));
                c.mutex.lockUncancelable(runtime.io());
                defer c.mutex.unlock(runtime.io());
                c.results.* += 1;
            }
        }.callback,
        &ctx,
    );
    defer pool.destroy();

    // Submit tasks
    try pool.submit(.{ .value = 1 });
    try pool.submit(.{ .value = 2 });
    try pool.submit(.{ .value = 3 });

    pool.shutdown();
    pool.wait();

    try std.testing.expectEqual(@as(usize, 3), results_collected);
}

test "ThreadPool without result callback" {
    const Task = struct { value: u32 };

    const Pool = ThreadPool(Task, void);

    var sum: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

    const pool = try Pool.create(
        std.testing.allocator,
        2,
        struct {
            fn exec(task: Task, context: ?*anyopaque) void {
                const s: *std.atomic.Value(u32) = @ptrCast(@alignCast(context));
                _ = s.fetchAdd(task.value, .seq_cst);
            }
        }.exec,
        &sum,
        {}, // void for result_callback when ResultData is void
        {}, // void for result_context when ResultData is void
    );
    defer pool.destroy();

    try pool.submit(.{ .value = 10 });
    try pool.submit(.{ .value = 20 });
    try pool.submit(.{ .value = 30 });

    pool.shutdown();
    pool.wait();

    try std.testing.expectEqual(@as(u32, 60), sum.load(.seq_cst));
}

test "WorkQueue FIFO order preserved with 10K items" {
    const WQ = ThreadPool(u32, void).WorkQueue;
    var wq = WQ.init(std.testing.allocator);
    defer wq.deinit();

    const count: u32 = 10_000;

    // Enqueue 10K items
    for (0..count) |i| {
        try wq.push(@intCast(i));
    }

    // Dequeue and verify FIFO order
    for (0..count) |i| {
        const val = wq.pop() orelse return error.UnexpectedNull;
        try std.testing.expectEqual(@as(u32, @intCast(i)), val);
    }
}

test "WorkQueue interleaved push/pop" {
    const WQ = ThreadPool(u32, void).WorkQueue;
    var wq = WQ.init(std.testing.allocator);
    defer wq.deinit();

    // Push 3, pop 2, push 3, pop 2... exercises ring buffer wrap-around
    var next_push: u32 = 0;
    var next_pop: u32 = 0;

    for (0..100) |_| {
        // Push 3
        for (0..3) |_| {
            try wq.push(next_push);
            next_push += 1;
        }
        // Pop 2
        for (0..2) |_| {
            const val = wq.pop() orelse return error.UnexpectedNull;
            try std.testing.expectEqual(next_pop, val);
            next_pop += 1;
        }
    }

    // Drain remaining
    while (true) {
        // Close to allow non-blocking pop
        wq.close();
        const val = wq.pop() orelse break;
        try std.testing.expectEqual(next_pop, val);
        next_pop += 1;
    }

    try std.testing.expectEqual(next_push, next_pop);
}

test "ThreadPool batch submit" {
    const Task = struct { id: usize };

    const Pool = ThreadPool(Task, void);

    var count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

    const pool = try Pool.create(
        std.testing.allocator,
        4,
        struct {
            fn exec(_: Task, context: ?*anyopaque) void {
                const c: *std.atomic.Value(usize) = @ptrCast(@alignCast(context));
                _ = c.fetchAdd(1, .seq_cst);
            }
        }.exec,
        &count,
        {}, // void for result_callback when ResultData is void
        {}, // void for result_context when ResultData is void
    );
    defer pool.destroy();

    const tasks = [_]Task{
        .{ .id = 0 },
        .{ .id = 1 },
        .{ .id = 2 },
        .{ .id = 3 },
        .{ .id = 4 },
    };

    try pool.submitBatch(&tasks);

    pool.shutdown();
    pool.wait();

    try std.testing.expectEqual(@as(usize, 5), count.load(.seq_cst));
}
