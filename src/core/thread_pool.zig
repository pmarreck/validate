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

/// DEBUG-only scheduler wait accounting for distinguishing exhausted work,
/// memory admission, and RSS-pressure backpressure. Counters are monotonic
/// nanoseconds so a polling consumer can derive a stable interval delta.
pub const SchedulerDebugStats = struct {
    pub const Snapshot = struct {
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
        completion_queue_wait_ns: u64,
        completion_queue_wait_events: u64,
        completion_queue_waiters: u64,
        completion_queue_high_water: u64,
    };

    worker_count: std.atomic.Value(u64) = .init(0),
    queue_empty_wait_ns: std.atomic.Value(u64) = .init(0),
    queue_empty_wait_events: std.atomic.Value(u64) = .init(0),
    queue_empty_waiters: std.atomic.Value(u64) = .init(0),
    memory_budget_wait_ns: std.atomic.Value(u64) = .init(0),
    memory_budget_wait_events: std.atomic.Value(u64) = .init(0),
    memory_budget_waiters: std.atomic.Value(u64) = .init(0),
    rss_pressure_wait_ns: std.atomic.Value(u64) = .init(0),
    rss_pressure_wait_events: std.atomic.Value(u64) = .init(0),
    rss_pressure_waiters: std.atomic.Value(u64) = .init(0),
    completion_queue_wait_ns: std.atomic.Value(u64) = .init(0),
    completion_queue_wait_events: std.atomic.Value(u64) = .init(0),
    completion_queue_waiters: std.atomic.Value(u64) = .init(0),
    completion_queue_high_water: std.atomic.Value(u64) = .init(0),

    pub fn init() SchedulerDebugStats {
        return .{};
    }

    pub fn setWorkerCount(self: *SchedulerDebugStats, worker_count: usize) void {
        self.worker_count.store(@intCast(worker_count), .seq_cst);
    }

    pub fn recordQueueEmptyWait(self: *SchedulerDebugStats, elapsed_ns: u64) void {
        _ = self.queue_empty_wait_ns.fetchAdd(elapsed_ns, .seq_cst);
        _ = self.queue_empty_wait_events.fetchAdd(1, .seq_cst);
    }

    pub fn recordMemoryBudgetWait(self: *SchedulerDebugStats, elapsed_ns: u64) void {
        _ = self.memory_budget_wait_ns.fetchAdd(elapsed_ns, .seq_cst);
        _ = self.memory_budget_wait_events.fetchAdd(1, .seq_cst);
    }

    pub fn recordRssPressureWait(self: *SchedulerDebugStats, elapsed_ns: u64) void {
        _ = self.rss_pressure_wait_ns.fetchAdd(elapsed_ns, .seq_cst);
        _ = self.rss_pressure_wait_events.fetchAdd(1, .seq_cst);
    }

    fn beginQueueEmptyWait(self: *SchedulerDebugStats) void {
        _ = self.queue_empty_waiters.fetchAdd(1, .seq_cst);
    }

    fn endQueueEmptyWait(self: *SchedulerDebugStats, elapsed_ns: u64) void {
        _ = self.queue_empty_waiters.fetchSub(1, .seq_cst);
        self.recordQueueEmptyWait(elapsed_ns);
    }

    pub fn memoryBudgetWaitBegin(context: ?*anyopaque) void {
        const self: *SchedulerDebugStats = @ptrCast(@alignCast(context orelse return));
        _ = self.memory_budget_waiters.fetchAdd(1, .seq_cst);
    }

    pub fn memoryBudgetWaitEnd(context: ?*anyopaque, elapsed_ns: u64) void {
        const self: *SchedulerDebugStats = @ptrCast(@alignCast(context orelse return));
        _ = self.memory_budget_waiters.fetchSub(1, .seq_cst);
        self.recordMemoryBudgetWait(elapsed_ns);
    }

    pub fn beginRssPressureWait(self: *SchedulerDebugStats) void {
        _ = self.rss_pressure_waiters.fetchAdd(1, .seq_cst);
    }

    pub fn endRssPressureWait(self: *SchedulerDebugStats, elapsed_ns: u64) void {
        _ = self.rss_pressure_waiters.fetchSub(1, .seq_cst);
        self.recordRssPressureWait(elapsed_ns);
    }

    fn beginCompletionQueueWait(self: *SchedulerDebugStats) void {
        _ = self.completion_queue_waiters.fetchAdd(1, .seq_cst);
    }

    fn endCompletionQueueWait(self: *SchedulerDebugStats, elapsed_ns: u64) void {
        _ = self.completion_queue_waiters.fetchSub(1, .seq_cst);
        _ = self.completion_queue_wait_ns.fetchAdd(elapsed_ns, .seq_cst);
        _ = self.completion_queue_wait_events.fetchAdd(1, .seq_cst);
    }

    fn recordCompletionQueueDepth(self: *SchedulerDebugStats, depth: usize) void {
        const value: u64 = @intCast(depth);
        var prior = self.completion_queue_high_water.load(.monotonic);
        while (value > prior) {
            if (self.completion_queue_high_water.cmpxchgWeak(prior, value, .monotonic, .monotonic)) |actual| {
                prior = actual;
            } else {
                return;
            }
        }
    }

    pub fn snapshot(self: *const SchedulerDebugStats) Snapshot {
        return .{
            .worker_count = self.worker_count.load(.seq_cst),
            .queue_empty_wait_ns = self.queue_empty_wait_ns.load(.seq_cst),
            .queue_empty_wait_events = self.queue_empty_wait_events.load(.seq_cst),
            .queue_empty_waiters = self.queue_empty_waiters.load(.seq_cst),
            .memory_budget_wait_ns = self.memory_budget_wait_ns.load(.seq_cst),
            .memory_budget_wait_events = self.memory_budget_wait_events.load(.seq_cst),
            .memory_budget_waiters = self.memory_budget_waiters.load(.seq_cst),
            .rss_pressure_wait_ns = self.rss_pressure_wait_ns.load(.seq_cst),
            .rss_pressure_wait_events = self.rss_pressure_wait_events.load(.seq_cst),
            .rss_pressure_waiters = self.rss_pressure_waiters.load(.seq_cst),
            .completion_queue_wait_ns = self.completion_queue_wait_ns.load(.seq_cst),
            .completion_queue_wait_events = self.completion_queue_wait_events.load(.seq_cst),
            .completion_queue_waiters = self.completion_queue_waiters.load(.seq_cst),
            .completion_queue_high_water = self.completion_queue_high_water.load(.seq_cst),
        };
    }
};

