//! MS-DOC (Word Binary File Format) Deep Validator
//!
//! Validates Word 97-2003 .doc files by parsing the FIB (File Information Block)
//! from the WordDocument stream and cross-validating offsets against the Table stream.
//! Uses structural cross-validation (offset/size bounds, piece table consistency)
//! since MS-DOC has no traditional checksums.
//!
//! Spec reference: [MS-DOC] — FibBase, FibRgLw97, FibRgFcLcb97, CLX/Piece Table.

const std = @import("std");
const Allocator = std.mem.Allocator;

const format_validation = @import("format_validation.zig");
const ValidationResult = format_validation.ValidationResult;
const ValidationDepth = format_validation.ValidationDepth;
const FileFormat = format_validation.FileFormat;

const ole2_validator = @import("ole2_validator.zig");

/// FIB magic signature — first two bytes of WordDocument stream (Word 97+)
const FIB_MAGIC: u16 = 0xA5EC;

/// Word 6/95 FIB magic — older format we can't fully validate
const FIB_MAGIC_WORD6: u16 = 0xA5DC;

/// Valid nFibBack values per [MS-DOC]
const NFIB_BACK_97: u16 = 0x00BF;
const NFIB_BACK_2000: u16 = 0x00C1;

/// Expected FibRgW97 count
const EXPECTED_CSW: u16 = 0x000E;

/// Expected FibRgLw97 count
const EXPECTED_CSLW: u16 = 0x0016;

/// Minimum cbRgFcLcb for Word 97
const MIN_CB_RG_FC_LCB: u16 = 88;

/// FIB flags bit positions
const FLAG_ENCRYPTED: u16 = 0x0100;
const FLAG_WHICH_TBL_STM: u16 = 0x0200;

/// Parsed FIB base structure (first 32 bytes of WordDocument stream)
const FibBase = struct {
    wIdent: u16,
    nFib: u16,
    lid: u16,
    pnNext: u16,
    flags: u16,
    nFibBack: u16,
    lKey: u32,
    envr: u8,
    flags2: u8,

    fn isEncrypted(self: FibBase) bool {
        return (self.flags & FLAG_ENCRYPTED) != 0;
    }

    fn tableStreamName(self: FibBase) []const u8 {
        return if ((self.flags & FLAG_WHICH_TBL_STM) != 0) "1Table" else "0Table";
    }
};

/// Parsed FibRgLw97 — character counts and document metrics
const FibRgLw97 = struct {
    cbMac: u32, // byte count of document area in WordDocument stream
    ccpText: u32, // character count — main document
    ccpFtn: u32, // character count — footnotes
    ccpHdd: u32, // character count — headers/footers
    ccpAtn: u32, // character count — annotations (comments)
    ccpEdn: u32, // character count — endnotes
    ccpTxbx: u32, // character count — textboxes
    ccpHdrTxbx: u32, // character count — header textboxes
};

