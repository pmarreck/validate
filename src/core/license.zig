//! Offline license-token verification (Ed25519).
//!
//! Verifies the license tokens issued by the mecha-commerce signing Worker
//! (Paddle webhook → EdDSA-signed token). The app embeds per-product public
//! keys and checks tokens entirely offline — no network, no clock read (the
//! `today` date is injected so the core stays pure and expiry tests stay
//! deterministic).
//!
//! Locked contract v1 (agreed with mecha_llc_website, 2026-06-14):
//!   token = b64url_nopad(payload_json) + "." + b64url_nopad(ed25519_sig)
//!   - signature is over the ASCII bytes of the LEFT part (everything before
//!     the single ".").
//!   - verifier splits on ".", verifies the sig over the left bytes, THEN
//!     base64url-decodes + JSON-parses. Algorithm is hardcoded — there is no
//!     `alg` field, so there is no downgrade/alg-confusion attack surface.
//!   - payload JSON key order (fixed for vector byte-stability):
//!     v, product, email, name, issued, expiry, features, txn, kid
//!   - GATE: `email` only (ASCII-lowercase, exact byte-equality). `name` is a
//!     display/audit field and is NOT gated (avoids a JS↔Zig Unicode-casing
//!     divergence that would reject a paying non-Latin-named customer's key).
//!
//! Independence note (MFIC): the verifier is pinned to a shared differential
//! vector file (`license_vectors.json` in mecha-commerce) that the issuer side
//! authors — neither side authors the other's oracle. The `signToken` helper in
//! this file's tests is only an author-side convenience for the red→green loop,
//! NOT the trusted oracle.

const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;

/// Distinct failure reasons. Drives validate's bilingual i18n error messages,
/// so each code maps to a localized + English-shadowed message at the FFI/CLI
/// edge.
pub const ErrorCode = enum(u8) {
    ok = 0,
    malformed_token,
    bad_base64,
    bad_json,
    bad_signature,
    unknown_kid,
    wrong_product,
    expired,
    bad_date,
    email_mismatch,
};

/// One embedded public key, selected by the token's `kid`.
pub const PubKey = struct {
    kid: []const u8,
    key: [Ed25519.PublicKey.encoded_length]u8,
};

/// The validated payload. Owns the JSON arena; call `deinit` when done.
pub const Verified = struct {
    parsed: std.json.Parsed(Payload),

    pub fn product(self: Verified) []const u8 {
        return self.parsed.value.product;
    }
    pub fn email(self: Verified) []const u8 {
        return self.parsed.value.email;
    }
    pub fn expiry(self: Verified) ?[]const u8 {
        return self.parsed.value.expiry;
    }
    pub fn features(self: Verified) []const []const u8 {
        return self.parsed.value.features;
    }
    pub fn deinit(self: Verified) void {
        self.parsed.deinit();
    }
};

/// Result of a verification attempt: either the validated payload, or a code.
pub const VerifyResult = union(enum) {
    ok: Verified,
    err: ErrorCode,
};

/// v1 token payload. Field order here is the canonical issue order.
pub const Payload = struct {
    v: i64,
    product: []const u8,
    email: []const u8,
    name: []const u8,
    issued: []const u8,
    expiry: ?[]const u8,
    features: []const []const u8,
    txn: []const u8,
    kid: []const u8,
};

/// Per-contract hard ceiling: reject anything larger before doing any work.
pub const max_token_len: usize = 4096;

/// ASCII-only case-insensitive byte-equality. Non-ASCII bytes are compared
/// verbatim (std.ascii.toLower passes them through), which is exactly the agreed
/// email match rule: "ASCII A–Z lowercase both sides, exact byte-equality."
fn asciiEqualIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

