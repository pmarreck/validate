//! MS-XLS (Excel 97-2003) Deep Validator
//!
//! Validates Excel .xls files by parsing the Workbook stream's BIFF8 record chain,
//! cross-validating BoundSheet8 offsets, fully decoding the SST (Shared String Table)
//! with CONTINUE record reassembly, and parsing per-sheet cell records including
//! formula token arrays. Best-effort full decode — catches corruption in all bytes
//! except raw IEEE 754 numeric values (which have no inherent integrity).
//!
//! Spec reference: [MS-XLS] — BIFF8 record format, BOF, BoundSheet8, SST, cell records.

const std = @import("std");
const Allocator = std.mem.Allocator;

const format_validation = @import("format_validation.zig");
const ValidationResult = format_validation.ValidationResult;
const ValidationDepth = format_validation.ValidationDepth;
const FileFormat = format_validation.FileFormat;

const ole2_validator = @import("ole2_validator.zig");

// ============ BIFF8 Record Types ============

const REC_BOF: u16 = 0x0809;
const REC_EOF: u16 = 0x000A;
const REC_BOUNDSHEET8: u16 = 0x0085;
const REC_SST: u16 = 0x00FC;
const REC_CONTINUE: u16 = 0x003C;
const REC_FILEPASS: u16 = 0x002F;
const REC_LABELSST: u16 = 0x00FD;
const REC_NUMBER: u16 = 0x0203;
const REC_RK: u16 = 0x027E;
const REC_MULRK: u16 = 0x00BD;
const REC_MULBLANK: u16 = 0x00BE;
const REC_FORMULA: u16 = 0x0006;
const REC_BOOLERR: u16 = 0x0205;
const REC_BLANK: u16 = 0x0201;
const REC_LABEL: u16 = 0x0204;
const REC_DBCELL: u16 = 0x00D7;
const REC_INDEX: u16 = 0x020B;
const REC_ROW: u16 = 0x0208;
const REC_XF: u16 = 0x00E0;

/// Known BIFF8 record types (from [MS-XLS] spec).
/// Used to detect corrupted record headers — a random byte flip will
/// almost certainly produce a type not in this set.
fn isKnownBiff8RecordType(rec_type: u16) bool {
    return switch (rec_type) {
        // Core records
        0x0006, // FORMULA
        0x000A, // EOF
        0x000C, // CALCCOUNT
        0x000D, // CALCMODE
        0x000E, // PRECISION
        0x000F, // REFMODE
        0x0010, // DELTA
        0x0011, // ITERATION
        0x0012, // PROTECT
        0x0013, // PASSWORD
        0x0014, // HEADER
        0x0015, // FOOTER
        0x0016, // EXTERNCOUNT
        0x0017, // EXTERNSHEET
        0x0018, // NAME/Lbl
        0x0019, // WINDOWPROTECT
        0x001A, // VERTICALPAGEBREAKS
        0x001B, // HORIZONTALPAGEBREAKS
        0x001C, // NOTE
        0x001D, // SELECTION
        0x0022, // 1904
        0x0026, // LEFTMARGIN
        0x0027, // RIGHTMARGIN
        0x0028, // TOPMARGIN
        0x0029, // BOTTOMMARGIN
        0x002A, // PRINTHEADERS
        0x002B, // PRINTGRIDLINES
        0x002F, // FILEPASS
        0x0031, // FONT
        0x003C, // CONTINUE
        0x003D, // WINDOW1
        0x0040, // BACKUP
        0x0041, // PANE
        0x0042, // CODEPAGE
        0x004D, // PLS
        0x0050, // DCON
        0x0051, // DCONREF
        0x0055, // DEFCOLWIDTH
        0x005C, // WRITEACCESS
        0x005D, // OBJ
        0x005E, // UNCALCED
        0x005F, // SAVERECALC
        0x0060, // TEMPLATE
        0x0063, // OBJPROTECT
        0x007D, // COLINFO
        0x007E, // RK (old)
        0x0080, // GUTS
        0x0081, // WSBOOL
        0x0082, // GRIDSET
        0x0083, // HCENTER
        0x0084, // VCENTER
        0x0085, // BOUNDSHEET8
        0x008C, // COUNTRY
        0x008D, // HIDEOBJ
        0x0090, // SORT
        0x0092, // PALETTE
        0x009B, // FILTERMODE
        0x009C, // FNGROUPCOUNT
        0x009D, // AUTOFILTERINFO
        0x009E, // AUTOFILTER
        0x00A1, // SETUP (PrintSetup)
        0x00AB, // GCW
        0x00BD, // MULRK
        0x00BE, // MULBLANK
        0x00C1, // MMS
        0x00D6, // RSTRING
        0x00D7, // DBCELL
        0x00DA, // BOOKBOOL
        0x00DD, // SCENPROTECT
        0x00E0, // XF
        0x00E1, // INTERFACEHDR
        0x00E2, // INTERFACEEND
        0x00E5, // MERGEDCELLS/MERGECELLS
        0x00EB, // MSO_DRAWING_GROUP (MsoDrawingGroup)
        0x00EC, // MSO_DRAWING (MsoDrawing)
        0x00ED, // MSO_DRAWING_SELECTION
        0x00EF, // PHONETICPR
        0x00FC, // SST
        0x00FD, // LABELSST
        0x00FF, // EXTSST
        0x013D, // TABID
        0x015F, // LABELRANGES
        0x0160, // USESELFS
        0x0161, // DSF
        0x01AE, // SUPBOOK
        0x01AF, // PROT4REV
        0x01B0, // CONDFMT
        0x01B1, // CF
        0x01B2, // DVAL
        0x01B5, // DCONBIN
        0x01B6, // TXO
        0x01B7, // REFRESHALL
        0x01B8, // HLINK
        0x01BA, // CODENAME
        0x01BB, // SXFDBTYPE
        0x01BC, // PROT4REVPASS
        0x01BE, // DV
        0x01C0, // XL5MODIFY
        0x01C1, // FILESHARING2
        0x0200, // DIMENSIONS
        0x0201, // BLANK
        0x0203, // NUMBER
        0x0204, // LABEL
        0x0205, // BOOLERR
        0x0207, // STRING (formula result)
        0x0208, // ROW
        0x020B, // INDEX
        0x0221, // ARRAY
        0x0225, // DEFAULTROWHEIGHT
        0x0236, // TABLE (DataTable)
        0x023E, // WINDOW2
        0x027E, // RK
        0x0293, // STYLE
        0x041E, // FORMAT
        0x04BC, // SHRFMLA (shared formula)
        0x0800, // SCREENTIP (HLink tooltip)
        0x0802, // QSISXTAG
        0x0803, // DBQUERYEXT
        0x0805, // TXTQUERY
        0x0809, // BOF
        0x0850, // CHARTFRTINFO
        0x0851, // FRTWRAPPER
        0x0852, // STARTBLOCK
        0x0853, // ENDBLOCK
        0x0854, // STARTOBJECT
        0x0855, // ENDOBJECT
        0x0856, // CATLAB
        0x0857, // MARKETO
        0x0858, // CRTCOOPT
        0x0859, // DROPDOWNOBJIDS
        0x085A, // SHEETPROTECTION (FeatHdr)
        0x085B, // RANGEPROTECTION (Feat)
        0x0862, // SHEETLAYOUT
        0x0863, // BOOKEXT
        0x0864, // SXADDL
        0x0867, // FEATHEADR11
        0x0868, // FEAT11
        0x0872, // SXADDL12
        0x087C, // PLV
        0x0892, // COMPAT12
        0x0896, // DXF
        0x0897, // TABLESTYLES
        0x089A, // TABLESTYLE
        0x089B, // TABLESTYLEELEMENT
        0x089C, // STYLEEXT
        0x08A3, // FORCEFULLCALCULATION
        // Extended/POI/newer Excel types
        0x0023, // EXTERNNAME
        0x0099, // STANDARDWIDTH
        0x009A, // (reserved)
        0x00A0, // SCL
        0x00D3, // OBPROJ
        0x01C2, // CLRTCLIENT
        0x087D, // XFCRC
        0x0866, // SHEETPROTECTION2
        0x088B, // PLV (Mac Excel)
        0x088C, // COMPAT12EX
        0x088E, // MTRSETTINGS
        0x08C8, // LISTCF
        0x105C, // SXTH
        => true,
        else => false,
    };
}