fn elapsedNanoseconds(start_ns: i128) u64 {
    const end_ns = runtime.nanoTimestamp();
    return if (end_ns > start_ns) @intCast(end_ns - start_ns) else 0;
}

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

        /// Optional task-admission hook. It runs only when queued work exists,
        /// before that work is dequeued or reserved against the memory budget.
        /// Implementations may block to coordinate an external resource such as
        /// process RSS without making the generic pool depend on that resource.
        pub const AdmissionGate = struct {
            context: ?*anyopaque,
            wait: *const fn (context: ?*anyopaque) void,
        };

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
        scheduler_debug: ?*SchedulerDebugStats,
        admission_gate: ?AdmissionGate,

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

            pub fn pop(
                self: *WorkQueue,
                scheduler_debug: ?*SchedulerDebugStats,
                admission_gate: ?AdmissionGate,
            ) ?TaskData {
                while (true) {
                    self.mutex.lockUncancelable(runtime.io());
                    while (self.len == 0 and !self.closed) {
                        if (scheduler_debug) |debug| {
                            debug.beginQueueEmptyWait();
                            const wait_start_ns = runtime.nanoTimestamp();
                            self.cond.waitUncancelable(runtime.io(), &self.mutex);
                            debug.endQueueEmptyWait(elapsedNanoseconds(wait_start_ns));
                        } else {
                            self.cond.waitUncancelable(runtime.io(), &self.mutex);
                        }
                    }
                    if (self.len == 0) {
                        self.mutex.unlock(runtime.io());
                        return null;
                    }
                    self.mutex.unlock(runtime.io());

                    if (admission_gate) |gate| gate.wait(gate.context);

                    self.mutex.lockUncancelable(runtime.io());
                    if (self.len == 0) {
                        const closed = self.closed;
                        self.mutex.unlock(runtime.io());
                        if (closed) return null;
                        continue;
                    }
                    const item = self.buf[self.head];
                    self.head = (self.head + 1) % self.buf.len;
                    self.len -= 1;
                    self.mutex.unlock(runtime.io());
                    return item;
                }
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
            buf: []ResultData,
            head: usize = 0,
            len: usize = 0,
            closed: bool = false,
            alloc: Allocator,

            pub fn init(allocator: Allocator, capacity: usize) !@This() {
                return .{
                    .buf = try allocator.alloc(ResultData, @max(@as(usize, 1), capacity)),
                    .alloc = allocator,
                };
            }

            pub fn deinit(self: *@This()) void {
                self.alloc.free(self.buf);
            }

            /// Enqueues a completion without allocating. A full queue blocks
            /// producers until the dedicated callback thread drains one item,
            /// bounding result memory instead of silently dropping callbacks.
            pub fn push(self: *@This(), item: ResultData, scheduler_debug: ?*SchedulerDebugStats) void {
                self.mutex.lockUncancelable(runtime.io());
                defer self.mutex.unlock(runtime.io());
                while (self.len == self.buf.len and !self.closed) {
                    if (scheduler_debug) |debug| {
                        debug.beginCompletionQueueWait();
                        const wait_start_ns = runtime.nanoTimestamp();
                        self.cond.waitUncancelable(runtime.io(), &self.mutex);
                        debug.endCompletionQueueWait(elapsedNanoseconds(wait_start_ns));
                    } else {
                        self.cond.waitUncancelable(runtime.io(), &self.mutex);
                    }
                }
                if (self.closed) return;
                const tail = (self.head + self.len) % self.buf.len;
                self.buf[tail] = item;
                self.len += 1;
                if (scheduler_debug) |debug| debug.recordCompletionQueueDepth(self.len);
                self.cond.signal(runtime.io());
            }

            pub fn pop(self: *@This()) ?ResultData {
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
                self.cond.signal(runtime.io());
                return item;
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
            return createWithBudgetAndDebug(
                allocator,
                job_count,
                task_fn,
                task_context,
                result_callback,
                result_context,
                budget,
                estimate_fn,
                null,
            );
        }

        /// Same as `createWithBudget`, with optional DEBUG-only wait counters.
        /// A null counter keeps the queue and budget admission hot paths unchanged.
        pub fn createWithBudgetAndDebug(
            allocator: Allocator,
            job_count: usize,
            task_fn: TaskFn,
            task_context: ?*anyopaque,
            result_callback: if (has_results) ?ResultCallback else void,
            result_context: if (has_results) ?*anyopaque else void,
            budget: ?*@import("memory_budget.zig").MemoryBudget,
            estimate_fn: ?EstimateFn,
            scheduler_debug: ?*SchedulerDebugStats,
        ) !*Self {
            return createWithBudgetAndDebugAndAdmission(
                allocator,
                job_count,
                task_fn,
                task_context,
                result_callback,
                result_context,
                budget,
                estimate_fn,
                scheduler_debug,
                null,
            );
        }

        /// Same as `createWithBudgetAndDebug`, with a pre-dequeue admission
        /// hook for external backpressure. A null hook leaves worker behavior
        /// unchanged.
        pub fn createWithBudgetAndDebugAndAdmission(
            allocator: Allocator,
            job_count: usize,
            task_fn: TaskFn,
            task_context: ?*anyopaque,
            result_callback: if (has_results) ?ResultCallback else void,
            result_context: if (has_results) ?*anyopaque else void,
            budget: ?*@import("memory_budget.zig").MemoryBudget,
            estimate_fn: ?EstimateFn,
            scheduler_debug: ?*SchedulerDebugStats,
            admission_gate: ?AdmissionGate,
        ) !*Self {
            const actual_jobs = @max(@as(usize, 1), job_count);
            const result_queue_capacity = @max(@as(usize, 2), actual_jobs * 2);

            // Allocate pool on heap
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            self.* = Self{
                .work_queue = WorkQueue.init(allocator),
                .result_queue = if (has_results) try ResultQueue.init(allocator, result_queue_capacity) else {},
                .workers = try allocator.alloc(std.Thread, actual_jobs),
                .pending_count = std.atomic.Value(usize).init(0),
                .shutdown_flag = std.atomic.Value(bool).init(false),
                .task_fn = task_fn,
                .task_context = task_context,
                .budget = budget,
                .estimate_fn = estimate_fn,
                .scheduler_debug = scheduler_debug,
                .admission_gate = admission_gate,
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
                const task = self.work_queue.pop(self.scheduler_debug, self.admission_gate) orelse break;

                // Optional budget gate: estimate, then acquire before task_fn.
                // Released after task_fn returns regardless of how it exited.
                const reserved: usize = if (self.budget != null and self.estimate_fn != null)
                    self.estimate_fn.?(task, self.task_context)
                else
                    0;
                if (self.budget) |b| {
                    if (reserved > 0) {
                        if (self.scheduler_debug) |debug| {
                            b.acquireObserved(reserved, .{
                                .context = debug,
                                .on_wait_begin = SchedulerDebugStats.memoryBudgetWaitBegin,
                                .on_wait_end = SchedulerDebugStats.memoryBudgetWaitEnd,
                            });
                        } else {
                            b.acquire(reserved);
                        }
                    }
                }
                defer if (self.budget) |b| {
                    if (reserved > 0) b.release(reserved);
                };

                // Execute task
                if (has_results) {
                    const result = self.task_fn(task, self.task_context);

                    // Push result (if we have a result callback)
                    if (self.result_callback != null) {
                        self.result_queue.push(result, self.scheduler_debug);
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

/// Upper bound for one nested pool. Standalone validation uses CPU/3 while an
/// explicit environment setting can request a still-smaller ceiling.
fn recommendedInnerJobCount(cpus: usize, explicit_cap: ?usize) usize {
    var jobs = @max(@as(usize, 2), cpus / 3);
    if (explicit_cap) |cap| {
        if (cap > 0) jobs = @min(jobs, cap);
    }
    return @max(@as(usize, 1), jobs);
}

fn ceilSquareRoot(value: usize) usize {
    var root: usize = 1;
    while (root * root < value) root += 1;
    return root;
}

/// Balance two-level file/image parallelism around sqrt(CPUs) outer nested
/// contenders. Very wide batches use half that contender count because RSS
/// admission empirically keeps only a small heavy-file wave active; this
/// restores CPU use without returning to the original `outer × CPU/3` blast.
fn balancedInnerJobCount(cpus: usize, outer_jobs: usize, explicit_cap: ?usize) usize {
    const standalone_ceiling = recommendedInnerJobCount(cpus, explicit_cap);
    const root = ceilSquareRoot(cpus);
    const contender_ceiling = if (outer_jobs > root)
        @max(@as(usize, 1), (root + 1) / 2)
    else
        root;
    const balanced_outer = @min(@max(@as(usize, 1), outer_jobs), contender_ceiling);
    const balanced_jobs = @max(@as(usize, 1), cpus / balanced_outer);
    return @min(standalone_ceiling, balanced_jobs);
}

threadlocal var batch_outer_job_count: ?usize = null;

pub fn setBatchOuterJobCount(job_count: usize) void {
    batch_outer_job_count = @max(@as(usize, 1), job_count);
}

pub fn clearBatchOuterJobCount() void {
    batch_outer_job_count = null;
}

/// Get the recommended job count for inner/nested parallelism.
///
/// Standalone validation uses 1/3 of CPUs (min 2). `VALIDATE_INNER_JOBS` can
/// impose a lower explicit cap (for example truly single-threaded coverage).
pub fn getInnerJobCount() usize {
    var explicit_cap: ?usize = null;
    if (comptime @import("builtin").os.tag != .windows) {
        if (std.c.getenv("VALIDATE_INNER_JOBS")) |s| {
            const slice = std.mem.span(s);
            if (std.fmt.parseInt(usize, slice, 10)) |n| {
                if (n > 0) explicit_cap = n;
            } else |_| {}
        }
    }
    const cpus = getCpuCount();
    if (batch_outer_job_count) |outer_jobs| {
        return balancedInnerJobCount(cpus, outer_jobs, explicit_cap);
    }
    return recommendedInnerJobCount(cpus, explicit_cap);
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

test "ThreadPool bounds completion delivery and records worker backpressure" {
    const Pool = ThreadPool(u32, u32);
    const Context = struct {
        mutex: std.Io.Mutex = .init,
        cond: std.Io.Condition = .init,
        task_calls: usize = 0,
        callback_calls: usize = 0,
        callback_blocked: bool = false,
        release_callback: bool = false,
    };

    var context: Context = .{};
    var debug = SchedulerDebugStats.init();
    const pool = try Pool.createWithBudgetAndDebugAndAdmission(
        std.testing.allocator,
        1,
        struct {
            fn exec(value: u32, context_ptr: ?*anyopaque) u32 {
                const ctx: *Context = @ptrCast(@alignCast(context_ptr));
                ctx.mutex.lockUncancelable(runtime.io());
                ctx.task_calls += 1;
                ctx.cond.broadcast(runtime.io());
                ctx.mutex.unlock(runtime.io());
                return value;
            }
        }.exec,
        &context,
        struct {
            fn callback(_: u32, context_ptr: ?*anyopaque) void {
                const ctx: *Context = @ptrCast(@alignCast(context_ptr));
                ctx.mutex.lockUncancelable(runtime.io());
                defer ctx.mutex.unlock(runtime.io());
                ctx.callback_calls += 1;
                if (ctx.callback_calls == 1) {
                    ctx.callback_blocked = true;
                    ctx.cond.broadcast(runtime.io());
                    while (!ctx.release_callback) {
                        ctx.cond.waitUncancelable(runtime.io(), &ctx.mutex);
                    }
                }
            }
        }.callback,
        &context,
        null,
        null,
        &debug,
        null,
    );
    defer pool.destroy();

    for (0..4) |value| try pool.submit(@intCast(value));
    pool.shutdown();

    context.mutex.lockUncancelable(runtime.io());
    while (!context.callback_blocked or context.task_calls < 4) {
        context.cond.waitUncancelable(runtime.io(), &context.mutex);
    }
    const snapshot = debug.snapshot();
    try std.testing.expect(snapshot.completion_queue_wait_events > 0);
    try std.testing.expectEqual(@as(u64, 2), snapshot.completion_queue_high_water);
    context.release_callback = true;
    context.cond.broadcast(runtime.io());
    context.mutex.unlock(runtime.io());

    pool.wait();
    try std.testing.expectEqual(@as(usize, 4), context.callback_calls);
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
        const val = wq.pop(null, null) orelse return error.UnexpectedNull;
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
            const val = wq.pop(null, null) orelse return error.UnexpectedNull;
            try std.testing.expectEqual(next_pop, val);
            next_pop += 1;
        }
    }

    // Drain remaining
    while (true) {
        // Close to allow non-blocking pop
        wq.close();
        const val = wq.pop(null, null) orelse break;
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

test "ThreadPool admission hook runs before reserving memory" {
    const Pool = ThreadPool(u32, void);
    const Context = struct {
        gate_calls: std.atomic.Value(u32) = .init(0),
        task_calls: std.atomic.Value(u32) = .init(0),
        available_at_gate: std.atomic.Value(usize) = .init(0),
        budget: *@import("memory_budget.zig").MemoryBudget,

        fn waitForAdmission(ctx_ptr: ?*anyopaque) void {
            const ctx: *@This() = @ptrCast(@alignCast(ctx_ptr orelse return));
            _ = ctx.gate_calls.fetchAdd(1, .seq_cst);
            ctx.available_at_gate.store(ctx.budget.available_bytes, .seq_cst);
        }

        fn runTask(_: u32, ctx_ptr: ?*anyopaque) void {
            const ctx: *@This() = @ptrCast(@alignCast(ctx_ptr orelse return));
            _ = ctx.task_calls.fetchAdd(1, .seq_cst);
        }

        fn estimate(_: u32, _: ?*anyopaque) usize {
            return 1;
        }
    };

    var budget = @import("memory_budget.zig").MemoryBudget.init(1);
    var context = Context{ .budget = &budget };
    const gate = Pool.AdmissionGate{
        .context = @ptrCast(&context),
        .wait = Context.waitForAdmission,
    };
    const pool = try Pool.createWithBudgetAndDebugAndAdmission(
        std.testing.allocator,
        1,
        Context.runTask,
        @ptrCast(&context),
        {},
        {},
        &budget,
        Context.estimate,
        null,
        gate,
    );
    defer pool.destroy();

    try pool.submit(7);
    pool.shutdown();
    pool.wait();

    try std.testing.expectEqual(@as(u32, 1), context.gate_calls.load(.seq_cst));
    try std.testing.expectEqual(@as(u32, 1), context.task_calls.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), context.available_at_gate.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), budget.available_bytes);
}

test "SchedulerDebugStats keeps wait reasons independent" {
    var stats = SchedulerDebugStats.init();
    stats.recordQueueEmptyWait(17);
    stats.recordMemoryBudgetWait(23);
    stats.recordRssPressureWait(29);
    stats.recordQueueEmptyWait(5);

    const snapshot = stats.snapshot();
    try std.testing.expectEqual(@as(u64, 22), snapshot.queue_empty_wait_ns);
    try std.testing.expectEqual(@as(u64, 23), snapshot.memory_budget_wait_ns);
    try std.testing.expectEqual(@as(u64, 29), snapshot.rss_pressure_wait_ns);
    try std.testing.expectEqual(@as(u64, 2), snapshot.queue_empty_wait_events);
    try std.testing.expectEqual(@as(u64, 1), snapshot.memory_budget_wait_events);
    try std.testing.expectEqual(@as(u64, 1), snapshot.rss_pressure_wait_events);
}

test "nested job ceiling preserves standalone and explicit limits" {
    const cases = [_]struct {
        cpus: usize,
        explicit_cap: ?usize,
        expected: usize,
    }{
        .{ .cpus = 128, .explicit_cap = null, .expected = 42 },
        .{ .cpus = 128, .explicit_cap = 4, .expected = 4 },
        .{ .cpus = 128, .explicit_cap = 64, .expected = 42 },
        .{ .cpus = 4, .explicit_cap = null, .expected = 2 },
        .{ .cpus = 2, .explicit_cap = 1, .expected = 1 },
    };

    for (cases) |case| {
        try std.testing.expectEqual(
            case.expected,
            recommendedInnerJobCount(case.cpus, case.explicit_cap),
        );
    }
}

test "balanced nested jobs use the square-root outer concurrency ceiling" {
    const cases = [_]struct {
        cpus: usize,
        outer_jobs: usize,
        explicit_cap: ?usize,
        expected: usize,
    }{
        .{ .cpus = 128, .outer_jobs = 1, .explicit_cap = null, .expected = 42 },
        .{ .cpus = 128, .outer_jobs = 12, .explicit_cap = null, .expected = 10 },
        .{ .cpus = 128, .outer_jobs = 85, .explicit_cap = null, .expected = 21 },
        .{ .cpus = 128, .outer_jobs = 85, .explicit_cap = 4, .expected = 4 },
        .{ .cpus = 64, .outer_jobs = 42, .explicit_cap = null, .expected = 16 },
        .{ .cpus = 4, .outer_jobs = 3, .explicit_cap = null, .expected = 2 },
    };

    for (cases) |case| {
        try std.testing.expectEqual(
            case.expected,
            balancedInnerJobCount(case.cpus, case.outer_jobs, case.explicit_cap),
        );
    }
}