/// True iff `s` is a well-formed "YYYY-MM-DD" string (shape only — not a
/// calendar-validity check; lexicographic order is what the expiry compare
/// relies on, and that only needs fixed-width zero-padded fields).
fn isIsoDate(s: []const u8) bool {
    if (s.len != 10) return false;
    if (s[4] != '-' or s[7] != '-') return false;
    for ([_]usize{ 0, 1, 2, 3, 5, 6, 8, 9 }) |i| {
        if (!std.ascii.isDigit(s[i])) return false;
    }
    return true;
}

/// Verify a license token offline. Pure: no I/O, no clock — `today` is injected
/// as "YYYY-MM-DD". On success the returned `Verified` owns an arena the caller
/// must `deinit`.
///
/// Ordering note: the `kid` that selects the public key lives inside the signed
/// payload, so we base64-decode + JSON-parse the (length-bounded, ≤4 KiB)
/// payload to read `kid` BEFORE the cryptographic check. No payload field is
/// *trusted* until `sig.verify` succeeds — product/email/expiry gates all run
/// post-verify. Algorithm is hardcoded (no `alg` field), so there is no
/// downgrade surface regardless of parse order. To be reconciled exactly
/// against the shared `license_vectors.json` when it lands.
pub fn verify(
    gpa: std.mem.Allocator,
    token: []const u8,
    user_email: []const u8,
    pubkeys: []const PubKey,
    today: []const u8,
    expected_product: []const u8,
) VerifyResult {
    if (token.len == 0 or token.len > max_token_len) return .{ .err = .malformed_token };
    if (!isIsoDate(today)) return .{ .err = .bad_date };

    // Split on the single '.'; reject missing/empty halves and extra dots.
    const dot = std.mem.indexOfScalar(u8, token, '.') orelse return .{ .err = .malformed_token };
    const left = token[0..dot];
    const right = token[dot + 1 ..];
    if (left.len == 0 or right.len == 0) return .{ .err = .malformed_token };
    if (std.mem.indexOfScalar(u8, right, '.') != null) return .{ .err = .malformed_token };

    const dec = std.base64.url_safe_no_pad.Decoder;

    // Decode the signature (fixed 64 bytes).
    var sig_bytes: [Ed25519.Signature.encoded_length]u8 = undefined;
    const sig_size = dec.calcSizeForSlice(right) catch return .{ .err = .bad_base64 };
    if (sig_size != sig_bytes.len) return .{ .err = .malformed_token };
    dec.decode(&sig_bytes, right) catch return .{ .err = .bad_base64 };
    const sig = Ed25519.Signature.fromBytes(sig_bytes);

    // Decode the payload.
    const payload_size = dec.calcSizeForSlice(left) catch return .{ .err = .bad_base64 };
    const payload_buf = gpa.alloc(u8, payload_size) catch return .{ .err = .malformed_token };
    defer gpa.free(payload_buf);
    dec.decode(payload_buf, left) catch return .{ .err = .bad_base64 };

    // Parse JSON (needed to read `kid`). Arena freed on every error path; kept
    // only on success (handed to the caller inside Verified).
    // `.alloc_always`: copy every string into the parse arena so the result is
    // independent of `payload_buf` (which we free on return).
    const parsed = std.json.parseFromSlice(
        Payload,
        gpa,
        payload_buf,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    ) catch return .{ .err = .bad_json };
    var keep = false;
    defer if (!keep) parsed.deinit();
    const p = parsed.value;

    // Select the embedded public key by kid.
    const pk_bytes = blk: {
        for (pubkeys) |pk| {
            if (std.mem.eql(u8, pk.kid, p.kid)) break :blk pk.key;
        }
        return .{ .err = .unknown_kid };
    };
    const public_key = Ed25519.PublicKey.fromBytes(pk_bytes) catch return .{ .err = .bad_signature };

    // Cryptographic gate: signature over the LEFT ASCII bytes.
    sig.verify(left, public_key) catch return .{ .err = .bad_signature };

    // Trusted from here on.
    if (!std.mem.eql(u8, p.product, expected_product)) return .{ .err = .wrong_product };
    if (!asciiEqualIgnoreCase(p.email, user_email)) return .{ .err = .email_mismatch };

    if (!isIsoDate(p.issued)) return .{ .err = .bad_date };
    if (p.expiry) |exp| {
        if (!isIsoDate(exp)) return .{ .err = .bad_date };
        // Lexicographic compare is valid for fixed-width YYYY-MM-DD.
        // Expired iff today is strictly after expiry (today == expiry accepts).
        if (std.mem.order(u8, today, exp) == .gt) return .{ .err = .expired };
    }

    keep = true;
    return .{ .ok = .{ .parsed = parsed } };
}

