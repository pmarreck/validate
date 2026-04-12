//! PDF Decryption Module
//!
//! Implements PDF standard security handler decryption for documents
//! with empty user passwords (owner-password-only encryption).
//!
//! Supports:
//! - V1 R2: 40-bit RC4 (PDF 1.3)
//! - V2 R3: Variable-length RC4 up to 128-bit (PDF 1.4)
//! - V4 R4: AES-128 or RC4-128 (PDF 1.5+)
//!
//! Note: V5 R5/R6 (AES-256, PDF 2.0) is not yet supported.

const std = @import("std");
const Allocator = std.mem.Allocator;
const errmsg = @import("error_messages.zig");

/// PDF standard padding string (32 bytes)
/// Used to pad passwords to 32 bytes
/// From PDF spec: used when password is shorter than 32 bytes
const PDF_PADDING: [32]u8 = .{
    0x28, 0xBF, 0x4E, 0x5E, 0x4E, 0x75, 0x8A, 0x41,
    0x64, 0x00, 0x4E, 0x56, 0xFF, 0xFA, 0x01, 0x08,
    0x2E, 0x2E, 0x00, 0xB6, 0xD0, 0x68, 0x3E, 0x80,
    0x2F, 0x0C, 0xA9, 0xFE, 0x64, 0x53, 0x69, 0x7A,
};

/// Encryption parameters parsed from PDF
pub const EncryptionParams = struct {
    version: u8, // /V value (1, 2, 3, 4, or 5)
    revision: u8, // /R value (2, 3, 4, 5, or 6)
    key_length: u8, // Key length in bytes (5 for 40-bit, 16 for 128-bit)
    permissions: i32, // /P value
    owner_key: [32]u8, // /O value
    user_key: [32]u8, // /U value
    document_id: [16]u8, // First element of /ID array
    use_aes: bool, // True if using AES (V4 with /CFM /AESV2)

    /// Check if encryption is supported
    pub fn isSupported(self: EncryptionParams) bool {
        return switch (self.version) {
            1, 2 => self.revision == 2 or self.revision == 3,
            4 => self.revision == 4,
            else => false,
        };
    }
};

/// Result of decryption attempt
pub const DecryptResult = struct {
    success: bool,
    encryption_key: ?[16]u8, // The derived encryption key (up to 16 bytes)
    key_length: u8, // Actual key length in bytes
    use_aes: bool,
    error_message: ?[]const u8,

    pub fn ok(key: [16]u8, key_len: u8, use_aes: bool) DecryptResult {
        return .{
            .success = true,
            .encryption_key = key,
            .key_length = key_len,
            .use_aes = use_aes,
            .error_message = null,
        };
    }

    pub fn fail(message: []const u8) DecryptResult {
        return .{
            .success = false,
            .encryption_key = null,
            .key_length = 0,
            .use_aes = false,
            .error_message = message,
        };
    }
};