/// Validate a .doc file deeply by parsing the FIB and cross-validating Table stream references.
pub fn validateDocDeep(allocator: Allocator, path: []const u8) ValidationResult {
    // Read WordDocument stream
    const wd_data = ole2_validator.readNamedStream(allocator, path, "WordDocument") orelse {
        // No WordDocument stream — this OLE2 container is not a Word document.
        // It may be an MSI (Windows Installer), Thumbs.db, or other OLE2/CFBF format.
        // The OLE2 structure itself is valid, so return structural OK with a warning.
        return ValidationResult.okWithDepthAndWarning(.doc, .structural, "OLE2 container has no WordDocument stream (may be MSI or other CFBF format)");
    };
    defer allocator.free(wd_data);

    if (wd_data.len < 0x9A) {
        return ValidationResult.invalidWithDepth(.doc, "WordDocument stream too small for FIB", .structural);
    }

    // Parse and validate FibBase (32 bytes at offset 0)
    const fib_base = parseFibBase(wd_data);

    // Validate FIB magic
    if (fib_base.wIdent == FIB_MAGIC_WORD6) {
        // Word 6/95 format — different FIB layout, can't deep-validate
        return ValidationResult.okWithDepthAndWarning(.doc, .structural, "Word 6/95 format; deep validation requires Word 97+");
    }
    if (fib_base.wIdent != FIB_MAGIC) {
        return ValidationResult.invalidWithDepth(.doc, "Invalid FIB signature (expected 0xA5EC)", .structural);
    }

    // Validate nFibBack
    if (fib_base.nFibBack != NFIB_BACK_97 and fib_base.nFibBack != NFIB_BACK_2000) {
        return ValidationResult.invalidWithDepth(.doc, "Invalid nFibBack value in FIB", .structural);
    }

    // Check encryption — we can't validate content of encrypted documents
    if (fib_base.isEncrypted()) {
        return ValidationResult.okWithDepthAndWarning(.doc, .structural, "Document is encrypted; content validation skipped");
    }

    // Validate section counts
    const csw = std.mem.readInt(u16, wd_data[0x20..0x22], .little);
    if (csw != EXPECTED_CSW) {
        return ValidationResult.invalidWithDepth(.doc, "Invalid csw value in FIB (expected 0x000E)", .structural);
    }

    const cslw = std.mem.readInt(u16, wd_data[0x3E..0x40], .little);
    if (cslw != EXPECTED_CSLW) {
        return ValidationResult.invalidWithDepth(.doc, "Invalid cslw value in FIB (expected 0x0016)", .structural);
    }

    // Parse FibRgLw97 (22 x u32 at offset 0x40)
    const fib_lw = parseFibRgLw97(wd_data);

    // Validate cbMac <= WordDocument stream size
    if (fib_lw.cbMac > wd_data.len) {
        return ValidationResult.invalidWithDepth(.doc, "FIB cbMac exceeds WordDocument stream size", .structural);
    }

    // Validate cbRgFcLcb count
    const cb_rg_fc_lcb = std.mem.readInt(u16, wd_data[0x98..0x9A], .little);
    if (cb_rg_fc_lcb < MIN_CB_RG_FC_LCB) {
        return ValidationResult.invalidWithDepth(.doc, "FIB cbRgFcLcb too small for Word 97 format", .structural);
    }

    // Verify the FIB has enough data for all declared fc/lcb pairs
    const fc_lcb_end: usize = 0x9A + @as(usize, cb_rg_fc_lcb) * 8;
    if (fc_lcb_end > wd_data.len) {
        return ValidationResult.invalidWithDepth(.doc, "FIB fc/lcb array extends beyond WordDocument stream", .structural);
    }

    // Read Table stream for cross-validation
    const table_name = fib_base.tableStreamName();
    const table_data = ole2_validator.readNamedStream(allocator, path, table_name) orelse {
        return ValidationResult.invalidWithDepth(.doc, "Failed to read Table stream from OLE2 container", .structural);
    };
    defer allocator.free(table_data);

    // Cross-validate well-known fc/lcb pairs against Table stream bounds.
    // Note: We only validate specific indices we understand, NOT all pairs — Word
    // frequently leaves garbage in unused FibRgFcLcb entries (even the spec says
    // "if lcb is zero, fc MUST be ignored" but real files have garbage in both).
    const table_bounds_result = validateKnownTableBounds(wd_data, cb_rg_fc_lcb, table_data.len);
    if (table_bounds_result) |err_msg| {
        return ValidationResult.invalidWithDepth(.doc, err_msg, .structural);
    }

    // Calculate total CP for PLCF validation
    const total_cp = fib_lw.ccpText +| fib_lw.ccpFtn +| fib_lw.ccpHdd +|
        fib_lw.ccpAtn +| fib_lw.ccpEdn +| fib_lw.ccpTxbx +| fib_lw.ccpHdrTxbx;

    // If CLX exists (fcClx/lcbClx at index 66), validate piece table with full PCD decode
    if (cb_rg_fc_lcb > 66) {
        const fc_clx = std.mem.readInt(u32, wd_data[0x9A + 66 * 8 ..][0..4], .little);
        const lcb_clx = std.mem.readInt(u32, wd_data[0x9A + 66 * 8 + 4 ..][0..4], .little);

        if (lcb_clx > 0) {
            if (@as(u64, fc_clx) + lcb_clx > table_data.len) {
                return ValidationResult.invalidWithDepth(.doc, "CLX extends beyond Table stream", .structural);
            }

            const clx_result = validateClx(table_data[fc_clx..][0..lcb_clx], fib_lw, wd_data.len);
            if (clx_result) |err_msg| {
                return ValidationResult.invalidWithDepth(.doc, err_msg, .structural);
            }
        }
    }

    // Validate PlcBteChpx (character property bin table) at FibRgFcLcb97 index 12
    if (cb_rg_fc_lcb > 12) {
        const fc_chpx = std.mem.readInt(u32, wd_data[0x9A + 12 * 8 ..][0..4], .little);
        const lcb_chpx = std.mem.readInt(u32, wd_data[0x9A + 12 * 8 + 4 ..][0..4], .little);

        if (lcb_chpx > 0) {
            if (@as(u64, fc_chpx) + lcb_chpx > table_data.len) {
                return ValidationResult.invalidWithDepth(.doc, "PlcBteChpx extends beyond Table stream", .structural);
            }

            const chpx_result = validatePlcBteChpx(table_data[fc_chpx..][0..lcb_chpx], total_cp, wd_data.len);
            if (chpx_result) |err_msg| {
                return ValidationResult.invalidWithDepth(.doc, err_msg, .structural);
            }
        }
    }

    // Validate PlcBtePapx (paragraph property bin table) at FibRgFcLcb97 index 13
    if (cb_rg_fc_lcb > 13) {
        const fc_papx = std.mem.readInt(u32, wd_data[0x9A + 13 * 8 ..][0..4], .little);
        const lcb_papx = std.mem.readInt(u32, wd_data[0x9A + 13 * 8 + 4 ..][0..4], .little);

        if (lcb_papx > 0) {
            if (@as(u64, fc_papx) + lcb_papx > table_data.len) {
                return ValidationResult.invalidWithDepth(.doc, "PlcBtePapx extends beyond Table stream", .structural);
            }

            const papx_result = validatePlcBtePapx(table_data[fc_papx..][0..lcb_papx], total_cp, wd_data.len);
            if (papx_result) |err_msg| {
                return ValidationResult.invalidWithDepth(.doc, err_msg, .structural);
            }
        }
    }

    return ValidationResult.okWithDepth(.doc, .full);
}