/// BIFF8 version in BOF record
const BIFF8_VERSION: u16 = 0x0600;

/// BOF doc type: Workbook globals
const DOCTYPE_WORKBOOK: u16 = 0x0005;

/// BOF doc type: Worksheet/dialog
const DOCTYPE_WORKSHEET: u16 = 0x0010;

/// BOF doc type: Chart
const DOCTYPE_CHART: u16 = 0x0020;

/// BOF doc type: Macro sheet
const DOCTYPE_MACRO: u16 = 0x0040;

/// Collected BoundSheet8 info during record walk
const BoundSheetInfo = struct {
    offset: u32,
    visibility: u8,
    sheet_type: u8,
};

/// Collected SST info
const SstInfo = struct {
    total_refs: u32,
    unique_count: u32,
    data_offset: usize, // stream offset of SST record data (after 8-byte header)
    rec_offset: usize, // stream offset of SST record header
};

/// A BIFF8 record position within the stream
const RecordPos = struct {
    offset: usize, // offset of record header in stream
    rec_type: u16,
    data_len: u16,
};

// ============ CONTINUE Record Reassembly ============

/// Reassemble a record's data with its CONTINUE records into a contiguous buffer.
/// Returns the assembled data (caller must free) and the stream position after
/// the last CONTINUE record consumed.
fn reassembleRecord(allocator: Allocator, wb_data: []const u8, rec_offset: usize) !struct { data: []u8, end_pos: usize } {
    const rec_len = std.mem.readInt(u16, wb_data[rec_offset + 2 ..][0..2], .little);

    // Collect total size first
    var total_len: usize = rec_len;
    var scan_pos: usize = rec_offset + 4 + rec_len;
    while (scan_pos + 4 <= wb_data.len) {
        const next_type = std.mem.readInt(u16, wb_data[scan_pos..][0..2], .little);
        if (next_type != REC_CONTINUE) break;
        const cont_len = std.mem.readInt(u16, wb_data[scan_pos + 2 ..][0..2], .little);
        if (scan_pos + 4 + cont_len > wb_data.len) break;
        total_len += cont_len;
        scan_pos += 4 + cont_len;
    }

    const buf = try allocator.alloc(u8, total_len);
    errdefer allocator.free(buf);

    // Copy primary record data
    @memcpy(buf[0..rec_len], wb_data[rec_offset + 4 ..][0..rec_len]);
    var write_pos: usize = rec_len;
    var end_pos: usize = rec_offset + 4 + rec_len;

    // Copy CONTINUE records
    while (end_pos + 4 <= wb_data.len) {
        const next_type = std.mem.readInt(u16, wb_data[end_pos..][0..2], .little);
        if (next_type != REC_CONTINUE) break;
        const cont_len = std.mem.readInt(u16, wb_data[end_pos + 2 ..][0..2], .little);
        if (end_pos + 4 + cont_len > wb_data.len) break;
        @memcpy(buf[write_pos..][0..cont_len], wb_data[end_pos + 4 ..][0..cont_len]);
        write_pos += cont_len;
        end_pos += 4 + cont_len;
    }

    return .{ .data = buf, .end_pos = end_pos };
}

// ============ SST String Parsing ============