// ───────────────────────────── tests ─────────────────────────────

/// Author-side issuer for tests ONLY (see MFIC note in the module doc). Builds
/// a contract-shaped token: b64url_nopad(payload) + "." + b64url_nopad(sig over
/// the left ASCII bytes).
fn signToken(a: std.mem.Allocator, kp: Ed25519.KeyPair, payload_json: []const u8) ![]u8 {
    const enc = std.base64.url_safe_no_pad.Encoder;
    const left_buf = try a.alloc(u8, enc.calcSize(payload_json.len));
    defer a.free(left_buf);
    const left = enc.encode(left_buf, payload_json);

    const sig = try kp.sign(left, null);
    const sig_bytes = sig.toBytes();
    const right_buf = try a.alloc(u8, enc.calcSize(sig_bytes.len));
    defer a.free(right_buf);
    const right = enc.encode(right_buf, &sig_bytes);

    return std.fmt.allocPrint(a, "{s}.{s}", .{ left, right });
}

fn testKeyPair() Ed25519.KeyPair {
    const seed = [_]u8{7} ** Ed25519.KeyPair.seed_length;
    return Ed25519.KeyPair.generateDeterministic(seed) catch unreachable;
}

fn expectErr(res: VerifyResult, want: ErrorCode) !void {
    switch (res) {
        .ok => |v| {
            v.deinit();
            std.debug.print("expected err {s}, got ok\n", .{@tagName(want)});
            return error.TestUnexpectedResult;
        },
        .err => |code| try std.testing.expectEqual(want, code),
    }
}

/// Canonical valid payload used by the negative tests (in fixed key order).
const valid_payload =
    \\{"v":1,"product":"validate","email":"buyer@example.com","name":"John Smith","issued":"2026-06-14","expiry":null,"features":["full"],"txn":"txn_x","kid":"validate-2026"}
;

fn defaultPubkeys(kp: Ed25519.KeyPair) [1]PubKey {
    return [_]PubKey{.{ .kid = "validate-2026", .key = kp.public_key.toBytes() }};
}

test "valid in-date token with matching email verifies ok" {
    const a = std.testing.allocator;
    const kp = testKeyPair();
    const pubkeys = [_]PubKey{.{ .kid = "validate-2026", .key = kp.public_key.toBytes() }};

    const payload =
        \\{"v":1,"product":"validate","email":"buyer@example.com","name":"John Smith","issued":"2026-06-14","expiry":null,"features":["full"],"txn":"txn_x","kid":"validate-2026"}
    ;
    const token = try signToken(a, kp, payload);
    defer a.free(token);

    const res = verify(a, token, "buyer@example.com", &pubkeys, "2026-09-01", "validate");
    switch (res) {
        .ok => |v| {
            defer v.deinit();
            try std.testing.expectEqualStrings("validate", v.product());
            try std.testing.expectEqualStrings("buyer@example.com", v.email());
            try std.testing.expect(v.expiry() == null);
            try std.testing.expectEqual(@as(usize, 1), v.features().len);
            try std.testing.expectEqualStrings("full", v.features()[0]);
        },
        .err => |code| {
            std.debug.print("expected ok, got err: {s}\n", .{@tagName(code)});
            return error.TestUnexpectedResult;
        },
    }
}