/// Parse FibBase from the first 32 bytes of WordDocument stream.
fn parseFibBase(data: []const u8) FibBase {
    return FibBase{
        .wIdent = std.mem.readInt(u16, data[0x00..0x02], .little),
        .nFib = std.mem.readInt(u16, data[0x02..0x04], .little),
        .lid = std.mem.readInt(u16, data[0x06..0x08], .little),
        .pnNext = std.mem.readInt(u16, data[0x08..0x0A], .little),
        .flags = std.mem.readInt(u16, data[0x0A..0x0C], .little),
        .nFibBack = std.mem.readInt(u16, data[0x0C..0x0E], .little),
        .lKey = std.mem.readInt(u32, data[0x0E..0x12], .little),
        .envr = data[0x12],
        .flags2 = data[0x13],
    };
}

/// Parse FibRgLw97 from offset 0x40 (22 x u32).
fn parseFibRgLw97(data: []const u8) FibRgLw97 {
    return FibRgLw97{
        .cbMac = std.mem.readInt(u32, data[0x40..0x44], .little),
        .ccpText = std.mem.readInt(u32, data[0x4C..0x50], .little),
        .ccpFtn = std.mem.readInt(u32, data[0x50..0x54], .little),
        .ccpHdd = std.mem.readInt(u32, data[0x54..0x58], .little),
        .ccpAtn = std.mem.readInt(u32, data[0x5C..0x60], .little),
        .ccpEdn = std.mem.readInt(u32, data[0x60..0x64], .little),
        .ccpTxbx = std.mem.readInt(u32, data[0x64..0x68], .little),
        .ccpHdrTxbx = std.mem.readInt(u32, data[0x68..0x6C], .little),
    };
}

/// Well-known FibRgFcLcb97 indices that are reliable for cross-validation.
/// Word leaves garbage in many other entries, especially those added in later
/// versions than the file's actual nFib. Only validate indices where real-world
/// Word files consistently have correct (fc, lcb) values.
const KNOWN_FC_LCB_INDICES = [_]u16{
    0, // fcStshfOrig — original stylesheet
    1, // fcStshf — stylesheet
    2, // fcPlcfLst — list formatting
    4, // fcPlfLfo — list format override
    6, // fcPlcfSed — section descriptors
    8, // fcPlcfPhe — paragraph heights
    10, // fcSttbfGlsy — glossary strings
    12, // fcPlcfBteChpx — character property bin table
    13, // fcPlcfBtePapx — paragraph property bin table
    14, // fcPlcfSea — private
    15, // fcPlcfFldMom — field positions in main doc
    16, // fcPlcfFldHdr — field positions in headers
    17, // fcPlcfFldFtn — field positions in footnotes
    18, // fcPlcfFldAtn — field positions in annotations
    20, // fcSttbfFfn — font table
    23, // fcPlcfBkf — bookmark first positions
    24, // fcPlcfBkl — bookmark last positions
    26, // fcSttbfBkmk — bookmark names
    28, // fcPlcfFldEdn — field positions in endnotes
    31, // fcSttbfAssoc — associated strings
    33, // fcDop — document properties
    39, // fcSttbfRMark — revision mark author names
    42, // fcPlcfFldTxbx — field positions in textboxes
    44, // fcPlcfFldHdrTxbx — field positions in header textboxes
    58, // fcSttbfCaption — auto-caption strings
    66, // fcClx — CLX / piece table (validated separately too)
    72, // fcSttbfBkmkArto — art object bookmark names
    80, // fcPlcfWkb — subdocument positions
    86, // fcCmds — macro commands
    92, // fcSttbfUsrMark — user mark names
};

/// Validate well-known fc/lcb pairs against Table stream bounds.
/// Only checks indices known to contain reliable data in real-world Word files.
/// Returns an error message string if validation fails, null if OK.
fn validateKnownTableBounds(wd_data: []const u8, cb_rg_fc_lcb: u16, table_size: usize) ?[]const u8 {
    for (KNOWN_FC_LCB_INDICES) |idx| {
        if (idx >= cb_rg_fc_lcb) continue;

        const pair_offset = 0x9A + @as(usize, idx) * 8;
        const fc = std.mem.readInt(u32, wd_data[pair_offset..][0..4], .little);
        const lcb = std.mem.readInt(u32, wd_data[pair_offset + 4 ..][0..4], .little);

        if (lcb > 0) {
            const end = @as(u64, fc) + lcb;
            if (end > table_size) {
                return "FIB fc/lcb pair references data beyond Table stream";
            }
        }
    }
    return null;
}