/// Parse encryption parameters from PDF data
pub fn parseEncryptionParams(data: []const u8) ?EncryptionParams {
    // Find /Encrypt reference
    const encrypt_idx = std.mem.indexOf(u8, data, "/Encrypt") orelse return null;

    // Parse the object reference: /Encrypt N G R
    var i = encrypt_idx + 8;
    while (i < data.len and (data[i] == ' ' or data[i] == '\n' or data[i] == '\r')) : (i += 1) {}

    const obj_num = parseNumber(data, i) orelse return null;
    i = obj_num.end;
    while (i < data.len and (data[i] == ' ' or data[i] == '\n' or data[i] == '\r')) : (i += 1) {}

    const gen_num = parseNumber(data, i) orelse return null;
    i = gen_num.end;
    while (i < data.len and (data[i] == ' ' or data[i] == '\n' or data[i] == '\r')) : (i += 1) {}

    if (i >= data.len or data[i] != 'R') return null;

    // Find the encryption object
    var pattern_buf: [32]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "{d} {d} obj", .{ obj_num.value, gen_num.value }) catch return null;

    const obj_idx = std.mem.indexOf(u8, data, pattern) orelse return null;
    const obj_end = std.mem.indexOfPos(u8, data, obj_idx, "endobj") orelse return null;
    const enc_dict = data[obj_idx..obj_end];

    // Parse encryption dictionary values
    var params = EncryptionParams{
        .version = 1,
        .revision = 2,
        .key_length = 5, // Default 40-bit
        .permissions = 0,
        .owner_key = undefined,
        .user_key = undefined,
        .document_id = undefined,
        .use_aes = false,
    };

    // Parse /V (version)
    if (findDictValue(enc_dict, "/V")) |v| {
        if (parseNumber(enc_dict, v)) |num| {
            params.version = @intCast(@max(0, @min(255, num.value)));
        }
    }

    // Parse /R (revision)
    if (findDictValue(enc_dict, "/R")) |v| {
        if (parseNumber(enc_dict, v)) |num| {
            params.revision = @intCast(@max(0, @min(255, num.value)));
        }
    }

    // Parse /Length (key length in bits)
    if (findDictValue(enc_dict, "/Length")) |v| {
        if (parseNumber(enc_dict, v)) |num| {
            params.key_length = @intCast(@max(5, @min(16, @divFloor(num.value, 8))));
        }
    } else {
        // Default key length based on version
        params.key_length = if (params.version >= 2) 16 else 5;
    }

    // Parse /P (permissions)
    if (findDictValue(enc_dict, "/P")) |v| {
        if (parseNumber(enc_dict, v)) |num| {
            params.permissions = @intCast(num.value);
        }
    }

    // Parse /O (owner key) - 32 bytes
    if (findDictValue(enc_dict, "/O")) |v| {
        if (parseStringValue(enc_dict, v)) |parsed| {
            const str = parsed.slice();
            if (str.len >= 32) {
                @memcpy(&params.owner_key, str[0..32]);
            } else {
                return null;
            }
        } else {
            return null;
        }
    } else {
        return null;
    }

    // Parse /U (user key) - 32 bytes
    if (findDictValue(enc_dict, "/U")) |v| {
        if (parseStringValue(enc_dict, v)) |parsed| {
            const str = parsed.slice();
            if (str.len >= 32) {
                @memcpy(&params.user_key, str[0..32]);
            } else {
                return null;
            }
        } else {
            return null;
        }
    } else {
        return null;
    }

    // Check for AES (/CFM /AESV2)
    if (std.mem.indexOf(u8, enc_dict, "/AESV2") != null or
        std.mem.indexOf(u8, enc_dict, "/AESV3") != null)
    {
        params.use_aes = true;
    }

    // Parse document ID from trailer
    if (parseDocumentId(data)) |id| {
        params.document_id = id;
    } else {
        return null;
    }

    return params;
}

/// Try to decrypt with empty password
pub fn tryEmptyPassword(params: EncryptionParams) DecryptResult {
    if (!params.isSupported()) {
        return DecryptResult.fail(errmsg.unsupported("encryption version"));
    }

    // Compute encryption key with empty password
    const computed = computeEncryptionKey(params, "");

    // Verify against user key
    if (verifyUserPassword(params, computed.slice())) {
        return DecryptResult.ok(computed.key, computed.length, params.use_aes);
    }

    return DecryptResult.fail("Document requires user password");
}

/// Key computation result (thread-safe, no static buffer)
const ComputedKey = struct {
    key: [16]u8,
    length: u8,

    pub fn slice(self: *const ComputedKey) []const u8 {
        return self.key[0..self.length];
    }
};

/// Compute encryption key from password
fn computeEncryptionKey(params: EncryptionParams, password: []const u8) ComputedKey {
    var md5 = std.crypto.hash.Md5.init(.{});

    // Step 1: Pad or truncate password to 32 bytes
    var padded_password: [32]u8 = undefined;
    const pw_len = @min(password.len, 32);
    @memcpy(padded_password[0..pw_len], password[0..pw_len]);
    if (pw_len < 32) {
        @memcpy(padded_password[pw_len..], PDF_PADDING[0 .. 32 - pw_len]);
    }

    md5.update(&padded_password);

    // Step 2: Append /O value
    md5.update(&params.owner_key);

    // Step 3: Append /P value (4 bytes, little-endian)
    const p_bytes: [4]u8 = @bitCast(@as(i32, params.permissions));
    md5.update(&p_bytes);

    // Step 4: Append document ID
    md5.update(&params.document_id);

    // Step 5: Finish MD5
    var hash: [16]u8 = undefined;
    md5.final(&hash);

    // Step 6: For R3+, do 50 additional MD5 iterations
    if (params.revision >= 3) {
        for (0..50) |_| {
            var md5_iter = std.crypto.hash.Md5.init(.{});
            md5_iter.update(hash[0..params.key_length]);
            md5_iter.final(&hash);
        }
    }

    return .{ .key = hash, .length = params.key_length };
}