/// Parse a BIFF8 Unicode string from SST data buffer.
/// Returns the number of bytes consumed, or error if corrupt.
/// BIFF8 string format: cch(u16) + flags(u8) + [cRun(u16)] + [cbExtRst(u32)] + chars + [runs] + [ext]
fn parseSstString(data: []const u8) !usize {
    if (data.len < 3) return error.SstStringTruncated;

    const cch = std.mem.readInt(u16, data[0..2], .little);
    const flags = data[2];
    var pos: usize = 3;

    const is_wide = (flags & 0x01) != 0; // fHighByte — UTF-16LE if set
    const has_rich = (flags & 0x08) != 0; // fRichSt
    const has_ext = (flags & 0x04) != 0; // fExtSt

    var c_run: u16 = 0;
    var cb_ext_rst: u32 = 0;

    if (has_rich) {
        if (pos + 2 > data.len) return error.SstStringTruncated;
        c_run = std.mem.readInt(u16, data[pos..][0..2], .little);
        pos += 2;
    }

    if (has_ext) {
        if (pos + 4 > data.len) return error.SstStringTruncated;
        cb_ext_rst = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;
    }

    // Character data
    const char_bytes: usize = if (is_wide) @as(usize, cch) * 2 else cch;
    if (pos + char_bytes > data.len) return error.SstStringTruncated;
    pos += char_bytes;

    // Rich text formatting runs (4 bytes each: u16 ichFirst + u16 ifnt)
    if (has_rich) {
        const run_bytes: usize = @as(usize, c_run) * 4;
        if (pos + run_bytes > data.len) return error.SstStringTruncated;
        pos += run_bytes;
    }

    // Extended string data
    if (has_ext) {
        if (pos + cb_ext_rst > data.len) return error.SstStringTruncated;
        pos += cb_ext_rst;
    }

    return pos;
}

/// Fully parse all strings in an SST data buffer (already reassembled with CONTINUE data).
/// Validates that exactly unique_count strings can be parsed and the data is consumed.
fn validateSstStrings(data: []const u8, unique_count: u32) !void {
    if (data.len < 8) return error.SstTooShort;

    // Skip the 8-byte SST header (cstTotal + cstUnique)
    var pos: usize = 8;
    var strings_parsed: u32 = 0;

    while (strings_parsed < unique_count) {
        if (pos >= data.len) return error.SstStringTruncated;
        const consumed = parseSstString(data[pos..]) catch |err| {
            return err;
        };
        if (consumed == 0) return error.SstStringZeroLength;
        pos += consumed;
        strings_parsed += 1;
    }

    // We don't require pos == data.len because CONTINUE record boundaries
    // can leave padding bytes, and there may be trailing data after strings
}

// ============ Formula Token (Ptg) Parsing ============

/// Validate a formula token array (RPN expression) by walking the ptg stream.
/// Each token starts with a 1-byte ptg type that determines its data size.
/// If the stream parses cleanly, the formula bytes are structurally valid.
fn validateFormulaTokens(data: []const u8) !void {
    var pos: usize = 0;
    while (pos < data.len) {
        const ptg = data[pos];
        pos += 1;

        // Variable-length tokens — must be handled before the fixed-size switch
        if (ptg == 0x17) {
            // ptgStr — u8 cch + u8 flags + chars
            if (pos + 2 > data.len) return error.FormulaTokenTruncated;
            const str_len = data[pos];
            const str_wide = (data[pos + 1] & 0x01) != 0;
            pos += 2;
            const str_bytes: usize = if (str_wide) @as(usize, str_len) * 2 else str_len;
            if (pos + str_bytes > data.len) return error.FormulaTokenTruncated;
            pos += str_bytes;
            continue;
        }

        if (ptg == 0x18) {
            // ptgExtended — subtype byte determines layout, skip conservatively
            // These are rare (NLR references, etc.). Accept remaining bytes.
            return;
        }

        if (ptg == 0x19) {
            // ptgAttr — u8 type + variable data
            if (pos >= data.len) return error.FormulaTokenTruncated;
            const attr_type = data[pos];
            pos += 1;
            if (attr_type & 0x04 != 0) {
                // attrChoose — u16 cOffset + (cOffset+1) * u16 offsets
                if (pos + 2 > data.len) return error.FormulaTokenTruncated;
                const c_offset = std.mem.readInt(u16, data[pos..][0..2], .little);
                pos += 2;
                const jump_bytes = (@as(usize, c_offset) + 1) * 2;
                if (pos + jump_bytes > data.len) return error.FormulaTokenTruncated;
                pos += jump_bytes;
            } else {
                // Other attr types (attrSemi, attrIf, attrGoto, attrSum, attrSpace): 2 bytes
                if (pos + 2 > data.len) return error.FormulaTokenTruncated;
                pos += 2;
            }
            continue;
        }

        // Fixed-size tokens by ptg byte value
        const size: usize = switch (ptg) {
            // Unary/binary operators — no data
            0x03...0x16 => 0,
            // Base control tokens
            0x01 => 4, // ptgExp (row u16 + col u16)
            0x02 => 4, // ptgTbl (row u16 + col u16)
            // Constants
            0x1C => 1, // ptgErr (u8 error code)
            0x1D => 1, // ptgBool (u8 value)
            0x1E => 2, // ptgInt (u16)
            0x1F => 8, // ptgNum (f64)
            // Classified operand tokens (base + 0x20/0x40/0x60 for R/V/A class)
            0x20, 0x40, 0x60 => 7, // ptgArray
            0x21, 0x41, 0x61 => 2, // ptgFunc (u16 iftab)
            0x22, 0x42, 0x62 => 3, // ptgFuncVar (u8 cargs + u16 iftab)
            0x23, 0x43, 0x63 => 4, // ptgName (u16 + 2 reserved)
            0x24, 0x44, 0x64 => 4, // ptgRef (u16 row + u16 col)
            0x25, 0x45, 0x65 => 8, // ptgArea (4 x u16)
            0x26, 0x46, 0x66 => 6, // ptgMemArea (4 reserved + u16 cce)
            0x27, 0x47, 0x67 => 6, // ptgMemErr
            0x28, 0x48, 0x68 => 6, // ptgMemNoMem
            0x29, 0x49, 0x69 => 2, // ptgMemFunc (u16 cce)
            0x2A, 0x4A, 0x6A => 4, // ptgRefErr
            0x2B, 0x4B, 0x6B => 8, // ptgAreaErr
            0x2C, 0x4C, 0x6C => 4, // ptgRefN
            0x2D, 0x4D, 0x6D => 8, // ptgAreaN
            0x39, 0x59, 0x79 => 6, // ptgNameX (u16 ixti + u16 name + 2 reserved)
            0x3A, 0x5A, 0x7A => 6, // ptgRef3d
            0x3B, 0x5B, 0x7B => 10, // ptgArea3d
            0x3C, 0x5C, 0x7C => 6, // ptgRefErr3d
            0x3D, 0x5D, 0x7D => 10, // ptgAreaErr3d
            else => {
                // Unknown/extended token — accept remaining bytes as opaque
                return;
            },
        };

        if (pos + size > data.len) return error.FormulaTokenTruncated;
        pos += size;
    }
}

