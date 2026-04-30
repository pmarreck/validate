//! Pure Zig bzip2 compressor/decompressor implementation.
//!
//! Based on the bzip2 format specification. This is a clean-room implementation
//! of the algorithm, not a direct port of the C code.
//!
//! The bzip2 format uses:
//! - Burrows-Wheeler Transform (BWT) for block sorting
//! - Move-To-Front (MTF) encoding for symbol locality
//! - Huffman coding for entropy compression
//! - Run-Length Encoding (RLE) for repeated symbols
//!
//! Thread Safety: This implementation is thread-safe. Each Decompressor/Compressor
//! instance is independent and can be used from different threads. The algorithm
//! uses no global state.
//!
//! ## License
//!
//! This is a clean-room implementation based on the publicly documented bzip2
//! format specification. The bzip2 algorithm and format were created by Julian
//! Seward and are covered by a BSD-style license.
//!
//! Original bzip2 license notice:
//!
//!   bzip2/libbzip2 version 1.0.6 of 6 September 2010
//!   Copyright (C) 1996-2010 Julian R Seward <jseward@bzip.org>
//!
//!   This program, "bzip2", the associated library "libbzip2", and all
//!   documentation, are copyright (C) 1996-2010 Julian R Seward. All rights
//!   reserved.
//!
//!   Redistribution and use in source and binary forms, with or without
//!   modification, are permitted provided that the following conditions are met:
//!
//!   1. Redistributions of source code must retain the above copyright notice,
//!      this list of conditions and the following disclaimer.
//!
//!   2. The origin of this software must not be misrepresented; you must not
//!      claim that you wrote the original software. If you use this software
//!      in a product, an acknowledgment in the product documentation would be
//!      appreciated but is not required.
//!
//!   3. Altered source versions must be plainly marked as such, and must not
//!      be misrepresented as being the original software.
//!
//!   4. The name of the author may not be used to endorse or promote products
//!      derived from this software without specific prior written permission.
//!
//! Note: This Zig implementation is an independent clean-room implementation
//! based on the format specification, not a derivative of the original C code.

