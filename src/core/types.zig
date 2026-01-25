//! Core data types for EntropyShield operations.
//!
//! These types are designed for FFI compatibility with stable memory layouts.

const std = @import("std");

/// Operation kinds matching the Swift OperationKind enum.
/// Raw values are stable and used in the C ABI.
pub const OperationKind = enum(i32) {
    create = 1,
    verify = 2,
    update = 3,
    repair = 4,
    clear = 5,
    scan = 6,

    pub fn description(self: OperationKind) []const u8 {
        return switch (self) {
            .create => "Create",
            .verify => "Verify",
            .update => "Update",
            .repair => "Repair",
            .clear => "Clear",
            .scan => "Scan",
        };
    }

    pub fn progressVerb(self: OperationKind) []const u8 {
        return switch (self) {
            .create => "Creating",
            .verify => "Verifying",
            .update => "Updating",
            .repair => "Repairing",
            .clear => "Clearing",
            .scan => "Scanning",
        };
    }

    pub fn completionVerb(self: OperationKind) []const u8 {
        return switch (self) {
            .create => "Created",
            .verify => "Verified",
            .update => "Updated",
            .repair => "Repaired",
            .clear => "Cleared",
            .scan => "Scanned",
        };
    }

    pub fn modifiesFileContents(self: OperationKind) bool {
        return self == .repair;
    }

    pub fn modifiesParityData(self: OperationKind) bool {
        return switch (self) {
            .verify, .scan => false,
            .create, .update, .repair, .clear => true,
        };
    }
};

/// Operation status for polling-based operations.
pub const OperationStatus = enum(i32) {
    running = 0,
    paused = 1,
    cancelled = 2,
    completed = 3,
    failed = 4,

    pub fn isTerminal(self: OperationStatus) bool {
        return switch (self) {
            .cancelled, .completed, .failed => true,
            .running, .paused => false,
        };
    }
};

/// Progress information for operations.
pub const OperationProgress = extern struct {
    processed_count: i32,
    processed_bytes: u64,
    total_count: i32,
    total_bytes: u64,

    pub fn percentComplete(self: OperationProgress) f64 {
        if (self.total_bytes == 0) {
            if (self.total_count == 0) return 0.0;
            return @as(f64, @floatFromInt(self.processed_count)) / @as(f64, @floatFromInt(self.total_count)) * 100.0;
        }
        return @as(f64, @floatFromInt(self.processed_bytes)) / @as(f64, @floatFromInt(self.total_bytes)) * 100.0;
    }
};

/// File entry for FFI (matches Swift FileEntryFFI).
pub const FileEntry = extern struct {
    /// File path (null-terminated UTF-8).
    path: [*:0]const u8,
    /// File size in bytes.
    size_bytes: u64,
    /// Modification time as nanoseconds since Unix epoch.
    mtime_ns: i64,
    /// Inode change time as nanoseconds since Unix epoch.
    /// Used for detecting changes when mtime is not updated.
    ctime_ns: i64,
    /// POSIX permissions.
    permissions: i32,
    /// Whether this is a symbolic link.
    is_symlink: bool,
};

/// Parity record location type.
pub const ParityLocationType = enum(u8) {
    file = 0,
    sqlite = 1,
};

/// Parity record for FFI (matches Swift ParityRecordFFI).
pub const ParityRecord = extern struct {
    /// Location type: 0 = file, 1 = sqlite.
    location_type: ParityLocationType,
    /// For file: the file path. For sqlite: the database path.
    path: [*:0]const u8,
    /// For sqlite: relative path within database. Empty for file.
    relative_path: [*:0]const u8,
    /// Modification time as nanoseconds since Unix epoch.
    modified_ns: i64,
};

test "OperationKind raw values are stable" {
    try std.testing.expectEqual(@as(i32, 1), @intFromEnum(OperationKind.create));
    try std.testing.expectEqual(@as(i32, 2), @intFromEnum(OperationKind.verify));
    try std.testing.expectEqual(@as(i32, 3), @intFromEnum(OperationKind.update));
    try std.testing.expectEqual(@as(i32, 4), @intFromEnum(OperationKind.repair));
    try std.testing.expectEqual(@as(i32, 5), @intFromEnum(OperationKind.clear));
    try std.testing.expectEqual(@as(i32, 6), @intFromEnum(OperationKind.scan));
}

test "OperationStatus terminal states" {
    try std.testing.expect(!OperationStatus.running.isTerminal());
    try std.testing.expect(!OperationStatus.paused.isTerminal());
    try std.testing.expect(OperationStatus.cancelled.isTerminal());
    try std.testing.expect(OperationStatus.completed.isTerminal());
    try std.testing.expect(OperationStatus.failed.isTerminal());
}

test "OperationProgress percentComplete" {
    const p1 = OperationProgress{
        .processed_count = 50,
        .processed_bytes = 0,
        .total_count = 100,
        .total_bytes = 0,
    };
    try std.testing.expectEqual(@as(f64, 50.0), p1.percentComplete());

    const p2 = OperationProgress{
        .processed_count = 0,
        .processed_bytes = 500,
        .total_count = 0,
        .total_bytes = 1000,
    };
    try std.testing.expectEqual(@as(f64, 50.0), p2.percentComplete());
}