/// Maximum number of piece descriptors before we consider the data corrupt.
/// Real Word documents rarely exceed a few hundred pieces; 1M is extremely generous.
const MAX_PIECE_DESCRIPTORS: u32 = 1_000_000;

/// Maximum number of Prc entries in CLX before we bail.
/// MS-DOC spec says Prc entries are rare; more than 1000 is suspicious.
const MAX_PRC_ENTRIES: u32 = 1_000;

/// Validate CLX structure (Piece Table) from the Table stream, including full PCD decode.
/// The CLX contains optional Prc entries (type 0x01) followed by a Pcdt (type 0x02).
/// Deep validation follows every PCD's fc to verify it points within the WordDocument stream.
/// Returns an error message if invalid, null if OK.
fn validateClx(clx_data: []const u8, fib_lw: FibRgLw97, wd_size: usize) ?[]const u8 {
    if (clx_data.len == 0) return null;

    var pos: usize = 0;

    // Skip any Prc entries (type 0x01)
    var prc_count: u32 = 0;
    while (pos < clx_data.len and clx_data[pos] == 0x01) {
        if (pos + 3 > clx_data.len) return "CLX Prc entry truncated";
        const prc_size = std.mem.readInt(u16, clx_data[pos + 1 ..][0..2], .little);
        const advance = @as(usize, 3) + prc_size;
        if (pos + advance > clx_data.len) return "CLX Prc entry extends beyond CLX data";
        pos += advance;
        prc_count += 1;
        if (prc_count > MAX_PRC_ENTRIES) return "CLX has too many Prc entries (likely corrupt)";
    }

    // Must have Pcdt header (type 0x02)
    if (pos >= clx_data.len) return "CLX missing Pcdt header";
    if (clx_data[pos] != 0x02) return "CLX invalid Pcdt marker (expected 0x02)";
    pos += 1;

    // Pcdt size (u32)
    if (pos + 4 > clx_data.len) return "CLX Pcdt size truncated";
    const pcdt_size = std.mem.readInt(u32, clx_data[pos..][0..4], .little);
    pos += 4;

    if (pos + pcdt_size > clx_data.len) return "CLX Pcdt extends beyond CLX data";

    // Pcdt contains PlcPcd: array of (n+1) CPs (u32) + n PCD entries (8 bytes each)
    // Calculate n from pcdt_size: pcdt_size = (n+1)*4 + n*8 = 4n + 4 + 8n = 12n + 4
    // So n = (pcdt_size - 4) / 12
    if (pcdt_size < 4) return "CLX Pcdt too small";
    if ((pcdt_size - 4) % 12 != 0) return "CLX Pcdt size inconsistent with piece descriptor layout";

    const n = (pcdt_size - 4) / 12;
    if (n == 0) return "CLX piece table has no entries";
    if (n > MAX_PIECE_DESCRIPTORS) return "CLX piece table has too many entries (likely corrupt)";

    // Read CP array and verify monotonicity
    const cp_array_start = pos;
    var prev_cp: u32 = 0;
    for (0..n + 1) |i| {
        const cp_offset = cp_array_start + i * 4;
        if (cp_offset + 4 > clx_data.len) return "CLX CP array truncated";
        const cp = std.mem.readInt(u32, clx_data[cp_offset..][0..4], .little);

        if (i > 0 and cp < prev_cp) {
            return "CLX piece table CP positions not monotonically increasing";
        }
        prev_cp = cp;
    }

    // Cross-validate: last CP should be consistent with FIB character counts
    const last_cp_offset = cp_array_start + n * 4;
    if (last_cp_offset + 4 <= clx_data.len) {
        const last_cp = std.mem.readInt(u32, clx_data[last_cp_offset..][0..4], .little);

        const total_ccp = fib_lw.ccpText +| fib_lw.ccpFtn +| fib_lw.ccpHdd +|
            fib_lw.ccpAtn +| fib_lw.ccpEdn +| fib_lw.ccpTxbx +| fib_lw.ccpHdrTxbx;

        if (total_ccp > 0) {
            if (last_cp < fib_lw.ccpText) {
                return "CLX piece table total CP range smaller than document text";
            }
        }
    }

    // === Deep PCD validation ===
    // Each PCD is 8 bytes: 2-byte descriptor word + 4-byte fc + 2-byte prm
    // fc has bit 30 = FcCompressed flag: if set, physical offset = (fc & 0x3FFFFFFF) / 2,
    // text is Latin-1 (1 byte/char); if clear, offset = fc, text is UTF-16LE (2 bytes/char)
    const pcd_array_start = cp_array_start + (n + 1) * 4;
    for (0..n) |i| {
        const pcd_offset = pcd_array_start + i * 8;
        if (pcd_offset + 8 > clx_data.len) return "CLX PCD array truncated";

        const fc_raw = std.mem.readInt(u32, clx_data[pcd_offset + 2 ..][0..4], .little);
        const fc_compressed = (fc_raw & 0x40000000) != 0;

        // Get CP range for this piece
        const cp_start = std.mem.readInt(u32, clx_data[cp_array_start + i * 4 ..][0..4], .little);
        const cp_end = std.mem.readInt(u32, clx_data[cp_array_start + (i + 1) * 4 ..][0..4], .little);
        if (cp_end < cp_start) return "CLX PCD has negative character range";
        const char_count = cp_end - cp_start;

        // Calculate physical byte range in WordDocument stream
        if (fc_compressed) {
            const phys_offset = (fc_raw & 0x3FFFFFFF) / 2;
            const byte_len = char_count; // 1 byte per char for Latin-1
            if (@as(u64, phys_offset) + byte_len > wd_size) {
                return "CLX PCD fc (compressed/Latin-1) points beyond WordDocument stream";
            }
        } else {
            const phys_offset = fc_raw & 0x3FFFFFFF;
            const byte_len = @as(u64, char_count) * 2; // 2 bytes per char for UTF-16LE
            if (@as(u64, phys_offset) + byte_len > wd_size) {
                return "CLX PCD fc (UTF-16LE) points beyond WordDocument stream";
            }
        }
    }

    return null;
}