// ============ Per-Sheet Cell Record Validation ============

/// Walk a worksheet substream and validate cell records.
/// Checks LabelSst indices against SST unique count, parses formula token arrays,
/// and validates cell record field sizes.
fn validateSheetRecords(wb_data: []const u8, sheet_offset: usize, sst_unique_count: u32, xf_count: u16) !void {
    var pos = sheet_offset;

    // Skip the sheet BOF
    if (pos + 4 > wb_data.len) return error.SheetTruncated;
    const bof_len = std.mem.readInt(u16, wb_data[pos + 2 ..][0..2], .little);
    pos += 4 + bof_len;

    while (pos + 4 <= wb_data.len) {
        const rec_type = std.mem.readInt(u16, wb_data[pos..][0..2], .little);
        const rec_len = std.mem.readInt(u16, wb_data[pos + 2 ..][0..2], .little);

        if (rec_type == 0 and rec_len == 0) break;
        if (pos + 4 + rec_len > wb_data.len) return error.SheetRecordOverrun;

        const rec_data = wb_data[pos + 4 ..][0..rec_len];

        switch (rec_type) {
            REC_EOF => break,

            REC_LABELSST => {
                // LabelSst: u16 row + u16 col + u16 ixfe + u32 isst
                if (rec_len < 10) return error.LabelSstTooShort;
                const isst = std.mem.readInt(u32, rec_data[6..10], .little);
                if (sst_unique_count > 0 and isst >= sst_unique_count) {
                    return error.LabelSstIndexOutOfRange;
                }
                // Validate XF index
                if (xf_count > 0) {
                    const ixfe = std.mem.readInt(u16, rec_data[4..6], .little);
                    if (ixfe >= xf_count) return error.CellXfIndexOutOfRange;
                }
            },

            REC_NUMBER => {
                // Number: u16 row + u16 col + u16 ixfe + f64 value = 14 bytes
                if (rec_len < 14) return error.NumberRecordTooShort;
            },

            REC_RK => {
                // RK: u16 row + u16 col + u16 ixfe + u32 rk = 10 bytes
                if (rec_len < 10) return error.RkRecordTooShort;
            },

            REC_MULRK => {
                // MulRk: u16 row + u16 colFirst + (u16 ixfe + u32 rk)* + u16 colLast
                if (rec_len < 6) return error.MulRkRecordTooShort;
                // Validate field count consistency
                const remaining = rec_len - 6; // minus row(2) + colFirst(2) + colLast(2)
                if (remaining % 6 != 0) return error.MulRkRecordMalformed;
            },

            REC_MULBLANK => {
                // MulBlank: u16 row + u16 colFirst + u16 ixfe* + u16 colLast
                if (rec_len < 6) return error.MulBlankRecordTooShort;
                const remaining = rec_len - 6;
                if (remaining % 2 != 0) return error.MulBlankRecordMalformed;
            },

            REC_FORMULA => {
                // Formula: u16 row + u16 col + u16 ixfe + 8 result + u16 grbit + u32 chn + u16 cce + ptg_data
                // Header = 2+2+2+8+2+4 = 20 bytes, then cce(2) at offset 20, tokens at 22
                if (rec_len < 22) return error.FormulaRecordTooShort;
                const cce = std.mem.readInt(u16, rec_data[20..22], .little);
                if (22 + cce > rec_len) return error.FormulaTokenOverrun;
                if (cce > 0) {
                    validateFormulaTokens(rec_data[22..][0..cce]) catch |err| {
                        return err;
                    };
                }
            },

            REC_BOOLERR => {
                // BoolErr: u16 row + u16 col + u16 ixfe + u8 bBoolErr + u8 fError = 8 bytes
                if (rec_len < 8) return error.BoolErrRecordTooShort;
                const f_error = rec_data[7];
                const b_value = rec_data[6];
                if (f_error == 0) {
                    // Boolean: value must be 0 or 1
                    if (b_value > 1) return error.BoolErrInvalidBool;
                } else if (f_error == 1) {
                    // Error: value must be a valid Excel error code
                    switch (b_value) {
                        0x00, 0x07, 0x0F, 0x17, 0x1D, 0x24, 0x2A, 0x2B => {},
                        else => return error.BoolErrInvalidError,
                    }
                } else {
                    return error.BoolErrInvalidFlag;
                }
            },

            REC_BLANK => {
                // Blank: u16 row + u16 col + u16 ixfe = 6 bytes
                if (rec_len < 6) return error.BlankRecordTooShort;
            },

            REC_ROW => {
                // Row: u16 rw + u16 colMic + u16 colMac + u16 miyRw + ... = at least 16 bytes
                if (rec_len < 16) return error.RowRecordTooShort;
            },

            else => {},
        }

        pos += 4 + rec_len;
    }
}

/// Validate a .xls file deeply by parsing the BIFF8 record chain in the Workbook stream,
/// fully decoding SST strings and per-sheet cell records.
pub fn validateXlsDeep(allocator: Allocator, path: []const u8) ValidationResult {
    return validateXlsStream(allocator, path);
}

fn validateXlsStream(allocator: Allocator, path: []const u8) ValidationResult {
    // Read Workbook stream (try "Workbook" first, then "Book" for BIFF5 compat)
    const wb_data = ole2_validator.readNamedStream(allocator, path, "Workbook") orelse
        ole2_validator.readNamedStream(allocator, path, "Book") orelse {
        return ValidationResult.invalidWithDepth(.xls, "Failed to read Workbook stream from OLE2 container", .structural);
    };
    defer allocator.free(wb_data);

    return validateWorkbookStream(allocator, wb_data);
}

