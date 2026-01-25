//! Error handling for EntropyShield.
//!
//! Error codes are stable and match the Swift EntropyShieldError codes.
//! Once assigned, error codes are never reused or changed.

const std = @import("std");

/// Error categories matching Swift EntropyShieldErrorCategory.
pub const ErrorCategory = enum(i32) {
    io = 1000,
    database = 2000,
    parity = 3000,
    settings = 4000,
    validation = 5000,
    internal = 9000,
    cancelled = 10000,
};

/// Stable error codes for the C ABI.
/// Format: category + subcategory (e.g., 1001 = IO error #1)
pub const ErrorCode = enum(i32) {
    // IO errors (1000-1999)
    io_not_directory = 1001,
    io_enumeration_failed = 1002,
    io_read_failed = 1003,
    io_write_failed = 1004,
    io_permission_denied = 1005,
    io_file_not_found = 1006,

    // Database errors (2000-2999)
    db_open_failed = 2001,
    db_query_failed = 2002,
    db_write_failed = 2003,
    db_schema_mismatch = 2004,

    // Parity errors (3000-3999)
    parity_missing = 3001,
    parity_invalid = 3002,
    parity_io = 3003,
    parity_create_failed = 3010,
    parity_verify_failed = 3011,
    parity_recover_failed = 3020,
    parity_unrecoverable = 3021,

    // Settings errors (4000-4999)
    settings_parse = 4001,
    settings_missing_key = 4002,
    settings_invalid_type = 4003,
    settings_invalid_value = 4004,
    settings_file_not_found = 4005,
    settings_io = 4006,

    // Validation errors (5000-5999)
    validation_invalid_path = 5001,
    validation_invalid_utf8 = 5002,
    validation_path_too_long = 5003,

    // Internal errors (9000-9999)
    internal_unexpected = 9001,
    internal_out_of_memory = 9002,

    // Cancelled (10000+)
    cancelled = 10000,

    pub fn category(self: ErrorCode) ErrorCategory {
        const code = @intFromEnum(self);
        if (code >= 10000) return .cancelled;
        if (code >= 9000) return .internal;
        if (code >= 5000) return .validation;
        if (code >= 4000) return .settings;
        if (code >= 3000) return .parity;
        if (code >= 2000) return .database;
        return .io;
    }
};

/// Error information for FFI.
pub const Error = extern struct {
    code: ErrorCode,
    message: [*:0]const u8,
};

/// Thread-local error storage for C API.
pub threadlocal var last_error: ?Error = null;
pub threadlocal var last_error_message: [1024:0]u8 = .{0} ** 1024;

/// Sets the last error with a formatted message.
pub fn setLastError(code: ErrorCode, comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.bufPrint(&last_error_message, fmt, args) catch {
        last_error_message[0] = 0;
        last_error = Error{ .code = code, .message = @ptrCast(&last_error_message) };
        return;
    };
    // Null-terminate
    if (msg.len < last_error_message.len) {
        last_error_message[msg.len] = 0;
    } else {
        last_error_message[last_error_message.len - 1] = 0;
    }
    last_error = Error{ .code = code, .message = @ptrCast(&last_error_message) };
}

/// Clears the last error.
pub fn clearLastError() void {
    last_error = null;
}

test "ErrorCode categories" {
    try std.testing.expectEqual(ErrorCategory.io, ErrorCode.io_not_directory.category());
    try std.testing.expectEqual(ErrorCategory.database, ErrorCode.db_open_failed.category());
    try std.testing.expectEqual(ErrorCategory.parity, ErrorCode.parity_missing.category());
    try std.testing.expectEqual(ErrorCategory.settings, ErrorCode.settings_parse.category());
    try std.testing.expectEqual(ErrorCategory.validation, ErrorCode.validation_invalid_path.category());
    try std.testing.expectEqual(ErrorCategory.internal, ErrorCode.internal_unexpected.category());
    try std.testing.expectEqual(ErrorCategory.cancelled, ErrorCode.cancelled.category());
}

test "setLastError" {
    clearLastError();
    try std.testing.expect(last_error == null);

    setLastError(.io_file_not_found, "File not found: {s}", .{"/test/path"});
    try std.testing.expect(last_error != null);
    try std.testing.expectEqual(ErrorCode.io_file_not_found, last_error.?.code);

    clearLastError();
    try std.testing.expect(last_error == null);
}