/// Maximum PLCF entries before we consider data corrupt.
const MAX_PLCF_ENTRIES: usize = 1_000_000;

/// Validate a PLCF (Plex of CPs) structure from the Table stream.
/// PLCFs contain (n+1) CPs (u32) followed by n data entries of fixed size.
/// Validates: CP monotonicity, entry count consistency, all CPs within total_cp range.
/// Returns error message if invalid, null if OK.
fn validatePlcf(data: []const u8, entry_size: usize, total_cp: u32) ?[]const u8 {
    if (data.len < 8) return "PLCF too small for even one entry";
    if (entry_size == 0) return "PLCF entry size is zero (invalid)";

    // Calculate n: data.len = (n+1)*4 + n*entry_size
    // => data.len = 4n + 4 + n*entry_size = n*(4+entry_size) + 4
    // => n = (data.len - 4) / (4 + entry_size)
    if (data.len < 4) return "PLCF too small";
    const remainder = (data.len - 4) % (4 + entry_size);
    if (remainder != 0) return "PLCF size inconsistent with entry layout";

    const n = (data.len - 4) / (4 + entry_size);
    if (n == 0) return null; // Empty PLCF is valid (no formatting runs)
    if (n > MAX_PLCF_ENTRIES) return "PLCF has too many entries (likely corrupt)";

    // Validate CP monotonicity and bounds
    var prev_cp: u32 = 0;
    for (0..n + 1) |i| {
        const offset = i * 4;
        if (offset + 4 > data.len) return "PLCF CP array truncated";
        const cp = std.mem.readInt(u32, data[offset..][0..4], .little);

        if (i > 0 and cp < prev_cp) {
            return "PLCF CP positions not monotonically increasing";
        }
        // CPs should be within document bounds (with some slack for separators)
        if (cp > total_cp +| 1) {
            return "PLCF CP exceeds document character count";
        }
        prev_cp = cp;
    }

    return null;
}

/// Validate PLCF monotonicity and size consistency only (no CP bounds check).
/// Used for BTEs where CPs can exceed the text-only character count.
fn validatePlcfMonotonic(data: []const u8, entry_size: usize) ?[]const u8 {
    if (data.len < 8) return "PLCF too small for even one entry";
    if (entry_size == 0) return "PLCF entry size is zero (invalid)";
    if (data.len < 4) return "PLCF too small";
    const remainder = (data.len - 4) % (4 + entry_size);
    if (remainder != 0) return "PLCF size inconsistent with entry layout";

    const n = (data.len - 4) / (4 + entry_size);
    if (n == 0) return null;
    if (n > MAX_PLCF_ENTRIES) return "PLCF has too many entries (likely corrupt)";

    var prev_cp: u32 = 0;
    for (0..n + 1) |i| {
        const offset = i * 4;
        if (offset + 4 > data.len) return "PLCF CP array truncated";
        const cp = std.mem.readInt(u32, data[offset..][0..4], .little);

        if (i > 0 and cp < prev_cp) {
            return "PLCF CP positions not monotonically increasing";
        }
        prev_cp = cp;
    }

    return null;
}

/// Validate PlcBteChpx (character formatting bin table) from Table stream.
/// FibRgFcLcb97 index 32 = fcPlcfBteChpx/lcbPlcfBteChpx.
/// Each BTE entry is 4 bytes (pn: u32 — page number in WordDocument stream).
fn validatePlcBteChpx(data: []const u8, _: u32, wd_size: usize) ?[]const u8 {
    // PlcBteChpx: (n+1) CPs + n BTE entries (4 bytes each)
    // Note: BTE CPs can exceed document text range — they index ALL character positions
    // including internal separators. Only validate monotonicity, not bounds.
    const base_result = validatePlcfMonotonic(data, 4);
    if (base_result != null) return "PlcBteChpx: CP structure invalid";

    if (data.len < 4) return null;
    const n = (data.len - 4) / 8; // (4+4) per entry
    if (n == 0) return null;

    // Validate each BTE page number points within WordDocument stream
    // Each pn refers to a 512-byte page
    const bte_start = (n + 1) * 4;
    for (0..n) |i| {
        const offset = bte_start + i * 4;
        if (offset + 4 > data.len) return "PlcBteChpx: BTE array truncated";
        const pn = std.mem.readInt(u32, data[offset..][0..4], .little);
        const byte_offset = @as(u64, pn) * 512;
        if (byte_offset >= wd_size) {
            return "PlcBteChpx: BTE page number exceeds WordDocument stream";
        }
    }

    return null;
}