test "email match is ASCII case-insensitive" {
    const a = std.testing.allocator;
    const kp = testKeyPair();
    const pubkeys = defaultPubkeys(kp);
    const token = try signToken(a, kp, valid_payload);
    defer a.free(token);

    const res = verify(a, token, "BUYER@Example.COM", &pubkeys, "2026-09-01", "validate");
    switch (res) {
        .ok => |v| v.deinit(),
        .err => |code| {
            std.debug.print("expected ok, got err: {s}\n", .{@tagName(code)});
            return error.TestUnexpectedResult;
        },
    }
}

test "wrong email is rejected (email_mismatch)" {
    const a = std.testing.allocator;
    const kp = testKeyPair();
    const pubkeys = defaultPubkeys(kp);
    const token = try signToken(a, kp, valid_payload);
    defer a.free(token);

    try expectErr(verify(a, token, "someone@else.com", &pubkeys, "2026-09-01", "validate"), .email_mismatch);
}

test "wrong product is rejected (wrong_product)" {
    const a = std.testing.allocator;
    const kp = testKeyPair();
    const pubkeys = defaultPubkeys(kp);
    const token = try signToken(a, kp, valid_payload);
    defer a.free(token);

    try expectErr(verify(a, token, "buyer@example.com", &pubkeys, "2026-09-01", "rotshield"), .wrong_product);
}

test "tampered signature is rejected (bad_signature)" {
    const a = std.testing.allocator;
    const kp = testKeyPair();
    const pubkeys = defaultPubkeys(kp);
    const token = try signToken(a, kp, valid_payload);
    defer a.free(token);

    // Flip a char in the signature half (after the dot).
    const dot = std.mem.indexOfScalar(u8, token, '.').?;
    token[token.len - 1] = if (token[token.len - 1] == 'A') 'B' else 'A';
    _ = dot;
    try expectErr(verify(a, token, "buyer@example.com", &pubkeys, "2026-09-01", "validate"), .bad_signature);
}

test "payload substitution is rejected (bad_signature)" {
    const a = std.testing.allocator;
    const kp = testKeyPair();
    const pubkeys = defaultPubkeys(kp);

    // A genuine substitution attack: take a VALID-JSON payload with a known
    // kid, but pair it with a DIFFERENT payload's signature. It decodes,
    // parses, and selects a key fine — only the crypto gate catches it.
    const other_payload =
        \\{"v":1,"product":"validate","email":"attacker@evil.com","name":"X","issued":"2026-06-14","expiry":null,"features":["full"],"txn":"t","kid":"validate-2026"}
    ;
    const enc = std.base64.url_safe_no_pad.Encoder;
    const left_buf = try a.alloc(u8, enc.calcSize(other_payload.len));
    defer a.free(left_buf);
    const left = enc.encode(left_buf, other_payload);

    // Signature is over the ORIGINAL valid payload's left bytes, not this one.
    const valid_token = try signToken(a, kp, valid_payload);
    defer a.free(valid_token);
    const sig_part = valid_token[std.mem.indexOfScalar(u8, valid_token, '.').? + 1 ..];

    const forged = try std.fmt.allocPrint(a, "{s}.{s}", .{ left, sig_part });
    defer a.free(forged);

    try expectErr(verify(a, forged, "attacker@evil.com", &pubkeys, "2026-09-01", "validate"), .bad_signature);
}

test "unknown kid is rejected (unknown_kid)" {
    const a = std.testing.allocator;
    const kp = testKeyPair();
    // Embed a key under a DIFFERENT kid than the token names.
    const pubkeys = [_]PubKey{.{ .kid = "some-other-kid", .key = kp.public_key.toBytes() }};
    const token = try signToken(a, kp, valid_payload);
    defer a.free(token);

    try expectErr(verify(a, token, "buyer@example.com", &pubkeys, "2026-09-01", "validate"), .unknown_kid);
}