/// Verify user password by checking /U value
fn verifyUserPassword(params: EncryptionParams, key: []const u8) bool {
    if (params.revision == 2) {
        // R2: RC4-encrypt padding string, compare to /U
        var rc4_state: [256]u8 = undefined;
        rc4Init(&rc4_state, key);

        var decrypted: [32]u8 = undefined;
        rc4Crypt(&rc4_state, &params.user_key, &decrypted);

        return std.mem.eql(u8, &decrypted, &PDF_PADDING);
    } else if (params.revision >= 3) {
        // R3/R4: More complex verification
        // Hash padding + document ID, then RC4 with key XOR 0..19
        var md5 = std.crypto.hash.Md5.init(.{});
        md5.update(&PDF_PADDING);
        md5.update(&params.document_id);
        var hash: [16]u8 = undefined;
        md5.final(&hash);

        // Apply RC4 with modified keys
        var result: [16]u8 = undefined;
        @memcpy(&result, &hash);

        // For R3+, apply RC4 with key XOR i for i = 19..0
        var i: u8 = 19;
        while (true) : (i -= 1) {
            var modified_key: [16]u8 = undefined;
            for (0..key.len) |j| {
                modified_key[j] = key[j] ^ i;
            }
            var rc4_state: [256]u8 = undefined;
            rc4Init(&rc4_state, modified_key[0..key.len]);
            var temp: [16]u8 = undefined;
            rc4Crypt(&rc4_state, &result, &temp);
            result = temp;
            if (i == 0) break;
        }

        // Compare first 16 bytes of /U
        return std.mem.eql(u8, &result, params.user_key[0..16]);
    }

    return false;
}

/// Decrypt a stream with the given key and object/generation numbers
pub fn decryptStream(
    allocator: Allocator,
    encrypted_data: []const u8,
    encryption_key: []const u8,
    obj_num: u32,
    gen_num: u32,
    use_aes: bool,
) ![]u8 {
    // Compute object-specific key
    var md5 = std.crypto.hash.Md5.init(.{});
    md5.update(encryption_key);

    // Append object number (3 bytes, little-endian)
    const obj_bytes: [4]u8 = @bitCast(obj_num);
    md5.update(obj_bytes[0..3]);

    // Append generation number (2 bytes, little-endian)
    const gen_bytes: [4]u8 = @bitCast(gen_num);
    md5.update(gen_bytes[0..2]);

    if (use_aes) {
        // For AES, append "sAlT"
        md5.update("sAlT");
    }

    var hash: [16]u8 = undefined;
    md5.final(&hash);

    // Key length is min(encryption_key.len + 5, 16)
    const stream_key_len = @min(encryption_key.len + 5, 16);
    const stream_key = hash[0..stream_key_len];

    if (use_aes) {
        return decryptAes128Cbc(allocator, encrypted_data, stream_key);
    } else {
        return decryptRc4(allocator, encrypted_data, stream_key);
    }
}

/// RC4 decryption
fn decryptRc4(allocator: Allocator, data: []const u8, key: []const u8) ![]u8 {
    var rc4_state: [256]u8 = undefined;
    rc4Init(&rc4_state, key);

    const result = try allocator.alloc(u8, data.len);
    rc4Crypt(&rc4_state, data, result);

    return result;
}