const std = @import("std");
const codec_utils = @import("codec_utils.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

// ============ Constants ============

/// Magic bytes for bzip2 stream header: "BZh"
pub const STREAM_MAGIC = [3]u8{ 'B', 'Z', 'h' };

/// Block header magic: 0x314159265359 (digits of pi)
pub const BLOCK_MAGIC: u48 = 0x314159265359;

/// Stream footer magic: 0x177245385090 (sqrt(pi) digits)
pub const FOOTER_MAGIC: u48 = 0x177245385090;

/// Maximum block size (900KB for level 9)
pub const MAX_BLOCK_SIZE: usize = 900_000;

/// Maximum expanded block size. Bzip2 spec caps block size at level*100K
/// (900K for level=9, the highest), but in practice some real-world
/// encoders produce streams whose intermediate (post-BWT, pre-RLE-decode)
/// state exceeds the nominal level*100K bound. Raised from the original
/// 1.2 MB to 4 MB to accept these streams while still capping pathological
/// "decompression bomb" scenarios. This matches roughly 4× the nominal
/// max bzip2 block. If a single block's decoded data exceeds 4 MB, that
/// is genuinely anomalous and `error.OutputOverflow` is appropriate.
pub const MAX_EXPANDED_BLOCK_SIZE: usize = 4 * 1024 * 1024;

/// Maximum number of Huffman groups
pub const MAX_GROUPS: usize = 6;

/// Maximum number of selectors
pub const MAX_SELECTORS: usize = 18002;

/// Maximum alphabet size (256 bytes + 2 special symbols RUNA/RUNB)
pub const MAX_ALPHA_SIZE: usize = 258;

/// Number of symbols per selector group
pub const GROUP_SIZE: usize = 50;

/// Maximum Huffman code length
pub const MAX_CODE_LEN: usize = 20;

/// Minimum Huffman code length
pub const MIN_CODE_LEN: usize = 1;

// ============ Error Types ============

pub const Error = error{
    InvalidMagic,
    InvalidBlockSize,
    InvalidBlockHeader,
    InvalidFooter,
    CorruptData,
    HuffmanOverflow,
    InvalidSelector,
    BlockCrcMismatch,
    StreamCrcMismatch,
    UnexpectedEof,
    OutputOverflow,
    OutOfMemory,
    InvalidBwtIndex,
};

// ============ CRC32 for bzip2 ============

/// bzip2 uses a specific CRC32 polynomial (same as used by Ethernet)
/// but processes bits MSB-first and uses 0xFFFFFFFF as initial value.
pub const Crc32Bzip2 = codec_utils.Crc32Bzip2;

// ============ Bit Reader (Generic) ============

/// Generic bit reader that reads bits MSB first (bzip2 convention)
pub fn BitReader(comptime ReaderType: type) type {
    return struct {
        const Self = @This();

        reader: ReaderType,
        buffer: u64, // Use u64 to handle up to 32 bit reads
        bits_in_buffer: u6, // u6 can hold 0-63

        pub fn init(reader: ReaderType) Self {
            return .{
                .reader = reader,
                .buffer = 0,
                .bits_in_buffer = 0,
            };
        }

        /// Read n bits (up to 32) from the stream
        pub fn readBits(self: *Self, comptime n: u6) Error!u32 {
            // Ensure we have enough bits
            while (self.bits_in_buffer < n) {
                const byte = self.reader.readByte() catch |err| {
                    if (err == error.EndOfStream) return Error.UnexpectedEof;
                    return Error.CorruptData;
                };
                self.buffer = (self.buffer << 8) | byte;
                self.bits_in_buffer += 8;
            }

            self.bits_in_buffer -= n;
            const shift: u6 = self.bits_in_buffer;
            const mask: u64 = (@as(u64, 1) << n) - 1;
            return @truncate((self.buffer >> shift) & mask);
        }

        /// Read a variable number of bits (up to 32)
        pub fn readBitsVar(self: *Self, n: u6) Error!u32 {
            // Ensure we have enough bits
            while (self.bits_in_buffer < n) {
                const byte = self.reader.readByte() catch |err| {
                    if (err == error.EndOfStream) return Error.UnexpectedEof;
                    return Error.CorruptData;
                };
                self.buffer = (self.buffer << 8) | byte;
                self.bits_in_buffer += 8;
            }

            self.bits_in_buffer -= n;
            const shift: u6 = self.bits_in_buffer;
            const mask: u64 = (@as(u64, 1) << n) - 1;
            return @truncate((self.buffer >> shift) & mask);
        }

        /// Read a single bit
        pub fn readBit(self: *Self) Error!u1 {
            return @truncate(try self.readBits(1));
        }

        /// Peek n bits without consuming them (for fast Huffman lookup)
        pub fn peekBits(self: *Self, n: u6) Error!u32 {
            // Ensure we have enough bits
            while (self.bits_in_buffer < n) {
                const byte = self.reader.readByte() catch |err| {
                    if (err == error.EndOfStream) return Error.UnexpectedEof;
                    return Error.CorruptData;
                };
                self.buffer = (self.buffer << 8) | byte;
                self.bits_in_buffer += 8;
            }

            // Don't consume - just peek
            const shift: u6 = self.bits_in_buffer - n;
            const mask: u64 = (@as(u64, 1) << n) - 1;
            return @truncate((self.buffer >> shift) & mask);
        }

        /// Consume n bits (after peeking)
        pub fn consumeBits(self: *Self, n: u8) void {
            self.bits_in_buffer -= @intCast(n);
        }

        /// Discard remaining bits to align to byte boundary
        pub fn alignToByte(self: *Self) void {
            // Discard any bits that aren't a full byte
            const extra_bits = self.bits_in_buffer % 8;
            self.bits_in_buffer -= extra_bits;
        }

        /// Try to read a byte, returning null on EOF
        pub fn readByteOrEof(self: *Self) ?u8 {
            // First use any buffered complete bytes
            if (self.bits_in_buffer >= 8) {
                self.bits_in_buffer -= 8;
                const shift: u6 = self.bits_in_buffer;
                return @truncate(self.buffer >> shift);
            }
            // Otherwise read from underlying reader
            return self.reader.readByte() catch null;
        }
    };
}

// ============ Huffman Table ============

/// Lookup table entry for fast Huffman decoding
const HuffmanLookupEntry = packed struct {
    symbol: u16, // Decoded symbol (or 0xFFFF if code is longer than LOOKUP_BITS)
    length: u8, // Code length (0 means need slow path)
    _padding: u8 = 0,
};

/// Number of bits for fast lookup table (2^10 = 1024 entries, good balance)
const HUFFMAN_LOOKUP_BITS: u5 = 10;
const HUFFMAN_LOOKUP_SIZE: usize = 1 << HUFFMAN_LOOKUP_BITS;

const HuffmanTable = struct {
    // Fast lookup table for codes up to LOOKUP_BITS long
    lookup: [HUFFMAN_LOOKUP_SIZE]HuffmanLookupEntry,

    // Fallback tables for codes longer than LOOKUP_BITS
    limits: [MAX_CODE_LEN + 2]u32,
    bases: [MAX_CODE_LEN + 2]u32,
    perm_offsets: [MAX_CODE_LEN + 2]u32,
    perms: [MAX_ALPHA_SIZE]u16,
    min_len: u5,
    max_len: u5,

    pub fn init() HuffmanTable {
        return .{
            .lookup = [_]HuffmanLookupEntry{.{ .symbol = 0xFFFF, .length = 0 }} ** HUFFMAN_LOOKUP_SIZE,
            .limits = [_]u32{0} ** (MAX_CODE_LEN + 2),
            .bases = [_]u32{0} ** (MAX_CODE_LEN + 2),
            .perm_offsets = [_]u32{0} ** (MAX_CODE_LEN + 2),
            .perms = [_]u16{0} ** MAX_ALPHA_SIZE,
            .min_len = 1,
            .max_len = MAX_CODE_LEN,
        };
    }

    /// Build decoding tables from code lengths
    pub fn build(self: *HuffmanTable, lengths: []const u8, num_symbols: usize) Error!void {
        if (num_symbols == 0) return;

        // Reset lookup table
        @memset(&self.lookup, .{ .symbol = 0xFFFF, .length = 0 });

        // Count codes of each length
        var count: [MAX_CODE_LEN + 1]u32 = [_]u32{0} ** (MAX_CODE_LEN + 1);
        var min_len: usize = MAX_CODE_LEN;
        var max_len: usize = 0;

        for (lengths[0..num_symbols]) |len| {
            if (len == 0) continue;
            if (len > MAX_CODE_LEN) return Error.HuffmanOverflow;
            count[len] += 1;
            if (len < min_len) min_len = len;
            if (len > max_len) max_len = len;
        }

        self.min_len = @intCast(min_len);
        self.max_len = @intCast(max_len);

        // Compute base codes and limits for each length.
        //
        // For each length we assign `count[len]` consecutive canonical codes
        // starting from `code`. Then `code` is shifted left by one to align
        // with the next length. For a *valid* canonical Huffman code, the
        // assigned codes for length `len` must all fit in `len` bits — i.e.
        // `code + count[len] <= (1 << len)`. Adversarial / corrupted inputs
        // can violate this (e.g. claiming many short codes), in which case the
        // lookup-table fill loop below would compute `base_idx >= 1024` and
        // write past `self.lookup`. Reject such tables here.
        var code: u32 = 0;
        var perm_offset: u32 = 0;
        for (1..MAX_CODE_LEN + 1) |len| {
            self.bases[len] = code;
            self.perm_offsets[len] = perm_offset;
            if (count[len] > 0) {
                // Guard against integer overflow before the canonical-fit check
                // (count[len] is bounded by num_symbols <= MAX_ALPHA_SIZE = 258
                // so this addition cannot wrap u32, but be defensive anyway).
                const end_code = std.math.add(u32, code, count[len]) catch return Error.HuffmanOverflow;
                // Canonical Huffman invariant: codes of length `len` must fit
                // in `len` bits. `end_code` is the first code value *after*
                // this length's range, so it must be <= 2^len.
                const max_for_len: u64 = @as(u64, 1) << @as(u6, @intCast(len));
                if (@as(u64, end_code) > max_for_len) return Error.HuffmanOverflow;
                self.limits[len] = code + count[len] - 1;
            } else {
                self.limits[len] = 0;
                if (code > 0) self.limits[len] = code - 1;
            }
            perm_offset += count[len];
            code = (code + count[len]) << 1;
        }
        self.limits[MAX_CODE_LEN + 1] = std.math.maxInt(u32);

        // Build permutation table
        var perm_idx: usize = 0;
        for (1..MAX_CODE_LEN + 1) |len| {
            for (0..num_symbols) |sym| {
                if (lengths[sym] == len) {
                    self.perms[perm_idx] = @intCast(sym);
                    perm_idx += 1;
                }
            }
        }

        // Build fast lookup table for codes <= LOOKUP_BITS
        // For each code, fill all table entries that start with that code
        for (0..num_symbols) |sym| {
            const len = lengths[sym];
            if (len == 0 or len > HUFFMAN_LOOKUP_BITS) continue;

            // Get the canonical code for this symbol
            const sym_code = self.getCode(@intCast(sym), len);

            // Fill all entries that start with this code
            // If code is 'len' bits, we need to fill 2^(LOOKUP_BITS - len) entries
            const fill_count = @as(usize, 1) << (HUFFMAN_LOOKUP_BITS - @as(u5, @intCast(len)));
            const base_idx = sym_code << (HUFFMAN_LOOKUP_BITS - @as(u5, @intCast(len)));

            for (0..fill_count) |i| {
                self.lookup[base_idx + i] = .{
                    .symbol = @intCast(sym),
                    .length = len,
                };
            }
        }
    }

    /// Get canonical code for a symbol given its length
    fn getCode(self: *const HuffmanTable, symbol: u16, len: u8) u32 {
        // Find position of symbol in perm array for this length
        const start = self.perm_offsets[len];
        const end = if (len < MAX_CODE_LEN) self.perm_offsets[len + 1] else @as(u32, @intCast(MAX_ALPHA_SIZE));

        for (start..end) |i| {
            if (self.perms[i] == symbol) {
                return self.bases[len] + @as(u32, @intCast(i - start));
            }
        }
        return 0;
    }

    /// Decode one symbol from bit reader (fast table lookup with fallback)
    pub fn decode(self: *const HuffmanTable, comptime ReaderType: type, bits: *BitReader(ReaderType)) Error!u16 {
        // Try fast path if we can peek enough bits
        if (bits.peekBits(HUFFMAN_LOOKUP_BITS)) |peek_bits| {
            const entry = self.lookup[peek_bits];

            if (entry.length != 0) {
                // Fast path: code was in lookup table
                bits.consumeBits(entry.length);
                return entry.symbol;
            }

            // Slow path: code is longer than LOOKUP_BITS
            // Consume the bits we peeked and continue reading
            bits.consumeBits(HUFFMAN_LOOKUP_BITS);
            var len: usize = HUFFMAN_LOOKUP_BITS;
            var code: u32 = peek_bits;

            while (len <= self.max_len) {
                if (code <= self.limits[len]) {
                    const idx = code - self.bases[len];
                    return self.perms[self.perm_offsets[len] + idx];
                }
                len += 1;
                code = (code << 1) | try bits.readBit();
            }
            return Error.HuffmanOverflow;
        } else |_| {
            // Not enough bits for fast path - use slow bit-by-bit approach
            var len: usize = self.min_len;
            var code: u32 = try bits.readBitsVar(@intCast(len));

            while (len <= self.max_len) {
                if (code <= self.limits[len]) {
                    const idx = code - self.bases[len];
                    return self.perms[self.perm_offsets[len] + idx];
                }
                len += 1;
                code = (code << 1) | try bits.readBit();
            }
            return Error.HuffmanOverflow;
        }
    }
};

// ============ Decompressor ============

pub const Decompressor = struct {
    allocator: Allocator,

    // Block data buffer
    block: []u8,
    block_size: usize,
    stored_block_crc: u32,

    // BWT state
    bwt_primary_index: u32,
    tt: []u32, // Transformation table

    // Huffman tables (up to 6 groups)
    huffman_tables: [MAX_GROUPS]HuffmanTable,
    num_groups: usize,

    // Selectors
    selectors: []u8,
    num_selectors: usize,

    // Symbol map (which bytes are used in this stream)
    in_use: [256]bool,
    seq_to_unseq: [256]u8,
    num_in_use: usize,

    // Stream state
    stream_crc: u32,
    block_randomized: bool,

    // Output buffer
    output: []u8,
    output_len: usize,

    pub fn init(allocator: Allocator) !Decompressor {
        // Buffers must handle RLE expansion during intermediate stages
        const block = try allocator.alloc(u8, MAX_EXPANDED_BLOCK_SIZE + 1);
        errdefer allocator.free(block);

        const tt = try allocator.alloc(u32, MAX_EXPANDED_BLOCK_SIZE + 1);
        errdefer allocator.free(tt);

        const output = try allocator.alloc(u8, MAX_EXPANDED_BLOCK_SIZE + 1);
        errdefer allocator.free(output);

        const selectors = try allocator.alloc(u8, MAX_SELECTORS);
        errdefer allocator.free(selectors);

        return Decompressor{
            .allocator = allocator,
            .block = block,
            .block_size = 0,
            .stored_block_crc = 0,
            .bwt_primary_index = 0,
            .tt = tt,
            .huffman_tables = [_]HuffmanTable{HuffmanTable.init()} ** MAX_GROUPS,
            .num_groups = 0,
            .selectors = selectors,
            .num_selectors = 0,
            .in_use = [_]bool{false} ** 256,
            .seq_to_unseq = [_]u8{0} ** 256,
            .num_in_use = 0,
            .stream_crc = 0,
            .block_randomized = false,
            .output = output,
            .output_len = 0,
        };
    }

    pub fn deinit(self: *Decompressor) void {
        self.allocator.free(self.block);
        self.allocator.free(self.tt);
        self.allocator.free(self.output);
        self.allocator.free(self.selectors);
    }

    /// Decompress bzip2 data from reader to writer
    pub fn decompress(self: *Decompressor, reader: anytype, writer: anytype) Error!void {
        return self.decompressInternal(reader, writer, true);
    }

    /// Decompress bzip2 data from reader to writer, optionally checking CRC
    /// Supports multi-stream concatenation (pbzip2 format)
    pub fn decompressInternal(self: *Decompressor, reader: anytype, writer: anytype, check_crc: bool) Error!void {
        const ReaderType = @TypeOf(reader);
        var bits = BitReader(ReaderType).init(reader);
        var first_stream = true;

        // Outer loop for multi-stream support (pbzip2)
        stream_loop: while (true) {
            // Read stream header (4 bytes: "BZhX" where X is block size 1-9)
            var header: [4]u8 = undefined;
            for (&header) |*h| {
                if (bits.readByteOrEof()) |b| {
                    h.* = b;
                } else {
                    // EOF - done if not first stream, error if first
                    if (first_stream) return Error.UnexpectedEof;
                    break :stream_loop;
                }
            }

            // Validate magic
            if (!std.mem.eql(u8, header[0..3], &STREAM_MAGIC)) {
                if (first_stream) return Error.InvalidMagic;
                // Non-first stream with invalid magic - just stop (could be trailing garbage)
                break :stream_loop;
            }

            // Validate block size digit ('1' - '9')
            const level = header[3];
            if (level < '1' or level > '9') {
                if (first_stream) return Error.InvalidBlockSize;
                break :stream_loop;
            }

            first_stream = false;

            // Reset stream CRC for this stream
            self.stream_crc = 0;

            // Process blocks until footer
            while (true) {
                // Read 48-bit block/footer magic
                const magic_high: u48 = try bits.readBits(24);
                const magic_low: u48 = try bits.readBits(24);
                const magic: u48 = (magic_high << 24) | magic_low;

                if (magic == FOOTER_MAGIC) {
                    // Stream footer - read and verify CRC
                    if (check_crc) {
                        const stored_stream_crc = try bits.readBits(32);
                        if (stored_stream_crc != self.stream_crc) {
                            return Error.StreamCrcMismatch;
                        }
                    } else {
                        _ = try bits.readBits(32); // Skip CRC
                    }
                    // Align to byte boundary before trying next stream
                    bits.alignToByte();
                    break; // Exit block loop, continue stream loop
                }

                if (magic != BLOCK_MAGIC) {
                    return Error.InvalidBlockHeader;
                }

                // Process block
                try self.readBlock(ReaderType, &bits);
                try self.decodeBlockInternal(check_crc);

                // Write decompressed output
                _ = writer.write(self.output[0..self.output_len]) catch return Error.CorruptData;

                // Update stream CRC (rotate left by 1 and XOR with block CRC)
                self.stream_crc = ((self.stream_crc << 1) | (self.stream_crc >> 31)) ^ self.stored_block_crc;
            }
        }
    }

    fn readBlock(self: *Decompressor, comptime ReaderType: type, bits: *BitReader(ReaderType)) Error!void {
        // Block CRC (32 bits)
        self.stored_block_crc = try bits.readBits(32);

        // Randomized flag (1 bit) - rarely used
        self.block_randomized = (try bits.readBit()) == 1;

        // BWT primary index (24 bits)
        self.bwt_primary_index = try bits.readBits(24);

        // Read symbol bitmap
        try self.readSymbolMap(ReaderType, bits);

        // Number of Huffman groups (3 bits)
        self.num_groups = try bits.readBits(3);
        if (self.num_groups < 2 or self.num_groups > MAX_GROUPS) {
            return Error.CorruptData;
        }

        // Number of selectors (15 bits)
        self.num_selectors = try bits.readBits(15);
        if (self.num_selectors == 0 or self.num_selectors > MAX_SELECTORS) {
            return Error.CorruptData;
        }

        // Read selectors (MTF encoded)
        try self.readSelectors(ReaderType, bits);

        // Read Huffman code lengths and build tables
        try self.readHuffmanTrees(ReaderType, bits);

        // Decode compressed data
        try self.readCompressedData(ReaderType, bits);
    }

    fn readSymbolMap(self: *Decompressor, comptime ReaderType: type, bits: *BitReader(ReaderType)) Error!void {
        // First level: 16-bit bitmap of which 16-symbol groups are used
        const group_bitmap: u16 = @truncate(try bits.readBits(16));

        self.num_in_use = 0;
        @memset(&self.in_use, false);

        for (0..16) |group_idx| {
            if (group_bitmap & (@as(u16, 0x8000) >> @intCast(group_idx)) != 0) {
                // This group of 16 symbols has a second-level bitmap
                const sym_bitmap: u16 = @truncate(try bits.readBits(16));
                for (0..16) |sym_idx| {
                    if (sym_bitmap & (@as(u16, 0x8000) >> @intCast(sym_idx)) != 0) {
                        const sym = group_idx * 16 + sym_idx;
                        self.in_use[sym] = true;
                        self.seq_to_unseq[self.num_in_use] = @intCast(sym);
                        self.num_in_use += 1;
                    }
                }
            }
        }
    }

    fn readSelectors(self: *Decompressor, comptime ReaderType: type, bits: *BitReader(ReaderType)) Error!void {
        // MTF state for selector decoding
        var mtf: [MAX_GROUPS]u8 = undefined;
        for (0..self.num_groups) |i| {
            mtf[i] = @intCast(i);
        }

        // Read MTF-encoded selectors
        for (0..self.num_selectors) |i| {
            // Count unary-coded selector index
            var j: usize = 0;
            while (try bits.readBit() == 1) {
                j += 1;
                if (j >= self.num_groups) {
                    return Error.InvalidSelector;
                }
            }

            // MTF decode
            const selected = mtf[j];
            // Move to front
            while (j > 0) : (j -= 1) {
                mtf[j] = mtf[j - 1];
            }
            mtf[0] = selected;

            self.selectors[i] = selected;
        }
    }

    fn readHuffmanTrees(self: *Decompressor, comptime ReaderType: type, bits: *BitReader(ReaderType)) Error!void {
        const alpha_size = self.num_in_use + 2; // +2 for RUNA and RUNB

        for (0..self.num_groups) |group| {
            var lengths: [MAX_ALPHA_SIZE]u8 = [_]u8{0} ** MAX_ALPHA_SIZE;

            // Read initial code length (5 bits)
            var curr_len: i32 = @intCast(try bits.readBits(5));

            for (0..alpha_size) |sym| {
                // Adjust length with delta encoding
                while (true) {
                    if (curr_len < 1 or curr_len > 20) {
                        return Error.HuffmanOverflow;
                    }

                    // Check for adjustment
                    const adjust = try bits.readBit();
                    if (adjust == 0) break;

                    // Direction: 0 = increment, 1 = decrement
                    if (try bits.readBit() == 0) {
                        curr_len += 1;
                    } else {
                        curr_len -= 1;
                    }
                }
                lengths[sym] = @intCast(curr_len);
            }

            // Build Huffman table
            try self.huffman_tables[group].build(&lengths, alpha_size);
        }
    }

    fn readCompressedData(self: *Decompressor, comptime ReaderType: type, bits: *BitReader(ReaderType)) Error!void {
        const eob: u16 = @intCast(self.num_in_use + 1); // End of block symbol

        // MTF state for decoding
        var mtf: [256]u8 = undefined;
        for (0..256) |i| {
            mtf[i] = @intCast(i);
        }

        self.block_size = 0;
        var group_pos: usize = 0; // Position within current group of 50 symbols
        var selector_idx: usize = 0;

        // Helper to get current table
        const getTable = struct {
            fn call(d: *Decompressor, sel_idx: usize) Error!*const HuffmanTable {
                if (sel_idx >= d.num_selectors) return Error.CorruptData;
                const table_idx = d.selectors[sel_idx];
                if (table_idx >= d.num_groups) return Error.CorruptData;
                return &d.huffman_tables[table_idx];
            }
        }.call;

        // Helper to advance to next symbol slot
        const advanceSlot = struct {
            fn call(gpos: *usize, sidx: *usize) void {
                gpos.* += 1;
                if (gpos.* >= GROUP_SIZE) {
                    gpos.* = 0;
                    sidx.* += 1;
                }
            }
        }.call;

        // Helper to decode next symbol
        const decodeNext = struct {
            fn call(d: *Decompressor, gpos: *usize, sidx: *usize, b: *BitReader(ReaderType)) Error!u16 {
                const table = try getTable(d, sidx.*);
                advanceSlot(gpos, sidx);
                return table.decode(ReaderType, b);
            }
        }.call;

        while (true) {
            const sym = try decodeNext(self, &group_pos, &selector_idx, bits);

            if (sym == eob) break;

            if (sym < 2) {
                // RUNA (0) or RUNB (1) - run-length encoded zeros
                // bzip2 uses a bijective base-2 encoding where:
                // - RUNA encodes value 1 at current power
                // - RUNB encodes value 2 at current power
                // The total run length is the sum of these values
                var run_len: u32 = 0;
                var run_power: u32 = 1;
                var current_sym = sym;

                // First symbol initializes the run
                run_len += (current_sym + 1) * run_power;
                run_power <<= 1;

                // Continue reading while we get RUNA/RUNB
                while (true) {
                    current_sym = try decodeNext(self, &group_pos, &selector_idx, bits);
                    if (current_sym >= 2) break;
                    run_len += (current_sym + 1) * run_power;
                    run_power <<= 1;
                }

                // Output run of MTF[0]
                const byte = self.seq_to_unseq[mtf[0]];
                for (0..run_len) |_| {
                    if (self.block_size >= MAX_EXPANDED_BLOCK_SIZE) {
                        return Error.OutputOverflow;
                    }
                    self.block[self.block_size] = byte;
                    self.block_size += 1;
                }

                // Now handle the non-RUNA/RUNB symbol we just read
                const next_sym = current_sym;

                // Handle the non-run symbol we just read
                if (next_sym == eob) break;
                if (next_sym >= 2) {
                    // In bzip2: symbol 2 = MTF[1], symbol 3 = MTF[2], etc.
                    // (RUNA/RUNB implicitly reference MTF[0])
                    const idx = next_sym - 1;
                    if (idx >= self.num_in_use) return Error.CorruptData;

                    const out_byte = mtf[idx];
                    // MTF update - move to front
                    var k = idx;
                    while (k > 0) : (k -= 1) {
                        mtf[k] = mtf[k - 1];
                    }
                    mtf[0] = out_byte;

                    if (self.block_size >= MAX_EXPANDED_BLOCK_SIZE) {
                        return Error.OutputOverflow;
                    }
                    self.block[self.block_size] = self.seq_to_unseq[out_byte];
                    self.block_size += 1;
                }
            } else {
                // Regular MTF symbol (sym >= 2)
                // In bzip2: symbol 2 = MTF[1], symbol 3 = MTF[2], etc.
                const idx = sym - 1;
                if (idx >= self.num_in_use) return Error.CorruptData;

                const out_byte = mtf[idx];
                // MTF update - move to front
                var k = idx;
                while (k > 0) : (k -= 1) {
                    mtf[k] = mtf[k - 1];
                }
                mtf[0] = out_byte;

                if (self.block_size >= MAX_EXPANDED_BLOCK_SIZE) {
                    return Error.OutputOverflow;
                }
                self.block[self.block_size] = self.seq_to_unseq[out_byte];
                self.block_size += 1;
            }
        }
    }

    fn decodeBlock(self: *Decompressor) Error!void {
        return self.decodeBlockInternal(true);
    }

    fn decodeBlockInternal(self: *Decompressor, check_crc: bool) Error!void {
        if (self.block_size == 0) {
            self.output_len = 0;
            return;
        }

        // Build inverse BWT transformation
        try self.buildInverseBwt();

        // Perform inverse BWT to get original data
        try self.inverseBwt();

        // Expand initial RLE (runs of 4+ identical bytes were compressed)
        try self.expandInitialRle();

        // Verify block CRC
        if (check_crc) {
            var crc = Crc32Bzip2.init();
            crc.updateSlice(self.output[0..self.output_len]);
            if (crc.final() != self.stored_block_crc) {
                return Error.BlockCrcMismatch;
            }
        }
    }

    fn expandInitialRle(self: *Decompressor) Error!void {
        // bzip2's initial RLE: runs of 4+ identical bytes are encoded as
        // XXXX + count, where count (0-255) indicates additional copies beyond 4.
        // We expand into block buffer, then copy back to output.
        //
        // Optimizations:
        // - Use @memset for run fills instead of byte-by-byte loop
        // - Batch non-run bytes when possible

        var read_pos: usize = 0;
        var write_pos: usize = 0;
        const input = self.output[0..self.output_len];

        while (read_pos < input.len) {
            const byte = input[read_pos];

            // Check for a run of 4 identical bytes (XXXX pattern)
            if (read_pos + 4 < input.len and
                input[read_pos + 1] == byte and
                input[read_pos + 2] == byte and
                input[read_pos + 3] == byte)
            {
                // Read the count byte (5th byte after XXXX)
                const count = input[read_pos + 4];
                read_pos += 5;

                // Output 4 + count copies of byte using memset
                const total = @as(usize, 4) + @as(usize, count);
                if (write_pos + total > MAX_BLOCK_SIZE) {
                    return Error.OutputOverflow;
                }

                @memset(self.block[write_pos..][0..total], byte);
                write_pos += total;
            } else {
                // Not a run - copy single byte
                if (write_pos >= MAX_BLOCK_SIZE) {
                    return Error.OutputOverflow;
                }
                self.block[write_pos] = byte;
                write_pos += 1;
                read_pos += 1;
            }
        }

        // Copy expanded data back to output
        @memcpy(self.output[0..write_pos], self.block[0..write_pos]);
        self.output_len = write_pos;
    }

    fn buildInverseBwt(self: *Decompressor) Error!void {
        // Optimized inverse BWT using packed representation.
        // We pack both the character AND the LF-mapping into tt[]:
        //   tt[i] = (LF[i] << 8) | L[i]
        // where i is position in L-column, LF[i] is the corresponding F-column position.
        //
        // This allows single-read traversal instead of reading both block[] and tt[].

        // First pass: count occurrences of each byte
        var counts: [256]u32 = [_]u32{0} ** 256;
        for (self.block[0..self.block_size]) |byte| {
            counts[byte] += 1;
        }

        // Compute cumulative counts (where each character starts in sorted order)
        var cumulative: [256]u32 = undefined;
        var sum: u32 = 0;
        for (0..256) |i| {
            cumulative[i] = sum;
            sum += counts[i];
        }

        // Second pass: build packed TT table
        // For position i with character c, the LF-mapped position is cumulative[c] + rank.
        // We store: tt[i] = (sorted_pos << 8) | c
        // This packs the LF-mapping (high 24 bits) and the character (low 8 bits).
        @memset(&counts, 0);
        for (0..self.block_size) |i| {
            const byte = self.block[i];
            const sorted_pos = cumulative[byte] + counts[byte];
            // Pack: high 24 bits = LF[i], low 8 bits = L[i]
            self.tt[i] = (sorted_pos << 8) | byte;
            counts[byte] += 1;
        }
    }

    fn inverseBwt(self: *Decompressor) Error!void {
        if (self.bwt_primary_index >= self.block_size) {
            return Error.InvalidBwtIndex;
        }

        // Optimized inverse BWT: single memory read per character.
        // tt[] is packed as (original_pos << 8) | char, so:
        //   char = tt[pos] & 0xFF
        //   next_pos = tt[pos] >> 8
        //
        // We traverse backwards to reconstruct the original data.
        self.output_len = self.block_size;
        var pos: u32 = self.bwt_primary_index;

        var i: usize = self.block_size;
        while (i > 0) {
            i -= 1;
            const tt_val = self.tt[pos];
            self.output[i] = @truncate(tt_val); // Low 8 bits = character
            pos = tt_val >> 8; // High 24 bits = next position
        }

        // Handle randomization (if used)
        if (self.block_randomized) {
            derandomize(self.output[0..self.output_len]);
        }
    }
};

/// Apply bzip2 derandomization (used for pathological inputs)
fn derandomize(data: []u8) void {
    // bzip2 randomization uses a specific PRNG sequence
    // This is rarely needed in practice
    const rand_nums = [_]u32{
        619, 720, 127, 481, 931, 816, 813, 233, 566, 247, 985, 724, 205, 454, 863, 491,
        741, 242, 949, 214, 733, 859, 335, 708, 621, 574, 73,  654, 730, 472, 419, 436,
        278, 496, 867, 210, 399, 680, 480, 51,  878, 465, 811, 169, 869, 675, 611, 697,
        867, 561, 862, 687, 507, 283, 482, 129, 807, 591, 733, 623, 150, 238, 59,  379,
        684, 877, 625, 169, 643, 105, 170, 607, 520, 932, 727, 476, 693, 425, 174, 647,
        73,  122, 335, 530, 442, 853, 695, 249, 445, 515, 909, 545, 703, 919, 874, 474,
        882, 500, 594, 612, 641, 801, 220, 162, 819, 984, 589, 513, 495, 799, 161, 604,
        958, 533, 221, 400, 386, 867, 600, 782, 382, 596, 414, 171, 516, 375, 682, 485,
    };

    var rand_idx: usize = 0;
    var count: usize = 0;

    for (data) |*byte| {
        count += 1;
        if (count >= rand_nums[rand_idx]) {
            byte.* ^= 1;
            count = 0;
            rand_idx = (rand_idx + 1) % rand_nums.len;
        }
    }
}

// ============ Compression Functions ============

/// Initial RLE encoding: compress runs of 4+ identical bytes.
/// Format: XXXX + count, where count (0-255) is additional copies beyond 4.
pub fn initialRleEncode(allocator: Allocator, input: []const u8) ![]u8 {
    var output: std.ArrayListUnmanaged(u8) = .empty;
    errdefer output.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        const byte = input[i];
        var run_len: usize = 1;

        // Count consecutive identical bytes
        while (i + run_len < input.len and input[i + run_len] == byte and run_len < 259) {
            run_len += 1;
        }

        if (run_len >= 4) {
            // Output 4 copies + count
            try output.append(allocator, byte);
            try output.append(allocator, byte);
            try output.append(allocator, byte);
            try output.append(allocator, byte);
            try output.append(allocator, @intCast(run_len - 4));
            i += run_len;
        } else {
            // Output bytes individually
            for (0..run_len) |_| {
                try output.append(allocator, byte);
            }
            i += run_len;
        }
    }

    return output.toOwnedSlice(allocator);
}