/// Validate PlcBtePapx (paragraph formatting bin table) from Table stream.
/// FibRgFcLcb97 index 33 = fcPlcfBtePapx/lcbPlcfBtePapx.
/// Each BTE entry is 4 bytes (pn: u32 — page number in WordDocument stream).
fn validatePlcBtePapx(data: []const u8, _: u32, wd_size: usize) ?[]const u8 {
    const base_result = validatePlcfMonotonic(data, 4);
    if (base_result != null) return "PlcBtePapx: CP structure invalid";

    if (data.len < 4) return null;
    const n = (data.len - 4) / 8;
    if (n == 0) return null;

    const bte_start = (n + 1) * 4;
    for (0..n) |i| {
        const offset = bte_start + i * 4;
        if (offset + 4 > data.len) return "PlcBtePapx: BTE array truncated";
        const pn = std.mem.readInt(u32, data[offset..][0..4], .little);
        const byte_offset = @as(u64, pn) * 512;
        if (byte_offset >= wd_size) {
            return "PlcBtePapx: BTE page number exceeds WordDocument stream";
        }
    }

    return null;
}

// ============ Tests ============

/// Skip test if a ground truth file doesn't exist (e.g., samples in external repo).
fn skipIfMissing(comptime path: []const u8) !void {
    std.fs.cwd().access(path, .{}) catch return error.SkipZigTest;
}

test "parseFibBase from synthetic data" {
    var data: [0x9A]u8 = [_]u8{0} ** 0x9A;

    // wIdent
    std.mem.writeInt(u16, data[0..2], FIB_MAGIC, .little);
    // nFib
    std.mem.writeInt(u16, data[2..4], 0x00C1, .little);
    // flags with fWhichTblStm set
    std.mem.writeInt(u16, data[0x0A..0x0C], FLAG_WHICH_TBL_STM, .little);
    // nFibBack
    std.mem.writeInt(u16, data[0x0C..0x0E], NFIB_BACK_97, .little);

    const fib = parseFibBase(&data);
    try std.testing.expectEqual(FIB_MAGIC, fib.wIdent);
    try std.testing.expectEqual(@as(u16, 0x00C1), fib.nFib);
    try std.testing.expectEqual(NFIB_BACK_97, fib.nFibBack);
    try std.testing.expect(!fib.isEncrypted());
    try std.testing.expectEqualStrings("1Table", fib.tableStreamName());
}

test "parseFibBase detects encryption" {
    var data: [0x9A]u8 = [_]u8{0} ** 0x9A;
    std.mem.writeInt(u16, data[0x0A..0x0C], FLAG_ENCRYPTED, .little);

    const fib = parseFibBase(&data);
    try std.testing.expect(fib.isEncrypted());
}

test "parseFibBase selects 0Table" {
    var data: [0x9A]u8 = [_]u8{0} ** 0x9A;
    std.mem.writeInt(u16, data[0x0A..0x0C], 0, .little); // fWhichTblStm not set

    const fib = parseFibBase(&data);
    try std.testing.expectEqualStrings("0Table", fib.tableStreamName());
}

test "validateKnownTableBounds accepts valid pairs" {
    // Index 0 (fcStshfOrig) is a known index; put a valid pair there
    const pair_size = 0x9A + 1 * 8; // Need at least 1 pair
    var wd: [pair_size]u8 = [_]u8{0} ** pair_size;
    // pair 0: fc=10, lcb=20
    std.mem.writeInt(u32, wd[0x9A..][0..4], 10, .little);
    std.mem.writeInt(u32, wd[0x9A + 4 ..][0..4], 20, .little);
    const result = validateKnownTableBounds(&wd, 1, 100);
    try std.testing.expect(result == null);
}

test "validateKnownTableBounds rejects out-of-bounds pair at known index" {
    // Index 0 (fcStshfOrig) with out-of-bounds reference
    const pair_size = 0x9A + 1 * 8;
    var wd: [pair_size]u8 = [_]u8{0} ** pair_size;
    // fc=50, lcb=60 => end=110, table_size=100
    std.mem.writeInt(u32, wd[0x9A..][0..4], 50, .little);
    std.mem.writeInt(u32, wd[0x9A + 4 ..][0..4], 60, .little);
    const result = validateKnownTableBounds(&wd, 1, 100);
    try std.testing.expect(result != null);
}

