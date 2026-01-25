//! Compatibility module for Zig 0.15+ API changes.
//!
//! Provides managed ArrayList wrapper for cleaner code.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Managed ArrayList that stores the allocator internally.
/// This provides the old ArrayList behavior from pre-0.15 Zig.
pub fn ManagedArrayList(comptime T: type) type {
    return struct {
        const Self = @This();

        items: []T,
        capacity: usize,
        allocator: Allocator,

        pub fn init(allocator: Allocator) Self {
            return .{
                .items = &[_]T{},
                .capacity = 0,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.capacity > 0) {
                self.allocator.free(self.allocatedSlice());
            }
            self.* = undefined;
        }

        pub fn append(self: *Self, item: T) Allocator.Error!void {
            try self.ensureCapacity(self.items.len + 1);
            self.items.len += 1;
            self.items[self.items.len - 1] = item;
        }

        pub fn appendSlice(self: *Self, items: []const T) Allocator.Error!void {
            try self.ensureCapacity(self.items.len + items.len);
            const old_len = self.items.len;
            self.items.len += items.len;
            @memcpy(self.items[old_len..], items);
        }

        pub fn toOwnedSlice(self: *Self) Allocator.Error![]T {
            const result = self.allocator.dupe(T, self.items) catch return error.OutOfMemory;
            self.deinit();
            self.* = init(self.allocator);
            return result;
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.items.len = 0;
        }

        pub fn shrinkRetainingCapacity(self: *Self, new_len: usize) void {
            self.items.len = @min(self.items.len, new_len);
        }

        pub fn popOrNull(self: *Self) ?T {
            if (self.items.len == 0) return null;
            const result = self.items[self.items.len - 1];
            self.items.len -= 1;
            return result;
        }

        pub fn orderedRemove(self: *Self, index: usize) T {
            const item = self.items[index];
            std.mem.copyForwards(T, self.items[index..], self.items[index + 1 ..]);
            self.items.len -= 1;
            return item;
        }

        fn ensureCapacity(self: *Self, min_capacity: usize) Allocator.Error!void {
            if (self.capacity >= min_capacity) return;

            const new_capacity = @max(min_capacity, self.capacity * 2);
            const new_mem = try self.allocator.alloc(T, new_capacity);

            if (self.items.len > 0) {
                @memcpy(new_mem[0..self.items.len], self.items);
            }

            if (self.capacity > 0) {
                self.allocator.free(self.allocatedSlice());
            }

            self.items.ptr = new_mem.ptr;
            self.capacity = new_capacity;
        }

        fn allocatedSlice(self: Self) []T {
            return self.items.ptr[0..self.capacity];
        }
    };
}
