# Decompression Honesty: Ratio-Based Corruption Detection + Depth Downgrade

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When decompression hits a size limit, distinguish legitimately large streams (depth downgrade to structural + warning) from corrupt/bomb streams (FAIL), using compression ratio as the discriminator.

**Architecture:** Add a `DecompressResult` tagged union to `zlib.zig` that replaces `?[]u8` returns. When decompression exceeds `max_output_size`, check `bytes_produced / compressed.len` — ratio >100:1 means corruption/bomb (FAIL), ratio <=100:1 means legitimately large data (skip with warning). PDF validators adopt first; other decompressors extend later.

**Tech Stack:** Zig, bundled zlib (C FFI)

---

## File Structure

| File | Role | Change Type |
|------|------|-------------|
| `src/core/zlib.zig` | Shared decompression with ratio-aware results | Modify |
| `src/core/pdf_font_validator.zig` | Font stream decompression consumer | Modify |
| `src/core/pdf_image_validator.zig` | Image stream decompression consumer | Modify |
| `src/core/pdf_embedded_file_validator.zig` | Embedded file decompression consumer | Modify |
| `src/core/pdf_validator.zig` | Top-level PDF deep validation — depth downgrade logic | Modify |

---

### Task 1: Add `DecompressResult` type and ratio-aware inflate to `zlib.zig`

**Files:**
- Modify: `src/core/zlib.zig`

The key insight: `inflateZlibAlloc` and `inflateRawAlloc` already know `compressed.len` and `stream.total_out` at the point where they hit `max_output_size`. We just need to return that info instead of collapsing it into a generic `BufferError`.

- [ ] **Step 1: Write the failing test**

Add to the end of `src/core/zlib.zig` tests:

```zig
test "inflateZlibAllocWithRatio: returns exceeded_limit with ratio for bomb-like data" {
    // Create a zlib-compressed stream that decompresses to all zeros (high ratio)
    // We'll compress 1MB of zeros, then set max_output to 1KB to force a limit hit
    const allocator = std.testing.allocator;

    // Compress 64KB of zeros
    const input_size: usize = 64 * 1024;
    const input = try allocator.alloc(u8, input_size);
    defer allocator.free(input);
    @memset(input, 0);

    var compressed_buf: [1024]u8 = undefined;
    const compressed = try deflateZlib(input, &compressed_buf);

    // Decompress with a very small limit (256 bytes) — should hit the limit
    const result = inflateZlibAllocWithRatio(allocator, compressed, 256);
    switch (result) {
        .exceeded_limit => |info| {
            // Compressed zeros should have a very high ratio
            try std.testing.expect(info.ratio > 100);
            try std.testing.expect(info.bytes_produced > 0);
        },
        .ok => |data| {
            allocator.free(data);
            return error.TestUnexpectedResult; // Should not succeed with 256 byte limit
        },
        .data_error, .alloc_error => return error.TestUnexpectedResult,
    }
}

test "inflateZlibAllocWithRatio: returns ok for normal data within limit" {
    const allocator = std.testing.allocator;

    // Compress a small string
    const input = "Hello, world! This is a test of normal compression.";
    var compressed_buf: [256]u8 = undefined;
    const compressed = try deflateZlib(input, &compressed_buf);

    const result = inflateZlibAllocWithRatio(allocator, compressed, 64 * 1024);
    switch (result) {
        .ok => |data| {
            defer allocator.free(data);
            try std.testing.expectEqualStrings(input, data);
        },
        else => return error.TestUnexpectedResult,
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nix build ".#checks.aarch64-darwin.test" 2>&1 | tail -20`
Expected: FAIL — `inflateZlibAllocWithRatio` and `deflateZlib` don't exist yet.

- [ ] **Step 3: Implement `DecompressResult`, `inflateZlibAllocWithRatio`, `inflateRawAllocWithRatio`, and `deflateZlib`**

Add these to `src/core/zlib.zig`:

```zig
/// Result of a ratio-aware decompression attempt.
/// Distinguishes successful decompression, size limit exceeded (with ratio),
/// and actual data errors.
pub const DecompressResult = union(enum) {
    /// Decompression succeeded. Caller owns the slice and must free with same allocator.
    ok: []u8,
    /// Output exceeded max_output_size. Ratio = bytes_produced / compressed_len.
    /// Ratio > 100 strongly suggests corruption or decompression bomb.
    /// Ratio <= 100 suggests legitimately large data beyond our validation budget.
    exceeded_limit: struct {
        bytes_produced: usize,
        compressed_len: usize,
        ratio: usize, // bytes_produced / compressed_len (floored)
    },
    /// Compressed data is invalid (corruption).
    data_error,
    /// Memory allocation failed.
    alloc_error,
};

/// Ratio-aware zlib decompression. Returns structured result instead of error union.
/// When decompression hits max_output_size, reports the compression ratio so callers
/// can distinguish legitimately large streams from decompression bombs.
pub fn inflateZlibAllocWithRatio(allocator: Allocator, compressed: []const u8, max_output_size: usize) DecompressResult {
    var stream: c.z_stream = .{
        .next_in = @constCast(compressed.ptr),
        .avail_in = @intCast(compressed.len),
        .next_out = undefined,
        .avail_out = 0,
        .zalloc = null,
        .zfree = null,
        .@"opaque" = null,
        .total_in = 0,
        .total_out = 0,
        .msg = null,
        .state = null,
        .data_type = 0,
        .adler = 0,
        .reserved = 0,
    };

    const init_ret = c.inflateInit(&stream);
    if (init_ret != c.Z_OK) return .data_error;
    defer _ = c.inflateEnd(&stream);

    var output_size: usize = @min(compressed.len * 4, max_output_size);
    if (output_size < 4096) output_size = 4096;

    var output = allocator.alloc(u8, output_size) catch return .alloc_error;
    errdefer allocator.free(output);

    stream.next_out = output.ptr;
    stream.avail_out = @intCast(output.len);

    while (true) {
        const ret = c.inflate(&stream, c.Z_NO_FLUSH);
        switch (ret) {
            c.Z_STREAM_END => {
                const final_size = stream.total_out;
                if (final_size < output.len) {
                    output = allocator.realloc(output, final_size) catch output;
                }
                return .{ .ok = output[0..final_size] };
            },
            c.Z_OK, c.Z_BUF_ERROR => {
                if (stream.avail_out == 0) {
                    const new_size = output.len * 2;
                    if (new_size > max_output_size) {
                        // Hit the limit — compute ratio and report
                        allocator.free(output);
                        const produced: usize = stream.total_out;
                        const comp_len = compressed.len;
                        const ratio = if (comp_len > 0) produced / comp_len else produced;
                        return .{ .exceeded_limit = .{
                            .bytes_produced = produced,
                            .compressed_len = comp_len,
                            .ratio = ratio,
                        } };
                    }
                    output = allocator.realloc(output, new_size) catch {
                        allocator.free(output);
                        return .alloc_error;
                    };
                    stream.next_out = output.ptr + stream.total_out;
                    stream.avail_out = @intCast(output.len - stream.total_out);
                } else if (stream.avail_in == 0) {
                    // No more input but not at stream end — truncated
                    allocator.free(output);
                    return .data_error;
                }
            },
            c.Z_DATA_ERROR => {
                allocator.free(output);
                return .data_error;
            },
            c.Z_MEM_ERROR => {
                allocator.free(output);
                return .alloc_error;
            },
            else => {
                allocator.free(output);
                return .data_error;
            },
        }
    }
}

/// Ratio-aware raw deflate decompression (no zlib header).
pub fn inflateRawAllocWithRatio(allocator: Allocator, compressed: []const u8, max_output_size: usize) DecompressResult {
    // Same as inflateZlibAllocWithRatio but uses inflateInit2 with -15 (raw deflate)
    var stream: c.z_stream = .{
        .next_in = @constCast(compressed.ptr),
        .avail_in = @intCast(compressed.len),
        .next_out = undefined,
        .avail_out = 0,
        .zalloc = null,
        .zfree = null,
        .@"opaque" = null,
        .total_in = 0,
        .total_out = 0,
        .msg = null,
        .state = null,
        .data_type = 0,
        .adler = 0,
        .reserved = 0,
    };

    const init_ret = c.inflateInit2(&stream, -15);
    if (init_ret != c.Z_OK) return .data_error;
    defer _ = c.inflateEnd(&stream);

    var output_size: usize = @min(compressed.len * 4, max_output_size);
    if (output_size < 4096) output_size = 4096;

    var output = allocator.alloc(u8, output_size) catch return .alloc_error;
    errdefer allocator.free(output);

    stream.next_out = output.ptr;
    stream.avail_out = @intCast(output.len);

    while (true) {
        const ret = c.inflate(&stream, c.Z_NO_FLUSH);
        switch (ret) {
            c.Z_STREAM_END => {
                const final_size = stream.total_out;
                if (final_size < output.len) {
                    output = allocator.realloc(output, final_size) catch output;
                }
                return .{ .ok = output[0..final_size] };
            },
            c.Z_OK, c.Z_BUF_ERROR => {
                if (stream.avail_out == 0) {
                    const new_size = output.len * 2;
                    if (new_size > max_output_size) {
                        allocator.free(output);
                        const produced: usize = stream.total_out;
                        const comp_len = compressed.len;
                        const ratio = if (comp_len > 0) produced / comp_len else produced;
                        return .{ .exceeded_limit = .{
                            .bytes_produced = produced,
                            .compressed_len = comp_len,
                            .ratio = ratio,
                        } };
                    }
                    output = allocator.realloc(output, new_size) catch {
                        allocator.free(output);
                        return .alloc_error;
                    };
                    stream.next_out = output.ptr + stream.total_out;
                    stream.avail_out = @intCast(output.len - stream.total_out);
                } else if (stream.avail_in == 0) {
                    allocator.free(output);
                    return .data_error;
                }
            },
            c.Z_DATA_ERROR => {
                allocator.free(output);
                return .data_error;
            },
            c.Z_MEM_ERROR => {
                allocator.free(output);
                return .alloc_error;
            },
            else => {
                allocator.free(output);
                return .data_error;
            },
        }
    }
}

/// Helper: compress data with zlib format (for tests).
pub fn deflateZlib(input: []const u8, output: []u8) ZlibError![]const u8 {
    var stream: c.z_stream = .{
        .next_in = @constCast(input.ptr),
        .avail_in = @intCast(input.len),
        .next_out = output.ptr,
        .avail_out = @intCast(output.len),
        .zalloc = null,
        .zfree = null,
        .@"opaque" = null,
        .total_in = 0,
        .total_out = 0,
        .msg = null,
        .state = null,
        .data_type = 0,
        .adler = 0,
        .reserved = 0,
    };
    const init_ret = c.deflateInit(&stream, c.Z_DEFAULT_COMPRESSION);
    if (init_ret != c.Z_OK) return ZlibError.InitFailed;
    defer _ = c.deflateEnd(&stream);

    const ret = c.deflate(&stream, c.Z_FINISH);
    if (ret != c.Z_STREAM_END) return ZlibError.ZlibError;

    return output[0..stream.total_out];
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `nix build ".#checks.aarch64-darwin.test" 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/core/zlib.zig
git commit -m "Add ratio-aware decompression: DecompressResult type + inflateWithRatio variants"
```

---

### Task 2: Update `pdf_font_validator.zig` to use ratio-aware decompression

**Files:**
- Modify: `src/core/pdf_font_validator.zig`

**Changes:**
- Replace `decompressFlate` returning `?[]u8` with version using `DecompressResult`
- Track skip reason: `skipped_size_limit` vs `skipped_corrupt` vs `skipped_other`
- Add `skipped_size_limit` and `skipped_corrupt` fields to `FontValidationSummary`

- [ ] **Step 1: Write the failing test**

Add test that verifies `FontValidationSummary` has the new fields:

```zig
test "FontValidationSummary tracks skip reasons" {
    const summary = FontValidationSummary.ok(10, 8, 2);
    // Existing fields still work
    try std.testing.expectEqual(@as(u32, 10), summary.total_fonts);
    try std.testing.expectEqual(@as(u32, 8), summary.validated);
    try std.testing.expectEqual(@as(u32, 2), summary.skipped);
    try std.testing.expect(summary.valid);

    // New: skip reason tracking
    const summary2 = FontValidationSummary{
        .total_fonts = 5,
        .validated = 2,
        .skipped = 3,
        .skipped_size_limit = 1,
        .skipped_corrupt = 1,
        .failed = 0,
        .valid = true,
        .error_message = null,
    };
    try std.testing.expectEqual(@as(u32, 1), summary2.skipped_size_limit);
    try std.testing.expectEqual(@as(u32, 1), summary2.skipped_corrupt);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nix build ".#checks.aarch64-darwin.test" 2>&1 | tail -20`
Expected: FAIL — `skipped_size_limit` field doesn't exist.

- [ ] **Step 3: Implement changes**

In `FontValidationSummary` struct, add:
```zig
skipped_size_limit: u32 = 0, // Streams that exceeded decompression size limit (legitimate large data)
skipped_corrupt: u32 = 0,    // Streams with suspicious compression ratio (likely corruption/bomb)
```

Update `ok()` and `withWarnings()` constructors to initialize these to 0.

Replace `decompressFlate` function body:
```zig
fn decompressFlate(allocator: Allocator, compressed: []const u8) DecompressFlateResult {
    const max_output: usize = 64 * 1024 * 1024; // 64MB max for fonts

    // Try zlib format first
    switch (zlib.inflateZlibAllocWithRatio(allocator, compressed, max_output)) {
        .ok => |data| return .{ .ok = data },
        .exceeded_limit => |info| {
            if (info.ratio > 100) return .corrupt;
            return .exceeded_limit;
        },
        .data_error => {},  // Fall through to raw deflate
        .alloc_error => return .alloc_error,
    }

    // Try raw deflate
    switch (zlib.inflateRawAllocWithRatio(allocator, compressed, max_output)) {
        .ok => |data| return .{ .ok = data },
        .exceeded_limit => |info| {
            if (info.ratio > 100) return .corrupt;
            return .exceeded_limit;
        },
        .data_error => return .data_error,
        .alloc_error => return .alloc_error,
    }
}

const DecompressFlateResult = union(enum) {
    ok: []u8,
    exceeded_limit,
    corrupt,
    data_error,
    alloc_error,
};
```

Update the loop in `validatePdfFonts` to use the new result:
```zig
const decoded: DecompressFlateResult = switch (filter) {
    .flate_decode => decompressFlate(allocator, stream_data),
    // ... other filters unchanged, wrapped as .ok or .data_error
};
switch (decoded) {
    .ok => |d| { decompressed_data = d; break :blk d; },
    .exceeded_limit => { skipped += 1; skipped_size_limit += 1; continue; },
    .corrupt => { failed += 1; if (first_error == null) first_error = "FlateDecode corruption (decompression bomb ratio >100:1)"; continue; },
    .data_error => { skipped += 1; continue; },
    .alloc_error => { skipped += 1; continue; },
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `nix build ".#checks.aarch64-darwin.test" 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/core/pdf_font_validator.zig
git commit -m "PDF font validator: ratio-aware decompression, track skip reasons"
```

---

### Task 3: Update `pdf_image_validator.zig` to use ratio-aware decompression

**Files:**
- Modify: `src/core/pdf_image_validator.zig`

Same pattern as Task 2 but for images. The image validator's `decompressFlate` already returns `![]u8` (error union, not optional), so the change is slightly different.

- [ ] **Step 1: Write failing test**

```zig
test "PdfImageValidationResult tracks skip reasons" {
    const result = PdfImageValidationResult{
        .valid = true,
        .total_images = 10,
        .validated_images = 7,
        .failed_images = 0,
        .skipped_images = 3,
        .skipped_size_limit = 2,
        .skipped_corrupt = 1,
        .results = &.{},
        .error_message = null,
    };
    try std.testing.expectEqual(@as(u32, 2), result.skipped_size_limit);
    try std.testing.expectEqual(@as(u32, 1), result.skipped_corrupt);
}
```

- [ ] **Step 2: Run test — FAIL**
- [ ] **Step 3: Implement** — same pattern: add fields to result struct, update `decompressFlate`, update callers in `validatePdfImagesImpl` and `validatePdfImagesParallel`.
- [ ] **Step 4: Run tests — PASS**
- [ ] **Step 5: Commit**

```bash
git add src/core/pdf_image_validator.zig
git commit -m "PDF image validator: ratio-aware decompression, track skip reasons"
```

---

### Task 4: Update `pdf_embedded_file_validator.zig` to use ratio-aware decompression

**Files:**
- Modify: `src/core/pdf_embedded_file_validator.zig`

Same pattern for embedded files.

- [ ] **Step 1: Write failing test**

```zig
test "EmbeddedFileValidationSummary tracks skip reasons" {
    const summary = EmbeddedFileValidationSummary{
        .total_files = 5,
        .validated = 3,
        .skipped = 2,
        .skipped_size_limit = 1,
        .skipped_corrupt = 1,
        .failed = 0,
        .valid = true,
        .error_message = null,
    };
    try std.testing.expectEqual(@as(u32, 1), summary.skipped_size_limit);
}
```

- [ ] **Step 2: Run test — FAIL**
- [ ] **Step 3: Implement** — add fields, update `decompressFlate`, update both `validatePdfEmbeddedFiles` and `validatePdfEmbeddedFilesBasic`.
- [ ] **Step 4: Run tests — PASS**
- [ ] **Step 5: Commit**

```bash
git add src/core/pdf_embedded_file_validator.zig
git commit -m "PDF embedded file validator: ratio-aware decompression, track skip reasons"
```

---

### Task 5: Depth downgrade in `pdf_validator.zig` when streams are skipped

**Files:**
- Modify: `src/core/pdf_validator.zig`

This is the top-level change: when any sub-validator reports `skipped_size_limit > 0`, downgrade from `.full` to `.structural` with a warning.

- [ ] **Step 1: Write failing test**

Add to `pdf_validator.zig` tests:

```zig
test "validatePdfDeep: skipped streams downgrade depth to structural" {
    // This test verifies the depth downgrade logic.
    // We need a PDF with a stream that exceeds the size limit.
    // For unit testing, we test the decision logic directly.

    // Test the helper that determines depth from sub-validator results
    const font_summary = pdf_font_validator.FontValidationSummary{
        .total_fonts = 5,
        .validated = 4,
        .skipped = 1,
        .skipped_size_limit = 1,
        .skipped_corrupt = 0,
        .failed = 0,
        .valid = true,
        .error_message = null,
    };
    const depth = pdfDeepValidationDepth(font_summary, .{}, .{});
    try std.testing.expectEqual(ValidationDepth.structural, depth.depth);
    try std.testing.expect(depth.warning != null);
    try std.testing.expect(std.mem.indexOf(u8, depth.warning.?, "skipped") != null);
}
```

- [ ] **Step 2: Run test — FAIL** (`pdfDeepValidationDepth` doesn't exist)

- [ ] **Step 3: Implement depth decision helper and wire into `validatePdfDeep`**

```zig
const DepthDecision = struct {
    depth: format_validation.ValidationDepth,
    warning: ?[]const u8,
};

/// Determine validation depth based on sub-validator skip/corruption counts.
/// Any skipped-due-to-size-limit streams means we can't claim full validation.
/// Any corruption-ratio streams are already counted as failures by sub-validators.
fn pdfDeepValidationDepth(
    font_result: pdf_font_validator.FontValidationSummary,
    image_result: pdf_image_validator.PdfImageValidationResult,
    embed_result: pdf_embedded_file_validator.EmbeddedFileValidationSummary,
) DepthDecision {
    const total_size_limit = font_result.skipped_size_limit +
        image_result.skipped_size_limit +
        embed_result.skipped_size_limit;

    if (total_size_limit > 0) {
        return .{
            .depth = .structural,
            .warning = "some streams skipped (exceeded decompression size limit); full validation not possible",
        };
    }

    return .{ .depth = .full, .warning = null };
}
```

In `validatePdfDeep`, after all three sub-validators run (line ~548), call `pdfDeepValidationDepth` and use its result for the final `validation_depth` field instead of hardcoding `.full`.

- [ ] **Step 4: Run tests — PASS**

- [ ] **Step 5: Also verify the corruption case (ratio > 100:1) results in FAIL**

The sub-validators already count `corrupt` as `failed`, so `!font_result.valid` etc. will trigger the existing FAIL paths. No extra logic needed — just verify with a test that the existing pipeline handles it.

- [ ] **Step 6: Commit**

```bash
git add src/core/pdf_validator.zig
git commit -m "PDF deep validation: downgrade depth to structural when streams exceed size limit"
```

---

### Task 6: Update docs and ship

**Files:**
- Modify: `PLAN.md`
- Modify: `CODE_MINIMAP.md`

- [ ] **Step 1: Update PLAN.md** — add completed checkbox for decompression honesty
- [ ] **Step 2: Update CODE_MINIMAP.md** — note ratio-aware decompression in zlib.zig entry
- [ ] **Step 3: Run full test suite**

Run: `nix build ".#checks.aarch64-darwin.test" 2>&1 | tail -20`
Expected: PASS, all tests green

- [ ] **Step 4: Commit and push**

```bash
git add PLAN.md CODE_MINIMAP.md
git commit -m "Update docs for decompression honesty feature"
git push origin HEAD
```

---

## Future Extension (not in scope)

Other decompressors that should adopt `DecompressResult` pattern:
- `bzip2.zig` — used by bzip2 validator, DMG
- `lzw_decoder.zig` — used by PDF, GIF, TIFF
- `lzma`/7z codecs — used by 7z, XZ
- ZIP entry decompression in `archive_validators.zig`

Each adoption follows the same pattern: replace size-limit error with ratio check, propagate skip reason to caller's summary, downgrade depth when skips occur.