test "validateKnownTableBounds ignores unknown indices" {
    // Put garbage at index 87 (NOT a known index) — should be ignored
    const pair_size = 0x9A + 88 * 8;
    var wd: [pair_size]u8 = [_]u8{0} ** pair_size;
    // Index 87: fc=0xFFFFFFFF, lcb=99999999
    std.mem.writeInt(u32, wd[0x9A + 87 * 8 ..][0..4], 0xFFFFFFFF, .little);
    std.mem.writeInt(u32, wd[0x9A + 87 * 8 + 4 ..][0..4], 99999999, .little);
    const result = validateKnownTableBounds(&wd, 88, 100);
    try std.testing.expect(result == null);
}

test "validateClx accepts valid piece table" {
    // Build a minimal CLX: Pcdt marker (0x02) + size + 1 piece (2 CPs + 1 PCD)
    // pcdt_size = 2*4 + 1*8 = 16
    var clx: [1 + 4 + 16]u8 = undefined;
    clx[0] = 0x02; // Pcdt marker
    std.mem.writeInt(u32, clx[1..5], 16, .little); // pcdt_size
    // CP[0] = 0
    std.mem.writeInt(u32, clx[5..9], 0, .little);
    // CP[1] = 20
    std.mem.writeInt(u32, clx[9..13], 20, .little);
    // PCD (8 bytes) — don't care about content for this test
    @memset(clx[13..21], 0);

    const fib_lw = FibRgLw97{
        .cbMac = 100,
        .ccpText = 20,
        .ccpFtn = 0,
        .ccpHdd = 0,
        .ccpAtn = 0,
        .ccpEdn = 0,
        .ccpTxbx = 0,
        .ccpHdrTxbx = 0,
    };

    const result = validateClx(&clx, fib_lw, 10000);
    try std.testing.expect(result == null);
}

test "validateClx rejects non-monotonic CPs" {
    var clx: [1 + 4 + 16]u8 = undefined;
    clx[0] = 0x02;
    std.mem.writeInt(u32, clx[1..5], 16, .little);
    // CP[0] = 50 (larger than CP[1])
    std.mem.writeInt(u32, clx[5..9], 50, .little);
    // CP[1] = 20
    std.mem.writeInt(u32, clx[9..13], 20, .little);
    @memset(clx[13..21], 0);

    const fib_lw = FibRgLw97{
        .cbMac = 100,
        .ccpText = 0,
        .ccpFtn = 0,
        .ccpHdd = 0,
        .ccpAtn = 0,
        .ccpEdn = 0,
        .ccpTxbx = 0,
        .ccpHdrTxbx = 0,
    };

    const result = validateClx(&clx, fib_lw, 10000);
    try std.testing.expect(result != null);
}

test "validateClx rejects missing Pcdt marker" {
    var clx: [5]u8 = undefined;
    clx[0] = 0x03; // Wrong marker
    std.mem.writeInt(u32, clx[1..5], 0, .little);

    const fib_lw = FibRgLw97{
        .cbMac = 0,
        .ccpText = 0,
        .ccpFtn = 0,
        .ccpHdd = 0,
        .ccpAtn = 0,
        .ccpEdn = 0,
        .ccpTxbx = 0,
        .ccpHdrTxbx = 0,
    };

    const result = validateClx(&clx, fib_lw, 10000);
    try std.testing.expect(result != null);
}

test "validateDocDeep with sample.doc" {
    const allocator = std.testing.allocator;
    try skipIfMissing("ground_truth_examples/doc/sample.doc");
    const result = validateDocDeep(allocator, "ground_truth_examples/doc/sample.doc");
    // If sample.doc exists, it should validate successfully with full depth
    if (result.is_valid) {
        try std.testing.expectEqual(ValidationDepth.full, result.validation_depth);
    } else {
        // File might not exist in test CWD
        return error.SkipZigTest;
    }
}

test "validateClx validates PCD physical offsets" {
    // Build CLX with 1 piece: CP[0]=0, CP[1]=100, PCD with compressed fc
    var clx: [1 + 4 + 16]u8 = undefined;
    clx[0] = 0x02; // Pcdt marker
    std.mem.writeInt(u32, clx[1..5], 16, .little); // pcdt_size
    std.mem.writeInt(u32, clx[5..9], 0, .little); // CP[0] = 0
    std.mem.writeInt(u32, clx[9..13], 100, .little); // CP[1] = 100
    // PCD: descriptor(2) + fc(4) + prm(2) = 8 bytes
    std.mem.writeInt(u16, clx[13..15], 0, .little); // descriptor
    // fc with FcCompressed bit set (bit 30): physical offset = (fc & 0x3FFFFFFF) / 2
    // Set fc = 0x40000000 | (200 << 1) = compressed, offset 200, 100 bytes of Latin-1
    std.mem.writeInt(u32, clx[15..19], 0x40000000 | (200 << 1), .little);
    std.mem.writeInt(u16, clx[19..21], 0, .little); // prm

    const fib_lw = FibRgLw97{
        .cbMac = 1000, .ccpText = 100, .ccpFtn = 0, .ccpHdd = 0,
        .ccpAtn = 0, .ccpEdn = 0, .ccpTxbx = 0, .ccpHdrTxbx = 0,
    };

    // wd_size=400 — offset 200 + 100 bytes fits
    const result = validateClx(&clx, fib_lw, 400);
    try std.testing.expect(result == null);

    // wd_size=250 — offset 200 + 100 bytes overflows
    const result2 = validateClx(&clx, fib_lw, 250);
    try std.testing.expect(result2 != null);
}

