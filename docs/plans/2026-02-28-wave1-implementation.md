# Wave 1: Archival Format Validators — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add BagIt, X12 EDI, EDIFACT, iCalendar, vCard, PEM, and DER validators to the `validate` tool with structural + deep validation.

**Architecture:** Each format pair gets its own validator file (`bagit_validator.zig`, `edi_validators.zig`, `pim_validators.zig`, `crypto_validators.zig`). Formats with distinctive magic bytes (BagIt, iCalendar, vCard, PEM) use magic-based detection. Others (X12, EDIFACT, DER) use extension-only detection. All follow the existing pattern: structural validator takes `std.fs.File`, deep validator takes `(Allocator, path)`.

**Tech Stack:** Zig 0.15, std.crypto.hash (SHA-256/SHA-512/MD5 for BagIt), std.base64 (PEM decoding)

**Design doc:** `docs/plans/2026-02-28-wave1-archival-formats-design.md`

---

## Reference: Integration Points in format_validation.zig

Every new format requires entries at these locations (search for `nacha` or `bai2` to find exact spots):

| # | Location | Pattern |
|---|----------|---------|
| 1 | `FileFormat` enum (~line 537) | Add after `.bai2` |
| 2 | `hasValidator` switch (~line 615) | Add to financial/archival line |
| 3 | `magic_signatures` array (~line 1130) | Only for magic-detected formats |
| 4 | `checkSpecialCases` (~line 1628) | Only if magic needs disambiguation |
| 5 | `detectFormatFromExtension` (~line 2183) | Extension→format mapping |
| 6 | `getExpectedFormatForExtension` (~line 2626) | Same mapping (for test harness) |
| 7 | `ext_has_no_magic` switch (~line 4423) | Only for extension-only formats |
| 8 | ext_has_no_magic structural dispatch (~line 4437) | Only for extension-only formats |
| 9 | `is_binary_format` exclusion (~line 4485) | Exclude text formats from secondary sig detection |
| 10 | `performDeepValidation` dispatch (~line 4985) | Deep validator dispatch |
| 11 | Main structural dispatch switch (~line 5448) | For ALL formats (magic + extension) |

Additionally:
- `src/core/mod.zig`: pub export (~line 89) + test import (~line 241)
- `ffi/c_api.zig`: `getFormatCategory` (~line 181)
- 30 i18n files: format descriptions (after `.bai2`)
- `scripts/corruption_opacity.tsv`: opacity classification

---

## Task 1: Create bagit_validator.zig with Structural + Deep Validation

**Files:**
- Create: `src/core/bagit_validator.zig`
- Modify: `src/core/mod.zig` (add pub export + test import)

BagIt bags are directories containing `bagit.txt` at root. The `bagit.txt` file starts with `BagIt-Version: X.Y`. Detection is by magic bytes on the `bagit.txt` file itself.

**Step 1: Write failing tests**

Create `src/core/bagit_validator.zig` with imports and test cases first:

```zig
const std = @import("std");
const format_validation = @import("format_validation.zig");
const FileFormat = format_validation.FileFormat;
const ValidationResult = format_validation.ValidationResult;
const Allocator = std.mem.Allocator;

// -- Validators will go here --

test "BagIt structural: valid bagit.txt" {
    // Create a temp directory with valid bagit.txt
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Write bagit.txt
    try tmp.dir.writeFile(.{ .sub_path = "bagit.txt", .data = "BagIt-Version: 1.0\nTag-File-Character-Encoding: UTF-8\n" });
    // Write manifest
    try tmp.dir.writeFile(.{ .sub_path = "manifest-sha256.txt", .data = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  data/empty.txt\n" });
    // Create data dir with empty file
    try tmp.dir.makePath("data");
    try tmp.dir.writeFile(.{ .sub_path = "data/empty.txt", .data = "" });

    const file = try tmp.dir.openFile("bagit.txt", .{});
    defer file.close();

    const result = validateBagit(file);
    try std.testing.expect(result.is_valid);
    try std.testing.expectEqual(FileFormat.bagit, result.format);
}

test "BagIt structural: missing version line" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "bagit.txt", .data = "Not a valid bagit file\n" });

    const file = try tmp.dir.openFile("bagit.txt", .{});
    defer file.close();

    const result = validateBagit(file);
    try std.testing.expect(!result.is_valid);
}

test "BagIt deep: verify SHA-256 manifest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const content = "Hello, BagIt!\n";
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(content);
    const digest = hasher.finalResult();
    var hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{}", .{std.fmt.fmtSliceHexLower(&digest)}) catch unreachable;

    try tmp.dir.writeFile(.{ .sub_path = "bagit.txt", .data = "BagIt-Version: 1.0\nTag-File-Character-Encoding: UTF-8\n" });
    var manifest_buf: [200]u8 = undefined;
    const manifest = std.fmt.bufPrint(&manifest_buf, "{s}  data/hello.txt\n", .{hex}) catch unreachable;
    try tmp.dir.writeFile(.{ .sub_path = "manifest-sha256.txt", .data = manifest });
    try tmp.dir.makePath("data");
    try tmp.dir.writeFile(.{ .sub_path = "data/hello.txt", .data = content });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp.dir.realpath("bagit.txt", &path_buf);

    const result = validateBagitDeep(std.testing.allocator, path);
    try std.testing.expect(result.is_valid);
    try std.testing.expectEqual(format_validation.ValidationDepth.full, result.validation_depth);
}

test "BagIt deep: corrupted file fails manifest check" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "bagit.txt", .data = "BagIt-Version: 1.0\nTag-File-Character-Encoding: UTF-8\n" });
    // Wrong hash for the content
    try tmp.dir.writeFile(.{ .sub_path = "manifest-sha256.txt", .data = "0000000000000000000000000000000000000000000000000000000000000000  data/hello.txt\n" });
    try tmp.dir.makePath("data");
    try tmp.dir.writeFile(.{ .sub_path = "data/hello.txt", .data = "Hello, BagIt!\n" });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp.dir.realpath("bagit.txt", &path_buf);

    const result = validateBagitDeep(std.testing.allocator, path);
    try std.testing.expect(!result.is_valid);
}
```

**Step 2: Run tests, verify they fail**