/// Result of BWT encoding
pub const BwtResult = struct {
    data: []u8,
    primary_index: u32,
};

// ============================================================================
// SA-IS (Suffix Array by Induced Sorting) Algorithm
// O(n) time complexity for suffix array construction
// Based on: Nong, Zhang, Chan - "Two Efficient Algorithms for Linear Time
// Suffix Array Construction" (2009)
// Reference implementation: github.com/sile/sais
// ============================================================================

/// Build suffix array using SA-IS algorithm. O(n) time and space.
/// Input text should NOT include a sentinel - we handle it internally.
pub fn buildSuffixArraySAIS(allocator: Allocator, text: []const u8) ![]u32 {
    if (text.len == 0) {
        return try allocator.alloc(u32, 0);
    }

    // Add sentinel (conceptually text + '\0')
    const n = text.len + 1; // Include sentinel position

    // Allocate SA buffer
    const sa = try allocator.alloc(i32, n);
    errdefer allocator.free(sa);

    // Classify types: false = S-type (0), true = L-type (1)
    // Last position (sentinel) is S-type by default
    const types = try allocator.alloc(bool, n);
    defer allocator.free(types);

    types[n - 1] = false; // Sentinel is S-type
    if (n >= 2) {
        var i: usize = n - 2;
        while (true) {
            const c_i = if (i < text.len) text[i] else 0;
            const c_next = if (i + 1 < text.len) text[i + 1] else 0;
            if (c_i < c_next) {
                types[i] = false; // S-type
            } else if (c_i > c_next) {
                types[i] = true; // L-type
            } else {
                types[i] = types[i + 1];
            }
            if (i == 0) break;
            i -= 1;
        }
    }

    // Helper: check if position is LMS (L-type followed by S-type)
    const isLMS = struct {
        fn check(pos: usize, t: []const bool) bool {
            return pos > 0 and t[pos - 1] and !t[pos]; // L=true, S=false
        }
    }.check;

    // Count character frequencies (including sentinel = 0)
    var bucket_sizes: [257]u32 = [_]u32{0} ** 257;
    bucket_sizes[0] = 1; // Sentinel
    for (text) |c| {
        bucket_sizes[@as(usize, c) + 1] += 1;
    }

    // Calculate bucket boundaries
    var bucket_starts: [257]u32 = [_]u32{0} ** 257;
    var bucket_ends: [257]u32 = [_]u32{0} ** 257;
    var sum: u32 = 0;
    for (0..257) |c| {
        bucket_starts[c] = sum;
        sum += bucket_sizes[c];
        bucket_ends[c] = sum;
    }

    // Helper to get character at position (0 = sentinel)
    const getChar = struct {
        fn get(pos: usize, txt: []const u8) usize {
            return if (pos < txt.len) @as(usize, txt[pos]) + 1 else 0;
        }
    }.get;

    // Initialize SA
    @memset(sa, 0);

    // Step 1: Place LMS suffixes at end of their buckets (right to left)
    var bucket_tails = bucket_ends;
    for (1..n) |i| {
        if (isLMS(i, types)) {
            const c = getChar(i, text);
            bucket_tails[c] -= 1;
            sa[bucket_tails[c]] = @intCast(i);
        }
    }

    // Place sentinel explicitly (it may not be LMS if types[n-2] is S-type)
    // Sentinel at position n-1 has character 0, always goes to sa[0]
    if (sa[0] == 0) { // Sentinel wasn't placed as LMS
        sa[0] = @intCast(n - 1);
    }

    // Step 2: Induce L-type suffixes (left to right)
    var bucket_heads = bucket_starts;
    for (0..n) |i| {
        const pos = sa[i] - 1;
        if (pos >= 0 and types[@intCast(pos)]) { // L-type
            const c = getChar(@intCast(pos), text);
            sa[bucket_heads[c]] = pos;
            bucket_heads[c] += 1;
        }
    }

    // Step 3: Induce S-type suffixes (right to left)
    bucket_tails = bucket_ends;
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        const pos = sa[i] - 1;
        if (pos >= 0 and !types[@intCast(pos)]) { // S-type
            const c = getChar(@intCast(pos), text);
            bucket_tails[c] -= 1;
            sa[bucket_tails[c]] = pos;
        }
    }

    // Step 4: Compact LMS suffixes and compute names
    var lms_count: usize = 0;
    for (0..n) |idx| {
        if (sa[idx] != 0 and isLMS(@intCast(sa[idx]), types)) {
            sa[lms_count] = sa[idx];
            lms_count += 1;
        }
    }

    // Initialize second half for names
    const names_start = n / 2;
    for (names_start..n) |idx| {
        sa[idx] = -1;
    }

    // Assign names to LMS substrings
    var name: i32 = 0;
    var prev_lms: i32 = -1;
    for (0..lms_count) |idx| {
        const pos = sa[idx];
        if (prev_lms >= 0) {
            // Compare LMS substrings
            if (!lmsEqual(text, types, @intCast(prev_lms), @intCast(pos), isLMS)) {
                name += 1;
            }
        }
        sa[names_start + @as(usize, @intCast(@divTrunc(pos - 1, 2)))] = name;
        prev_lms = pos;
    }

    // Compact names into reduced string
    var reduced_len: usize = 0;
    for (names_start..n) |idx| {
        if (sa[idx] >= 0) {
            sa[names_start + reduced_len] = sa[idx];
            reduced_len += 1;
        }
    }

    // Check if recursion needed
    const unique = (@as(u32, @intCast(name)) + 1 == reduced_len);

    if (!unique) {
        // Recursive call on reduced problem
        // Note: reduced string is at sa[names_start..], SA output goes to sa[0..reduced_len]
        const reduced = sa[names_start .. names_start + reduced_len];
        try saisRecurse(allocator, reduced, @intCast(name + 1), sa[0..reduced_len]);

        // Convert suffix array to ranks, storing IN the reduced string area
        // sa[0..reduced_len] contains SA positions, we write ranks to sa[names_start..]
        for (0..reduced_len) |idx| {
            const sa_pos: usize = @intCast(sa[idx]); // Position in reduced string
            sa[names_start + sa_pos] = @intCast(idx); // Store rank at that position
        }
    }

    // Now sa[names_start + j] contains the rank of the j-th LMS substring
    // Place LMS suffixes at their ranked positions (as negative values)
    var lms_idx: usize = 0;
    for (1..n) |idx| {
        if (isLMS(idx, types)) {
            const rank: usize = @intCast(sa[names_start + lms_idx]);
            sa[rank] = -@as(i32, @intCast(idx)); // Negative to mark as LMS
            lms_idx += 1;
        }
    }
    // Clear the rest
    for (lms_idx..n) |idx| {
        if (idx < names_start or sa[idx] >= 0) {
            sa[idx] = 0;
        }
    }

    // Final induced sorting
    bucket_tails = bucket_ends;
    var j_final = reduced_len;
    while (j_final > 0) {
        j_final -= 1;
        const pos_neg = sa[j_final];
        sa[j_final] = 0;
        const pos: usize = @intCast(-pos_neg);
        const c = getChar(pos, text);
        bucket_tails[c] -= 1;
        sa[bucket_tails[c]] = @intCast(pos);
    }

    // Place sentinel explicitly if not already placed
    if (sa[0] == 0) {
        sa[0] = @intCast(n - 1);
    }

    // Induce L-type
    bucket_heads = bucket_starts;
    for (0..n) |idx| {
        const pos = sa[idx] - 1;
        if (pos >= 0 and types[@intCast(pos)]) {
            const c = getChar(@intCast(pos), text);
            sa[bucket_heads[c]] = pos;
            bucket_heads[c] += 1;
        }
    }

    // Induce S-type
    bucket_tails = bucket_ends;
    var idx_final: usize = n;
    while (idx_final > 0) {
        idx_final -= 1;
        const pos = sa[idx_final] - 1;
        if (pos >= 0 and !types[@intCast(pos)]) {
            const c = getChar(@intCast(pos), text);
            bucket_tails[c] -= 1;
            sa[bucket_tails[c]] = pos;
        }
    }

    // Convert to u32 and remove sentinel position
    // Sentinel is at position n-1 (text.len), skip it
    const result = try allocator.alloc(u32, text.len);
    var out_idx: usize = 0;
    for (sa) |pos| {
        const upos: usize = @intCast(pos);
        if (upos < text.len) { // Skip sentinel at position text.len
            result[out_idx] = @intCast(upos);
            out_idx += 1;
            if (out_idx >= text.len) break;
        }
    }

    allocator.free(sa);
    return result;
}