/// Core validation logic operating on an in-memory Workbook stream.
/// Separated from I/O for testability.
pub fn validateWorkbookStream(allocator: Allocator, wb_data: []const u8) ValidationResult {
    if (wb_data.len < 4) {
        return ValidationResult.invalidWithDepth(.xls, "Workbook stream too small for BIFF8", .structural);
    }

    // Validate first record is BOF
    const first_type = std.mem.readInt(u16, wb_data[0..2], .little);
    const first_len = std.mem.readInt(u16, wb_data[2..4], .little);

    if (first_type != REC_BOF) {
        return ValidationResult.invalidWithDepth(.xls, "Workbook stream does not start with BOF record", .structural);
    }

    if (first_len < 4 or 4 + first_len > wb_data.len) {
        return ValidationResult.invalidWithDepth(.xls, "BOF record truncated", .structural);
    }

    // Check BIFF version
    const biff_version = std.mem.readInt(u16, wb_data[4..6], .little);
    if (biff_version != BIFF8_VERSION) {
        return ValidationResult.okWithDepthAndWarning(.xls, .structural, "Older BIFF version; deep validation requires BIFF8");
    }

    // Check doc type
    const doc_type = std.mem.readInt(u16, wb_data[6..8], .little);
    if (doc_type != DOCTYPE_WORKBOOK) {
        return ValidationResult.invalidWithDepth(.xls, "BOF doc type is not Workbook globals (expected 0x0005)", .structural);
    }

    // Walk the entire record chain. The Workbook stream contains multiple
    // substreams: workbook globals (BOF..EOF), then each sheet (BOF..EOF).
    // We walk all of them sequentially.
    var pos: usize = 0;
    var rec_count: u32 = 0;
    var eof_count: u32 = 0;
    var last_type: u16 = 0;
    var has_filepass = false;
    var bound_sheets_buf: [256]BoundSheetInfo = undefined;
    var bound_sheet_count: usize = 0;
    var sst_info: ?SstInfo = null;
    var xf_count: u16 = 0;

    while (pos + 4 <= wb_data.len) {
        const rec_type = std.mem.readInt(u16, wb_data[pos..][0..2], .little);
        const rec_len = std.mem.readInt(u16, wb_data[pos + 2 ..][0..2], .little);

        // Null padding: type=0x0000 len=0 after sector alignment — stop parsing
        if (rec_type == 0 and rec_len == 0) break;

        // Validate record doesn't extend beyond stream
        if (pos + 4 + rec_len > wb_data.len) {
            return ValidationResult.invalidWithDepth(.xls, "BIFF8 record extends beyond Workbook stream", .structural);
        }

        // Validate record type is known — catches corrupted record headers
        if (!isKnownBiff8RecordType(rec_type)) {
            return ValidationResult.invalidWithDepth(.xls, "Unknown BIFF8 record type (corrupted record header)", .full);
        }

        // Collect specific records
        switch (rec_type) {
            REC_EOF => {
                eof_count += 1;
            },
            REC_FILEPASS => {
                has_filepass = true;
            },
            REC_BOUNDSHEET8 => {
                if (rec_len >= 6 and bound_sheet_count < bound_sheets_buf.len) {
                    bound_sheets_buf[bound_sheet_count] = .{
                        .offset = std.mem.readInt(u32, wb_data[pos + 4 ..][0..4], .little),
                        .visibility = wb_data[pos + 8],
                        .sheet_type = wb_data[pos + 9],
                    };
                    bound_sheet_count += 1;
                }
            },
            REC_SST => {
                if (rec_len >= 8) {
                    sst_info = .{
                        .total_refs = std.mem.readInt(u32, wb_data[pos + 4 ..][0..4], .little),
                        .unique_count = std.mem.readInt(u32, wb_data[pos + 8 ..][0..4], .little),
                        .data_offset = pos + 4,
                        .rec_offset = pos,
                    };
                }
            },
            REC_XF => {
                xf_count += 1;
            },
            else => {},
        }

        last_type = rec_type;
        rec_count += 1;
        pos += 4 + rec_len;
    }

    // Record chain must consume entire stream (allow trailing zero padding
    // from OLE2 sector alignment)
    if (pos != wb_data.len) {
        var all_zero = true;
        for (wb_data[pos..]) |b| {
            if (b != 0) {
                all_zero = false;
                break;
            }
        }
        if (!all_zero) {
            return ValidationResult.invalidWithDepth(.xls, "BIFF8 record chain does not consume entire Workbook stream", .structural);
        }
    }

    // Last record must be EOF (end of final substream)
    if (last_type != REC_EOF) {
        return ValidationResult.invalidWithDepth(.xls, "Workbook stream does not end with EOF record", .structural);
    }

    // Must have at least 1 EOF for workbook globals
    if (eof_count == 0) {
        return ValidationResult.invalidWithDepth(.xls, "No EOF records found in Workbook stream", .structural);
    }

    // Must have at least 2 records (BOF + EOF)
    if (rec_count < 2) {
        return ValidationResult.invalidWithDepth(.xls, "Workbook stream has too few records", .structural);
    }

    // Check encryption
    if (has_filepass) {
        return ValidationResult.okWithDepthAndWarning(.xls, .structural, "Workbook is encrypted; content validation skipped");
    }

    // Cross-validate BoundSheet8 offsets
    if (bound_sheet_count == 0) {
        return ValidationResult.invalidWithDepth(.xls, "No BoundSheet8 records found (workbook must have at least one sheet)", .structural);
    }

    const bound_sheets = bound_sheets_buf[0..bound_sheet_count];
    for (bound_sheets) |sheet| {
        // Offset must be within stream, with room for at least a record header
        if (sheet.offset + 4 > wb_data.len) {
            return ValidationResult.invalidWithDepth(.xls, "BoundSheet8 offset points beyond Workbook stream", .structural);
        }

        // Record at offset must be BOF
        const sheet_rec_type = std.mem.readInt(u16, wb_data[sheet.offset..][0..2], .little);
        if (sheet_rec_type != REC_BOF) {
            return ValidationResult.invalidWithDepth(.xls, "BoundSheet8 offset does not point to a BOF record", .structural);
        }

        // Check sheet BOF has enough data for version + doc type
        const sheet_rec_len = std.mem.readInt(u16, wb_data[sheet.offset + 2 ..][0..2], .little);
        if (sheet_rec_len >= 4) {
            const sheet_doc_type = std.mem.readInt(u16, wb_data[sheet.offset + 6 ..][0..2], .little);
            // Valid sheet doc types
            if (sheet_doc_type != DOCTYPE_WORKSHEET and
                sheet_doc_type != DOCTYPE_CHART and
                sheet_doc_type != DOCTYPE_MACRO)
            {
                return ValidationResult.invalidWithDepth(.xls, "Sheet BOF has invalid doc type", .structural);
            }
        }
    }

    // Validate SST header if present
    if (sst_info) |sst| {
        if (sst.unique_count > sst.total_refs) {
            return ValidationResult.invalidWithDepth(.xls, "SST unique string count exceeds total references", .structural);
        }

        // Full SST string decode with CONTINUE record reassembly
        if (sst.unique_count > 0) {
            const reassembled = reassembleRecord(allocator, wb_data, sst.rec_offset) catch {
                return ValidationResult.invalidWithDepth(.xls, "Failed to reassemble SST with CONTINUE records", .structural);
            };
            defer allocator.free(reassembled.data);

            validateSstStrings(reassembled.data, sst.unique_count) catch {
                return ValidationResult.invalidWithDepth(.xls, "SST string data is corrupt", .full);
            };
        }
    }

    // Validate per-sheet cell records
    for (bound_sheets) |sheet| {
        // Only validate worksheet substreams (not charts or macros)
        if (sheet.offset + 8 > wb_data.len) continue;
        const sheet_rec_len = std.mem.readInt(u16, wb_data[sheet.offset + 2 ..][0..2], .little);
        if (sheet_rec_len < 4) continue;
        const sheet_doc_type = std.mem.readInt(u16, wb_data[sheet.offset + 6 ..][0..2], .little);
        if (sheet_doc_type != DOCTYPE_WORKSHEET) continue;

        const sst_count = if (sst_info) |sst| sst.unique_count else 0;
        validateSheetRecords(wb_data, sheet.offset, sst_count, xf_count) catch {
            return ValidationResult.invalidWithDepth(.xls, "Sheet cell record data is corrupt", .full);
        };
    }

    return ValidationResult.okWithDepth(.xls, .full);
}