/// AES-128-CBC decryption
fn decryptAes128Cbc(allocator: Allocator, data: []const u8, key: []const u8) ![]u8 {
    if (data.len < 16) return error.DataTooShort;

    // First 16 bytes are the IV
    const iv = data[0..16];
    const ciphertext = data[16..];

    if (ciphertext.len == 0 or ciphertext.len % 16 != 0) {
        return error.InvalidPadding;
    }

    const result = try allocator.alloc(u8, ciphertext.len);
    errdefer allocator.free(result);

    // Use Zig's AES implementation
    const Aes128 = std.crypto.core.aes.Aes128;
    var aes = Aes128.initDec(key[0..16].*);

    var prev_block: [16]u8 = iv.*;
    var i: usize = 0;
    while (i < ciphertext.len) : (i += 16) {
        var block: [16]u8 = undefined;
        @memcpy(&block, ciphertext[i..][0..16]);

        var decrypted: [16]u8 = undefined;
        aes.decrypt(&decrypted, &block);

        // XOR with previous ciphertext block (CBC mode)
        for (0..16) |j| {
            result[i + j] = decrypted[j] ^ prev_block[j];
        }

        prev_block = block;
    }

    // Remove PKCS#7 padding
    const pad_len = result[result.len - 1];
    if (pad_len > 16 or pad_len == 0) {
        return error.InvalidPadding;
    }

    // Verify padding
    for (result[result.len - pad_len ..]) |b| {
        if (b != pad_len) {
            return error.InvalidPadding;
        }
    }

    // Return unpadded result (need to reallocate to shrink)
    const unpadded_len = result.len - pad_len;
    const final_result = try allocator.alloc(u8, unpadded_len);
    @memcpy(final_result, result[0..unpadded_len]);
    allocator.free(result);

    return final_result;
}

/// Initialize RC4 state
fn rc4Init(state: *[256]u8, key: []const u8) void {
    for (0..256) |i| {
        state[i] = @intCast(i);
    }

    var j: u8 = 0;
    for (0..256) |i| {
        j = j +% state[i] +% key[i % key.len];
        std.mem.swap(u8, &state[i], &state[j]);
    }
}

/// RC4 encrypt/decrypt (symmetric)
fn rc4Crypt(state: *[256]u8, input: []const u8, output: []u8) void {
    var i: u8 = 0;
    var j: u8 = 0;

    for (input, 0..) |byte, idx| {
        i = i +% 1;
        j = j +% state[i];
        std.mem.swap(u8, &state[i], &state[j]);
        const k = state[state[i] +% state[j]];
        output[idx] = byte ^ k;
    }
}

// ============ Helper Functions ============

fn parseNumber(data: []const u8, start: usize) ?struct { value: i64, end: usize } {
    var i = start;
    var negative = false;

    if (i < data.len and data[i] == '-') {
        negative = true;
        i += 1;
    }

    const num_start = i;
    while (i < data.len and data[i] >= '0' and data[i] <= '9') : (i += 1) {}

    if (i == num_start) return null;

    const value = std.fmt.parseInt(i64, data[num_start..i], 10) catch return null;
    return .{
        .value = if (negative) -value else value,
        .end = i,
    };
}

fn findDictValue(dict: []const u8, key: []const u8) ?usize {
    const idx = std.mem.indexOf(u8, dict, key) orelse return null;
    var i = idx + key.len;
    while (i < dict.len and (dict[i] == ' ' or dict[i] == '\n' or dict[i] == '\r')) : (i += 1) {}
    return i;
}

/// Parsed string result (thread-safe, no static buffer)
const ParsedString = struct {
    buf: [256]u8,
    len: usize,

    pub fn slice(self: *const ParsedString) []const u8 {
        return self.buf[0..self.len];
    }
};