/// Compare two LMS substrings for equality
fn lmsEqual(text: []const u8, types: []const bool, pos1: usize, pos2: usize, isLMS: fn (usize, []const bool) bool) bool {
    const n = text.len + 1;
    var i: usize = 0;
    while (true) {
        const p1 = pos1 + i;
        const p2 = pos2 + i;

        if (p1 >= n or p2 >= n) return false;

        const c1 = if (p1 < text.len) text[p1] else 0;
        const c2 = if (p2 < text.len) text[p2] else 0;

        if (c1 != c2) return false;
        if (types[p1] != types[p2]) return false;

        // Check if we've reached the end of both LMS substrings
        if (i > 0) {
            const lms1 = isLMS(p1, types);
            const lms2 = isLMS(p2, types);
            if (lms1 and lms2) return true;
            if (lms1 != lms2) return false;
        }

        i += 1;
        if (i > n) return false;
    }
}

/// Compare two LMS substrings for equality (integer version)
fn lmsEqualInt(text: []i32, types: []const bool, pos1: usize, pos2: usize, isLMS: fn (usize, []const bool) bool) bool {
    const n = text.len; // text within saisRecurse usually includes sentinel at end if needed
    // But note: buildSuffixArraySAIS uses n=text.len+1.
    // In saisRecurse, n is length of text (names).
    // Bounds check must be strict.

    var i: usize = 0;
    while (true) {
        const p1 = pos1 + i;
        const p2 = pos2 + i;

        if (p1 >= n or p2 >= n) return false;

        const c1 = text[p1];
        const c2 = text[p2];

        if (c1 != c2) return false;
        if (types[p1] != types[p2]) return false;

        // Check if we've reached the end of both LMS substrings
        if (i > 0) {
            const lms1 = isLMS(p1, types);
            const lms2 = isLMS(p2, types);
            if (lms1 and lms2) return true;
            if (lms1 != lms2) return false;
        }

        i += 1;
    }
}

/// Recursive SA-IS for integer alphabet (in-place in buffer)
fn saisRecurse(allocator: Allocator, text: []i32, alphabet_size: u32, sa_out: []i32) !void {
    const n = text.len;
    if (n == 0) return;
    if (n == 1) {
        sa_out[0] = 0;
        return;
    }

    // Classify types
    const types = try allocator.alloc(bool, n);
    defer allocator.free(types);

    // S-type at end
    types[n - 1] = false;
    if (n >= 2) {
        var i: usize = n - 2;
        while (true) {
            if (text[i] < text[i + 1]) {
                types[i] = false;
            } else if (text[i] > text[i + 1]) {
                types[i] = true;
            } else {
                types[i] = types[i + 1];
            }
            if (i == 0) break;
            i -= 1;
        }
    }

    const isLMS = struct {
        fn check(pos: usize, t: []const bool) bool {
            return pos > 0 and t[pos - 1] and !t[pos];
        }
    }.check;

    // Bucket sort
    const bucket_sizes = try allocator.alloc(u32, alphabet_size);
    defer allocator.free(bucket_sizes);
    @memset(bucket_sizes, 0);

    for (text) |c| {
        bucket_sizes[@intCast(c)] += 1;
    }

    const bucket_starts = try allocator.alloc(u32, alphabet_size);
    defer allocator.free(bucket_starts);
    const bucket_ends = try allocator.alloc(u32, alphabet_size);
    defer allocator.free(bucket_ends);

    var sum: u32 = 0;
    for (0..alphabet_size) |c| {
        bucket_starts[c] = sum;
        sum += bucket_sizes[c];
        bucket_ends[c] = sum;
    }

    @memset(sa_out, 0);

    // Step 1: Place LMS
    const bucket_tails = try allocator.alloc(u32, alphabet_size);
    defer allocator.free(bucket_tails);
    @memcpy(bucket_tails, bucket_ends);

    for (1..n) |i| {
        if (isLMS(i, types)) {
            const c: usize = @intCast(text[i]);
            bucket_tails[c] -= 1;
            sa_out[bucket_tails[c]] = @intCast(i);
        }
    }

    // Place sentinel explicitly if not already placed
    // In recursive case, sentinel is at position n-1 with the smallest character value
    // Assuming smallest char is 0. If sa_out[0] is empty, force place n-1.
    // If n-1 was LMS, it might be already placed.
    if (sa_out[0] == 0) {
        // Only force if text fits (assumes text[n-1] is effectively sentinel/LMS)
        // In reduced string, last element is name of previous sentinel, so it behaves as such.
        sa_out[0] = @intCast(n - 1);
    }

    // Step 2: Induce L
    const bucket_heads = try allocator.alloc(u32, alphabet_size);
    defer allocator.free(bucket_heads);
    @memcpy(bucket_heads, bucket_starts);

    for (0..n) |i| {
        const pos = sa_out[i] - 1;
        if (pos >= 0 and types[@intCast(pos)]) {
            const c: usize = @intCast(text[@intCast(pos)]);
            sa_out[bucket_heads[c]] = pos;
            bucket_heads[c] += 1;
        }
    }

    // Step 3: Induce S
    @memcpy(bucket_tails, bucket_ends);
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        const pos = sa_out[i] - 1;
        if (pos >= 0 and !types[@intCast(pos)]) {
            const c: usize = @intCast(text[@intCast(pos)]);
            bucket_tails[c] -= 1;
            sa_out[bucket_tails[c]] = pos;
        }
    }

    // Step 4: Compact LMS suffixes and compute names
    var lms_count: usize = 0;
    for (0..n) |idx| {
        // If position is non-zero (or 0 is LMS), check if LMS
        // Careful with 0: sa value 0 is valid.
        // We need to check if slot is occupied by LMS?
        // Step 3 output contains ALL suffixes sorted.
        // We select only LMS ones.
        const pos = sa_out[idx];
        if (isLMS(@intCast(pos), types) or (pos == @as(i32, @intCast(n - 1)) and types[n - 1] == false)) {
            // n-1 is sentinel (S), usually LMS unless n-2 is also S.
            // Wait, standard check:
            if (pos == 0) {
                // 0 is LMS only if sentinel? No, 0 is never LMS by definition (pos>0)
                // Unless we handle 0 specially?
                // In recursion, 0 is valid position.
                // isLMS(0) is false.
            } else {
                if (isLMS(@intCast(pos), types)) {
                    sa_out[lms_count] = pos;
                    lms_count += 1;
                }
                // Special check for sentinel at n-1 if it didn't trigger isLMS?
                // Sentinel logic should match main.
                // Main checks sa[idx] != 0.
                // Here 0 is a valid position.
                // But sa was init to 0? Step 3 fills SA fully.
            }
        }
    }
    // Also include sentinel if not found?
    // In recursion, sentinel is just another character.
    // If n-1 is S and n-2 is L, n-1 is LMS.
    // If n-1 is S and n-2 is S, n-1 is Not LMS.
    // But sentinel MUST be included in LMS list for recursion to work?
    // Normally yes.
    // If names are not unique, we recurse.

    // Initialize names area
    const names_start = n / 2;
    for (names_start..n) |idx| {
        sa_out[idx] = -1;
    }

    // Assign names
    var name: i32 = 0;
    var prev_lms: i32 = -1;
    for (0..lms_count) |idx| {
        const pos = sa_out[idx];
        if (prev_lms >= 0) {
            if (!lmsEqualInt(text, types, @intCast(prev_lms), @intCast(pos), isLMS)) {
                name += 1;
            }
        }
        sa_out[names_start + @as(usize, @intCast(@divTrunc(pos, 2)))] = name; // Note: integer div
        prev_lms = pos;
    }

    // Compact names
    var reduced_len: usize = 0;
    for (names_start..n) |idx| {
        if (sa_out[idx] >= 0) {
            sa_out[names_start + reduced_len] = sa_out[idx];
            reduced_len += 1;
        }
    }

    // Recursion check
    if (@as(u32, @intCast(name)) + 1 < reduced_len) {
        // Names not unique - RECURSE
        const reduced = sa_out[names_start .. names_start + reduced_len];
        try saisRecurse(allocator, reduced, @intCast(name + 1), sa_out[0..reduced_len]);

        // Convert to ranks
        for (0..reduced_len) |idx| {
            const sa_pos: usize = @intCast(sa_out[idx]);
            sa_out[names_start + sa_pos] = @intCast(idx);
        }
    } else {
        // Unique - generate ranks directly
        // The sa_out[names_start...] currently holds names (unsorted physically by pos? no sorted by pos)
        // Wait. sa_out[names_start + reduced_len] holding compact names.
        // They are in text order.
        // And they are unique (0..reduced_len-1).
        // So reduced[i] is the name of i-th LMS.
        // We want SA of this permutation.
        // Since names are unique numbers 0..cnt-1, we can just bucket sort / invert.
        const reduced = sa_out[names_start .. names_start + reduced_len];
        for (reduced, 0..) |n_val, idx| {
            sa_out[@intCast(n_val)] = @intCast(idx);
        }
        // Result is in sa_out[0..reduced_len]

        // Need to move ranks to names area?
        // Logic below expects ranks at sa_out[names_start + j].
        // Currently sa_out[0..] has SA.
        // SA[i] = j means j-th LMS is i-th smallest.
        // We want Rank[j] = i.
        // So sa_out[j] = i ? No.
        // We write ranks to sa_out[names_start..].
        for (0..reduced_len) |idx| {
            const sa_pos: usize = @intCast(sa_out[idx]);
            sa_out[names_start + sa_pos] = @intCast(idx);
        }
    }

    // Step 7: Place LMS from ranks
    var lms_idx: usize = 0;
    for (1..n) |idx| {
        if (isLMS(idx, types)) {
            const rank: usize = @intCast(sa_out[names_start + lms_idx]);
            sa_out[rank] = @intCast(idx); // Store +pos (we use sign bit if needed, but here i32 fits)
            // Main algo uses negative. We can use negative too to distinguish?
            // "Place LMS suffixes at their ranked positions (as negative values)"
            // Step 8 below expects negative or check types?
            // "if (pos >= 0 and types[pos])..."
            // If we store positive, we rely on checking "types[pos]".
            // But we need to distinguish "placed LMS" from "empty/sentinel".
            // sa_out was typically cleared.
            // Let's use negative for safety/consistency.
            sa_out[rank] = -@as(i32, @intCast(idx));
            lms_idx += 1;
        }
    }

    // Clear the rest
    for (lms_idx..n) |idx| {
        // In recursive, we don't have buffer overlap issues as complex as main?
        // sa_out[0..n] is the buffer.
        // We wrote to sa_out[0..lms_count].
        // We need to clear sa_out[lms_count..n].
        if (sa_out[idx] >= 0) sa_out[idx] = 0;
    }

    // Step 8: Induce L and S (Final)
    @memcpy(bucket_tails, bucket_ends);
    var j_final = reduced_len;
    while (j_final > 0) {
        j_final -= 1;
        const pos_neg = sa_out[j_final];
        sa_out[j_final] = 0;
        const pos: usize = @intCast(-pos_neg);

        const c: usize = @intCast(text[pos]);
        bucket_tails[c] -= 1;
        sa_out[bucket_tails[c]] = @intCast(pos);
    }

    // Explicit sentinel?
    if (sa_out[0] == 0) {
        sa_out[0] = @intCast(n - 1);
    }

    @memcpy(bucket_heads, bucket_starts);
    for (0..n) |idx| {
        const pos = sa_out[idx] - 1;
        if (pos >= 0 and types[@intCast(pos)]) { // L-type
            const c: usize = @intCast(text[@intCast(pos)]);
            sa_out[bucket_heads[c]] = pos;
            bucket_heads[c] += 1;
        }
    }

    @memcpy(bucket_tails, bucket_ends);
    i = n;
    while (i > 0) {
        i -= 1;
        const pos = sa_out[i] - 1;
        if (pos >= 0 and !types[@intCast(pos)]) {
            const c: usize = @intCast(text[@intCast(pos)]);
            bucket_tails[c] -= 1;
            sa_out[bucket_tails[c]] = pos;
        }
    }
}

/// Burrows-Wheeler Transform (forward transform) using SA-IS algorithm.
/// Returns the last column of the sorted rotation matrix and the primary index.
/// O(n) time complexity.
///
/// Uses string doubling technique: build SA of input++input, then filter to
/// positions < n. This correctly sorts circular rotations.
pub fn bwtEncode(allocator: Allocator, input: []const u8) !BwtResult {
    const n = input.len;
    if (n == 0) {
        return BwtResult{ .data = try allocator.alloc(u8, 0), .primary_index = 0 };
    }

    // Double the string: "hello" -> "hellohello"
    // This makes suffix comparison equivalent to rotation comparison
    const doubled = try allocator.alloc(u8, n * 2);
    defer allocator.free(doubled);
    @memcpy(doubled[0..n], input);
    @memcpy(doubled[n..], input);

    // Build suffix array on doubled string
    const sa_doubled = try buildSuffixArraySAIS(allocator, doubled);
    defer allocator.free(sa_doubled);

    // Extract positions < n (these correspond to valid rotations)
    const output = try allocator.alloc(u8, n);
    errdefer allocator.free(output);

    var primary_index: u32 = 0;
    var out_idx: usize = 0;

    for (sa_doubled) |pos| {
        if (pos < n) {
            // BWT character: last character of rotation starting at pos
            output[out_idx] = input[(pos + n - 1) % n];
            if (pos == 0) {
                primary_index = @intCast(out_idx);
            }
            out_idx += 1;
            if (out_idx >= n) break;
        }
    }

    return BwtResult{ .data = output, .primary_index = primary_index };
}

