//! bzip2 — thin wrapper re-exporting the cleanroom `bzip2z` decoder/encoder.
//!
//! The previous in-tree implementation has been replaced by a dependency on
//! the sibling `bzip2z` project (clean-room pure-Zig bzip2 by Peter, also
//! consumed by other projects). bzip2z's decoder correctly handles streams
//! that the in-tree fork choked on (specifically: blocks recovered by
//! `bzip2recover` from the dolphin-master DMG that triggered
//! `error.OutputOverflow` here — see commit history for the full story and
//! `../bzip2z/inbox/level1-runa-runb-desync-2026-04-30.md` for the
//! investigation notes).
//!
//! All symbols previously exported here are re-exported from bzip2z so
//! existing call sites (archive_validators.zig, bzip2_test.zig) continue to
//! work without changes. The `validateStream` function is locally defined
//! since it's a validate-specific addition; it's a candidate for upstream
//! contribution to bzip2z.

const std = @import("std");
const bzip2z = @import("bzip2z").bzip2;
const Allocator = std.mem.Allocator;

// ===== Re-exports from bzip2z =====

pub const STREAM_MAGIC = bzip2z.STREAM_MAGIC;
pub const BLOCK_MAGIC = bzip2z.BLOCK_MAGIC;
pub const FOOTER_MAGIC = bzip2z.FOOTER_MAGIC;
pub const Error = bzip2z.Error;
pub const Crc32Bzip2 = bzip2z.Crc32Bzip2;
pub const Decompressor = bzip2z.Decompressor;
pub const compress = bzip2z.compress;
pub const decompress = bzip2z.decompress;
pub const decompressNoCrc = bzip2z.decompressNoCrc;

// ===== validate-specific addition =====

/// Validate bzip2 data without materializing decompressed output.
///
/// Same per-block + stream CRC verification as `decompress`, but emitted
/// bytes are discarded as they're produced rather than accumulated. Memory
/// is bounded by the per-block working buffer regardless of decompressed
/// file size — useful for validating large bzip2 streams (multi-GB
/// tarballs, etc.) without holding the full payload in heap.
///
/// Candidate for upstreaming to bzip2z.
pub fn validateStream(allocator: Allocator, input: []const u8) !void {
    // TODO(0.16): bzip2z's Decompressor.decompressInternal still expects 0.15
    // reader/writer interfaces. Until bzip2z is ported to std.Io, fall back to
    // the in-memory decompress and discard the output. Memory grows with the
    // decompressed size — fine for typical archives, problematic for multi-GB
    // bz2 streams. Restore streaming when bzip2z gains a std.Io decompress API.
    const output = bzip2z.decompress(allocator, input) catch |err| return err;
    defer allocator.free(output);
}
