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

        // Result handling (only when has_results)
        result_callback: if (has_results) ?ResultCallback else void,
        result_context: if (has_results) ?*anyopaque else void,
        result_thread: if (has_results) ?std.Thread else void,

        // Memory
        allocator: Allocator,

        // ============ Work Queue ============

        const WorkQueue = struct {
            mutex: std.Thread.Mutex = .{},
            cond: std.Thread.Condition = .{},
            items: std.ArrayListUnmanaged(TaskData) = .{},
            closed: bool = false,
            alloc: Allocator,

            pub fn init(allocator: Allocator) WorkQueue {
                return .{ .alloc = allocator };
            }

            pub fn deinit(self: *WorkQueue) void {
                self.items.deinit(self.alloc);
            }

            pub fn push(self: *WorkQueue, item: TaskData) !void {
                self.mutex.lock();
                defer self.mutex.unlock();
                try self.items.append(self.alloc, item);
                self.cond.signal();
            }

            pub fn pop(self: *WorkQueue) ?TaskData {
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

        // ============ Result Queue (only when ResultData != void) ============

        const ResultQueue = if (has_results) struct {
            mutex: std.Thread.Mutex = .{},
            cond: std.Thread.Condition = .{},
            items: std.ArrayListUnmanaged(ResultData) = .{},
            closed: bool = false,
            alloc: Allocator,

            pub fn init(allocator: Allocator) @This() {
                return .{ .alloc = allocator };
            }

            pub fn deinit(self: *@This()) void {
                self.items.deinit(self.alloc);
            }

            pub fn push(self: *@This(), item: ResultData) !void {
                self.mutex.lock();
                defer self.mutex.unlock();
                try self.items.append(self.alloc, item);
                self.cond.signal();
            }

            pub fn pop(self: *@This()) ?ResultData {
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

            pub fn close(self: *@This()) void {
                self.mutex.lock();
                self.closed = true;
                self.mutex.unlock();
                self.cond.broadcast();
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

/// Get the default number of jobs based on CPU count.
pub fn getDefaultJobCount() usize {
    return std.Thread.getCpuCount() catch 4;
}

// ============ Tests ============

test "ThreadPool basic functionality" {
    const Task = struct { value: u32 };
    const Result = struct { doubled: u32 };

    const Pool = ThreadPool(Task, Result);

    var results_collected: usize = 0;
    var results_mutex: std.Thread.Mutex = .{};

    const Context = struct {
        results: *usize,
        mutex: *std.Thread.Mutex,
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
                c.mutex.lock();
                defer c.mutex.unlock();
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