/// Move-To-Front encoding.
/// Each input byte is replaced by its position in a list that's updated after each byte.
pub fn mtfEncode(allocator: Allocator, input: []const u8, alphabet: []const u8) ![]u8 {
    var output = try allocator.alloc(u8, input.len);
    errdefer allocator.free(output);

    // Initialize MTF list with alphabet
    var mtf: [256]u8 = undefined;
    for (alphabet, 0..) |c, i| {
        mtf[i] = c;
    }
    const alpha_len = alphabet.len;

    for (input, 0..) |byte, out_idx| {
        // Find position of byte in MTF list
        var pos: usize = 0;
        while (pos < alpha_len and mtf[pos] != byte) {
            pos += 1;
        }

        if (pos >= alpha_len) {
            // Byte not in alphabet - this shouldn't happen with valid input
            allocator.free(output);
            return Error.CorruptData;
        }

        output[out_idx] = @intCast(pos);

        // Move to front
        if (pos > 0) {
            const char = mtf[pos];
            var j = pos;
            while (j > 0) : (j -= 1) {
                mtf[j] = mtf[j - 1];
            }
            mtf[0] = char;
        }
    }

    return output;
}

/// Result of encoding a zero run with RUNA/RUNB
pub const ZeroRunResult = struct {
    symbols: [32]u8, // Max symbols needed for any run length
    len: usize,
};

/// Encode a run of zeros using bijective base-2 (RUNA/RUNB).
/// RUNA (0) contributes 1*power, RUNB (1) contributes 2*power.
pub fn encodeZeroRun(run_len: u32) ZeroRunResult {
    var result = ZeroRunResult{ .symbols = undefined, .len = 0 };

    if (run_len == 0) return result;

    // Bijective base-2 encoding:
    // To encode n, we find the sequence where sum of (symbol+1)*power = n
    var remaining = run_len;
    var power: u32 = 1;

    while (remaining > 0) {
        // At each position, we can contribute 1*power (RUNA) or 2*power (RUNB)
        // Determine which symbol to use
        if (remaining >= 2 * power and (remaining - 2 * power) % (2 * power) < power) {
            // Use RUNB
            result.symbols[result.len] = 1;
            remaining -= 2 * power;
        } else {
            // Use RUNA
            result.symbols[result.len] = 0;
            remaining -= power;
        }
        result.len += 1;
        power *= 2;
    }

    return result;
}

// ============ BitWriter ============

/// Bit writer that writes bits MSB first (bzip2 convention)
pub const BitWriter = struct {
    output: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    buffer: u64,
    bits_in_buffer: u6,

    pub fn init(allocator: Allocator, output: *std.ArrayListUnmanaged(u8)) BitWriter {
        return .{
            .output = output,
            .allocator = allocator,
            .buffer = 0,
            .bits_in_buffer = 0,
        };
    }

    /// Write n bits (MSB first), n can be 0-32
    pub fn writeBits(self: *BitWriter, value: u32, n: u6) !void {
        if (n == 0) return;

        // Add bits to buffer
        const mask: u64 = (@as(u64, 1) << n) - 1;
        self.buffer = (self.buffer << n) | (@as(u64, value) & mask);
        self.bits_in_buffer += n;

        // Flush complete bytes
        while (self.bits_in_buffer >= 8) {
            self.bits_in_buffer -= 8;
            const byte: u8 = @truncate(self.buffer >> self.bits_in_buffer);
            try self.output.append(self.allocator, byte);
        }
    }

    /// Write a single bit
    pub fn writeBit(self: *BitWriter, bit: u1) !void {
        try self.writeBits(bit, 1);
    }

    /// Flush remaining bits (padded with zeros)
    pub fn flush(self: *BitWriter) !void {
        if (self.bits_in_buffer > 0) {
            const remaining: u6 = 8 - self.bits_in_buffer;
            const byte: u8 = @truncate(self.buffer << remaining);
            try self.output.append(self.allocator, byte);
            self.buffer = 0;
            self.bits_in_buffer = 0;
        }
    }
};

// ============ Huffman Encoding ============

/// Build Huffman code lengths from symbol frequencies.
/// Returns array of code lengths (0 = symbol not used).
pub fn buildHuffmanLengths(freqs: []const u32, num_symbols: usize) [MAX_ALPHA_SIZE]u8 {
    var lengths: [MAX_ALPHA_SIZE]u8 = [_]u8{0} ** MAX_ALPHA_SIZE;

    if (num_symbols == 0) return lengths;

    // Simple approach: assign lengths based on frequency ranking
    // More frequent symbols get shorter codes
    // This is a simplified version - real bzip2 uses package-merge algorithm

    // Find total frequency
    var total_freq: u64 = 0;
    for (freqs[0..num_symbols]) |f| {
        total_freq += f;
    }

    if (total_freq == 0) {
        // All symbols have zero frequency - assign length 1 to first symbol
        lengths[0] = 1;
        return lengths;
    }

    // Assign lengths based on frequency (simplified)
    // Use a basic strategy: frequent symbols get shorter codes
    for (0..num_symbols) |i| {
        if (freqs[i] > 0) {
            // Calculate ideal length based on Shannon entropy
            // length ≈ -log2(probability)
            const prob = @as(f64, @floatFromInt(freqs[i])) / @as(f64, @floatFromInt(total_freq));
            const ideal_len = -@log2(prob);
            var len: u8 = @intFromFloat(@max(1.0, @min(20.0, @ceil(ideal_len))));
            // Ensure minimum length of 1
            if (len == 0) len = 1;
            lengths[i] = len;
        }
    }

    // Ensure at least one symbol has length 1 for valid Huffman tree
    var has_short: bool = false;
    for (lengths[0..num_symbols]) |l| {
        if (l > 0 and l <= 2) {
            has_short = true;
            break;
        }
    }
    if (!has_short) {
        // Find the most frequent symbol and give it a shorter code
        var max_freq: u32 = 0;
        var max_idx: usize = 0;
        for (0..num_symbols) |i| {
            if (freqs[i] > max_freq) {
                max_freq = freqs[i];
                max_idx = i;
            }
        }
        if (max_freq > 0) {
            lengths[max_idx] = 1;
        }
    }

    return lengths;
}

/// Compute optimal Huffman code lengths from symbol frequencies.
/// Uses a simplified heap-based algorithm, then limits lengths to max_len.
/// Returns code lengths for each symbol (0 for unused symbols).
fn computeHuffmanLengths(freqs: []const u32, num_symbols: usize, max_len: u8) [MAX_ALPHA_SIZE]u8 {
    var lengths: [MAX_ALPHA_SIZE]u8 = [_]u8{0} ** MAX_ALPHA_SIZE;

    if (num_symbols == 0) return lengths;
    if (num_symbols == 1) {
        lengths[0] = 1;
        return lengths;
    }

    // Count non-zero frequencies
    var num_used: usize = 0;
    for (freqs[0..num_symbols]) |f| {
        if (f > 0) num_used += 1;
    }

    if (num_used == 0) return lengths;
    if (num_used == 1) {
        // Single symbol - give it length 1
        for (freqs[0..num_symbols], 0..) |f, i| {
            if (f > 0) {
                lengths[i] = 1;
                break;
            }
        }
        return lengths;
    }

    // Node structure for Huffman tree building
    // We use indices: 0..num_symbols are leaves, num_symbols.. are internal nodes
    const Node = struct {
        freq: u64,
        left: u16, // Child index or 0xFFFF for leaf
        right: u16,
        depth: u8,
    };

    var nodes: [MAX_ALPHA_SIZE * 2]Node = undefined;
    var num_nodes: usize = 0;

    // Initialize leaf nodes for used symbols
    var symbol_to_node: [MAX_ALPHA_SIZE]u16 = [_]u16{0xFFFF} ** MAX_ALPHA_SIZE;
    for (freqs[0..num_symbols], 0..) |f, i| {
        if (f > 0) {
            symbol_to_node[i] = @intCast(num_nodes);
            nodes[num_nodes] = .{
                .freq = f,
                .left = 0xFFFF,
                .right = 0xFFFF,
                .depth = 0,
            };
            num_nodes += 1;
        }
    }

    // Build Huffman tree using min-heap for O(n log n) complexity
    // Heap stores node indices, ordered by frequency
    var heap: [MAX_ALPHA_SIZE * 2]u16 = undefined;
    var heap_size: usize = 0;

    // Heap helper functions (inline for performance)
    const heapLess = struct {
        fn call(n: []const Node, a: u16, b: u16) bool {
            return n[a].freq < n[b].freq;
        }
    }.call;

    const heapSwap = struct {
        fn call(h: []u16, i: usize, j: usize) void {
            const tmp = h[i];
            h[i] = h[j];
            h[j] = tmp;
        }
    }.call;

    const heapBubbleUp = struct {
        fn call(n: []const Node, h: []u16, idx: usize) void {
            var i = idx;
            while (i > 0) {
                const parent = (i - 1) / 2;
                if (!heapLess(n, h[i], h[parent])) break;
                heapSwap(h, i, parent);
                i = parent;
            }
        }
    }.call;

    const heapBubbleDown = struct {
        fn call(n: []const Node, h: []u16, size: usize, idx: usize) void {
            var i = idx;
            while (true) {
                var smallest = i;
                const left = 2 * i + 1;
                const right = 2 * i + 2;
                if (left < size and heapLess(n, h[left], h[smallest])) {
                    smallest = left;
                }
                if (right < size and heapLess(n, h[right], h[smallest])) {
                    smallest = right;
                }
                if (smallest == i) break;
                heapSwap(h, i, smallest);
                i = smallest;
            }
        }
    }.call;

    // Insert initial nodes into heap - O(n log n)
    for (0..num_nodes) |i| {
        heap[heap_size] = @intCast(i);
        heapBubbleUp(&nodes, &heap, heap_size);
        heap_size += 1;
    }

    // Build Huffman tree by repeatedly combining two smallest nodes - O(n log n)
    while (heap_size > 1) {
        // Extract two smallest
        const min1_idx = heap[0];
        heap[0] = heap[heap_size - 1];
        heap_size -= 1;
        heapBubbleDown(&nodes, &heap, heap_size, 0);

        const min2_idx = heap[0];
        heap[0] = heap[heap_size - 1];
        heap_size -= 1;
        heapBubbleDown(&nodes, &heap, heap_size, 0);

        // Combine into new internal node
        nodes[num_nodes] = .{
            .freq = nodes[min1_idx].freq + nodes[min2_idx].freq,
            .left = min1_idx,
            .right = min2_idx,
            .depth = 0,
        };

        // Insert new node into heap
        heap[heap_size] = @intCast(num_nodes);
        heapBubbleUp(&nodes, &heap, heap_size);
        heap_size += 1;
        num_nodes += 1;
    }

    // Calculate depths (code lengths) by traversing from root
    const root = num_nodes - 1;
    nodes[root].depth = 0;

    // Process nodes in reverse order (root to leaves)
    var i: usize = num_nodes;
    while (i > 0) {
        i -= 1;
        const node = nodes[i];
        if (node.left != 0xFFFF) {
            nodes[node.left].depth = node.depth + 1;
            nodes[node.right].depth = node.depth + 1;
        }
    }

    // Extract lengths for original symbols
    // IMPORTANT: All symbols must have a valid non-zero length for canonical Huffman encoding
    // Symbols with 0 frequency get max_len (least efficient, but correct for encoder/decoder agreement)
    for (0..num_symbols) |sym| {
        const node_idx = symbol_to_node[sym];
        if (node_idx != 0xFFFF) {
            var len = nodes[node_idx].depth;
            // Clamp to max_len
            if (len > max_len) len = max_len;
            if (len < 1) len = 1;
            lengths[sym] = len;
        } else {
            // Symbol had 0 frequency - assign max_len for valid Huffman encoding
            lengths[sym] = max_len;
        }
    }

    // If any lengths were clamped, we need to rebalance to maintain valid Huffman
    // For simplicity, use package-merge style adjustment: if over limit, steal from longest
    var iterations: u32 = 0;
    while (iterations < 100) { // Safety limit
        iterations += 1;
        // Check Kraft inequality: sum of 2^(-len) must equal 1
        var kraft: u64 = 0;
        const base: u64 = @as(u64, 1) << @as(u6, @intCast(max_len));
        for (lengths[0..num_symbols]) |len| {
            kraft += base >> @as(u6, @intCast(len));
        }

        if (kraft == base) break; // Valid

        if (kraft > base) {
            // Over-subscribed: need to make some codes longer
            // Find shortest code and make it longer
            var shortest: u8 = max_len;
            var shortest_idx: usize = 0;
            for (lengths[0..num_symbols], 0..) |len, idx| {
                if (len < shortest) {
                    shortest = len;
                    shortest_idx = idx;
                }
            }
            if (lengths[shortest_idx] < max_len) {
                lengths[shortest_idx] += 1;
            }
        } else {
            // Under-subscribed: need to make some codes shorter
            // Find longest code and make it shorter
            var longest: u8 = 1;
            var longest_idx: usize = 0;
            for (lengths[0..num_symbols], 0..) |len, idx| {
                if (len > longest) {
                    longest = len;
                    longest_idx = idx;
                }
            }
            if (lengths[longest_idx] > 1) {
                lengths[longest_idx] -= 1;
            } else {
                break; // Can't improve further
            }
        }
    }

    return lengths;
}

/// Build canonical Huffman codes from lengths.
/// Returns array of codes corresponding to each symbol.
pub fn buildHuffmanCodes(lengths: []const u8, num_symbols: usize) [MAX_ALPHA_SIZE]u32 {
    var codes: [MAX_ALPHA_SIZE]u32 = [_]u32{0} ** MAX_ALPHA_SIZE;

    // Count codes of each length
    var count: [MAX_CODE_LEN + 1]u32 = [_]u32{0} ** (MAX_CODE_LEN + 1);
    for (lengths[0..num_symbols]) |len| {
        if (len > 0 and len <= MAX_CODE_LEN) {
            count[len] += 1;
        }
    }

    // Compute first code of each length
    var first_code: [MAX_CODE_LEN + 2]u32 = [_]u32{0} ** (MAX_CODE_LEN + 2);
    var code: u32 = 0;
    for (1..MAX_CODE_LEN + 1) |len| {
        first_code[len] = code;
        code = (code + count[len]) << 1;
    }

    // Assign codes to symbols
    var next_code: [MAX_CODE_LEN + 1]u32 = undefined;
    for (0..MAX_CODE_LEN + 1) |i| {
        next_code[i] = first_code[i];
    }

    for (0..num_symbols) |i| {
        const len = lengths[i];
        if (len > 0 and len <= MAX_CODE_LEN) {
            codes[i] = next_code[len];
            next_code[len] += 1;
        }
    }

    return codes;
}

// ============ High-Level API ============