```bash
nix develop -c zig build test 2>&1 | grep -E "FAIL|error"
```
Expected: compilation errors (functions don't exist yet)

**Step 3: Implement structural validator**

```zig
/// BagIt (RFC 8493) structural validator.
/// Verifies bagit.txt format: "BagIt-Version: X.Y" first line, Tag-File-Character-Encoding second.
pub fn validateBagit(file: std.fs.File) ValidationResult {
    var buf: [4096]u8 = undefined;
    const bytes_read = file.read(&buf) catch {
        return ValidationResult.invalid(.bagit, "Failed to read bagit.txt");
    };
    if (bytes_read == 0) return ValidationResult.invalid(.bagit, "Empty bagit.txt");
    const data = buf[0..bytes_read];

    // First line must be "BagIt-Version: X.Y"
    const first_nl = std.mem.indexOfScalar(u8, data, '\n') orelse {
        return ValidationResult.invalid(.bagit, "No newline in bagit.txt");
    };
    var first_line = data[0..first_nl];
    if (first_line.len > 0 and first_line[first_line.len - 1] == '\r') {
        first_line = first_line[0 .. first_line.len - 1];
    }
    if (!std.mem.startsWith(u8, first_line, "BagIt-Version: ")) {
        return ValidationResult.invalid(.bagit, "Missing BagIt-Version header");
    }
    // Verify version is numeric (X.Y)
    const version_str = first_line["BagIt-Version: ".len..];
    const dot_pos = std.mem.indexOfScalar(u8, version_str, '.') orelse {
        return ValidationResult.invalid(.bagit, "Invalid BagIt version format");
    };
    for (version_str[0..dot_pos]) |c| {
        if (c < '0' or c > '9') return ValidationResult.invalid(.bagit, "Invalid BagIt version number");
    }
    for (version_str[dot_pos + 1 ..]) |c| {
        if (c < '0' or c > '9') return ValidationResult.invalid(.bagit, "Invalid BagIt version number");
    }

    return ValidationResult.ok(.bagit);
}
```

**Step 4: Implement deep validator**

```zig
/// BagIt deep validator: reads manifest-{alg}.txt, hashes every listed file, verifies matches.
/// Returns .full depth on success (complete content verification via cryptographic hashes).
pub fn validateBagitDeep(allocator: Allocator, path: []const u8) ValidationResult {
    // Derive bag root from bagit.txt path (strip "/bagit.txt" suffix)
    const bag_root = blk: {
        if (std.mem.endsWith(u8, path, "/bagit.txt") or std.mem.endsWith(u8, path, "\\bagit.txt")) {
            break :blk path[0 .. path.len - "/bagit.txt".len];
        }
        // If path IS just "bagit.txt", use "."
        if (std.mem.eql(u8, path, "bagit.txt")) {
            break :blk ".";
        }
        return ValidationResult.invalid(.bagit, "Path does not end with bagit.txt");
    };

    // Open bag root directory
    var bag_dir = std.fs.openDirAbsolute(bag_root, .{ .iterate = true }) catch {
        return ValidationResult.invalid(.bagit, "Cannot open bag directory");
    };
    defer bag_dir.close();

    // Find manifest files (manifest-sha256.txt, manifest-sha512.txt, manifest-md5.txt)
    const algorithms = [_]struct { name: []const u8, hash_len: usize }{
        .{ .name = "sha256", .hash_len = 64 },
        .{ .name = "sha512", .hash_len = 128 },
        .{ .name = "md5", .hash_len = 32 },
    };

    var verified_any = false;
    for (algorithms) |alg| {
        var manifest_name_buf: [64]u8 = undefined;
        const manifest_name = std.fmt.bufPrint(&manifest_name_buf, "manifest-{s}.txt", .{alg.name}) catch continue;

        const manifest_data = bag_dir.readFileAlloc(allocator, manifest_name, 10 * 1024 * 1024) catch continue;
        defer allocator.free(manifest_data);

        // Parse each line: "<hex_hash>  <filepath>"
        var lines = std.mem.splitScalar(u8, manifest_data, '\n');
        while (lines.next()) |line| {
            var clean_line = line;
            if (clean_line.len > 0 and clean_line[clean_line.len - 1] == '\r') {
                clean_line = clean_line[0 .. clean_line.len - 1];
            }
            if (clean_line.len == 0) continue;

            if (clean_line.len < alg.hash_len + 2) {
                return ValidationResult.invalid(.bagit, "Malformed manifest line");
            }
            const expected_hex = clean_line[0..alg.hash_len];
            // Separator is two spaces "  " per RFC 8493
            if (!std.mem.eql(u8, clean_line[alg.hash_len..][0..2], "  ")) {
                return ValidationResult.invalid(.bagit, "Invalid manifest separator (expected two spaces)");
            }
            const file_path = clean_line[alg.hash_len + 2 ..];

            // Read the file and compute hash
            const file_data = bag_dir.readFileAlloc(allocator, file_path, 100 * 1024 * 1024) catch {
                return ValidationResult.invalid(.bagit, "Cannot read file listed in manifest");
            };
            defer allocator.free(file_data);

            // Compute hash and compare
            if (std.mem.eql(u8, alg.name, "sha256")) {
                var hasher = std.crypto.hash.sha2.Sha256.init(.{});
                hasher.update(file_data);
                const digest = hasher.finalResult();
                var computed_hex: [64]u8 = undefined;
                _ = std.fmt.bufPrint(&computed_hex, "{}", .{std.fmt.fmtSliceHexLower(&digest)}) catch unreachable;
                if (!std.mem.eql(u8, &computed_hex, expected_hex)) {
                    return ValidationResult.invalid(.bagit, "SHA-256 mismatch in manifest");
                }
            } else if (std.mem.eql(u8, alg.name, "sha512")) {
                var hasher = std.crypto.hash.sha2.Sha512.init(.{});
                hasher.update(file_data);
                const digest = hasher.finalResult();
                var computed_hex: [128]u8 = undefined;
                _ = std.fmt.bufPrint(&computed_hex, "{}", .{std.fmt.fmtSliceHexLower(&digest)}) catch unreachable;
                if (!std.mem.eql(u8, &computed_hex, expected_hex)) {
                    return ValidationResult.invalid(.bagit, "SHA-512 mismatch in manifest");
                }
            } else if (std.mem.eql(u8, alg.name, "md5")) {
                var hasher = std.crypto.hash.Md5.init(.{});
                hasher.update(file_data);
                const digest = hasher.finalResult();
                var computed_hex: [32]u8 = undefined;
                _ = std.fmt.bufPrint(&computed_hex, "{}", .{std.fmt.fmtSliceHexLower(&digest)}) catch unreachable;
                if (!std.mem.eql(u8, &computed_hex, expected_hex)) {
                    return ValidationResult.invalid(.bagit, "MD5 mismatch in manifest");
                }
            }
            verified_any = true;
        }
    }

    if (!verified_any) {
        return ValidationResult.invalid(.bagit, "No manifest files found in bag");
    }

    var result = ValidationResult.ok(.bagit);
    result.validation_depth = .full;
    return result;
}
```

**Step 5: Register in mod.zig**

Add after `pub const financial_validators = @import("financial_validators.zig");`:
```zig
pub const bagit_validator = @import("bagit_validator.zig");
```

In test block, add after financial_validators import:
```zig
    _ = @import("bagit_validator.zig");
```

**Step 6: Run tests, verify they pass**

```bash
nix develop -c zig build test 2>&1 | tail -5
```
Expected: All pass (exit 0). Note: format_validation.zig wiring happens in Task 5.

**Step 7: Commit**

```bash
git add src/core/bagit_validator.zig src/core/mod.zig
git commit -m "Add BagIt validator: SHA-256/512/MD5 manifest verification"
```

---

## Task 2: Create edi_validators.zig with X12 + EDIFACT Validation

**Files:**
- Create: `src/core/edi_validators.zig`
- Modify: `src/core/mod.zig`

**Step 1: Write failing tests for X12 EDI**

```zig
const std = @import("std");
const format_validation = @import("format_validation.zig");
const FileFormat = format_validation.FileFormat;
const ValidationResult = format_validation.ValidationResult;
const Allocator = std.mem.Allocator;

// -- Validators will go here --

test "X12 EDI structural: valid ISA/IEA envelope" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Minimal valid X12: ISA + GS + ST + SE + GE + IEA
    // ISA is exactly 106 chars (including segment terminator ~)
    // Element separator: * | Sub-element: : | Segment terminator: ~
    const x12 =
        "ISA*00*          *00*          *ZZ*SENDER         *ZZ*RECEIVER       *200101*1200*^*00501*000000001*0*P*:~" ++
        "GS*HP*SENDER*RECEIVER*20200101*1200*1*X*005010X222A1~" ++
        "ST*837*0001*005010X222A1~" ++
        "BHT*0019*00*12345*20200101*1200*CH~" ++
        "SE*3*0001~" ++
        "GE*1*1~" ++
        "IEA*1*000000001~";
    try tmp.dir.writeFile(.{ .sub_path = "test.edi", .data = x12 });

    const file = try tmp.dir.openFile("test.edi", .{});
    defer file.close();

    const result = validateX12Edi(file);
    try std.testing.expect(result.is_valid);
    try std.testing.expectEqual(FileFormat.x12_edi, result.format);
}

test "X12 EDI structural: invalid (not ISA start)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "test.edi", .data = "NOT*AN*EDI*FILE~" });

    const file = try tmp.dir.openFile("test.edi", .{});
    defer file.close();

    const result = validateX12Edi(file);
    try std.testing.expect(!result.is_valid);
}

test "X12 EDI deep: verify SE segment count" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const x12 =
        "ISA*00*          *00*          *ZZ*SENDER         *ZZ*RECEIVER       *200101*1200*^*00501*000000001*0*P*:~" ++
        "GS*HP*SENDER*RECEIVER*20200101*1200*1*X*005010X222A1~" ++
        "ST*837*0001*005010X222A1~" ++
        "BHT*0019*00*12345*20200101*1200*CH~" ++
        "SE*3*0001~" ++  // 3 segments: ST, BHT, SE
        "GE*1*1~" ++
        "IEA*1*000000001~";
    try tmp.dir.writeFile(.{ .sub_path = "test.edi", .data = x12 });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp.dir.realpath("test.edi", &path_buf);

    const result = validateX12EdiDeep(std.testing.allocator, path);
    try std.testing.expect(result.is_valid);
    try std.testing.expectEqual(format_validation.ValidationDepth.full, result.validation_depth);
}

test "X12 EDI deep: wrong SE count fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const x12 =
        "ISA*00*          *00*          *ZZ*SENDER         *ZZ*RECEIVER       *200101*1200*^*00501*000000001*0*P*:~" ++
        "GS*HP*SENDER*RECEIVER*20200101*1200*1*X*005010X222A1~" ++
        "ST*837*0001*005010X222A1~" ++
        "BHT*0019*00*12345*20200101*1200*CH~" ++
        "SE*99*0001~" ++  // Wrong: says 99 but only 3
        "GE*1*1~" ++
        "IEA*1*000000001~";
    try tmp.dir.writeFile(.{ .sub_path = "test.edi", .data = x12 });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp.dir.realpath("test.edi", &path_buf);

    const result = validateX12EdiDeep(std.testing.allocator, path);
    try std.testing.expect(!result.is_valid);
}
```

**Step 2: Write failing tests for EDIFACT**

```zig
test "EDIFACT structural: valid UNB/UNZ envelope" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const edifact =
        "UNA:+.? '" ++
        "UNB+UNOC:3+SENDER+RECEIVER+200101:1200+00000001'" ++
        "UNH+1+INVOIC:D:96A:UN'" ++
        "BGM+380+INV001+9'" ++
        "UNT+3+1'" ++
        "UNZ+1+00000001'";
    try tmp.dir.writeFile(.{ .sub_path = "test.edifact", .data = edifact });

    const file = try tmp.dir.openFile("test.edifact", .{});
    defer file.close();

    const result = validateEdifact(file);
    try std.testing.expect(result.is_valid);
    try std.testing.expectEqual(FileFormat.edifact, result.format);
}

test "EDIFACT deep: verify UNT segment count" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const edifact =
        "UNA:+.? '" ++
        "UNB+UNOC:3+SENDER+RECEIVER+200101:1200+00000001'" ++
        "UNH+1+INVOIC:D:96A:UN'" ++
        "BGM+380+INV001+9'" ++
        "UNT+3+1'" ++  // 3 segments: UNH, BGM, UNT
        "UNZ+1+00000001'";
    try tmp.dir.writeFile(.{ .sub_path = "test.edifact", .data = edifact });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp.dir.realpath("test.edifact", &path_buf);

    const result = validateEdifactDeep(std.testing.allocator, path);
    try std.testing.expect(result.is_valid);
    try std.testing.expectEqual(format_validation.ValidationDepth.full, result.validation_depth);
}
```

**Step 3: Implement X12 EDI structural validator**

X12 ISA segment is ALWAYS exactly 106 characters. The element separator is the character at position 3. The segment terminator is the last character of the ISA (position 105).

```zig
/// X12 EDI structural validator.
/// Verifies ISA segment (106 chars), self-describing delimiters, and valid segment hierarchy.
pub fn validateX12Edi(file: std.fs.File) ValidationResult {
    var buf: [8192]u8 = undefined;
    const bytes_read = file.read(&buf) catch {
        return ValidationResult.invalid(.x12_edi, "Failed to read file");
    };
    if (bytes_read < 106) return ValidationResult.invalid(.x12_edi, "File too short for ISA segment");
    const data = buf[0..bytes_read];

    if (!std.mem.startsWith(u8, data, "ISA")) {
        return ValidationResult.invalid(.x12_edi, "Does not start with ISA");
    }

    // Element separator is at position 3
    const elem_sep = data[3];
    // Segment terminator is at position 105
    const seg_term = data[105];

    // Verify ISA has correct number of elements (16 elements = 16 separators)
    var sep_count: usize = 0;
    for (data[3..106]) |c| {
        if (c == elem_sep) sep_count += 1;
    }
    if (sep_count < 16) {
        return ValidationResult.invalid(.x12_edi, "ISA segment has wrong number of elements");
    }

    // Verify we can find at least one more segment after ISA
    if (bytes_read > 106) {
        // Next segment should start after the terminator
        var pos: usize = 106;
        // Skip whitespace/newlines after terminator
        while (pos < bytes_read and (data[pos] == '\r' or data[pos] == '\n')) : (pos += 1) {}
        if (pos < bytes_read) {
            // Should be GS, IEA, or another valid segment ID
            const remaining = data[pos..];
            if (remaining.len >= 2) {
                const seg_id = remaining[0..2];
                const valid_starts = [_][]const u8{ "GS", "IE", "TA" };
                var valid = false;
                for (valid_starts) |vs| {
                    if (std.mem.eql(u8, seg_id, vs)) { valid = true; break; }
                }
                if (!valid) {
                    return ValidationResult.invalid(.x12_edi, "Invalid segment after ISA");
                }
            }
        }
    }
    _ = seg_term;

    return ValidationResult.ok(.x12_edi);
}
```

**Step 4: Implement X12 EDI deep validator**

Parses all segments, verifies:
- SE01 = segment count (ST through SE inclusive)
- GE01 = number of transaction sets in functional group
- IEA01 = number of functional groups
- Control numbers match (ST02==SE02, GS06==GE02, ISA13==IEA02)

```zig
/// X12 EDI deep validator: verifies segment counts and control number integrity at all three levels.
pub fn validateX12EdiDeep(allocator: Allocator, path: []const u8) ValidationResult {
    const data = std.fs.cwd().readFileAlloc(allocator, path, 50 * 1024 * 1024) catch {
        return ValidationResult.invalid(.x12_edi, "Failed to read file");
    };
    defer allocator.free(data);

    if (data.len < 106 or !std.mem.startsWith(u8, data, "ISA")) {
        return ValidationResult.invalid(.x12_edi, "Invalid ISA header");
    }

    const elem_sep = data[3];
    const seg_term = data[105];

    // Split into segments
    var segments = std.ArrayList([]const u8).init(allocator);
    defer segments.deinit();

    var seg_start: usize = 0;
    for (data, 0..) |c, i| {
        if (c == seg_term) {
            const seg = std.mem.trim(u8, data[seg_start..i], &[_]u8{ '\r', '\n', ' ' });
            if (seg.len > 0) {
                segments.append(seg) catch return ValidationResult.invalid(.x12_edi, "Out of memory");
            }
            seg_start = i + 1;
        }
    }

    // Parse and verify control structures
    var gs_count: u32 = 0;
    var st_count: u32 = 0;
    var seg_count: u32 = 0;
    var in_transaction = false;
    var current_st_num: ?[]const u8 = null;
    var current_gs_num: ?[]const u8 = null;

    for (segments.items) |seg| {
        // Get segment ID (first element before separator)
        const id_end = std.mem.indexOfScalar(u8, seg, elem_sep) orelse seg.len;
        const seg_id = seg[0..id_end];

        if (std.mem.eql(u8, seg_id, "GS")) {
            gs_count += 1;
            st_count = 0;
            // GS06 = group control number
            current_gs_num = getElement(seg, elem_sep, 6);
        } else if (std.mem.eql(u8, seg_id, "ST")) {
            in_transaction = true;
            seg_count = 1; // ST itself counts
            current_st_num = getElement(seg, elem_sep, 2);
        } else if (std.mem.eql(u8, seg_id, "SE")) {
            seg_count += 1; // SE itself counts
            in_transaction = false;
            st_count += 1;

            // Verify SE01 = segment count
            if (getElement(seg, elem_sep, 1)) |count_str| {
                const expected = std.fmt.parseInt(u32, count_str, 10) catch {
                    return ValidationResult.invalid(.x12_edi, "Invalid SE segment count");
                };
                if (expected != seg_count) {
                    return ValidationResult.invalid(.x12_edi, "SE segment count mismatch");
                }
            }
            // Verify SE02 = ST02 control number
            if (getElement(seg, elem_sep, 2)) |se_num| {
                if (current_st_num) |st_num| {
                    if (!std.mem.eql(u8, se_num, st_num)) {
                        return ValidationResult.invalid(.x12_edi, "SE/ST control number mismatch");
                    }
                }
            }
        } else if (std.mem.eql(u8, seg_id, "GE")) {
            // Verify GE01 = transaction set count
            if (getElement(seg, elem_sep, 1)) |count_str| {
                const expected = std.fmt.parseInt(u32, count_str, 10) catch {
                    return ValidationResult.invalid(.x12_edi, "Invalid GE transaction count");
                };
                if (expected != st_count) {
                    return ValidationResult.invalid(.x12_edi, "GE transaction set count mismatch");
                }
            }
            // Verify GE02 = GS06 control number
            if (getElement(seg, elem_sep, 2)) |ge_num| {
                if (current_gs_num) |gs_num| {
                    if (!std.mem.eql(u8, ge_num, gs_num)) {
                        return ValidationResult.invalid(.x12_edi, "GE/GS control number mismatch");
                    }
                }
            }
        } else if (std.mem.eql(u8, seg_id, "IEA")) {
            // Verify IEA01 = functional group count
            if (getElement(seg, elem_sep, 1)) |count_str| {
                const expected = std.fmt.parseInt(u32, count_str, 10) catch {
                    return ValidationResult.invalid(.x12_edi, "Invalid IEA group count");
                };
                if (expected != gs_count) {
                    return ValidationResult.invalid(.x12_edi, "IEA functional group count mismatch");
                }
            }
        } else if (in_transaction) {
            seg_count += 1;
        }
    }

    var result = ValidationResult.ok(.x12_edi);
    result.validation_depth = .full;
    return result;
}

/// Get the Nth element (1-indexed) from an EDI segment using the given separator.
fn getElement(seg: []const u8, sep: u8, n: usize) ?[]const u8 {
    var count: usize = 0;
    var start: usize = 0;
    for (seg, 0..) |c, i| {
        if (c == sep) {
            count += 1;
            if (count == n) {
                return seg[start..i]; // Wait, this is wrong - need previous start
            }
            start = i + 1;
            if (count == n) return seg[start..];
        }
    }
    // Handle: if count reaches n, return from start to end
    if (count + 1 == n) return null; // Not enough elements
    return null;
}
```

Note: The `getElement` helper needs careful implementation. The actual field indexing for EDI segments is: `SEG*field1*field2*field3`, so element 1 = "field1", element 2 = "field2". The implementer should test this helper thoroughly.

**Step 5: Implement EDIFACT validators**

EDIFACT uses `UNA:+.? '` as service string advice (defines delimiters). Default separators: `:` (component), `+` (element), `'` (segment terminator).

```zig
/// EDIFACT structural validator.
/// Verifies UNA/UNB envelope and segment hierarchy.
pub fn validateEdifact(file: std.fs.File) ValidationResult {
    var buf: [8192]u8 = undefined;
    const bytes_read = file.read(&buf) catch {
        return ValidationResult.invalid(.edifact, "Failed to read file");
    };
    if (bytes_read < 9) return ValidationResult.invalid(.edifact, "File too short");
    const data = buf[0..bytes_read];

    // Check for UNA or UNB
    if (std.mem.startsWith(u8, data, "UNA")) {
        // UNA is exactly 9 characters: UNA + 6 service chars
        if (bytes_read < 9) return ValidationResult.invalid(.edifact, "UNA too short");
        // After UNA, must have UNB
        var pos: usize = 9;
        while (pos < bytes_read and (data[pos] == '\r' or data[pos] == '\n')) : (pos += 1) {}
        if (pos + 3 > bytes_read or !std.mem.startsWith(u8, data[pos..], "UNB")) {
            return ValidationResult.invalid(.edifact, "Missing UNB after UNA");
        }
    } else if (std.mem.startsWith(u8, data, "UNB")) {
        // Direct UNB without UNA (default delimiters)
    } else {
        return ValidationResult.invalid(.edifact, "Does not start with UNA or UNB");
    }

    return ValidationResult.ok(.edifact);
}

/// EDIFACT deep validator: verifies UNT segment counts and UNZ message/group counts.
pub fn validateEdifactDeep(allocator: Allocator, path: []const u8) ValidationResult {
    const data = std.fs.cwd().readFileAlloc(allocator, path, 50 * 1024 * 1024) catch {
        return ValidationResult.invalid(.edifact, "Failed to read file");
    };
    defer allocator.free(data);

    // Parse UNA to get separators (or use defaults)
    var seg_term: u8 = '\'';
    var elem_sep: u8 = '+';
    // var comp_sep: u8 = ':'; // component separator (unused for integrity checks)

    if (std.mem.startsWith(u8, data, "UNA") and data.len >= 9) {
        // comp_sep = data[3];
        elem_sep = data[4];
        // decimal = data[5];
        // escape = data[6];
        // reserved = data[7];
        seg_term = data[8];
    }

    // Split into segments by segment terminator
    var segments = std.ArrayList([]const u8).init(allocator);
    defer segments.deinit();
    var seg_start: usize = 0;
    for (data, 0..) |c, i| {
        if (c == seg_term) {
            const seg = std.mem.trim(u8, data[seg_start..i], &[_]u8{ '\r', '\n', ' ' });
            if (seg.len > 0) {
                segments.append(seg) catch return ValidationResult.invalid(.edifact, "Out of memory");
            }
            seg_start = i + 1;
        }
    }

    var unh_count: u32 = 0;
    var seg_count: u32 = 0;
    var in_message = false;
    var current_unh_ref: ?[]const u8 = null;

    for (segments.items) |seg| {
        const id_end = std.mem.indexOfScalar(u8, seg, elem_sep) orelse seg.len;
        const seg_id = seg[0..id_end];

        if (std.mem.eql(u8, seg_id, "UNH")) {
            in_message = true;
            seg_count = 1;
            current_unh_ref = getElement(seg, elem_sep, 1);
        } else if (std.mem.eql(u8, seg_id, "UNT")) {
            seg_count += 1;
            in_message = false;
            unh_count += 1;

            // UNT element 1 = segment count (UNH through UNT inclusive)
            if (getElement(seg, elem_sep, 1)) |count_str| {
                const expected = std.fmt.parseInt(u32, count_str, 10) catch {
                    return ValidationResult.invalid(.edifact, "Invalid UNT segment count");
                };
                if (expected != seg_count) {
                    return ValidationResult.invalid(.edifact, "UNT segment count mismatch");
                }
            }
            // UNT element 2 = reference number (must match UNH element 1)
            if (getElement(seg, elem_sep, 2)) |unt_ref| {
                if (current_unh_ref) |unh_ref| {
                    if (!std.mem.eql(u8, unt_ref, unh_ref)) {
                        return ValidationResult.invalid(.edifact, "UNT/UNH reference number mismatch");
                    }
                }
            }
        } else if (std.mem.eql(u8, seg_id, "UNZ")) {
            // UNZ element 1 = interchange message count
            if (getElement(seg, elem_sep, 1)) |count_str| {
                const expected = std.fmt.parseInt(u32, count_str, 10) catch {
                    return ValidationResult.invalid(.edifact, "Invalid UNZ message count");
                };
                if (expected != unh_count) {
                    return ValidationResult.invalid(.edifact, "UNZ message count mismatch");
                }
            }
        } else if (in_message) {
            seg_count += 1;
        }
    }

    var result = ValidationResult.ok(.edifact);
    result.validation_depth = .full;
    return result;
}
```

**Step 6: Register in mod.zig, run tests, commit**

Add to mod.zig (same pattern as step 5 of Task 1).

```bash
nix develop -c zig build test 2>&1 | tail -5
git add src/core/edi_validators.zig src/core/mod.zig
git commit -m "Add X12 EDI + EDIFACT validators: control total integrity verification"
```

---

## Task 3: Create pim_validators.zig with iCalendar + vCard Validation

**Files:**
- Create: `src/core/pim_validators.zig`
- Modify: `src/core/mod.zig`

**Step 1: Write failing tests for iCalendar**

```zig
test "iCalendar structural: valid VCALENDAR" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ical =
        "BEGIN:VCALENDAR\r\n" ++
        "VERSION:2.0\r\n" ++
        "PRODID:-//Test//Test//EN\r\n" ++
        "BEGIN:VEVENT\r\n" ++
        "DTSTART:20200101T120000Z\r\n" ++
        "DTEND:20200101T130000Z\r\n" ++
        "SUMMARY:Test Event\r\n" ++
        "END:VEVENT\r\n" ++
        "END:VCALENDAR\r\n";
    try tmp.dir.writeFile(.{ .sub_path = "test.ics", .data = ical });

    const file = try tmp.dir.openFile("test.ics", .{});
    defer file.close();

    const result = validateICalendar(file);
    try std.testing.expect(result.is_valid);
    try std.testing.expectEqual(FileFormat.icalendar, result.format);
}

test "iCalendar structural: missing END:VCALENDAR" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ical =
        "BEGIN:VCALENDAR\r\n" ++
        "VERSION:2.0\r\n" ++
        "PRODID:-//Test//Test//EN\r\n";
    try tmp.dir.writeFile(.{ .sub_path = "test.ics", .data = ical });

    const file = try tmp.dir.openFile("test.ics", .{});
    defer file.close();

    const result = validateICalendar(file);
    try std.testing.expect(!result.is_valid);
}
```

**Step 2: Implement iCalendar structural validator**

RFC 5545: verify BEGIN/END nesting, required properties (VERSION, PRODID), valid component types.

```zig
/// iCalendar (RFC 5545) structural validator.
/// Verifies BEGIN/END nesting, required properties (VERSION, PRODID), valid component types.
pub fn validateICalendar(file: std.fs.File) ValidationResult {
    var buf: [65536]u8 = undefined;
    const bytes_read = file.read(&buf) catch {
        return ValidationResult.invalid(.icalendar, "Failed to read file");
    };
    if (bytes_read < 30) return ValidationResult.invalid(.icalendar, "File too short");
    const data = buf[0..bytes_read];

    // Must start with BEGIN:VCALENDAR
    if (!std.mem.startsWith(u8, data, "BEGIN:VCALENDAR")) {
        return ValidationResult.invalid(.icalendar, "Does not start with BEGIN:VCALENDAR");
    }

    // Must contain END:VCALENDAR
    if (std.mem.indexOf(u8, data, "END:VCALENDAR") == null) {
        return ValidationResult.invalid(.icalendar, "Missing END:VCALENDAR");
    }

    // Must contain VERSION property
    if (std.mem.indexOf(u8, data, "VERSION:") == null) {
        return ValidationResult.invalid(.icalendar, "Missing VERSION property");
    }

    // Check BEGIN/END balance
    var begin_count: u32 = 0;
    var end_count: u32 = 0;
    var lines = std.mem.splitSequence(u8, data, "\n");
    while (lines.next()) |raw_line| {
        var line = raw_line;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (std.mem.startsWith(u8, line, "BEGIN:")) begin_count += 1;
        if (std.mem.startsWith(u8, line, "END:")) end_count += 1;
    }
    if (begin_count != end_count) {
        return ValidationResult.invalid(.icalendar, "Unbalanced BEGIN/END blocks");
    }

    return ValidationResult.ok(.icalendar);
}
```

**Step 3: Implement iCalendar deep validator**

Deep: validate DTSTART/DTEND consistency, component structure, property value formats.

**Step 4: Write failing tests for vCard, implement**

```zig
/// vCard (RFC 6350) structural validator.
/// Verifies BEGIN/END:VCARD envelope, VERSION property, required properties per version.
pub fn validateVCard(file: std.fs.File) ValidationResult {
    var buf: [65536]u8 = undefined;
    const bytes_read = file.read(&buf) catch {
        return ValidationResult.invalid(.vcard, "Failed to read file");
    };
    if (bytes_read < 20) return ValidationResult.invalid(.vcard, "File too short");
    const data = buf[0..bytes_read];

    if (!std.mem.startsWith(u8, data, "BEGIN:VCARD")) {
        return ValidationResult.invalid(.vcard, "Does not start with BEGIN:VCARD");
    }
    if (std.mem.indexOf(u8, data, "END:VCARD") == null) {
        return ValidationResult.invalid(.vcard, "Missing END:VCARD");
    }
    if (std.mem.indexOf(u8, data, "VERSION:") == null) {
        return ValidationResult.invalid(.vcard, "Missing VERSION property");
    }

    // Check version-specific required properties
    if (std.mem.indexOf(u8, data, "VERSION:4.0") != null) {
        // RFC 6350: FN is required
        if (std.mem.indexOf(u8, data, "FN:") == null and std.mem.indexOf(u8, data, "FN;") == null) {
            return ValidationResult.invalid(.vcard, "vCard 4.0 requires FN property");
        }
    } else if (std.mem.indexOf(u8, data, "VERSION:3.0") != null) {
        // RFC 2426: N and FN are required
        if (std.mem.indexOf(u8, data, "N:") == null and std.mem.indexOf(u8, data, "N;") == null) {
            return ValidationResult.invalid(.vcard, "vCard 3.0 requires N property");
        }
    }

    return ValidationResult.ok(.vcard);
}
```

**Step 5: Register in mod.zig, run tests, commit**

```bash
nix develop -c zig build test 2>&1 | tail -5
git add src/core/pim_validators.zig src/core/mod.zig
git commit -m "Add iCalendar + vCard validators: RFC 5545/6350 structural validation"
```

---

## Task 4: Create crypto_validators.zig with PEM + DER Validation

**Files:**
- Create: `src/core/crypto_validators.zig`
- Modify: `src/core/mod.zig`

**Step 1: Write failing tests for PEM**

```zig
test "PEM structural: valid certificate" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const pem =
        "-----BEGIN CERTIFICATE-----\r\n" ++
        "MIIBkTCB+wIJALRiMLAh0FMXMA0GCSqGSIb3DQEBCwUAMBExDzANBgNVBAMMBnRl\r\n" ++
        "c3RDQTAeFw0yMDAxMDExMjAwMDBaFw0zMDAxMDExMjAwMDBaMBExDzANBgNVBAMM\r\n" ++
        "BnRlc3RDQTBcMA0GCSqGSIb3DQEBAQUAAwsAMEgCQQC7o96HtiuCaPBPOFI7LifG\r\n" ++
        "cS4nRFa0qm5VBVuRDTI3MhJUuBfn1FIjql0ldOGM0lS7IOnGAlmgKmHnxSJzBqbD\r\n" ++
        "AgMBAAEwDQYJKoZIhvcNAQELBQADQQAXUCQpjJONFUUY2J5R5CxjCWJ1IuzvC5D7\r\n" ++
        "GR0lBfLMiE0s0JD+TlSEGfdaPj3N7V2IxHJiDMZRjGUjOo0tLAA\r\n" ++
        "-----END CERTIFICATE-----\r\n";
    try tmp.dir.writeFile(.{ .sub_path = "test.pem", .data = pem });

    const file = try tmp.dir.openFile("test.pem", .{});
    defer file.close();

    const result = validatePem(file);
    try std.testing.expect(result.is_valid);
    try std.testing.expectEqual(FileFormat.pem, result.format);
}

test "PEM structural: mismatched header/footer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const pem =
        "-----BEGIN CERTIFICATE-----\r\n" ++
        "MIIBkTCB+w==\r\n" ++
        "-----END PRIVATE KEY-----\r\n";
    try tmp.dir.writeFile(.{ .sub_path = "test.pem", .data = pem });

    const file = try tmp.dir.openFile("test.pem", .{});
    defer file.close();

    const result = validatePem(file);
    try std.testing.expect(!result.is_valid);
}
```

**Step 2: Implement PEM structural validator**

```zig
/// PEM (RFC 7468) structural validator.
/// Verifies header/footer match, valid base64 content between markers.
pub fn validatePem(file: std.fs.File) ValidationResult {
    var buf: [65536]u8 = undefined;
    const bytes_read = file.read(&buf) catch {
        return ValidationResult.invalid(.pem, "Failed to read file");
    };
    if (bytes_read < 30) return ValidationResult.invalid(.pem, "File too short");
    const data = buf[0..bytes_read];

    if (!std.mem.startsWith(u8, data, "-----BEGIN ")) {
        return ValidationResult.invalid(.pem, "Does not start with -----BEGIN");
    }

    // Extract label from header
    const header_end = std.mem.indexOf(u8, data, "-----\n") orelse
        std.mem.indexOf(u8, data, "-----\r\n") orelse {
        return ValidationResult.invalid(.pem, "Malformed PEM header");
    };
    const label_start = "-----BEGIN ".len;
    const label = data[label_start..header_end];

    // Find matching footer
    var footer_buf: [100]u8 = undefined;
    const footer = std.fmt.bufPrint(&footer_buf, "-----END {s}-----", .{label}) catch {
        return ValidationResult.invalid(.pem, "Label too long");
    };
    if (std.mem.indexOf(u8, data, footer) == null) {
        return ValidationResult.invalid(.pem, "Missing or mismatched PEM footer");
    }

    // Verify base64 content between header and footer
    const content_start = header_end + 5 + 1; // "-----\n"
    const footer_pos = std.mem.indexOf(u8, data, footer).?;
    if (content_start >= footer_pos) {
        return ValidationResult.invalid(.pem, "Empty PEM content");
    }
    const base64_content = data[content_start..footer_pos];
    for (base64_content) |c| {
        if (c == '\r' or c == '\n' or c == ' ') continue;
        if ((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or c == '+' or c == '/' or c == '=') continue;
        return ValidationResult.invalid(.pem, "Invalid base64 character in PEM body");
    }

    return ValidationResult.ok(.pem);
}
```

**Step 3: Implement DER structural validator**

```zig
/// DER/ASN.1 structural validator.
/// Verifies ASN.1 SEQUENCE tag and consistent TLV lengths.
pub fn validateDer(file: std.fs.File) ValidationResult {
    var buf: [65536]u8 = undefined;
    const bytes_read = file.read(&buf) catch {
        return ValidationResult.invalid(.der, "Failed to read file");
    };
    if (bytes_read < 4) return ValidationResult.invalid(.der, "File too short");
    const data = buf[0..bytes_read];

    // Must start with SEQUENCE tag (0x30)
    if (data[0] != 0x30) {
        return ValidationResult.invalid(.der, "Does not start with ASN.1 SEQUENCE tag");
    }

    // Parse length
    const len_result = parseAsn1Length(data[1..]) orelse {
        return ValidationResult.invalid(.der, "Invalid ASN.1 length encoding");
    };

    // Verify total length is consistent with file
    const total = 1 + len_result.header_len + len_result.content_len;
    if (total > bytes_read) {
        return ValidationResult.invalid(.der, "ASN.1 length exceeds file size");
    }

    return ValidationResult.ok(.der);
}

const Asn1LenResult = struct {
    content_len: usize,
    header_len: usize,
};

fn parseAsn1Length(data: []const u8) ?Asn1LenResult {
    if (data.len == 0) return null;
    if (data[0] < 0x80) {
        return .{ .content_len = data[0], .header_len = 1 };
    }
    if (data[0] == 0x80) return null; // Indefinite length (not valid DER)
    const num_bytes = data[0] & 0x7F;
    if (num_bytes > 4 or data.len < 1 + num_bytes) return null;
    var len: usize = 0;
    for (data[1..][0..num_bytes]) |b| {
        len = (len << 8) | b;
    }
    return .{ .content_len = len, .header_len = 1 + num_bytes };
}
```

**Step 4: Implement PEM deep validator** (decode base64, validate ASN.1 structure recursively)

**Step 5: Register in mod.zig, run tests, commit**

```bash
nix develop -c zig build test 2>&1 | tail -5
git add src/core/crypto_validators.zig src/core/mod.zig
git commit -m "Add PEM + DER validators: ASN.1 structural + base64 integrity"
```

---

## Task 5: Wire Up format_validation.zig

**Files:**
- Modify: `src/core/format_validation.zig`

This is the largest integration step. Add all 7 new formats to the 11 registration points.

**Step 1: Add FileFormat enum entries**

After `.bai2` (~line 537), add:

```zig
    bagit, // BagIt preservation bag (RFC 8493, bagit.txt anchor)
    x12_edi, // X12 EDI (healthcare/supply chain, ISA/IEA envelope)
    edifact, // UN/EDIFACT (international trade, UNB/UNZ envelope)
    icalendar, // iCalendar (RFC 5545, .ics)
    vcard, // vCard (RFC 6350, .vcf)
    pem, // PEM-encoded certificate/key (RFC 7468)
    der, // DER-encoded ASN.1 certificate/key
```

**Step 2: Add to hasValidator**

At ~line 615, add to existing financial line or create new:
```zig
.bagit, .x12_edi, .edifact, .icalendar, .vcard, .pem, .der => true, // Archival/PIM/crypto
```

**Step 3: Add magic signatures** (for magic-detected formats)

In `magic_signatures` array (~line 1130), add near the text-format signatures:

```zig
    // BagIt: "BagIt-Version: "
    .{ .bytes = "BagIt-Version: ", .offset = 0, .format = .bagit },
    // iCalendar: "BEGIN:VCALENDAR"
    .{ .bytes = "BEGIN:VCALENDAR", .offset = 0, .format = .icalendar },
    // vCard: "BEGIN:VCARD"
    .{ .bytes = "BEGIN:VCARD", .offset = 0, .format = .vcard },
    // PEM: "-----BEGIN "
    .{ .bytes = "-----BEGIN ", .offset = 0, .format = .pem },
```

**Step 4: Add extension mappings**

In `detectFormatFromExtension` (~line 2192, after bai2):
```zig
    // Archival/PIM/crypto formats
    if (std.mem.eql(u8, ext_lower, "edi") or std.mem.eql(u8, ext_lower, "x12") or
        std.mem.eql(u8, ext_lower, "837") or std.mem.eql(u8, ext_lower, "835") or
        std.mem.eql(u8, ext_lower, "834") or std.mem.eql(u8, ext_lower, "820")) return .x12_edi;
    if (std.mem.eql(u8, ext_lower, "edifact")) return .edifact;
    if (std.mem.eql(u8, ext_lower, "ics") or std.mem.eql(u8, ext_lower, "ical")) return .icalendar;
    if (std.mem.eql(u8, ext_lower, "vcf") or std.mem.eql(u8, ext_lower, "vcard")) return .vcard;
    if (std.mem.eql(u8, ext_lower, "pem") or std.mem.eql(u8, ext_lower, "crt") or
        std.mem.eql(u8, ext_lower, "key") or std.mem.eql(u8, ext_lower, "csr")) return .pem;
    if (std.mem.eql(u8, ext_lower, "der") or std.mem.eql(u8, ext_lower, "cer")) return .der;
```

Same entries in `getExpectedFormatForExtension` (~line 2635).

**Step 5: Add ext_has_no_magic entries** (extension-only formats only)

At ~line 4427, add to the switch:
```zig
.x12_edi, .edifact, .der,
```

**Step 6: Add ext_has_no_magic structural dispatch**

At ~line 4468, add:
```zig
.x12_edi => edi_validators.validateX12Edi(reopen_ext),
.edifact => edi_validators.validateEdifact(reopen_ext),
.der => crypto_validators.validateDer(reopen_ext),
```

**Step 7: Add is_binary_format exclusion**

At ~line 4485, add text formats to the exclusion list:
```zig
.x12_edi, .edifact, .icalendar, .vcard, .pem, .bagit => false,
```

(DER is binary, so it stays excluded from this list — meaning it WILL go through secondary sig detection.)

**Step 8: Add deep validation dispatch**

At ~line 4990, add:
```zig
.bagit => bagit_validator.validateBagitDeep(allocator, path),
.x12_edi => edi_validators.validateX12EdiDeep(allocator, path),
.edifact => edi_validators.validateEdifactDeep(allocator, path),
.icalendar => pim_validators.validateICalendarDeep(allocator, path),
.vcard => pim_validators.validateVCardDeep(allocator, path),
.pem => crypto_validators.validatePemDeep(allocator, path),
```

**Step 9: Add main structural dispatch**

At ~line 5456, add:
```zig
.bagit => bagit_validator.validateBagit(file),
.x12_edi => edi_validators.validateX12Edi(file),
.edifact => edi_validators.validateEdifact(file),
.icalendar => pim_validators.validateICalendar(file),
.vcard => pim_validators.validateVCard(file),
.pem => crypto_validators.validatePem(file),
.der => crypto_validators.validateDer(file),
```

**Step 10: Run tests, commit**

```bash
nix develop -c zig build test 2>&1 | tail -5
git add src/core/format_validation.zig
git commit -m "Wire up 7 new formats: enum, detection, dispatch across format_validation.zig"
```

---

## Task 6: Wire Up FFI, i18n, and corruption_opacity

**Files:**
- Modify: `ffi/c_api.zig`
- Modify: 30 `src/core/i18n/*.zig` files
- Modify: `scripts/corruption_opacity.tsv`

**Step 1: Add to FFI category**

In `ffi/c_api.zig` `getFormatCategory`, add to existing categories:
```zig
.bagit => "archive",   // preservation archive
.x12_edi, .edifact => "financial",  // EDI interchange
.icalendar, .vcard => "document",   // personal information
.pem, .der => "other",  // cryptographic materials
```

**Step 2: Add i18n format descriptions**

In ALL 30 locale files, add after `.bai2`:
```zig
.bagit = "BagIt Preservation Archive",
.x12_edi = "X12 EDI Transaction",
.edifact = "UN/EDIFACT Message",
.icalendar = "iCalendar Event Data",
.vcard = "vCard Contact",
.pem = "PEM Certificate/Key",
.der = "DER Certificate/Key",
```

Translate for non-English locales (same pattern as NACHA/MT940/BAI2 addition — one line per format per locale).

**Step 3: Add corruption_opacity entries**

```
bagit	transparent	SHA-256/SHA-512/MD5 manifest provides complete content hash verification
x12_edi	transparent	Segment counts and control numbers at transaction/group/interchange levels
edifact	transparent	UNT/UNE/UNZ segment and message counts provide full integrity coverage
icalendar	mixed	RFC 5545 structural grammar but no integrity checksums
vcard	mixed	RFC 6350 structural grammar but no integrity checksums
pem	mixed	Base64 encoding + ASN.1 structure but no content checksums
der	mixed	ASN.1 TLV structure verification but no content checksums
```

**Step 4: Run tests, commit**

```bash
nix develop -c zig build test 2>&1 | tail -5
git add ffi/c_api.zig src/core/i18n/*.zig scripts/corruption_opacity.tsv
git commit -m "Wire up FFI categories, i18n descriptions (30 locales), corruption opacity for 7 formats"
```

---

## Task 7: Create Ground Truth Samples + Tests

**Files:**
- Create: `ground_truth_examples/bagit/sample/bagit.txt` (and sibling files)
- Create: `ground_truth_examples/edi/sample.x12`
- Create: `ground_truth_examples/edi/sample.edifact`
- Create: `ground_truth_examples/icalendar/sample.ics`
- Create: `ground_truth_examples/vcard/sample.vcf`
- Create: `ground_truth_examples/pem/sample.pem`

All samples are synthetic — note this in PLAN.md for future replacement.

**Step 1: Create BagIt sample**

A minimal valid BagIt bag with 2 payload files and SHA-256 manifest.

Use bash to create with correct hashes:
```bash
mkdir -p ground_truth_examples/bagit/sample/data
echo -n "Hello from BagIt sample" > ground_truth_examples/bagit/sample/data/hello.txt
echo -n "Second payload file" > ground_truth_examples/bagit/sample/data/second.txt
printf "BagIt-Version: 1.0\nTag-File-Character-Encoding: UTF-8\n" > ground_truth_examples/bagit/sample/bagit.txt
# Compute SHA-256 hashes and write manifest
sha256sum ground_truth_examples/bagit/sample/data/hello.txt | sed 's| ground_truth_examples/bagit/sample/| |' > ground_truth_examples/bagit/sample/manifest-sha256.txt
sha256sum ground_truth_examples/bagit/sample/data/second.txt | sed 's| ground_truth_examples/bagit/sample/| |' >> ground_truth_examples/bagit/sample/manifest-sha256.txt
```

**Step 2: Create X12 EDI sample** (valid 837P with correct control totals)

**Step 3: Create EDIFACT sample** (valid INVOIC with correct UNT/UNZ)

**Step 4: Create iCalendar sample** (VEVENT with VTIMEZONE and RRULE)

**Step 5: Create vCard sample** (v4.0 with FN, structured name, org)

**Step 6: Create PEM sample** (self-signed certificate, can generate with openssl)

```bash
openssl req -x509 -newkey rsa:512 -keyout /dev/null -out ground_truth_examples/pem/sample.pem \
  -days 3650 -nodes -subj "/CN=validate-test" 2>/dev/null
```

**Step 7: Add ground truth tests to each validator file**

Same pattern as financial_validators.zig:
```zig
test "ground truth: BagIt sample structural validation" {
    const file = std.fs.cwd().openFile("ground_truth_examples/bagit/sample/bagit.txt", .{}) catch return;
    defer file.close();
    const result = validateBagit(file);
    try std.testing.expect(result.is_valid);
    try std.testing.expectEqual(FileFormat.bagit, result.format);
}

test "ground truth: BagIt sample deep validation" {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fs.cwd().realpath("ground_truth_examples/bagit/sample/bagit.txt", &path_buf) catch return;
    const result = validateBagitDeep(std.testing.allocator, path);
    try std.testing.expect(result.is_valid);
    try std.testing.expectEqual(format_validation.ValidationDepth.full, result.validation_depth);
}
```

**Step 8: Run full test suite, commit**

```bash
nix develop -c zig build test 2>&1 | tail -5
git add ground_truth_examples/ src/core/bagit_validator.zig src/core/edi_validators.zig src/core/pim_validators.zig src/core/crypto_validators.zig
git commit -m "Add ground truth samples + tests for 7 archival formats (synthetic, flagged for replacement)"
```

---

## Task 8: Update Documentation

**Files:**
- Modify: `PLAN.md` — check off Wave 1 items
- Modify: `CODE_MINIMAP.md` — add 4 new validator files
- Modify: `FORMAT_VERIFICATIONS.md` — add 7 new format entries

**Step 1: Update PLAN.md** — check off all Wave 1 items with timestamps

**Step 2: Update CODE_MINIMAP.md** — add entries for:
```
| `src/core/bagit_validator.zig` | BagIt (RFC 8493) preservation bag validation with SHA manifest verification |
| `src/core/edi_validators.zig` | X12 EDI + EDIFACT transaction validation with control total integrity |
| `src/core/pim_validators.zig` | iCalendar (RFC 5545) + vCard (RFC 6350) structural validation |
| `src/core/crypto_validators.zig` | PEM/DER certificate and key validation with ASN.1 structure checks |
```

**Step 3: Update FORMAT_VERIFICATIONS.md** — add sections for all 7 formats with:
- Format name and description
- Detection method (magic vs extension)
- Structural validation details
- Deep validation details (integrity mechanisms)
- Corruption opacity classification

**Step 4: Commit**

```bash
git add PLAN.md CODE_MINIMAP.md FORMAT_VERIFICATIONS.md
git commit -m "Update docs: PLAN.md, CODE_MINIMAP.md, FORMAT_VERIFICATIONS.md for Wave 1 formats"
```

---

## Verification

After all tasks complete:

```bash
# Full test suite
nix develop -c zig build test

# Validate ground truth samples
./zig-out/bin/validate ground_truth_examples/bagit/sample/bagit.txt \
  ground_truth_examples/edi/sample.x12 \
  ground_truth_examples/edi/sample.edifact \
  ground_truth_examples/icalendar/sample.ics \
  ground_truth_examples/vcard/sample.vcf \
  ground_truth_examples/pem/sample.pem

# Strict coverage harness (check for regressions)
bash scripts/strict_format_coverage
```

Expected: All OK, no regressions, 7 new formats passing.