fn parseStringValue(data: []const u8, start: usize) ?ParsedString {
    if (start >= data.len) return null;

    if (data[start] == '(') {
        // Literal string
        var i = start + 1;
        var depth: u32 = 1;
        var result: ParsedString = .{ .buf = undefined, .len = 0 };

        while (i < data.len and depth > 0) {
            if (data[i] == '\\' and i + 1 < data.len) {
                // Escape sequence
                i += 1;
                const escaped: u8 = switch (data[i]) {
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    'b' => 0x08,
                    'f' => 0x0C,
                    '(' => '(',
                    ')' => ')',
                    '\\' => '\\',
                    '0'...'7' => blk: {
                        // Octal escape — use u16 to avoid overflow on malformed
                        // sequences like \777 (511 decimal, exceeds u8 max 255).
                        // Truncate to u8 on return, matching real-world PDF behavior.
                        var octal: u16 = data[i] - '0';
                        if (i + 1 < data.len and data[i + 1] >= '0' and data[i + 1] <= '7') {
                            i += 1;
                            octal = octal * 8 + (data[i] - '0');
                            if (i + 1 < data.len and data[i + 1] >= '0' and data[i + 1] <= '7') {
                                i += 1;
                                octal = octal * 8 + (data[i] - '0');
                            }
                        }
                        break :blk @as(u8, @truncate(octal));
                    },
                    else => data[i],
                };
                if (result.len < result.buf.len) {
                    result.buf[result.len] = escaped;
                    result.len += 1;
                }
            } else if (data[i] == '(') {
                depth += 1;
                if (result.len < result.buf.len) {
                    result.buf[result.len] = '(';
                    result.len += 1;
                }
            } else if (data[i] == ')') {
                depth -= 1;
                if (depth > 0 and result.len < result.buf.len) {
                    result.buf[result.len] = ')';
                    result.len += 1;
                }
            } else {
                if (result.len < result.buf.len) {
                    result.buf[result.len] = data[i];
                    result.len += 1;
                }
            }
            i += 1;
        }

        return result;
    } else if (data[start] == '<' and start + 1 < data.len and data[start + 1] != '<') {
        // Hex string
        var i = start + 1;
        var result: ParsedString = .{ .buf = undefined, .len = 0 };

        while (i < data.len and data[i] != '>') {
            // Skip whitespace
            if (data[i] == ' ' or data[i] == '\n' or data[i] == '\r' or data[i] == '\t') {
                i += 1;
                continue;
            }

            const high = hexDigit(data[i]) orelse {
                i += 1;
                continue;
            };
            i += 1;

            var low: u8 = 0;
            if (i < data.len and data[i] != '>') {
                low = hexDigit(data[i]) orelse 0;
                i += 1;
            }

            if (result.len < result.buf.len) {
                result.buf[result.len] = (high << 4) | low;
                result.len += 1;
            }
        }

        return result;
    }

    return null;
}

fn hexDigit(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn parseDocumentId(data: []const u8) ?[16]u8 {
    // Search for /ID [ <hex> <hex> ]
    const id_idx = std.mem.indexOf(u8, data, "/ID") orelse return null;

    var i = id_idx + 3;
    while (i < data.len and (data[i] == ' ' or data[i] == '\n' or data[i] == '\r')) : (i += 1) {}

    if (i >= data.len or data[i] != '[') return null;
    i += 1;

    while (i < data.len and (data[i] == ' ' or data[i] == '\n' or data[i] == '\r')) : (i += 1) {}

    if (parseStringValue(data, i)) |parsed| {
        const id_str = parsed.slice();
        if (id_str.len >= 16) {
            var result: [16]u8 = undefined;
            @memcpy(&result, id_str[0..16]);
            return result;
        }
    }

    return null;
}

// ============ Tests ============

test "RC4 encryption/decryption" {
    // Test vector from RFC 6229
    const key = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05 };
    var state: [256]u8 = undefined;
    rc4Init(&state, &key);

    const plaintext = "Hello, World!";
    var ciphertext: [13]u8 = undefined;
    rc4Crypt(&state, plaintext, &ciphertext);

    // Re-init and decrypt
    rc4Init(&state, &key);
    var decrypted: [13]u8 = undefined;
    rc4Crypt(&state, &ciphertext, &decrypted);

    try std.testing.expectEqualStrings(plaintext, &decrypted);
}

test "PDF padding is correct length" {
    try std.testing.expectEqual(@as(usize, 32), PDF_PADDING.len);
}

test "parseNumber handles positive and negative" {
    const data = "-123 456";
    const neg = parseNumber(data, 0).?;
    try std.testing.expectEqual(@as(i64, -123), neg.value);

    const pos = parseNumber(data, 5).?;
    try std.testing.expectEqual(@as(i64, 456), pos.value);
}

test "hexDigit converts correctly" {
    try std.testing.expectEqual(@as(?u8, 0), hexDigit('0'));
    try std.testing.expectEqual(@as(?u8, 9), hexDigit('9'));
    try std.testing.expectEqual(@as(?u8, 10), hexDigit('a'));
    try std.testing.expectEqual(@as(?u8, 15), hexDigit('f'));
    try std.testing.expectEqual(@as(?u8, 10), hexDigit('A'));
    try std.testing.expectEqual(@as(?u8, null), hexDigit('g'));
}