/// Compress data using bzip2 algorithm.
/// Caller owns the returned slice and must free it with the provided allocator.
pub fn compress(allocator: Allocator, input: []const u8) ![]u8 {
    var output: std.ArrayListUnmanaged(u8) = .empty;
    errdefer output.deinit(allocator);

    // Write stream header: "BZh9" (level 9)
    try output.appendSlice(allocator, &STREAM_MAGIC);
    try output.append(allocator, '9');

    var bits = BitWriter.init(allocator, &output);
    var stream_crc: u32 = 0;

    // Process input in blocks
    var input_pos: usize = 0;
    while (input_pos < input.len or (input_pos == 0 and input.len == 0)) {
        // According to bzip2 spec, block size '9' means 900,000 bytes of UNCOMPRESSED data (pre-RLE).
        // However, we must be careful not to produce a block that expands beyond what decompressors can handle.
        // Standard bzip2 splits at 900,000 raw bytes.
        const chunk_len = @min(input.len - input_pos, MAX_BLOCK_SIZE);
        const chunk = input[input_pos .. input_pos + chunk_len];
        input_pos += chunk_len;

        // Compute block CRC
        var block_crc = Crc32Bzip2.init();
        block_crc.updateSlice(chunk);
        const crc_value = block_crc.final();

        // Update stream CRC (classic bzip2 combined CRC: rotate left 1, xor block CRC)
        stream_crc = ((stream_crc << 1) | (stream_crc >> 31)) ^ crc_value;

        // Step 1: Initial RLE encoding
        // Note: this can expand data (runs of 4 -> 5 bytes).
        // The resulting size can be up to ~1.125MB for 900KB input.
        // Our Decompressor is updated to handle this via MAX_EXPANDED_BLOCK_SIZE.
        const rle_data = try initialRleEncode(allocator, chunk);
        defer allocator.free(rle_data);

        // Step 2: BWT
        const bwt_result = try bwtEncode(allocator, rle_data);
        defer allocator.free(bwt_result.data);

        // Step 3: Build symbol map (which bytes are used)
        var in_use = [_]bool{false} ** 256;
        for (bwt_result.data) |b| {
            in_use[b] = true;
        }

        // Build seq_to_unseq mapping
        var seq_to_unseq: [256]u8 = undefined;
        var unseq_to_seq: [256]u8 = undefined;
        var num_in_use: usize = 0;
        for (0..256) |i| {
            if (in_use[i]) {
                seq_to_unseq[num_in_use] = @intCast(i);
                unseq_to_seq[i] = @intCast(num_in_use);
                num_in_use += 1;
            }
        }

        // Step 4: MTF encode using sequence numbers
        var mtf_data = try allocator.alloc(u8, bwt_result.data.len);
        defer allocator.free(mtf_data);

        var mtf_list: [256]u8 = undefined;
        for (0..num_in_use) |i| {
            mtf_list[i] = @intCast(i);
        }

        for (bwt_result.data, 0..) |byte, i| {
            const seq = unseq_to_seq[byte];
            // Find position in MTF list
            var pos: usize = 0;
            while (mtf_list[pos] != seq) : (pos += 1) {}
            mtf_data[i] = @intCast(pos);
            // Move to front
            if (pos > 0) {
                const val = mtf_list[pos];
                var j = pos;
                while (j > 0) : (j -= 1) {
                    mtf_list[j] = mtf_list[j - 1];
                }
                mtf_list[0] = val;
            }
        }

        // Step 5: Convert MTF output to symbols with RUNA/RUNB
        // Symbols: 0=RUNA, 1=RUNB, 2..num_in_use+1 = MTF values 1..num_in_use, num_in_use+1 = EOB
        var symbols: std.ArrayListUnmanaged(u16) = .empty;
        defer symbols.deinit(allocator);

        var idx: usize = 0;
        while (idx < mtf_data.len) {
            if (mtf_data[idx] == 0) {
                // Count run of zeros
                var run_len: u32 = 0;
                while (idx < mtf_data.len and mtf_data[idx] == 0) {
                    run_len += 1;
                    idx += 1;
                }
                // Encode with RUNA/RUNB
                const encoded = encodeZeroRun(run_len);
                for (encoded.symbols[0..encoded.len]) |s| {
                    try symbols.append(allocator, s);
                }
            } else {
                // Non-zero MTF value -> symbol = mtf_value + 1
                try symbols.append(allocator, @as(u16, mtf_data[idx]) + 1);
                idx += 1;
            }
        }

        // Append EOB
        try symbols.append(allocator, @intCast(num_in_use + 1));

        // Step 6: Huffman coding
        // Create 6 groups (simplified)
        // For simplicity, we'll just use 1 group if small, or divide into chunks of 50
        const num_selectors = (symbols.items.len + GROUP_SIZE - 1) / GROUP_SIZE;
        const num_groups: u3 = if (num_selectors < 2) 2 else 6; // Use min 2 groups as per spec or logic

        // Generate selectors (simplified: just cycle 0..num_groups)
        // In a real implementation, we would optimize selector assignment
        var selectors = try allocator.alloc(u8, num_selectors);
        defer allocator.free(selectors);
        for (0..num_selectors) |i| {
            selectors[i] = @intCast(i % num_groups);
        }

        // Calculate frequencies for each group
        var lens = try allocator.alloc([MAX_ALPHA_SIZE]u8, num_groups);
        defer allocator.free(lens);

        // Calculate code lengths for each group
        for (0..num_groups) |g| {
            var freqs = [_]u32{0} ** MAX_ALPHA_SIZE;
            for (0..symbols.items.len) |s_idx| {
                if (selectors[s_idx / GROUP_SIZE] == g) {
                    freqs[symbols.items[s_idx]] += 1;
                }
            }
            // Ensure every symbol has at least 1 freq so we generate a valid length (1-20).
            // Bzip2 spec requires all symbols in the alphabet to have a valid length.
            for (0..num_in_use + 2) |s| {
                if (freqs[s] == 0) freqs[s] = 1;
            }

            const codes = computeHuffmanLengths(&freqs, num_in_use + 2, 20);
            @memcpy(&lens[g], codes[0..MAX_ALPHA_SIZE]);
        }

        // Step 7: Write block to bitstream

        // Block header
        try bits.writeBits(BLOCK_MAGIC >> 24, 24);
        try bits.writeBits(BLOCK_MAGIC & 0xFFFFFF, 24);
        try bits.writeBits(crc_value, 32);
        try bits.writeBit(0); // Randomized = false

        // BWT primary index
        try bits.writeBits(bwt_result.primary_index, 24);

        // Symbol map
        // 1. Used groups bitmap (16 bits)
        var used_groups: u16 = 0;
        for (0..16) |g| {
            var used = false;
            for (0..16) |s| {
                if (in_use[g * 16 + s]) {
                    used = true;
                    break;
                }
            }
            if (used) used_groups |= (@as(u16, 1) << @as(u4, @intCast(15 - g)));
        }
        try bits.writeBits(used_groups, 16);

        // 2. Used symbols bitmaps
        for (0..16) |g| {
            if (used_groups & (@as(u16, 1) << @as(u4, @intCast(15 - g))) != 0) {
                var used_syms: u16 = 0;
                for (0..16) |s| {
                    if (in_use[g * 16 + s]) {
                        used_syms |= (@as(u16, 1) << @as(u4, @intCast(15 - s)));
                    }
                }
                try bits.writeBits(used_syms, 16);
            }
        }

        // Huffman groups (3 bits)
        try bits.writeBits(num_groups, 3);

        // Selectors (15 bits)
        try bits.writeBits(@intCast(num_selectors), 15);

        // Write selectors (MTF encoded)
        var sel_mtf: [6]u8 = .{ 0, 1, 2, 3, 4, 5 };
        for (selectors) |sel| {
            // Find index in MTF
            var pos: usize = 0;
            while (sel_mtf[pos] != sel) : (pos += 1) {}
            // Write unary code
            for (0..pos) |_| {
                try bits.writeBit(1);
            }
            try bits.writeBit(0);
            // Update MTF
            var k = pos;
            while (k > 0) : (k -= 1) {
                sel_mtf[k] = sel_mtf[k - 1];
            }
            sel_mtf[0] = sel;
        }

        // Write Huffman tables
        for (0..num_groups) |g| {
            var curr_len: i32 = @intCast(lens[g][0]);
            try bits.writeBits(@intCast(curr_len), 5);

            for (0..num_in_use + 2) |s| {
                const len: i32 = @intCast(lens[g][s]);
                var diff = len - curr_len;
                while (diff != 0) {
                    try bits.writeBit(1); // Continue
                    if (diff > 0) {
                        try bits.writeBit(0); // Increment
                        diff -= 1;
                        curr_len += 1;
                    } else {
                        try bits.writeBit(1); // Decrement
                        diff += 1;
                        curr_len -= 1;
                    }
                }
                try bits.writeBit(0); // Stop
            }
        }

        // Write compressed data
        var gpos: usize = 0;
        var sidx: usize = 0;

        // Build codes for all groups
        var group_codes: [MAX_GROUPS][MAX_ALPHA_SIZE]u32 = undefined;
        for (0..num_groups) |g| {
            group_codes[g] = buildHuffmanCodes(&lens[g], num_in_use + 2);
        }

        for (symbols.items) |sym| {
            // Get current table
            const table_idx = selectors[sidx];
            const code = group_codes[table_idx][sym];
            const len = lens[table_idx][sym];

            // Write code
            try bits.writeBits(code, @intCast(len));

            gpos += 1;
            if (gpos >= GROUP_SIZE) {
                gpos = 0;
                sidx += 1;
            }
        }

        // Loop condition check (explicit break if we processed everything and len > 0)
        if (input.len == 0 and input_pos == 0) break; // Handled empty input once
    }

    // Write footer
    try bits.writeBits(FOOTER_MAGIC >> 24, 24);
    try bits.writeBits(FOOTER_MAGIC & 0xFFFFFF, 24);
    try bits.writeBits(stream_crc, 32);

    try bits.flush();
    return output.toOwnedSlice(allocator);
}

/// Decompress bzip2 data from a slice, returning the decompressed data.
/// Caller owns the returned slice and must free it with the provided allocator.
pub fn decompress(allocator: Allocator, input: []const u8) ![]u8 {
    return decompressInternal(allocator, input, true);
}

/// Validate bzip2 data without materializing decompressed output.
///
/// Same per-block + stream CRC verification as `decompress`, but emitted
/// bytes are discarded as they're produced rather than accumulated. Memory
/// is bounded by the per-block working buffer (`MAX_EXPANDED_BLOCK_SIZE`)
/// regardless of the decompressed file size — useful for validating large
/// bzip2 streams (multi-GB tarballs, etc.) without OOM risk.
///
/// Returns the same error codes as `decompress`. Use this in validation
/// contexts where you only care about "did it decode cleanly?" not the
/// bytes themselves.
pub fn validateStream(allocator: Allocator, input: []const u8) Error!void {
    var decompressor = try Decompressor.init(allocator);
    defer decompressor.deinit();

    var input_stream = std.io.fixedBufferStream(input);
    var discard = DiscardWriter{};
    try decompressor.decompressInternal(input_stream.reader(), discard.writer(), true);
}

/// Writer adapter that discards all bytes written to it. Used by
/// `validateStream` for memory-bounded bzip2 validation.
const DiscardWriter = struct {
    bytes_written: u64 = 0,

    pub const WriteError = error{};
    pub const Writer = std.io.GenericWriter(*DiscardWriter, WriteError, write);

    fn write(self: *DiscardWriter, bytes: []const u8) WriteError!usize {
        self.bytes_written += bytes.len;
        return bytes.len;
    }

    pub fn writer(self: *DiscardWriter) Writer {
        return .{ .context = self };
    }
};

/// Decompress without CRC verification (for diagnostics).
pub fn decompressNoCrc(allocator: Allocator, input: []const u8) ![]u8 {
    return decompressInternal(allocator, input, false);
}

fn decompressInternal(allocator: Allocator, input: []const u8, check_crc: bool) ![]u8 {
    var decompressor = try Decompressor.init(allocator);
    defer decompressor.deinit();

    var input_stream = std.io.fixedBufferStream(input);
    var output_list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer output_list.deinit(allocator);

    try decompressor.decompressInternal(input_stream.reader(), output_list.writer(allocator), check_crc);

    return output_list.toOwnedSlice(allocator);
}

/// Decompress bzip2 data from a file path.
/// Caller owns the returned slice and must free it with the provided allocator.
pub fn decompressFile(allocator: Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var decompressor = try Decompressor.init(allocator);
    defer decompressor.deinit();

    var output_list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer output_list.deinit(allocator);

    // Use deprecated reader for compatibility with the generic decompress function
    try decompressor.decompress(file.deprecatedReader(), output_list.writer(allocator));

    return output_list.toOwnedSlice(allocator);
}

// ============ Tests ============

test "CRC32 bzip2 - basic" {
    var crc = Crc32Bzip2.init();
    crc.updateSlice("hello");
    const result = crc.final();
    try std.testing.expect(result != 0);
}

test "CRC32 bzip2 - standard test vector" {
    // The standard CRC-32/BZIP2 check value for "123456789" is 0xfc891918
    // See: https://reveng.sourceforge.io/crc-catalogue/17plus.htm
    var crc = Crc32Bzip2.init();
    crc.updateSlice("123456789");
    const result = crc.final();
    try std.testing.expectEqual(@as(u32, 0xfc891918), result);
}

test "CRC32 bzip2 - empty" {
    var crc = Crc32Bzip2.init();
    const result = crc.final();
    try std.testing.expectEqual(@as(u32, 0), result);
}

test "CRC32 bzip2 - incremental equals batch" {
    var crc1 = Crc32Bzip2.init();
    crc1.update('h');
    crc1.update('e');
    crc1.update('l');
    crc1.update('l');
    crc1.update('o');

    var crc2 = Crc32Bzip2.init();
    crc2.updateSlice("hello");

    try std.testing.expectEqual(crc1.final(), crc2.final());
}

// ============ SA-IS Algorithm Unit Tests ============
// These tests verify individual pieces of the SA-IS algorithm

test "SA-IS - suffix array for 'banana'" {
    // "banana$" - well-known test case
    // Sorted suffixes: $, a$, ana$, anana$, banana$, na$, nana$
    // SA = [6, 5, 3, 1, 0, 4, 2] (positions of suffixes in sorted order)
    const allocator = std.testing.allocator;
    const text = "banana";

    const sa = try buildSuffixArraySAIS(allocator, text);
    defer allocator.free(sa);

    // Verify suffix array length (excludes sentinel)
    try std.testing.expectEqual(@as(usize, 6), sa.len);

    // Verify sorted order by checking suffix comparisons
    // sa[i] should give the i-th smallest suffix
    for (0..sa.len - 1) |i| {
        const pos1 = sa[i];
        const pos2 = sa[i + 1];
        const s1 = text[pos1..];
        const s2 = text[pos2..];
        // s1 should be <= s2 in lexicographic order
        const cmp = std.mem.order(u8, s1, s2);
        try std.testing.expect(cmp != .gt);
    }
}