test "expired token is rejected; expiry == today still accepts" {
    const a = std.testing.allocator;
    const kp = testKeyPair();
    const pubkeys = defaultPubkeys(kp);
    const payload =
        \\{"v":1,"product":"validate","email":"buyer@example.com","name":"J","issued":"2026-01-01","expiry":"2026-06-14","features":["full"],"txn":"t","kid":"validate-2026"}
    ;
    const token = try signToken(a, kp, payload);
    defer a.free(token);

    // today strictly after expiry → expired
    try expectErr(verify(a, token, "buyer@example.com", &pubkeys, "2026-06-15", "validate"), .expired);

    // today == expiry → accepts (boundary)
    const res = verify(a, token, "buyer@example.com", &pubkeys, "2026-06-14", "validate");
    switch (res) {
        .ok => |v| v.deinit(),
        .err => |code| {
            std.debug.print("expected ok on expiry boundary, got err: {s}\n", .{@tagName(code)});
            return error.TestUnexpectedResult;
        },
    }
}

test "malformed expiry date is rejected (bad_date)" {
    const a = std.testing.allocator;
    const kp = testKeyPair();
    const pubkeys = defaultPubkeys(kp);
    const payload =
        \\{"v":1,"product":"validate","email":"buyer@example.com","name":"J","issued":"2026-01-01","expiry":"2026-6-1","features":[],"txn":"t","kid":"validate-2026"}
    ;
    const token = try signToken(a, kp, payload);
    defer a.free(token);

    try expectErr(verify(a, token, "buyer@example.com", &pubkeys, "2026-09-01", "validate"), .bad_date);
}

test "malformed injected today is rejected (bad_date)" {
    const a = std.testing.allocator;
    const kp = testKeyPair();
    const pubkeys = defaultPubkeys(kp);
    const token = try signToken(a, kp, valid_payload);
    defer a.free(token);

    try expectErr(verify(a, token, "buyer@example.com", &pubkeys, "06/14/2026", "validate"), .bad_date);
}

test "missing dot is rejected (malformed_token)" {
    const a = std.testing.allocator;
    const kp = testKeyPair();
    const pubkeys = defaultPubkeys(kp);
    try expectErr(verify(a, "no-dot-here", "buyer@example.com", &pubkeys, "2026-09-01", "validate"), .malformed_token);
}

test "extra dot is rejected (malformed_token)" {
    const a = std.testing.allocator;
    const kp = testKeyPair();
    const pubkeys = defaultPubkeys(kp);
    try expectErr(verify(a, "aaaa.bbbb.cccc", "buyer@example.com", &pubkeys, "2026-09-01", "validate"), .malformed_token);
}

test "oversized token is rejected before any work (malformed_token)" {
    const a = std.testing.allocator;
    const kp = testKeyPair();
    const pubkeys = defaultPubkeys(kp);
    const big = try a.alloc(u8, max_token_len + 1);
    defer a.free(big);
    @memset(big, 'A');
    big[10] = '.';
    try expectErr(verify(a, big, "buyer@example.com", &pubkeys, "2026-09-01", "validate"), .malformed_token);
}

test "invalid base64 in payload is rejected (bad_base64)" {
    const a = std.testing.allocator;
    const kp = testKeyPair();
    const pubkeys = defaultPubkeys(kp);
    const token = try signToken(a, kp, valid_payload);
    defer a.free(token);

    // '*' is not in the url-safe alphabet; length is unchanged so the size
    // calc succeeds and the decode is what fails.
    token[0] = '*';
    try expectErr(verify(a, token, "buyer@example.com", &pubkeys, "2026-09-01", "validate"), .bad_base64);
}

test "valid base64 but non-JSON payload is rejected (bad_json)" {
    const a = std.testing.allocator;
    const kp = testKeyPair();
    const pubkeys = defaultPubkeys(kp);
    // "not valid json at all" — valid UTF-8, signed correctly, but not JSON.
    const token = try signToken(a, kp, "not json");
    defer a.free(token);

    try expectErr(verify(a, token, "buyer@example.com", &pubkeys, "2026-09-01", "validate"), .bad_json);
}