test "thread-safety: concurrent parseStringValue calls" {
    // This test verifies that parseStringValue is thread-safe by running
    // multiple threads that call it simultaneously with different data.
    // Before the fix, static buffers caused race conditions.
    const num_threads = 16;
    const iterations = 1000;

    const ThreadContext = struct {
        thread_id: usize,
        success: bool = true,

        fn worker(self: *@This()) void {
            const test_strings = [_][]const u8{
                "(Hello World)",
                "<48656C6C6F>",
                "(Test\\nString)",
                "<DEADBEEF>",
            };

            for (0..iterations) |iter| {
                const idx = (self.thread_id + iter) % test_strings.len;
                if (parseStringValue(test_strings[idx], 0)) |result| {
                    // Verify the result is what we expect
                    const expected_lens = [_]usize{ 11, 5, 11, 4 };
                    if (result.len != expected_lens[idx]) {
                        self.success = false;
                        return;
                    }
                } else {
                    self.success = false;
                    return;
                }
            }
        }
    };

    var contexts: [num_threads]ThreadContext = undefined;
    var threads: [num_threads]std.Thread = undefined;

    // Start all threads
    for (0..num_threads) |i| {
        contexts[i] = .{ .thread_id = i };
        threads[i] = std.Thread.spawn(.{}, ThreadContext.worker, .{&contexts[i]}) catch {
            // If we can't spawn threads, skip this test
            return;
        };
    }

    // Wait for all threads to complete
    for (&threads) |*t| {
        t.join();
    }

    // Check all threads succeeded
    for (&contexts) |*ctx| {
        try std.testing.expect(ctx.success);
    }
}

test "octal escape \\777 does not overflow u8 accumulator" {
    // PDF spec allows \NNN octal escapes up to \377 (255).
    // Malformed real-world PDFs contain \777 which is 511 in decimal,
    // overflowing a u8 accumulator. The parser must handle this gracefully
    // by using a wider accumulator and truncating to u8.
    const input = "(\\777)";
    const result = parseStringValue(input, 0);
    try std.testing.expect(result != null);
    // 7*64 + 7*8 + 7 = 511, truncated to u8 = 511 & 0xFF = 255
    try std.testing.expectEqual(@as(u8, 255), result.?.buf[0]);
    try std.testing.expectEqual(@as(usize, 1), result.?.len);
}

test "octal escape \\377 parses correctly as 255" {
    const input = "(\\377)";
    const result = parseStringValue(input, 0);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u8, 255), result.?.buf[0]);
    try std.testing.expectEqual(@as(usize, 1), result.?.len);
}

test "octal escape \\101 parses correctly as 'A'" {
    const input = "(\\101)";
    const result = parseStringValue(input, 0);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u8, 'A'), result.?.buf[0]);
    try std.testing.expectEqual(@as(usize, 1), result.?.len);
}

test "thread-safety: concurrent computeEncryptionKey calls" {
    // Test that computeEncryptionKey is thread-safe
    const num_threads = 16;
    const iterations = 100;

    const ThreadContext = struct {
        thread_id: usize,
        success: bool = true,

        fn worker(self: *@This()) void {
            // Create test params with different values per thread
            var params = EncryptionParams{
                .version = 2,
                .revision = 3,
                .key_length = 16,
                .permissions = -4,
                .owner_key = undefined,
                .user_key = undefined,
                .document_id = undefined,
                .use_aes = false,
            };

            // Fill with thread-specific data
            for (&params.owner_key) |*b| b.* = @truncate(self.thread_id);
            for (&params.user_key) |*b| b.* = @truncate(self.thread_id + 1);
            for (&params.document_id) |*b| b.* = @truncate(self.thread_id + 2);

            for (0..iterations) |_| {
                const result = computeEncryptionKey(params, "");
                // Just verify we got a result with expected length
                if (result.length != 16) {
                    self.success = false;
                    return;
                }
            }
        }
    };

    var contexts: [num_threads]ThreadContext = undefined;
    var threads: [num_threads]std.Thread = undefined;

    for (0..num_threads) |i| {
        contexts[i] = .{ .thread_id = i };
        threads[i] = std.Thread.spawn(.{}, ThreadContext.worker, .{&contexts[i]}) catch {
            return;
        };
    }

    for (&threads) |*t| {
        t.join();
    }

    for (&contexts) |*ctx| {
        try std.testing.expect(ctx.success);
    }
}