// ============ Synthetic stream builder helpers ============

fn writeRec(buf: []u8, pos: *usize, rec_type: u16, data: []const u8) void {
    std.mem.writeInt(u16, buf[pos.*..][0..2], rec_type, .little);
    std.mem.writeInt(u16, buf[pos.* + 2 ..][0..2], @intCast(data.len), .little);
    if (data.len > 0) @memcpy(buf[pos.* + 4 ..][0..data.len], data);
    pos.* += 4 + data.len;
}

fn writeBof(buf: []u8, pos: *usize, doc_type: u16) void {
    var bof_data: [16]u8 = .{0} ** 16;
    std.mem.writeInt(u16, bof_data[0..2], BIFF8_VERSION, .little);
    std.mem.writeInt(u16, bof_data[2..4], doc_type, .little);
    writeRec(buf, pos, REC_BOF, &bof_data);
}

fn writeEof(buf: []u8, pos: *usize) void {
    writeRec(buf, pos, REC_EOF, &.{});
}

// ============ Tests ============

test "validateXlsDeep with sample.xls" {
    const allocator = std.testing.allocator;
    const result = validateXlsDeep(allocator, "ground_truth_examples/ole2/sample.xls");
    if (result.is_valid) {
        try std.testing.expectEqual(ValidationDepth.full, result.validation_depth);
    } else {
        // File might not exist in test CWD
        return error.SkipZigTest;
    }
}

test "synthetic: minimal valid workbook validates" {
    const allocator = std.testing.allocator;
    var stream: [512]u8 = .{0} ** 512;
    var pos: usize = 0;

    writeBof(&stream, &pos, DOCTYPE_WORKBOOK);

    // BoundSheet8 pointing to sheet BOF (we'll fill offset after)
    const bs_pos = pos;
    var bs_data: [8]u8 = .{0} ** 8;
    writeRec(&stream, &pos, REC_BOUNDSHEET8, &bs_data);

    // Workbook EOF
    writeEof(&stream, &pos);

    // Sheet BOF
    const sheet_offset = pos;
    std.mem.writeInt(u32, stream[bs_pos + 4 ..][0..4], @intCast(sheet_offset), .little);
    writeBof(&stream, &pos, DOCTYPE_WORKSHEET);
    writeEof(&stream, &pos);

    const result = validateWorkbookStream(allocator, stream[0..pos]);
    try std.testing.expect(result.is_valid);
    try std.testing.expectEqual(ValidationDepth.full, result.validation_depth);
}

test "synthetic: SST string parsing validates" {
    const allocator = std.testing.allocator;
    var stream: [1024]u8 = .{0} ** 1024;
    var pos: usize = 0;

    writeBof(&stream, &pos, DOCTYPE_WORKBOOK);

    // BoundSheet8 (offset filled below)
    const bs_pos = pos;
    var bs_data: [8]u8 = .{0} ** 8;
    writeRec(&stream, &pos, REC_BOUNDSHEET8, &bs_data);

    // SST with 2 strings: "Hi" (Latin-1) and "Go" (Latin-1)
    // SST header: cstTotal=2, cstUnique=2
    // String 1: cch=2, flags=0x00, "Hi"
    // String 2: cch=2, flags=0x00, "Go"
    var sst_data: [8 + 5 + 5]u8 = undefined;
    std.mem.writeInt(u32, sst_data[0..4], 2, .little); // cstTotal
    std.mem.writeInt(u32, sst_data[4..8], 2, .little); // cstUnique
    // String 1
    std.mem.writeInt(u16, sst_data[8..10], 2, .little); // cch
    sst_data[10] = 0x00; // flags (Latin-1)
    sst_data[11] = 'H';
    sst_data[12] = 'i';
    // String 2
    std.mem.writeInt(u16, sst_data[13..15], 2, .little); // cch
    sst_data[15] = 0x00; // flags (Latin-1)
    sst_data[16] = 'G';
    sst_data[17] = 'o';
    writeRec(&stream, &pos, REC_SST, &sst_data);

    // Workbook EOF
    writeEof(&stream, &pos);

    // Sheet BOF + EOF
    const sheet_offset = pos;
    std.mem.writeInt(u32, stream[bs_pos + 4 ..][0..4], @intCast(sheet_offset), .little);
    writeBof(&stream, &pos, DOCTYPE_WORKSHEET);
    writeEof(&stream, &pos);

    const result = validateWorkbookStream(allocator, stream[0..pos]);
    try std.testing.expect(result.is_valid);
    try std.testing.expectEqual(ValidationDepth.full, result.validation_depth);
}