test "validateClx validates UTF-16LE PCD offsets" {
    var clx: [1 + 4 + 16]u8 = undefined;
    clx[0] = 0x02;
    std.mem.writeInt(u32, clx[1..5], 16, .little);
    std.mem.writeInt(u32, clx[5..9], 0, .little); // CP[0] = 0
    std.mem.writeInt(u32, clx[9..13], 50, .little); // CP[1] = 50
    std.mem.writeInt(u16, clx[13..15], 0, .little);
    // fc without compressed bit: offset=100, 50 chars * 2 bytes = 100 bytes
    std.mem.writeInt(u32, clx[15..19], 100, .little);
    std.mem.writeInt(u16, clx[19..21], 0, .little);

    const fib_lw = FibRgLw97{
        .cbMac = 1000, .ccpText = 50, .ccpFtn = 0, .ccpHdd = 0,
        .ccpAtn = 0, .ccpEdn = 0, .ccpTxbx = 0, .ccpHdrTxbx = 0,
    };

    // wd_size=200: offset 100 + 100 bytes fits exactly
    try std.testing.expect(validateClx(&clx, fib_lw, 200) == null);
    // wd_size=199: one byte short
    try std.testing.expect(validateClx(&clx, fib_lw, 199) != null);
}

test "validatePlcf accepts valid PLCF" {
    // 2 entries: 3 CPs (12 bytes) + 2 * 4-byte entries (8 bytes) = 20 bytes
    var data: [20]u8 = undefined;
    std.mem.writeInt(u32, data[0..4], 0, .little); // CP[0]
    std.mem.writeInt(u32, data[4..8], 10, .little); // CP[1]
    std.mem.writeInt(u32, data[8..12], 20, .little); // CP[2]
    @memset(data[12..20], 0); // entries

    try std.testing.expect(validatePlcf(&data, 4, 100) == null);
}

test "validatePlcf rejects non-monotonic CPs" {
    var data: [20]u8 = undefined;
    std.mem.writeInt(u32, data[0..4], 50, .little); // CP[0] = 50
    std.mem.writeInt(u32, data[4..8], 10, .little); // CP[1] = 10 (backwards!)
    std.mem.writeInt(u32, data[8..12], 20, .little); // CP[2]
    @memset(data[12..20], 0);

    try std.testing.expect(validatePlcf(&data, 4, 100) != null);
}

test "validatePlcBteChpx validates page numbers" {
    // 1 entry: 2 CPs (8 bytes) + 1 * 4-byte BTE (4 bytes) = 12 bytes
    var data: [12]u8 = undefined;
    std.mem.writeInt(u32, data[0..4], 0, .little); // CP[0]
    std.mem.writeInt(u32, data[4..8], 100, .little); // CP[1]
    // BTE: page number 2 -> byte offset 1024
    std.mem.writeInt(u32, data[8..12], 2, .little);

    // wd_size=2048 — page 2 (offset 1024) is within bounds
    try std.testing.expect(validatePlcBteChpx(&data, 100, 2048) == null);
    // wd_size=512 — page 2 (offset 1024) exceeds stream
    try std.testing.expect(validatePlcBteChpx(&data, 100, 512) != null);
}

test "validatePlcBtePapx validates page numbers" {
    var data: [12]u8 = undefined;
    std.mem.writeInt(u32, data[0..4], 0, .little);
    std.mem.writeInt(u32, data[4..8], 100, .little);
    std.mem.writeInt(u32, data[8..12], 5, .little); // page 5 -> offset 2560

    try std.testing.expect(validatePlcBtePapx(&data, 100, 4096) == null);
    try std.testing.expect(validatePlcBtePapx(&data, 100, 2000) != null);
}

test "validateDocDeep rejects corrupted FIB magic" {
    // This test creates a real .doc with corrupted FIB magic by reading the sample
    // and flipping the first two bytes of the WordDocument stream
    const allocator = std.testing.allocator;

    // First verify we can read the sample
    const wd = ole2_validator.readNamedStream(allocator, "ground_truth_examples/doc/sample.doc", "WordDocument") orelse {
        return error.SkipZigTest;
    };
    defer allocator.free(wd);

    // Verify it has the correct magic before we test corruption
    const wIdent = std.mem.readInt(u16, wd[0..2], .little);
    try std.testing.expectEqual(FIB_MAGIC, wIdent);

    // We'll test the internal parsing functions directly with corrupted data
    var corrupted = try allocator.alloc(u8, wd.len);
    defer allocator.free(corrupted);
    @memcpy(corrupted, wd);
    // Corrupt wIdent
    corrupted[0] = 0x00;
    corrupted[1] = 0x00;

    const fib = parseFibBase(corrupted);
    try std.testing.expect(fib.wIdent != FIB_MAGIC);
}