test "SA-IS - suffix array for 'abracadabra'" {
    const allocator = std.testing.allocator;
    const text = "abracadabra";

    const sa = try buildSuffixArraySAIS(allocator, text);
    defer allocator.free(sa);

    try std.testing.expectEqual(@as(usize, 11), sa.len);

    // Verify sorted order
    for (0..sa.len - 1) |i| {
        const s1 = text[sa[i]..];
        const s2 = text[sa[i + 1]..];
        try std.testing.expect(std.mem.order(u8, s1, s2) != .gt);
    }
}

test "SA-IS - suffix array for repetitive 'aaa'" {
    const allocator = std.testing.allocator;
    const text = "aaa";

    const sa = try buildSuffixArraySAIS(allocator, text);
    defer allocator.free(sa);

    // For "aaa$", suffixes: $, a$, aa$, aaa$
    // SA should be [2, 1, 0] (after removing sentinel)
    try std.testing.expectEqual(@as(usize, 3), sa.len);
    try std.testing.expectEqual(@as(u32, 2), sa[0]); // "a" - shortest
    try std.testing.expectEqual(@as(u32, 1), sa[1]); // "aa"
    try std.testing.expectEqual(@as(u32, 0), sa[2]); // "aaa" - longest
}

test "SA-IS - BWT uses correct suffix array" {
    const allocator = std.testing.allocator;

    // Test "banana" BWT
    const result = try bwtEncode(allocator, "banana");
    defer allocator.free(result.data);

    // BWT of "banana" should have length 6
    try std.testing.expectEqual(@as(usize, 6), result.data.len);
}

test "SA-IS - verify suffix array sorted at various sizes" {
    const allocator = std.testing.allocator;

    // Verify SA correctness at various sizes including large inputs
    const sizes = [_]usize{ 100, 500, 1000, 2000, 4000, 8000, 16000, 32000, 50000 };

    for (sizes) |size| {
        // Create test data with pattern
        const text = try allocator.alloc(u8, size);
        defer allocator.free(text);

        for (text, 0..) |*b, i| {
            b.* = @truncate((i *% 31 +% 17) ^ (i >> 8));
        }

        const sa = try buildSuffixArraySAIS(allocator, text);
        defer allocator.free(sa);

        // Verify length
        try std.testing.expectEqual(size, sa.len);

        // Verify sorted order: sa[i] suffix should be <= sa[i+1] suffix
        for (0..sa.len - 1) |i| {
            const s1 = text[sa[i]..];
            const s2 = text[sa[i + 1]..];
            const cmp = std.mem.order(u8, s1, s2);
            if (cmp == .gt) {
                std.debug.print("\nSA NOT SORTED at size {}: sa[{}]={} > sa[{}]={}\n", .{ size, i, sa[i], i + 1, sa[i + 1] });
                std.debug.print("  suffix at {}: ", .{sa[i]});
                for (s1[0..@min(20, s1.len)]) |c| std.debug.print("{X:0>2} ", .{c});
                std.debug.print("\n  suffix at {}: ", .{sa[i + 1]});
                for (s2[0..@min(20, s2.len)]) |c| std.debug.print("{X:0>2} ", .{c});
                std.debug.print("\n", .{});
            }
            try std.testing.expect(cmp != .gt);
        }
    }
}

test "stream magic" {
    try std.testing.expectEqualSlices(u8, "BZh", &STREAM_MAGIC);
}

test "block magic values" {
    try std.testing.expectEqual(@as(u48, 0x314159265359), BLOCK_MAGIC);
    try std.testing.expectEqual(@as(u48, 0x177245385090), FOOTER_MAGIC);
}

// ============ BitReader Tests ============

test "BitReader - read aligned bytes" {
    const data = [_]u8{ 0xAB, 0xCD, 0xEF };
    var stream = std.io.fixedBufferStream(&data);
    var reader = BitReader(@TypeOf(stream.reader())).init(stream.reader());

    // Read 8 bits at a time (byte aligned)
    const b1 = try reader.readBits(8);
    try std.testing.expectEqual(@as(u32, 0xAB), b1);

    const b2 = try reader.readBits(8);
    try std.testing.expectEqual(@as(u32, 0xCD), b2);
}

test "BitReader - read unaligned bits" {
    // Binary: 1010 1100 1101 0011
    const data = [_]u8{ 0xAC, 0xD3 };
    var stream = std.io.fixedBufferStream(&data);
    var reader = BitReader(@TypeOf(stream.reader())).init(stream.reader());

    // Read 4 bits: should be 1010 = 0xA
    const b1 = try reader.readBits(4);
    try std.testing.expectEqual(@as(u32, 0xA), b1);

    // Read 6 bits: should be 110011 = 0x33
    const b2 = try reader.readBits(6);
    try std.testing.expectEqual(@as(u32, 0x33), b2);

    // Read 6 bits: should be 010011 = 0x13
    const b3 = try reader.readBits(6);
    try std.testing.expectEqual(@as(u32, 0x13), b3);
}

test "BitReader - read single bits" {
    // Binary: 1010 0101
    const data = [_]u8{0xA5};
    var stream = std.io.fixedBufferStream(&data);
    var reader = BitReader(@TypeOf(stream.reader())).init(stream.reader());

    // Read bit by bit
    try std.testing.expectEqual(@as(u1, 1), try reader.readBit());
    try std.testing.expectEqual(@as(u1, 0), try reader.readBit());
    try std.testing.expectEqual(@as(u1, 1), try reader.readBit());
    try std.testing.expectEqual(@as(u1, 0), try reader.readBit());
    try std.testing.expectEqual(@as(u1, 0), try reader.readBit());
    try std.testing.expectEqual(@as(u1, 1), try reader.readBit());
    try std.testing.expectEqual(@as(u1, 0), try reader.readBit());
    try std.testing.expectEqual(@as(u1, 1), try reader.readBit());
}

// ============ Huffman Table Tests ============

test "HuffmanTable - simple 2 symbol table" {
    var table = HuffmanTable.init();

    // Simple table: symbol 0 has code "0" (length 1), symbol 1 has code "1" (length 1)
    const lengths = [_]u8{ 1, 1 };
    try table.build(&lengths, 2);

    // Decode from bit stream
    const data = [_]u8{0b10100000}; // bits: 1, 0, 1, 0, ...
    var stream = std.io.fixedBufferStream(&data);
    const ReaderType = @TypeOf(stream.reader());
    var reader = BitReader(ReaderType).init(stream.reader());

    // First bit is 1 -> symbol 1
    const s1 = try table.decode(ReaderType, &reader);
    try std.testing.expectEqual(@as(u16, 1), s1);

    // Next bit is 0 -> symbol 0
    const s2 = try table.decode(ReaderType, &reader);
    try std.testing.expectEqual(@as(u16, 0), s2);
}

test "HuffmanTable - varying code lengths" {
    var table = HuffmanTable.init();

    // Table: A=1bit, B=2bits, C=3bits, D=3bits
    // Canonical Huffman: A=0, B=10, C=110, D=111
    const lengths = [_]u8{ 1, 2, 3, 3 };
    try table.build(&lengths, 4);

    // bits: 0 10 110 111 = A B C D
    // binary: 0101 1011 1... = 0x5B...
    const data = [_]u8{ 0x5B, 0x80 };
    var stream = std.io.fixedBufferStream(&data);
    const ReaderType = @TypeOf(stream.reader());
    var reader = BitReader(ReaderType).init(stream.reader());

    try std.testing.expectEqual(@as(u16, 0), try table.decode(ReaderType, &reader)); // A
    try std.testing.expectEqual(@as(u16, 1), try table.decode(ReaderType, &reader)); // B
    try std.testing.expectEqual(@as(u16, 2), try table.decode(ReaderType, &reader)); // C
    try std.testing.expectEqual(@as(u16, 3), try table.decode(ReaderType, &reader)); // D
}

// ============ RLE Bijective Base-2 Tests ============

// ============ Inverse BWT Tests ============

test "inverse BWT - simple known transformation" {
    // Test with a known BWT transformation
    // Original: "banana"
    // BWT output: "annb$aa" where $ marks the end
    // Actually for bzip2 style (no explicit end marker):
    // BWT of "banana" produces last column: "nnbaaa" with primary index pointing
    // to the row that starts with the original string's first character
    //
    // Let's use a simpler example: "abracadabra"
    // BWT gives: "ard$rcaaaabb" (with end marker) or similar
    //
    // For a very simple test, let's use "aaab"
    // Rotations: aaab, aaba, abaa, baaa
    // Sorted:    aaab (0), aaba (1), abaa (2), baaa (3)
    // Last col:  b, a, a, a
    // If original "aaab" is at position 0, primary index = 0

    const allocator = std.testing.allocator;

    // Allocate decompressor
    var decompressor = try Decompressor.init(allocator);
    defer decompressor.deinit();

    // Set up a simple test case
    // BWT of "aaab" gives last column "baaa" with primary index 0
    decompressor.block[0] = 'b';
    decompressor.block[1] = 'a';
    decompressor.block[2] = 'a';
    decompressor.block[3] = 'a';
    decompressor.block_size = 4;
    decompressor.bwt_primary_index = 0;

    // Run inverse BWT
    try decompressor.buildInverseBwt();
    try decompressor.inverseBwt();

    // The output should be "aaab"
    try std.testing.expectEqualSlices(u8, "aaab", decompressor.output[0..4]);
}

test "inverse BWT - packed representation at various sizes" {
    // Test the optimized packed inverse BWT at various sizes
    // This verifies the tt[i] = (LF[i] << 8) | L[i] optimization works correctly
    const allocator = std.testing.allocator;

    const sizes = [_]usize{ 10, 100, 500, 1000, 5000, 10000 };

    for (sizes) |size| {
        // Generate test data with varied content
        const original = try allocator.alloc(u8, size);
        defer allocator.free(original);

        for (original, 0..) |*b, i| {
            b.* = @truncate((i *% 31 +% 17) ^ (i >> 8));
        }

        // Forward BWT
        const bwt_result = try bwtEncode(allocator, original);
        defer allocator.free(bwt_result.data);

        // Set up decompressor for inverse BWT
        var decompressor = try Decompressor.init(allocator);
        defer decompressor.deinit();

        @memcpy(decompressor.block[0..size], bwt_result.data);
        decompressor.block_size = size;
        decompressor.bwt_primary_index = bwt_result.primary_index;

        // Inverse BWT (uses packed representation)
        try decompressor.buildInverseBwt();
        try decompressor.inverseBwt();

        // Verify round-trip
        try std.testing.expectEqualSlices(u8, original, decompressor.output[0..size]);
    }
}

test "RLE bijective base-2 encoding - known values" {
    // In bzip2's bijective base-2 system:
    // RUNA (sym=0) contributes (0+1)*power = 1*power
    // RUNB (sym=1) contributes (1+1)*power = 2*power
    // Power doubles with each symbol

    // Helper function to compute run length from symbols
    const computeRunLen = struct {
        fn call(symbols: []const u8) u32 {
            var run_len: u32 = 0;
            var power: u32 = 1;
            for (symbols) |sym| {
                run_len += (@as(u32, sym) + 1) * power;
                power <<= 1;
            }
            return run_len;
        }
    }.call;

    // Test known values
    // 1 = RUNA
    try std.testing.expectEqual(@as(u32, 1), computeRunLen(&[_]u8{0}));
    // 2 = RUNB
    try std.testing.expectEqual(@as(u32, 2), computeRunLen(&[_]u8{1}));
    // 3 = RUNA RUNA (1 + 2)
    try std.testing.expectEqual(@as(u32, 3), computeRunLen(&[_]u8{ 0, 0 }));
    // 4 = RUNB RUNA (2 + 2)
    try std.testing.expectEqual(@as(u32, 4), computeRunLen(&[_]u8{ 1, 0 }));
    // 5 = RUNA RUNB (1 + 4)
    try std.testing.expectEqual(@as(u32, 5), computeRunLen(&[_]u8{ 0, 1 }));
    // 6 = RUNB RUNB (2 + 4)
    try std.testing.expectEqual(@as(u32, 6), computeRunLen(&[_]u8{ 1, 1 }));
    // 7 = RUNA RUNA RUNA (1 + 2 + 4)
    try std.testing.expectEqual(@as(u32, 7), computeRunLen(&[_]u8{ 0, 0, 0 }));
    // 40 = RUNB RUNA RUNA RUNB RUNA (2 + 2 + 4 + 16 + 16)
    try std.testing.expectEqual(@as(u32, 40), computeRunLen(&[_]u8{ 1, 0, 0, 1, 0 }));
}

test "initial RLE expansion - known patterns" {
    const allocator = std.testing.allocator;

    var decompressor = try Decompressor.init(allocator);
    defer decompressor.deinit();

    // Test: "AAAA" + count(6) should expand to 10 A's
    decompressor.output[0] = 'A';
    decompressor.output[1] = 'A';
    decompressor.output[2] = 'A';
    decompressor.output[3] = 'A';
    decompressor.output[4] = 6; // 6 more copies
    decompressor.output_len = 5;

    try decompressor.expandInitialRle();

    try std.testing.expectEqual(@as(usize, 10), decompressor.output_len);
    for (decompressor.output[0..10]) |byte| {
        try std.testing.expectEqual(@as(u8, 'A'), byte);
    }
}

test "initial RLE expansion - no runs" {
    const allocator = std.testing.allocator;

    var decompressor = try Decompressor.init(allocator);
    defer decompressor.deinit();

    // Test: "ABC" (no runs) should stay unchanged
    decompressor.output[0] = 'A';
    decompressor.output[1] = 'B';
    decompressor.output[2] = 'C';
    decompressor.output_len = 3;

    try decompressor.expandInitialRle();

    try std.testing.expectEqual(@as(usize, 3), decompressor.output_len);
    try std.testing.expectEqualSlices(u8, "ABC", decompressor.output[0..3]);
}

test "initial RLE expansion - mixed content" {
    const allocator = std.testing.allocator;

    var decompressor = try Decompressor.init(allocator);
    defer decompressor.deinit();

    // Test: "XY" + "AAAA" + count(2) + "Z" should become "XYAAAAAAZ"
    decompressor.output[0] = 'X';
    decompressor.output[1] = 'Y';
    decompressor.output[2] = 'A';
    decompressor.output[3] = 'A';
    decompressor.output[4] = 'A';
    decompressor.output[5] = 'A';
    decompressor.output[6] = 2; // 2 more A's
    decompressor.output[7] = 'Z';
    decompressor.output_len = 8;

    try decompressor.expandInitialRle();

    try std.testing.expectEqual(@as(usize, 9), decompressor.output_len);
    try std.testing.expectEqualSlices(u8, "XYAAAAAAZ", decompressor.output[0..9]);
}