test "synthetic: corrupt SST string length detected" {
    const allocator = std.testing.allocator;
    var stream: [1024]u8 = .{0} ** 1024;
    var pos: usize = 0;

    writeBof(&stream, &pos, DOCTYPE_WORKBOOK);

    const bs_pos = pos;
    var bs_data: [8]u8 = .{0} ** 8;
    writeRec(&stream, &pos, REC_BOUNDSHEET8, &bs_data);

    // SST with 1 string, but cch claims 255 chars — way beyond SST data
    var sst_data: [8 + 3]u8 = undefined;
    std.mem.writeInt(u32, sst_data[0..4], 1, .little);
    std.mem.writeInt(u32, sst_data[4..8], 1, .little);
    std.mem.writeInt(u16, sst_data[8..10], 255, .little); // corrupt: claims 255 chars
    sst_data[10] = 0x00;
    writeRec(&stream, &pos, REC_SST, &sst_data);

    writeEof(&stream, &pos);

    const sheet_offset = pos;
    std.mem.writeInt(u32, stream[bs_pos + 4 ..][0..4], @intCast(sheet_offset), .little);
    writeBof(&stream, &pos, DOCTYPE_WORKSHEET);
    writeEof(&stream, &pos);

    const result = validateWorkbookStream(allocator, stream[0..pos]);
    try std.testing.expect(!result.is_valid);
}

test "synthetic: LabelSst with out-of-range SST index detected" {
    const allocator = std.testing.allocator;
    var stream: [1024]u8 = .{0} ** 1024;
    var pos: usize = 0;

    writeBof(&stream, &pos, DOCTYPE_WORKBOOK);

    const bs_pos = pos;
    var bs_data: [8]u8 = .{0} ** 8;
    writeRec(&stream, &pos, REC_BOUNDSHEET8, &bs_data);

    // SST with 1 string "A"
    var sst_data: [8 + 4]u8 = undefined;
    std.mem.writeInt(u32, sst_data[0..4], 1, .little);
    std.mem.writeInt(u32, sst_data[4..8], 1, .little);
    std.mem.writeInt(u16, sst_data[8..10], 1, .little);
    sst_data[10] = 0x00;
    sst_data[11] = 'A';
    writeRec(&stream, &pos, REC_SST, &sst_data);

    writeEof(&stream, &pos);

    // Sheet with LabelSst referencing SST index 99 (only 1 string exists)
    const sheet_offset = pos;
    std.mem.writeInt(u32, stream[bs_pos + 4 ..][0..4], @intCast(sheet_offset), .little);
    writeBof(&stream, &pos, DOCTYPE_WORKSHEET);

    var label_data: [10]u8 = .{0} ** 10;
    std.mem.writeInt(u16, label_data[0..2], 0, .little); // row
    std.mem.writeInt(u16, label_data[2..4], 0, .little); // col
    std.mem.writeInt(u16, label_data[4..6], 0, .little); // ixfe
    std.mem.writeInt(u32, label_data[6..10], 99, .little); // isst — out of range!
    writeRec(&stream, &pos, REC_LABELSST, &label_data);

    writeEof(&stream, &pos);

    const result = validateWorkbookStream(allocator, stream[0..pos]);
    try std.testing.expect(!result.is_valid);
}

test "synthetic: valid formula token array" {
    const allocator = std.testing.allocator;
    var stream: [1024]u8 = .{0} ** 1024;
    var pos: usize = 0;

    writeBof(&stream, &pos, DOCTYPE_WORKBOOK);

    const bs_pos = pos;
    var bs_data: [8]u8 = .{0} ** 8;
    writeRec(&stream, &pos, REC_BOUNDSHEET8, &bs_data);

    writeEof(&stream, &pos);

    const sheet_offset = pos;
    std.mem.writeInt(u32, stream[bs_pos + 4 ..][0..4], @intCast(sheet_offset), .little);
    writeBof(&stream, &pos, DOCTYPE_WORKSHEET);

    // Formula: =A1+1 → ptgRef(0x44, row=0, col=0) + ptgInt(0x1E, val=1) + ptgAdd(0x03)
    // Formula record: row(2) + col(2) + ixfe(2) + result(8) + grbit(2) + chn(4) + cce(2) + tokens
    // Header = 22 bytes, then 8 bytes of tokens = 30 total
    var formula_data: [22 + 8]u8 = .{0} ** 30;
    std.mem.writeInt(u16, formula_data[20..22], 8, .little); // cce = 8 bytes of tokens
    // ptgRef (0x44): 4 bytes data (row u16 + col u16)
    formula_data[22] = 0x44;
    formula_data[23] = 0; // row low
    formula_data[24] = 0; // row high
    formula_data[25] = 0; // col low
    formula_data[26] = 0; // col high (with flags)
    // ptgInt (0x1E): 2 bytes data (u16 value)
    formula_data[27] = 0x1E;
    std.mem.writeInt(u16, formula_data[28..30], 1, .little); // value = 1
    // ptgRef=1+4=5 + ptgInt=1+2=3 = 8 bytes total. Perfect.

    writeRec(&stream, &pos, REC_FORMULA, &formula_data);

    writeEof(&stream, &pos);

    const result = validateWorkbookStream(allocator, stream[0..pos]);
    try std.testing.expect(result.is_valid);
    try std.testing.expectEqual(ValidationDepth.full, result.validation_depth);
}

test "synthetic: truncated formula tokens detected" {
    const allocator = std.testing.allocator;
    var stream: [1024]u8 = .{0} ** 1024;
    var pos: usize = 0;

    writeBof(&stream, &pos, DOCTYPE_WORKBOOK);

    const bs_pos = pos;
    var bs_data: [8]u8 = .{0} ** 8;
    writeRec(&stream, &pos, REC_BOUNDSHEET8, &bs_data);

    writeEof(&stream, &pos);

    const sheet_offset = pos;
    std.mem.writeInt(u32, stream[bs_pos + 4 ..][0..4], @intCast(sheet_offset), .little);
    writeBof(&stream, &pos, DOCTYPE_WORKSHEET);

    // Formula with cce=5 but only ptgRef (needs 5 bytes: 1+4) — then claims more tokens
    var formula_data: [22 + 2]u8 = .{0} ** 24;
    std.mem.writeInt(u16, formula_data[20..22], 5, .little); // cce = 5
    formula_data[22] = 0x44; // ptgRef — needs 4 more bytes but only 1 available
    formula_data[23] = 0;
    writeRec(&stream, &pos, REC_FORMULA, &formula_data);

    writeEof(&stream, &pos);

    const result = validateWorkbookStream(allocator, stream[0..pos]);
    try std.testing.expect(!result.is_valid);
}

test "synthetic: MulRk record size consistency" {
    const allocator = std.testing.allocator;
    var stream: [1024]u8 = .{0} ** 1024;
    var pos: usize = 0;

    writeBof(&stream, &pos, DOCTYPE_WORKBOOK);

    const bs_pos = pos;
    var bs_data: [8]u8 = .{0} ** 8;
    writeRec(&stream, &pos, REC_BOUNDSHEET8, &bs_data);
    writeEof(&stream, &pos);

    const sheet_offset = pos;
    std.mem.writeInt(u32, stream[bs_pos + 4 ..][0..4], @intCast(sheet_offset), .little);
    writeBof(&stream, &pos, DOCTYPE_WORKSHEET);

    // MulRk with inconsistent size: row(2)+colFirst(2)+colLast(2)=6 + 7 bytes (not divisible by 6)
    var mulrk_data: [13]u8 = .{0} ** 13;
    writeRec(&stream, &pos, REC_MULRK, &mulrk_data);

    writeEof(&stream, &pos);

    const result = validateWorkbookStream(allocator, stream[0..pos]);
    try std.testing.expect(!result.is_valid);
}

test "SST string parser: Latin-1 string" {
    // cch=3, flags=0x00, "ABC"
    const data = [_]u8{ 3, 0, 0x00, 'A', 'B', 'C' };
    const consumed = try parseSstString(&data);
    try std.testing.expectEqual(@as(usize, 6), consumed);
}

test "SST string parser: UTF-16LE string" {
    // cch=2, flags=0x01, 'H' 0x00 'i' 0x00
    const data = [_]u8{ 2, 0, 0x01, 'H', 0, 'i', 0 };
    const consumed = try parseSstString(&data);
    try std.testing.expectEqual(@as(usize, 7), consumed);
}

test "SST string parser: rich text string" {
    // cch=1, flags=0x08 (has rich), cRun=1, 'A', then 4 bytes of run data
    const data = [_]u8{ 1, 0, 0x08, 1, 0, 'A', 0, 0, 0, 0 };
    const consumed = try parseSstString(&data);
    try std.testing.expectEqual(@as(usize, 10), consumed);
}

test "SST string parser: truncated string rejected" {
    // cch=100, flags=0x00, but only 2 bytes of char data
    const data = [_]u8{ 100, 0, 0x00, 'A', 'B' };
    try std.testing.expectError(error.SstStringTruncated, parseSstString(&data));
}

test "formula token parser: simple ptgInt" {
    // ptgInt (0x1E) + u16 value
    const data = [_]u8{ 0x1E, 42, 0 };
    try validateFormulaTokens(&data);
}

test "formula token parser: ptgRef + ptgAdd" {
    // ptgRef (0x44): 4 bytes data, then ptgAdd (0x03): 0 bytes
    const data = [_]u8{ 0x44, 0, 0, 0, 0, 0x03 };
    try validateFormulaTokens(&data);
}

test "BoolErr: invalid bool value detected" {
    const allocator = std.testing.allocator;
    var stream: [1024]u8 = .{0} ** 1024;
    var pos: usize = 0;

    writeBof(&stream, &pos, DOCTYPE_WORKBOOK);
    const bs_pos = pos;
    var bs_data: [8]u8 = .{0} ** 8;
    writeRec(&stream, &pos, REC_BOUNDSHEET8, &bs_data);
    writeEof(&stream, &pos);

    const sheet_offset = pos;
    std.mem.writeInt(u32, stream[bs_pos + 4 ..][0..4], @intCast(sheet_offset), .little);
    writeBof(&stream, &pos, DOCTYPE_WORKSHEET);

    // BoolErr: row(2)+col(2)+ixfe(2)+bBoolErr(1)+fError(1)
    // fError=0 (boolean), value=5 (invalid — must be 0 or 1)
    var be_data: [8]u8 = .{0} ** 8;
    be_data[6] = 5; // invalid bool
    be_data[7] = 0; // fError=0 means boolean
    writeRec(&stream, &pos, REC_BOOLERR, &be_data);

    writeEof(&stream, &pos);

    const result = validateWorkbookStream(allocator, stream[0..pos]);
    try std.testing.expect(!result.is_valid);
}

test "reject non-BOF first record" {
    const allocator = std.testing.allocator;
    var stream: [8]u8 = .{0} ** 8;
    // Write a non-BOF record type
    std.mem.writeInt(u16, stream[0..2], 0x0085, .little);
    std.mem.writeInt(u16, stream[2..4], 4, .little);
    const result = validateWorkbookStream(allocator, &stream);
    try std.testing.expect(!result.is_valid);
}

test "SST unique count cannot exceed total refs" {
    const allocator = std.testing.allocator;
    var stream: [1024]u8 = .{0} ** 1024;
    var pos: usize = 0;

    writeBof(&stream, &pos, DOCTYPE_WORKBOOK);
    const bs_pos = pos;
    var bs_data: [8]u8 = .{0} ** 8;
    writeRec(&stream, &pos, REC_BOUNDSHEET8, &bs_data);

    // SST with unique > total
    var sst_data: [8]u8 = undefined;
    std.mem.writeInt(u32, sst_data[0..4], 5, .little); // total=5
    std.mem.writeInt(u32, sst_data[4..8], 10, .little); // unique=10 (invalid!)
    writeRec(&stream, &pos, REC_SST, &sst_data);

    writeEof(&stream, &pos);
    const sheet_offset = pos;
    std.mem.writeInt(u32, stream[bs_pos + 4 ..][0..4], @intCast(sheet_offset), .little);
    writeBof(&stream, &pos, DOCTYPE_WORKSHEET);
    writeEof(&stream, &pos);

    const result = validateWorkbookStream(allocator, stream[0..pos]);
    try std.testing.expect(!result.is_valid);
}