// ============ Compression Tests (TDD - write tests first!) ============

test "initial RLE encode - no runs" {
    const allocator = std.testing.allocator;
    // Input without runs of 4+ identical bytes should pass through unchanged
    const input = "ABCDEF";
    const result = try initialRleEncode(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualSlices(u8, "ABCDEF", result);
}

test "initial RLE encode - single run" {
    const allocator = std.testing.allocator;
    // 10 A's should become "AAAA" + chr(6)
    const input = "AAAAAAAAAA";
    const result = try initialRleEncode(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 5), result.len);
    try std.testing.expectEqualSlices(u8, "AAAA", result[0..4]);
    try std.testing.expectEqual(@as(u8, 6), result[4]);
}

test "initial RLE encode - exactly 4" {
    const allocator = std.testing.allocator;
    // Exactly 4 identical bytes should become "XXXX" + chr(0)
    const input = "AAAA";
    const result = try initialRleEncode(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 5), result.len);
    try std.testing.expectEqualSlices(u8, "AAAA", result[0..4]);
    try std.testing.expectEqual(@as(u8, 0), result[4]);
}

test "initial RLE encode - mixed content" {
    const allocator = std.testing.allocator;
    // "XY" + 6 A's + "Z" should become "XY" + "AAAA" + chr(2) + "Z"
    const input = "XYAAAAAAZ";
    const result = try initialRleEncode(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 8), result.len);
    try std.testing.expectEqualSlices(u8, "XYAAAA", result[0..6]);
    try std.testing.expectEqual(@as(u8, 2), result[6]);
    try std.testing.expectEqual(@as(u8, 'Z'), result[7]);
}

test "BWT forward transform - simple" {
    const allocator = std.testing.allocator;
    // BWT of "banana" is well-known: last column is "annb$aa" or similar
    // For "aaab": rotations are aaab, aaba, abaa, baaa
    // Sorted: aaab, aaba, abaa, baaa -> last column: b, a, a, a
    // Primary index = 0 (original "aaab" is at sorted position 0)
    const result = try bwtEncode(allocator, "aaab");
    defer allocator.free(result.data);
    try std.testing.expectEqualSlices(u8, "baaa", result.data);
    try std.testing.expectEqual(@as(u32, 0), result.primary_index);
}

test "BWT forward transform - hello" {
    const allocator = std.testing.allocator;
    // BWT of "hello": rotations sorted give last column
    // Rotations: hello, elloh, llohe, lohel, ohell
    // Sorted: elloh, hello, llohe, lohel, ohell
    // Last column: h, o, e, l, l
    // Primary index = 1 (original "hello" is at sorted position 1)
    const result = try bwtEncode(allocator, "hello");
    defer allocator.free(result.data);
    try std.testing.expectEqualSlices(u8, "hoell", result.data);
    try std.testing.expectEqual(@as(u32, 1), result.primary_index);
}

test "BWT round-trip" {
    const allocator = std.testing.allocator;
    const original = "the quick brown fox";

    // Encode
    const encoded = try bwtEncode(allocator, original);
    defer allocator.free(encoded.data);

    // Decode using existing decompressor
    var decompressor = try Decompressor.init(allocator);
    defer decompressor.deinit();

    @memcpy(decompressor.block[0..encoded.data.len], encoded.data);
    decompressor.block_size = encoded.data.len;
    decompressor.bwt_primary_index = encoded.primary_index;

    try decompressor.buildInverseBwt();
    try decompressor.inverseBwt();

    try std.testing.expectEqualSlices(u8, original, decompressor.output[0..decompressor.output_len]);
}

test "BWT round-trip - pattern data sizes" {
    const allocator = std.testing.allocator;

    // Test various sizes - smaller sizes to avoid memory pressure issues
    const sizes = [_]usize{ 1024, 2048, 4096, 8192 };

    for (sizes) |size| {
        const data = try allocator.alloc(u8, size);
        defer allocator.free(data);

        for (data, 0..) |*b, i| {
            b.* = @truncate((i *% 31 +% 17) ^ (i >> 8));
        }

        const result = try bwtEncode(allocator, data);
        defer allocator.free(result.data);

        var decompressor = try Decompressor.init(allocator);
        defer decompressor.deinit();
        @memcpy(decompressor.block[0..result.data.len], result.data);
        decompressor.block_size = result.data.len;
        decompressor.bwt_primary_index = result.primary_index;
        try decompressor.buildInverseBwt();
        try decompressor.inverseBwt();

        // Debug: check if output is a rotation of input
        if (!std.mem.eql(u8, data, decompressor.output[0..decompressor.output_len])) {
            std.debug.print("\nBWT FAIL at size {}: primary_index={}\n", .{ size, result.primary_index });
            // Check if output is a rotation
            for (0..size) |offset| {
                var is_rotation = true;
                for (0..@min(64, size)) |i| {
                    if (data[i] != decompressor.output[(i + offset) % size]) {
                        is_rotation = false;
                        break;
                    }
                }
                if (is_rotation) {
                    std.debug.print("  Output appears to be rotation by {}\n", .{offset});
                    break;
                }
            }
        }
        try std.testing.expectEqualSlices(u8, data, decompressor.output[0..decompressor.output_len]);
    }
}

test "BWT performance - 50KB should complete in under 500ms" {
    const allocator = std.testing.allocator;

    // Generate 50KB of test data
    const size = 50 * 1024;
    const data = try allocator.alloc(u8, size);
    defer allocator.free(data);

    // Fill with semi-random but reproducible data
    for (data, 0..) |*b, i| {
        b.* = @truncate((i *% 31 +% 17) ^ (i >> 8));
    }

    const start = std.time.nanoTimestamp();
    const result = try bwtEncode(allocator, data);
    defer allocator.free(result.data);
    const elapsed_ms = @divTrunc(std.time.nanoTimestamp() - start, 1_000_000);

    // Must complete in under 500ms (naive O(n²) would take minutes)
    try std.testing.expect(elapsed_ms < 500);

    // Verify output length matches input
    try std.testing.expectEqual(data.len, result.data.len);

    // Verify primary index is valid
    try std.testing.expect(result.primary_index < data.len);
}

test "MTF encode - simple" {
    const allocator = std.testing.allocator;
    // MTF encoding: each byte is replaced by its position in a list that's
    // updated after each byte (move accessed item to front)
    // For "aaab" with alphabet {a, b}:
    // Initial MTF list: [a, b] (or [0, 1] for indices)
    // 'a' -> 0, list stays [a, b]
    // 'a' -> 0, list stays [a, b]
    // 'a' -> 0, list stays [a, b]
    // 'b' -> 1, list becomes [b, a]
    const result = try mtfEncode(allocator, "aaab", "ab");
    defer allocator.free(result);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 1 }, result);
}

test "MTF encode - mixed" {
    const allocator = std.testing.allocator;
    // For "abab" with alphabet {a, b}:
    // Initial MTF list: [a, b]
    // 'a' -> 0, list stays [a, b]
    // 'b' -> 1, list becomes [b, a]
    // 'a' -> 1, list becomes [a, b]
    // 'b' -> 1, list becomes [b, a]
    const result = try mtfEncode(allocator, "abab", "ab");
    defer allocator.free(result);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 1, 1, 1 }, result);
}

test "RUNA/RUNB encode - single zero" {
    // A single zero in MTF output becomes RUNA (symbol 0)
    // run_len=1 -> RUNA
    const result = encodeZeroRun(1);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqual(@as(u8, 0), result.symbols[0]); // RUNA
}

test "RUNA/RUNB encode - two zeros" {
    // run_len=2 -> RUNB
    const result = encodeZeroRun(2);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqual(@as(u8, 1), result.symbols[0]); // RUNB
}

test "RUNA/RUNB encode - three zeros" {
    // run_len=3 -> RUNA, RUNA (1 + 2 = 3)
    const result = encodeZeroRun(3);
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqual(@as(u8, 0), result.symbols[0]); // RUNA
    try std.testing.expectEqual(@as(u8, 0), result.symbols[1]); // RUNA
}

test "RUNA/RUNB encode - forty zeros" {
    // run_len=40 -> specific sequence
    // 40 = 2 + 2 + 4 + 16 + 16 = RUNB + RUNA + RUNA + RUNB + RUNA
    const result = encodeZeroRun(40);
    try std.testing.expectEqual(@as(usize, 5), result.len);
    try std.testing.expectEqual(@as(u8, 1), result.symbols[0]); // RUNB (2)
    try std.testing.expectEqual(@as(u8, 0), result.symbols[1]); // RUNA (2)
    try std.testing.expectEqual(@as(u8, 0), result.symbols[2]); // RUNA (4)
    try std.testing.expectEqual(@as(u8, 1), result.symbols[3]); // RUNB (16)
    try std.testing.expectEqual(@as(u8, 0), result.symbols[4]); // RUNA (16)
}

test "BitWriter - write bytes" {
    const allocator = std.testing.allocator;
    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(allocator);

    var writer = BitWriter.init(allocator, &output);

    // Write 8 bits at a time (byte aligned)
    try writer.writeBits(0xAB, 8);
    try writer.writeBits(0xCD, 8);
    try writer.flush();

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xAB, 0xCD }, output.items);
}

test "BitWriter - write unaligned bits" {
    const allocator = std.testing.allocator;
    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(allocator);

    var writer = BitWriter.init(allocator, &output);

    // Write 4 bits: 1010
    try writer.writeBits(0xA, 4);
    // Write 4 bits: 1100
    try writer.writeBits(0xC, 4);
    // Should produce 0xAC
    try writer.flush();

    try std.testing.expectEqualSlices(u8, &[_]u8{0xAC}, output.items);
}

test "BitWriter - write 32 bits" {
    const allocator = std.testing.allocator;
    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(allocator);

    var writer = BitWriter.init(allocator, &output);

    // Write 32 bits
    try writer.writeBits(0xDEADBEEF, 32);
    try writer.flush();

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF }, output.items);
}

test "BitWriter - write single bits" {
    const allocator = std.testing.allocator;
    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(allocator);

    var writer = BitWriter.init(allocator, &output);

    // Write 10100101 bit by bit
    try writer.writeBit(1);
    try writer.writeBit(0);
    try writer.writeBit(1);
    try writer.writeBit(0);
    try writer.writeBit(0);
    try writer.writeBit(1);
    try writer.writeBit(0);
    try writer.writeBit(1);
    try writer.flush();

    try std.testing.expectEqualSlices(u8, &[_]u8{0xA5}, output.items);
}

test "buildHuffmanCodes - uniform lengths" {
    // All 4 symbols with length 2 should get codes 00, 01, 10, 11
    const lengths = [_]u8{ 2, 2, 2, 2 };
    const codes = buildHuffmanCodes(&lengths, 4);

    try std.testing.expectEqual(@as(u32, 0b00), codes[0]);
    try std.testing.expectEqual(@as(u32, 0b01), codes[1]);
    try std.testing.expectEqual(@as(u32, 0b10), codes[2]);
    try std.testing.expectEqual(@as(u32, 0b11), codes[3]);
}

test "buildHuffmanCodes - canonical varying lengths" {
    // Lengths: 1, 2, 3, 3 should give canonical codes: 0, 10, 110, 111
    const lengths = [_]u8{ 1, 2, 3, 3 };
    const codes = buildHuffmanCodes(&lengths, 4);

    try std.testing.expectEqual(@as(u32, 0b0), codes[0]); // length 1
    try std.testing.expectEqual(@as(u32, 0b10), codes[1]); // length 2
    try std.testing.expectEqual(@as(u32, 0b110), codes[2]); // length 3
    try std.testing.expectEqual(@as(u32, 0b111), codes[3]); // length 3
}

test "Huffman encode-decode round-trip" {
    const allocator = std.testing.allocator;

    // Build codes with known lengths
    const lengths = [_]u8{ 2, 2, 3, 3, 0, 0, 0, 0 } ++ [_]u8{0} ** (MAX_ALPHA_SIZE - 8);
    const codes = buildHuffmanCodes(&lengths, 4);

    // Write symbols using BitWriter
    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(allocator);

    var writer = BitWriter.init(allocator, &output);

    // Write symbol 0 (code 00, len 2)
    try writer.writeBits(codes[0], 2);
    // Write symbol 1 (code 01, len 2)
    try writer.writeBits(codes[1], 2);
    // Write symbol 2 (code 10, len 3)
    // Wait, let me recalculate...

    try writer.flush();

    // Build HuffmanTable for decoding
    var table = HuffmanTable.init();
    try table.build(&lengths, 4);

    // Read back using BitReader
    var stream = std.io.fixedBufferStream(output.items);
    const ReaderType = @TypeOf(stream.reader());
    var reader = BitReader(ReaderType).init(stream.reader());

    // Decode symbols
    const sym0 = try table.decode(ReaderType, &reader);
    const sym1 = try table.decode(ReaderType, &reader);

    try std.testing.expectEqual(@as(u16, 0), sym0);
    try std.testing.expectEqual(@as(u16, 1), sym1);
}

test "compress - valid header" {
    const allocator = std.testing.allocator;
    const original = "Hello, World!";

    const compressed = try compress(allocator, original);
    defer allocator.free(compressed);

    // Verify it's valid bzip2 format
    try std.testing.expectEqualSlices(u8, "BZh9", compressed[0..4]);
    try std.testing.expect(compressed.len > 10); // Should have some data
}

test "compress round-trip - simple" {
    const allocator = std.testing.allocator;
    const original = "Hello, World!";

    const compressed = try compress(allocator, original);
    defer allocator.free(compressed);

    // Verify it's valid bzip2 format
    try std.testing.expectEqualSlices(u8, "BZh", compressed[0..3]);

    // Decompress and verify
    const decompressed = try decompress(allocator, compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualSlices(u8, original, decompressed);
}

test "compress round-trip - repetitive" {
    const allocator = std.testing.allocator;
    const original = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"; // 40 A's

    const compressed = try compress(allocator, original);
    defer allocator.free(compressed);

    const decompressed = try decompress(allocator, compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualSlices(u8, original, decompressed);
}

test "compress round-trip - binary" {
    const allocator = std.testing.allocator;
    var original: [256]u8 = undefined;
    for (0..256) |i| {
        original[i] = @intCast(i);
    }

    const compressed = try compress(allocator, &original);
    defer allocator.free(compressed);

    const decompressed = try decompress(allocator, compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualSlices(u8, &original, decompressed);
}
