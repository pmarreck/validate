//! Creative suite / Adobe / NLE format validators extracted from format_validation.zig.
//! Covers Premiere Pro (.prproj), InDesign (.indd), IDML (.idml), Final Cut Pro (.fcpxml),
//! DaVinci Resolve (.drp), Sketch (.sketch), Illustrator (.ai), PostScript/EPS (.eps),
//! and After Effects (.aep).

const std = @import("std");
const Allocator = std.mem.Allocator;
const file_source = @import("file_source.zig");
const FileSource = file_source.FileSource;
const format_validation = @import("format_validation.zig");
const ValidationResult = format_validation.ValidationResult;
const FileFormat = format_validation.FileFormat;
const ValidationDepth = format_validation.ValidationDepth;
const DoctypeStrippedResult = format_validation.DoctypeStrippedResult;
const stripDoctypeDeclaration = format_validation.stripDoctypeDeclaration;
const xml = @import("xml");
const errmsg = @import("error_messages.zig");
const pdf_validator = @import("pdf_validator.zig");
const archive_validators = @import("archive_validators.zig");

const FormatValidator = format_validation.FormatValidator;

// ============ Premiere Pro (.prproj) Validator ============

pub fn validatePrproj(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.prproj, .failed_to_seek, "to start");

    var header: [10]u8 = undefined;
    const bytes_read = file.read(&header) catch {
        return ValidationResult.invalidCode(.prproj, .failed_to_read, "PRPROJ header");
    };

    if (bytes_read < 5) {
        return ValidationResult.invalidCode(.prproj, .file_too_small, "PRPROJ format");
    }

    // Check for gzip magic (0x1f 0x8b) - modern PRPROJ format (CS6+/CC7+)
    if (header[0] == 0x1f and header[1] == 0x8b) {
        // Check compression method (should be 8 = deflate)
        if (header[2] != 8) {
            return ValidationResult.invalidCode(.prproj, .invalid_value, "compression method");
        }
        // Valid gzip-compressed PRPROJ
        // The gzip container provides CRC32 coverage for all data
        return ValidationResult.ok(.prproj);
    }

    // Check for XML declaration - legacy PRPROJ format (pre-CS6)
    if (bytes_read >= 5 and std.mem.eql(u8, header[0..5], "<?xml")) {
        // Uncompressed XML format - structurally valid
        return ValidationResult.ok(.prproj);
    }

    // Check for BOM + XML declaration
    if (bytes_read >= 8 and header[0] == 0xEF and header[1] == 0xBB and header[2] == 0xBF) {
        // UTF-8 BOM followed by XML
        if (std.mem.eql(u8, header[3..8], "<?xml")) {
            return ValidationResult.ok(.prproj);
        }
    }

    return ValidationResult.invalidCodeMsg(.prproj, .invalid_signature_not, "PRPROJ", errmsg.invalidSignatureNot("PRPROJ", "gzip or XML"));
}

pub fn validatePrprojDeep(allocator: Allocator, source: *FileSource) ValidationResult {
    const file = source;

    // Read header to determine format
    var header: [10]u8 = undefined;
    const header_read = file.read(&header) catch {
        return ValidationResult.invalidCode(.prproj, .failed_to_read, "header");
    };

    if (header_read < 5) {
        return ValidationResult.invalid(.prproj, "File too small");
    }

    // Reset file position
    file.seekTo(0) catch return ValidationResult.invalid(.prproj, "Failed to seek");

    // Check if gzip-compressed
    if (header[0] == 0x1f and header[1] == 0x8b) {
        // Use gzip deep validation for CRC verification
        // This validates every byte through decompression and CRC32 check
        const gzip_result = archive_validators.validateGzipDeep(allocator, file);
        if (!gzip_result.is_valid) {
            // Remap format to prproj but preserve error
            var result = gzip_result;
            result.format = .prproj;
            return result;
        }
        // Gzip CRC verified - all bytes are valid
        return ValidationResult.okWithDepth(.prproj, .full);
    }

    // Legacy XML format - parse and validate XML structure
    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCode(.prproj, .failed_to_get, "file size");
    };

    if (file_size > 500 * 1024 * 1024) { // 500MB limit for XML files
        return ValidationResult.invalid(.prproj, "PRPROJ XML too large");
    }

    var heap1: ?[]u8 = null;
    defer if (heap1) |buf| allocator.free(buf);
    const xml_data: []const u8 = if (file.getMappedSlice()) |m| m else blk: {
        const buf = allocator.alloc(u8, @intCast(file_size)) catch return ValidationResult.invalidCode(.prproj, .failed_to_allocate, "memory for XML");
        heap1 = buf;
        const n = file.readAll(buf) catch return ValidationResult.invalidCode(.prproj, .failed_to_read, "XML data");
        break :blk buf[0..n];
    };
    const xml_read = xml_data.len;
    if (xml_read != file_size) {
        return ValidationResult.invalidCode(.prproj, .incomplete, "XML read");
    }

    // Validate XML structure using the xml module
    // Strip DOCTYPE declarations to avoid DTD validation issues
    const preprocessed = stripDoctypeDeclaration(allocator, xml_data);
    defer if (preprocessed.allocated) allocator.free(preprocessed.data);

    // Parse the XML to validate structure using zig-xml's spec-compliant parser
    var static_reader: xml.Reader.Static = .init(allocator, preprocessed.data, .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    // Iterate through all XML elements to validate structure
    var element_count: usize = 0;
    while (true) {
        const node = reader.read() catch {
            return ValidationResult.invalidCode(.prproj, .invalid_value, "XML structure");
        };
        if (node == .eof) break;
        element_count += 1;
    }

    if (element_count == 0) {
        return ValidationResult.invalidCode(.prproj, .empty, "XML document");
    }

    // Successfully parsed - validate all bytes via XML parse
    // Check for Premiere-specific content
    // Look for Project or PremiereData tags that indicate Premiere XML
    if (std.mem.indexOf(u8, xml_data, "<Project") != null or
        std.mem.indexOf(u8, xml_data, "<PremiereData") != null or
        std.mem.indexOf(u8, xml_data, "ObjectType=\"Sequence\"") != null)
    {
        return ValidationResult.okWithDepth(.prproj, .full);
    }

    // Valid XML but might not be Premiere-specific - still accept with structural depth
    return ValidationResult.structuralOnly(.prproj);
}

pub fn validatePrprojFromBuffer(data: []const u8) ValidationResult {
    if (data.len < 5) {
        return ValidationResult.invalidCode(.prproj, .buffer_too_small, "PRPROJ");
    }

    // Check for gzip magic
    if (data[0] == 0x1f and data[1] == 0x8b) {
        if (data[2] != 8) {
            return ValidationResult.invalidCode(.prproj, .invalid_value, "compression method");
        }
        return ValidationResult.ok(.prproj);
    }

    // Check for XML declaration
    if (data.len >= 5 and std.mem.eql(u8, data[0..5], "<?xml")) {
        return ValidationResult.ok(.prproj);
    }

    // Check for BOM + XML
    if (data.len >= 8 and data[0] == 0xEF and data[1] == 0xBB and data[2] == 0xBF) {
        if (std.mem.eql(u8, data[3..8], "<?xml")) {
            return ValidationResult.ok(.prproj);
        }
    }

    return ValidationResult.invalidCode(.prproj, .invalid_signature, "PRPROJ");
}

// ============ InDesign (.indd) Validator ============

/// Validate an InDesign (.indd) file.
/// InDesign files are structured as a stream of 4096-byte pages. Pages come in
/// redundant pairs (master + duplicate), so the file size must be a multiple of
/// 4096 and at least 8192 bytes. Both the primary master page (offset 0) and its
/// duplicate (offset 4096) must carry the 16-byte InDesign magic signature.
pub fn validateIndd(file: *FileSource) ValidationResult {
    // ---- Size checks ----
    const file_size = file.getEndPos() catch
        return ValidationResult.invalidCode(.indd, .failed_to_read, "INDD file size");

    if (file_size < 8192) {
        return ValidationResult.invalidCode(.indd, .file_too_small, "INDD format (need at least two 4096-byte master pages)");
    }

    if (file_size % 4096 != 0) {
        return ValidationResult.invalidCode(.indd, .invalid_value, "INDD file size is not a multiple of 4096");
    }

    // Full 16-byte InDesign magic signature
    const indd_magic = "\x06\x06\xED\xF5\xD8\x1D\x46\xE5\xBD\x31\xEF\xE7\xFE\x74\xB7\x1D";

    // ---- Primary master page (offset 0) ----
    file.seekTo(0) catch return ValidationResult.invalidCode(.indd, .failed_to_seek, "to start");

    var page0: [32]u8 = undefined;
    const read0 = file.read(&page0) catch
        return ValidationResult.invalidCode(.indd, .failed_to_read, "INDD primary master page");

    if (read0 < 32) {
        return ValidationResult.invalidCode(.indd, .file_too_small, "INDD primary master page header");
    }

    if (!std.mem.eql(u8, page0[0..16], indd_magic)) {
        return ValidationResult.invalidCode(.indd, .invalid_magic, "INDD primary master page");
    }

    // Sequence number (bytes 28-31, u32 LE) for the first master page should be 0
    const seq0 = std.mem.readInt(u32, page0[28..32], .little);
    if (seq0 != 0) {
        return ValidationResult.invalidCode(.indd, .invalid_value, "INDD primary master page sequence number (expected 0)");
    }

    // ---- Duplicate master page (offset 4096) ----
    file.seekTo(4096) catch return ValidationResult.invalidCode(.indd, .failed_to_seek, "to duplicate master page");

    var page1: [32]u8 = undefined;
    const read1 = file.read(&page1) catch
        return ValidationResult.invalidCode(.indd, .failed_to_read, "INDD duplicate master page");

    if (read1 < 32) {
        return ValidationResult.invalidCode(.indd, .file_too_small, "INDD duplicate master page header");
    }

    if (!std.mem.eql(u8, page1[0..16], indd_magic)) {
        return ValidationResult.invalidCode(.indd, .invalid_magic, "INDD duplicate master page");
    }

    // Sequence number in the duplicate must match the primary
    const seq1 = std.mem.readInt(u32, page1[28..32], .little);
    if (seq1 != seq0) {
        return ValidationResult.invalidCode(.indd, .invalid_value, "INDD master page sequence number mismatch between primary and duplicate");
    }

    return ValidationResult.okWithDepth(.indd, .structural);
}

pub fn validateInddDeep(allocator: Allocator, source: *FileSource) ValidationResult {
    _ = allocator;
    const file = source;

    // Structural validation is all we can do for proprietary format
    const result = validateIndd(file);
    if (!result.is_valid) return result;

    // Return structural depth since we can't validate all bytes without Adobe's spec
    return ValidationResult.structuralOnly(.indd);
}

pub fn validateInddFromBuffer(data: []const u8) ValidationResult {
    if (data.len < 16) {
        return ValidationResult.invalidCode(.indd, .buffer_too_small, "INDD");
    }

    // Check 16-byte InDesign magic
    const indd_magic = [16]u8{ 0x06, 0x06, 0xED, 0xF5, 0xD8, 0x1D, 0x46, 0xE5, 0xBD, 0x31, 0xEF, 0xE7, 0xFE, 0x74, 0xB7, 0x1D };
    if (!std.mem.eql(u8, data[0..16], &indd_magic)) {
        return ValidationResult.invalidCode(.indd, .invalid_magic, "INDD");
    }

    return ValidationResult.structuralOnly(.indd);
}
// ============ IDML Validator ============

pub fn validateIdml(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.idml, .failed_to_seek, "to start");

    var header: [4]u8 = undefined;
    const bytes_read = file.read(&header) catch {
        return ValidationResult.invalidCode(.idml, .failed_to_read, "IDML header");
    };

    if (bytes_read < 4) {
        return ValidationResult.invalidCode(.idml, .file_too_small, "IDML format");
    }

    // Check for ZIP magic (PK)
    if (header[0] != 'P' or header[1] != 'K' or header[2] != 0x03 or header[3] != 0x04) {
        return ValidationResult.invalidCodeMsg(.idml, .invalid_signature_not, "IDML", errmsg.invalidSignatureNot("IDML", "ZIP"));
    }

    // IDML is a ZIP container - only checked magic bytes, not internal structure
    return ValidationResult.okWithDepth(.idml, .structural);
}

// ============ Final Cut Pro (.fcpxml) Validator ============

/// Helper: check if content starts with XML declaration or a specific element
fn startsWithXmlOrElement(content: []const u8, comptime element_name: []const u8) bool {
    // Skip whitespace
    var i: usize = 0;
    while (i < content.len and (content[i] == ' ' or content[i] == '\t' or content[i] == '\n' or content[i] == '\r')) : (i += 1) {}

    if (i >= content.len) return false;

    // Check for XML declaration
    if (content.len >= i + 5 and std.mem.eql(u8, content[i .. i + 5], "<?xml")) {
        // Find the element after XML declaration/DTD
        return containsElement(content[i..], element_name);
    }

    // Check for direct element
    if (content[i] == '<') {
        return containsElement(content[i..], element_name);
    }

    return false;
}

fn containsElement(content: []const u8, comptime element_name: []const u8) bool {
    // Use comptime string concatenation - both parts are comptime-known
    const search_pattern = "<" ++ element_name;
    return std.mem.indexOf(u8, content, search_pattern) != null;
}

pub fn validateFcpxml(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.fcpxml, .failed_to_seek, "to start");

    // Read enough for XML declaration and root element detection
    var header: [512]u8 = undefined;
    const bytes_read = file.read(&header) catch {
        return ValidationResult.invalidCode(.fcpxml, .failed_to_read, "FCPXML header");
    };

    if (bytes_read < 10) {
        return ValidationResult.invalidCode(.fcpxml, .file_too_small, "FCPXML format");
    }

    // Skip BOM if present
    var start: usize = 0;
    if (bytes_read >= 3 and header[0] == 0xEF and header[1] == 0xBB and header[2] == 0xBF) {
        start = 3;
    }

    // Check for XML declaration or fcpxml element
    const content = header[start..bytes_read];

    // Should start with XML declaration or directly with fcpxml element
    if (!startsWithXmlOrElement(content, "fcpxml")) {
        return ValidationResult.invalidCode(.fcpxml, .invalid_value, "FCPXML: missing fcpxml element");
    }

    // Valid FCPXML structure
    return ValidationResult.ok(.fcpxml);
}

pub fn validateFcpxmlDeep(allocator: Allocator, source: *FileSource) ValidationResult {
    const file = source;

    // First do structural validation
    const structural_result = validateFcpxml(file);
    if (!structural_result.is_valid) return structural_result;

    // For deep validation, parse full XML
    file.seekTo(0) catch return ValidationResult.invalid(.fcpxml, "Failed to seek");

    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCode(.fcpxml, .failed_to_get, "file size");
    };

    if (file_size > 500 * 1024 * 1024) { // 500MB limit
        return ValidationResult.invalid(.fcpxml, "FCPXML too large");
    }

    var heap2: ?[]u8 = null;
    defer if (heap2) |buf| allocator.free(buf);
    const xml_data: []const u8 = if (file.getMappedSlice()) |m| m else blk: {
        const buf = allocator.alloc(u8, @intCast(file_size)) catch return ValidationResult.invalidCode(.fcpxml, .failed_to_allocate, "memory");
        heap2 = buf;
        const n = file.readAll(buf) catch return ValidationResult.invalidCode(.fcpxml, .failed_to_read, "XML data");
        break :blk buf[0..n];
    };
    const xml_read = xml_data.len;
    if (xml_read != file_size) {
        return ValidationResult.invalidCode(.fcpxml, .incomplete, "read");
    }

    // Use XML parser to validate structure
    const preprocessed = stripDoctypeDeclaration(allocator, xml_data);
    defer if (preprocessed.allocated) allocator.free(preprocessed.data);

    var static_reader: xml.Reader.Static = .init(allocator, preprocessed.data, .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    var element_count: usize = 0;
    var found_fcpxml: bool = false;
    while (true) {
        const node = reader.read() catch {
            return ValidationResult.invalidCode(.fcpxml, .invalid_value, "XML structure");
        };
        if (node == .eof) break;
        if (node == .element_start) {
            if (element_count == 0) {
                // Check root element
                const name = reader.elementName();
                if (std.mem.eql(u8, name, "fcpxml")) {
                    found_fcpxml = true;
                }
            }
        }
        element_count += 1;
    }

    if (!found_fcpxml) {
        return ValidationResult.okWithDepthAndWarning(.fcpxml, .structural, errmsg.missing("fcpxml root element"));
    }

    return ValidationResult.okWithDepth(.fcpxml, .full);
}

pub fn validateFcpxmlFromBuffer(data: []const u8) ValidationResult {
    if (data.len < 10) {
        return ValidationResult.invalidCode(.fcpxml, .buffer_too_small, "FCPXML");
    }

    // Skip BOM if present
    var start: usize = 0;
    if (data.len >= 3 and data[0] == 0xEF and data[1] == 0xBB and data[2] == 0xBF) {
        start = 3;
    }

    const content = data[start..];

    // Should contain XML declaration or fcpxml element
    if (!startsWithXmlOrElement(content, "fcpxml")) {
        return ValidationResult.invalidCode(.fcpxml, .invalid_value, "FCPXML: missing fcpxml element");
    }

    return ValidationResult.ok(.fcpxml);
}

// ============ DaVinci Resolve (.drp) Validator ============

pub fn validateDrp(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.drp, .failed_to_seek, "to start");

    var header: [4]u8 = undefined;
    const bytes_read = file.read(&header) catch {
        return ValidationResult.invalidCode(.drp, .failed_to_read, "DRP header");
    };

    if (bytes_read < 4) {
        return ValidationResult.invalidCode(.drp, .file_too_small, "DRP format");
    }

    // Check for ZIP magic (PK\x03\x04)
    if (header[0] != 'P' or header[1] != 'K' or header[2] != 0x03 or header[3] != 0x04) {
        return ValidationResult.invalidCodeMsg(.drp, .invalid_signature_not, "DRP", errmsg.invalidSignatureNot("DRP", "ZIP"));
    }

    // DRP is a ZIP container - basic structural validation passes
    // Deep validation will check for project.xml and CRC integrity
    return ValidationResult.ok(.drp);
}

pub fn validateDrpDeep(allocator: Allocator, source: *FileSource) ValidationResult {
    // Use ZIP deep validation for the container integrity
    source.seekTo(0) catch return ValidationResult.invalidCode(.drp, .failed_to_seek, "to start");
    const zip_result = archive_validators.validateZipDeep(allocator, source);
    if (!zip_result.is_valid) {
        return ValidationResult.invalid(.drp, zip_result.error_message orelse "Invalid ZIP structure");
    }

    // Now check for project.xml in the archive
    source.seekTo(0) catch return ValidationResult.invalidCode(.drp, .failed_to_seek, "to start");
    const file = source;

    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCode(.drp, .failed_to_get, "file size");
    };

    if (file_size > 500 * 1024 * 1024) {
        // For very large files, trust the ZIP validation (container-level only)
        return ValidationResult.okWithDepth(.drp, .structural);
    }

    // Read the file to find project.xml in the central directory
    var heap3: ?[]u8 = null;
    defer if (heap3) |buf| allocator.free(buf);
    const data: []const u8 = if (file.getMappedSlice()) |m| m else blk: {
        const buf = allocator.alloc(u8, @intCast(file_size)) catch return ValidationResult.invalidCode(.drp, .failed_to_allocate, "memory");
        heap3 = buf;
        const n = file.readAll(buf) catch return ValidationResult.invalidCode(.drp, .failed_to_read, "file");
        break :blk buf[0..n];
    };
    const read_len = data.len;

    if (read_len != file_size) {
        return ValidationResult.invalidCode(.drp, .incomplete, "read");
    }

    // Look for project.xml in the file names
    // Simple check: search for "project.xml" in the data (ZIP structure + expected file presence)
    if (std.mem.indexOf(u8, data, "project.xml") != null) {
        return ValidationResult.okWithDepth(.drp, .structural);
    }

    return ValidationResult.okWithDepthAndWarning(.drp, .structural, errmsg.missing("project.xml in DRP archive"));
}

pub fn validateDrpFromBuffer(data: []const u8) ValidationResult {
    if (data.len < 4) {
        return ValidationResult.invalidCode(.drp, .buffer_too_small, "DRP");
    }

    // Check for ZIP magic (PK\x03\x04)
    if (data[0] != 'P' or data[1] != 'K' or data[2] != 0x03 or data[3] != 0x04) {
        return ValidationResult.invalidCodeMsg(.drp, .invalid_signature_not, "DRP", errmsg.invalidSignatureNot("DRP", "ZIP"));
    }

    return ValidationResult.ok(.drp);
}

// ============ Sketch (.sketch) Validator ============

pub fn validateSketch(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.sketch, .failed_to_seek, "to start");

    var header: [4]u8 = undefined;
    const bytes_read = file.read(&header) catch {
        return ValidationResult.invalidCode(.sketch, .failed_to_read, "Sketch header");
    };

    if (bytes_read < 4) {
        return ValidationResult.invalidCode(.sketch, .file_too_small, "Sketch format");
    }

    // Check for ZIP magic (PK\x03\x04)
    if (header[0] != 'P' or header[1] != 'K' or header[2] != 0x03 or header[3] != 0x04) {
        return ValidationResult.invalidCodeMsg(.sketch, .invalid_signature_not, "Sketch", errmsg.invalidSignatureNot("Sketch", "ZIP"));
    }

    // Sketch is a ZIP container - basic structural validation passes
    // Deep validation will check for document.json/meta.json and CRC integrity
    return ValidationResult.ok(.sketch);
}

pub fn validateSketchDeep(allocator: Allocator, source: *FileSource) ValidationResult {
    // Use ZIP deep validation for the container integrity
    source.seekTo(0) catch return ValidationResult.invalidCode(.sketch, .failed_to_seek, "to start");
    const zip_result = archive_validators.validateZipDeep(allocator, source);
    if (!zip_result.is_valid) {
        return ValidationResult.invalid(.sketch, zip_result.error_message orelse "Invalid ZIP structure");
    }

    // Now check for required Sketch files in the archive
    source.seekTo(0) catch return ValidationResult.invalidCode(.sketch, .failed_to_seek, "to start");
    const file = source;

    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCode(.sketch, .failed_to_get, "file size");
    };

    if (file_size > 500 * 1024 * 1024) {
        // For very large files, trust the ZIP validation
        return ValidationResult.okWithDepth(.sketch, .full);
    }

    // Read the file to find document.json and meta.json in the central directory
    var heap4: ?[]u8 = null;
    defer if (heap4) |buf| allocator.free(buf);
    const data: []const u8 = if (file.getMappedSlice()) |m| m else blk: {
        const buf = allocator.alloc(u8, @intCast(file_size)) catch return ValidationResult.invalidCode(.sketch, .failed_to_allocate, "memory");
        heap4 = buf;
        const n = file.readAll(buf) catch return ValidationResult.invalidCode(.sketch, .failed_to_read, "file");
        break :blk buf[0..n];
    };
    const read_len = data.len;

    if (read_len != file_size) {
        return ValidationResult.invalidCode(.sketch, .incomplete, "read");
    }

    // Look for required Sketch files
    const has_document = std.mem.indexOf(u8, data, "document.json") != null;
    const has_meta = std.mem.indexOf(u8, data, "meta.json") != null;

    if (!has_document) {
        return ValidationResult.okWithDepthAndWarning(.sketch, .structural, errmsg.missing("document.json in Sketch archive"));
    }
    if (!has_meta) {
        return ValidationResult.okWithDepthAndWarning(.sketch, .structural, errmsg.missing("meta.json in Sketch archive"));
    }

    return ValidationResult.okWithDepth(.sketch, .full);
}

pub fn validateSketchFromBuffer(data: []const u8) ValidationResult {
    if (data.len < 4) {
        return ValidationResult.invalidCode(.sketch, .buffer_too_small, "Sketch");
    }

    // Check for ZIP magic (PK\x03\x04)
    if (data[0] != 'P' or data[1] != 'K' or data[2] != 0x03 or data[3] != 0x04) {
        return ValidationResult.invalidCodeMsg(.sketch, .invalid_signature_not, "Sketch", errmsg.invalidSignatureNot("Sketch", "ZIP"));
    }

    return ValidationResult.ok(.sketch);
}

// ============ Illustrator (.ai) Validator ============

pub fn validateAi(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.ai, .failed_to_seek, "to start");

    var header: [16]u8 = undefined;
    const bytes_read = file.read(&header) catch return ValidationResult.invalidCode(.ai, .failed_to_read, "AI header");
    if (bytes_read < 5) {
        return ValidationResult.invalidCode(.ai, .file_too_small, "AI header");
    }

    // Check if it's PDF-based (modern AI files)
    if (std.mem.startsWith(u8, header[0..bytes_read], "%PDF-")) {
        // Delegate to PDF buffer validator for structural check
        const pdf_result = pdf_validator.validatePdfFromBuffer(header[0..bytes_read]);
        // Return AI format but with PDF validation result
        return ValidationResult{
            .format = .ai,
            .is_valid = pdf_result.is_valid,
            .error_message = pdf_result.error_message,
            .validation_depth = pdf_result.validation_depth,
            .malformations = pdf_result.malformations,
        };
    }

    // Check if it's PostScript-based (legacy AI files)
    if (std.mem.startsWith(u8, header[0..bytes_read], "%!PS-Adobe") or
        std.mem.startsWith(u8, header[0..bytes_read], "%!PS-"))
    {
        // Reset file position before validation
        file.seekTo(0) catch return ValidationResult.invalidCode(.ai, .failed_to_seek, "to start");
        // Do basic PostScript/EPS structural validation
        return validatePostScript(file, .ai);
    }

    return ValidationResult.invalidCodeMsg(.ai, .invalid_signature_expected, "AI", errmsg.invalidSignatureExpected("AI", "%PDF- or %!PS-Adobe"));
}

pub fn validateAiDeep(allocator: Allocator, source: *FileSource) ValidationResult {
    const file = source;

    var header: [16]u8 = undefined;
    const bytes_read = file.read(&header) catch return ValidationResult.invalidCode(.ai, .failed_to_read, "header");

    // If PDF-based, use deep PDF validation
    if (std.mem.startsWith(u8, header[0..bytes_read], "%PDF-")) {
        source.seekTo(0) catch {};
        const pdf_result = pdf_validator.validatePdfDeep(allocator, source);
        return ValidationResult{
            .format = .ai,
            .is_valid = pdf_result.is_valid,
            .error_message = pdf_result.error_message,
            .validation_depth = pdf_result.validation_depth,
            .malformations = pdf_result.malformations,
        };
    }

    // For PostScript-based AI, structural validation is the best we can do
    file.seekTo(0) catch return ValidationResult.invalid(.ai, "Failed to seek");
    const basic_result = validateAi(file);
    return ValidationResult{
        .format = .ai,
        .is_valid = basic_result.is_valid,
        .error_message = basic_result.error_message,
        .validation_depth = .structural, // PostScript doesn't have checksums
        .malformations = basic_result.malformations,
    };
}

pub fn validateAiFromBuffer(data: []const u8) ValidationResult {
    if (data.len < 5) {
        return ValidationResult.invalid(.ai, "Buffer too small");
    }

    // Check if PDF-based
    if (std.mem.startsWith(u8, data, "%PDF-")) {
        const pdf_result = pdf_validator.validatePdfFromBuffer(data);
        return ValidationResult{
            .format = .ai,
            .is_valid = pdf_result.is_valid,
            .error_message = pdf_result.error_message,
            .validation_depth = pdf_result.validation_depth,
            .malformations = pdf_result.malformations,
        };
    }

    // Check if PostScript-based
    if (std.mem.startsWith(u8, data, "%!PS-Adobe") or std.mem.startsWith(u8, data, "%!PS-")) {
        // Note: Missing %%EOF is common in PostScript files, not flagged as malformation
        return ValidationResult.ok(.ai);
    }

    return ValidationResult.invalidCode(.ai, .invalid_signature, "AI");
}

// ============ EPS / PostScript Validator ============

pub fn validateEps(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.eps, .failed_to_seek, "to start");

    var header: [16]u8 = undefined;
    const bytes_read = file.read(&header) catch return ValidationResult.invalidCode(.eps, .failed_to_read, "EPS header");
    if (bytes_read < 4) {
        return ValidationResult.invalidCode(.eps, .file_too_small, "EPS header");
    }

    // EPS can start with binary header (0xC5D0D3C6) for DOS EPS or %!PS-Adobe for standard EPS
    const dos_eps_sig = [_]u8{ 0xC5, 0xD0, 0xD3, 0xC6 };
    if (std.mem.startsWith(u8, header[0..bytes_read], &dos_eps_sig)) {
        // DOS EPS with binary header - parse header to find PS data offset
        if (bytes_read < 12) {
            return ValidationResult.invalidCode(.eps, .truncated, "DOS EPS header");
        }
        // DOS EPS header: 4-byte magic, 4-byte PS offset, 4-byte PS length
        const ps_offset = std.mem.readInt(u32, header[4..8], .little);
        file.seekTo(ps_offset) catch return ValidationResult.invalidCode(.eps, .failed_to_seek, "to PS data");
        return validatePostScript(file, .eps);
    }

    // Standard EPS with %!PS-Adobe header
    if (std.mem.startsWith(u8, header[0..bytes_read], "%!PS-Adobe") or
        std.mem.startsWith(u8, header[0..bytes_read], "%!PS-"))
    {
        file.seekTo(0) catch return ValidationResult.invalidCode(.eps, .failed_to_seek, "to start");
        return validatePostScript(file, .eps);
    }

    return ValidationResult.invalidCode(.eps, .invalid_signature, "EPS");
}

pub fn validateEpsDeep(allocator: Allocator, source: *FileSource) ValidationResult {
    _ = allocator;
    const file = source;

    // EPS is PostScript-based, structural validation is the best we can do
    const basic_result = validateEps(file);
    return ValidationResult{
        .format = .eps,
        .is_valid = basic_result.is_valid,
        .error_message = basic_result.error_message,
        .validation_depth = .structural, // PostScript doesn't have checksums
        .malformations = basic_result.malformations,
    };
}

pub fn validateEpsFromBuffer(data: []const u8) ValidationResult {
    if (data.len < 4) {
        return ValidationResult.invalid(.eps, "Buffer too small");
    }

    // Check for DOS EPS binary header
    const dos_eps_sig = [_]u8{ 0xC5, 0xD0, 0xD3, 0xC6 };
    if (std.mem.startsWith(u8, data, &dos_eps_sig)) {
        if (data.len < 12) {
            return ValidationResult.invalidCode(.eps, .truncated, "DOS EPS header");
        }
        // For buffer validation, just verify the header structure
        return ValidationResult.ok(.eps);
    }

    // Check for standard PostScript header
    if (std.mem.startsWith(u8, data, "%!PS-Adobe") or std.mem.startsWith(u8, data, "%!PS-")) {
        // Look for %%BoundingBox (required for EPS)
        if (std.mem.indexOf(u8, data[0..@min(2048, data.len)], "%%BoundingBox")) |_| {
            // Note: Missing %%EOF is common in PostScript files, not flagged as malformation
            return ValidationResult.ok(.eps);
        }
        return ValidationResult.invalid(.eps, "EPS missing %%BoundingBox");
    }

    return ValidationResult.invalidCode(.eps, .invalid_signature, "EPS");
}

/// Shared PostScript structural validator (used by both AI and EPS)
pub fn validatePostScript(file: *FileSource, format: FileFormat) ValidationResult {
    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(format, .failed_to_get, "file size");
    if (file_size < 20) {
        return ValidationResult.invalidCode(format, .file_too_small, "valid PostScript");
    }

    // Read first chunk to verify header
    var header_buf: [256]u8 = undefined;
    const header_read = file.read(&header_buf) catch return ValidationResult.invalidCode(format, .failed_to_read, "header");
    if (header_read < 10) {
        return ValidationResult.invalid(format, "File too small");
    }

    // Verify %!PS-Adobe or %!PS header
    if (!std.mem.startsWith(u8, header_buf[0..header_read], "%!PS-Adobe") and
        !std.mem.startsWith(u8, header_buf[0..header_read], "%!PS"))
    {
        return ValidationResult.invalidCode(format, .invalid_value, "PostScript header");
    }

    // Look for DSC structure comments in header
    var has_bounding_box = false;
    var has_eof = false;

    // Check for %%BoundingBox in header (required for EPS)
    if (std.mem.indexOf(u8, header_buf[0..header_read], "%%BoundingBox")) |_| {
        has_bounding_box = true;
    }

    // Check trailer for %%EOF
    const trailer_size: u64 = @min(1024, file_size);
    const trailer_start = file_size - trailer_size;
    file.seekTo(trailer_start) catch return ValidationResult.invalidCode(format, .failed_to_seek, "to trailer");

    var trailer_buf: [1024]u8 = undefined;
    const trailer_read = file.read(&trailer_buf) catch return ValidationResult.invalidCode(format, .failed_to_read, "trailer");
    if (trailer_read > 0) {
        // Look for %%EOF marker (may have trailing whitespace)
        if (std.mem.indexOf(u8, trailer_buf[0..trailer_read], "%%EOF")) |_| {
            has_eof = true;
        }
    }

    // For EPS, BoundingBox is required; for general PS, it's optional
    // %%EOF is recommended but not strictly required

    if (!has_eof) {
        // Warning but still valid - some PS files omit %%EOF
        // Note: Missing %%EOF is common in PostScript files, not flagged as malformation
        return ValidationResult.ok(format);
    }

    if (format == .eps and !has_bounding_box) {
        // BoundingBox is required for EPS per EPSF spec
        return ValidationResult.invalid(format, "EPS missing required %%BoundingBox");
    }

    return ValidationResult.ok(format);
}

// ============ After Effects (.aep) Validator ============

pub fn validateAep(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.aep, .failed_to_seek, "to start");

    var header: [12]u8 = undefined;
    const bytes_read = file.read(&header) catch return ValidationResult.invalidCode(.aep, .failed_to_read, "AEP header");
    if (bytes_read < 12) {
        return ValidationResult.invalidCode(.aep, .file_too_small, "AEP header");
    }

    // Verify RIFX signature (big-endian RIFF)
    if (!std.mem.eql(u8, header[0..4], "RIFX")) {
        return ValidationResult.invalidCodeMsg(.aep, .invalid_signature_expected, "AEP", errmsg.invalidSignatureExpected("AEP", "RIFX"));
    }

    // Verify "Egg!" format marker
    if (!std.mem.eql(u8, header[8..12], "Egg!")) {
        return ValidationResult.invalidCode(.aep, .invalid_value, "AEP format marker (expected Egg!)");
    }

    // Read declared file size (big-endian, at offset 4)
    const declared_size = std.mem.readInt(u32, header[4..8], .big);

    // Get actual file size
    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.aep, .failed_to_get, "file size");

    // RIFX size is file size minus 8 (excludes RIFX and size field itself)
    const expected_size = @as(u64, declared_size) + 8;
    if (file_size < expected_size) {
        return ValidationResult.invalid(.aep, "File truncated (size mismatch)");
    }

    // For full validation, we'd parse the RIFX chunks
    // AEP uses various chunk types like 'LIST', 'tdsn', 'fnam', etc.
    // Basic structural validation: verify we can read chunk headers

    var pos: u64 = 12; // After RIFX header
    var chunks_found: u32 = 0;
    const max_chunks: u32 = 10000; // Sanity limit

    while (pos + 8 <= file_size and chunks_found < max_chunks) {
        file.seekTo(pos) catch break;

        var chunk_header: [8]u8 = undefined;
        const chunk_read = file.read(&chunk_header) catch break;
        if (chunk_read < 8) break;

        // Chunk type (4 bytes) + chunk size (4 bytes, big-endian for RIFX)
        const chunk_size = std.mem.readInt(u32, chunk_header[4..8], .big);

        // Validate chunk type has reasonable ASCII characters
        var valid_type = true;
        for (chunk_header[0..4]) |c| {
            if (c < 0x20 or c > 0x7E) {
                valid_type = false;
                break;
            }
        }

        if (!valid_type) {
            // Could be end of valid data or corruption
            break;
        }

        // Move to next chunk (chunks are word-aligned in RIFF)
        const aligned_size = (chunk_size + 1) & ~@as(u32, 1);
        pos += 8 + aligned_size;
        chunks_found += 1;
    }

    if (chunks_found == 0) {
        return ValidationResult.invalid(.aep, "No valid chunks found in AEP file");
    }

    return ValidationResult.ok(.aep);
}

pub fn validateAepDeep(allocator: Allocator, source: *FileSource) ValidationResult {
    _ = allocator;
    const file = source;

    // AEP uses RIFX which doesn't have internal checksums
    // Structural validation is the best we can do
    const basic_result = validateAep(file);
    return ValidationResult{
        .format = .aep,
        .is_valid = basic_result.is_valid,
        .error_message = basic_result.error_message,
        .validation_depth = .structural, // RIFX doesn't have checksums
        .malformations = basic_result.malformations,
    };
}

pub fn validateAepFromBuffer(data: []const u8) ValidationResult {
    if (data.len < 12) {
        return ValidationResult.invalidCode(.aep, .buffer_too_small, "AEP header");
    }

    // Verify RIFX signature
    if (!std.mem.eql(u8, data[0..4], "RIFX")) {
        return ValidationResult.invalidCode(.aep, .invalid_signature, "AEP");
    }

    // Verify "Egg!" format marker
    if (!std.mem.eql(u8, data[8..12], "Egg!")) {
        return ValidationResult.invalidCode(.aep, .invalid_value, "AEP format marker");
    }

    // Verify size
    const declared_size = std.mem.readInt(u32, data[4..8], .big);
    if (@as(u64, declared_size) + 8 > data.len) {
        return ValidationResult.invalid(.aep, "Buffer truncated");
    }

    return ValidationResult.ok(.aep);
}

// ============ Tests ============

const testing = std.testing;

// ---------- Ground truth file-based tests ----------

test "validateEps accepts ground truth EPS" {
    var source = FileSource.open("ground_truth_examples/eps/sample.eps") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validateEps(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.eps, result.format);
}

test "validateFcpxml accepts ground truth FCPXML" {
    var source = FileSource.open("ground_truth_examples/fcpxml/sample.fcpxml") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validateFcpxml(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.fcpxml, result.format);
}

test "validatePrproj accepts ground truth PRPROJ" {
    var source = FileSource.open("ground_truth_examples/prproj/sample.prproj") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validatePrproj(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.prproj, result.format);
}

// ---------- Invalid data rejection (file-based) ----------

test "validateEps rejects garbage file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const garbage = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05 };
    tmp.dir.writeFile(.{ .sub_path = "bad.eps", .data = &garbage }) catch return;
    const path = tmp.dir.realpathAlloc(testing.allocator, "bad.eps") catch return;
    defer testing.allocator.free(path);
    var source = FileSource.open(path) catch return;
    defer source.close();
    const result = validateEps(&source);
    try testing.expect(!result.is_valid);
}

test "validateFcpxml rejects garbage file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const garbage = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05 };
    tmp.dir.writeFile(.{ .sub_path = "bad.fcpxml", .data = &garbage }) catch return;
    const path = tmp.dir.realpathAlloc(testing.allocator, "bad.fcpxml") catch return;
    defer testing.allocator.free(path);
    var source = FileSource.open(path) catch return;
    defer source.close();
    const result = validateFcpxml(&source);
    try testing.expect(!result.is_valid);
}

test "validatePrproj rejects garbage file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const garbage = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05 };
    tmp.dir.writeFile(.{ .sub_path = "bad.prproj", .data = &garbage }) catch return;
    const path = tmp.dir.realpathAlloc(testing.allocator, "bad.prproj") catch return;
    defer testing.allocator.free(path);
    var source = FileSource.open(path) catch return;
    defer source.close();
    const result = validatePrproj(&source);
    try testing.expect(!result.is_valid);
}

// ---------- Buffer-based tests ----------

test "validateEpsFromBuffer accepts valid EPS header" {
    const result = validateEpsFromBuffer("%!PS-Adobe-3.0 EPSF-3.0\n%%BoundingBox: 0 0 200 100\n%%EOF\n");
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.eps, result.format);
}

test "validateEpsFromBuffer accepts DOS EPS binary header" {
    const data = [_]u8{ 0xC5, 0xD0, 0xD3, 0xC6 } ++ [_]u8{ 0x1C, 0x00, 0x00, 0x00 } ++ [_]u8{ 0x00, 0x01, 0x00, 0x00 };
    const result = validateEpsFromBuffer(&data);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.eps, result.format);
}

test "validateEpsFromBuffer rejects PS without BoundingBox" {
    const result = validateEpsFromBuffer("%!PS-Adobe-3.0 EPSF-3.0\n%%EOF\n");
    try testing.expect(!result.is_valid);
}

test "validateEpsFromBuffer rejects garbage" {
    const result = validateEpsFromBuffer("this is not postscript");
    try testing.expect(!result.is_valid);
}

test "validateEpsFromBuffer rejects too-small data" {
    const result = validateEpsFromBuffer("ab");
    try testing.expect(!result.is_valid);
}

test "validateFcpxmlFromBuffer accepts valid FCPXML" {
    const result = validateFcpxmlFromBuffer("<?xml version=\"1.0\"?>\n<fcpxml version=\"1.10\">\n</fcpxml>\n");
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.fcpxml, result.format);
}

test "validateFcpxmlFromBuffer accepts direct fcpxml element" {
    const result = validateFcpxmlFromBuffer("<fcpxml version=\"1.10\"><resources/></fcpxml>");
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.fcpxml, result.format);
}

test "validateFcpxmlFromBuffer rejects garbage" {
    const result = validateFcpxmlFromBuffer("this is not fcpxml at all really");
    try testing.expect(!result.is_valid);
}

test "validateFcpxmlFromBuffer rejects too-small data" {
    const result = validateFcpxmlFromBuffer("short");
    try testing.expect(!result.is_valid);
}

test "validatePrprojFromBuffer accepts gzip-compressed data" {
    const data = [_]u8{ 0x1f, 0x8b, 0x08, 0x00, 0x00 };
    const result = validatePrprojFromBuffer(&data);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.prproj, result.format);
}

test "validatePrprojFromBuffer accepts XML declaration" {
    const result = validatePrprojFromBuffer("<?xml version=\"1.0\"?>\n<Project/>");
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.prproj, result.format);
}

test "validatePrprojFromBuffer accepts BOM + XML" {
    const data = [_]u8{ 0xEF, 0xBB, 0xBF } ++ "<?xml version=\"1.0\"?>";
    const result = validatePrprojFromBuffer(data);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.prproj, result.format);
}

test "validatePrprojFromBuffer rejects garbage" {
    const result = validatePrprojFromBuffer("this is not a premiere project");
    try testing.expect(!result.is_valid);
}

test "validatePrprojFromBuffer rejects too-small data" {
    const result = validatePrprojFromBuffer("abc");
    try testing.expect(!result.is_valid);
}

// ============================================================
// Tests moved from format_validation.zig
// ============================================================

test "validateAi accepts valid PDF-based AI file" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Minimal PDF structure for AI file
    const pdf_ai =
        \\%PDF-1.4
        \\1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj
        \\2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj
        \\3 0 obj<</Type/Page/MediaBox[0 0 612 792]/Parent 2 0 R>>endobj
        \\xref
        \\0 4
        \\0000000000 65535 f
        \\0000000009 00000 n
        \\0000000052 00000 n
        \\0000000101 00000 n
        \\trailer<</Size 4/Root 1 0 R>>
        \\startxref
        \\166
        \\%%EOF
    ;

    const file = try tmp_dir.dir.createFile("test.ai", .{});
    try file.writeAll(pdf_ai);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test.ai");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);
    try std.testing.expectEqual(FileFormat.ai, result.format);
    try std.testing.expect(result.is_valid);
}

test "validateAi accepts valid PostScript-based AI file" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Minimal PostScript AI structure
    const ps_ai =
        \\%!PS-Adobe-3.0
        \\%%Creator: Adobe Illustrator
        \\%%BoundingBox: 0 0 612 792
        \\%%EndComments
        \\%%BeginProlog
        \\%%EndProlog
        \\%%Page: 1 1
        \\showpage
        \\%%EOF
    ;

    const file = try tmp_dir.dir.createFile("legacy.ai", .{});
    try file.writeAll(ps_ai);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "legacy.ai");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);
    try std.testing.expectEqual(FileFormat.ai, result.format);
    try std.testing.expect(result.is_valid);
}

test "validateEps accepts valid EPS file" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Minimal EPS structure
    const eps_data =
        \\%!PS-Adobe-3.0 EPSF-3.0
        \\%%Creator: Test
        \\%%BoundingBox: 0 0 100 100
        \\%%EndComments
        \\newpath
        \\0 0 moveto
        \\100 100 lineto
        \\stroke
        \\%%EOF
    ;

    const file = try tmp_dir.dir.createFile("test.eps", .{});
    try file.writeAll(eps_data);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test.eps");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);
    try std.testing.expectEqual(FileFormat.eps, result.format);
    try std.testing.expect(result.is_valid);
}

test "validateEps rejects EPS missing BoundingBox" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // EPS without required BoundingBox
    const bad_eps =
        \\%!PS-Adobe-3.0 EPSF-3.0
        \\%%Creator: Test
        \\%%EndComments
        \\showpage
        \\%%EOF
    ;

    const file = try tmp_dir.dir.createFile("bad.eps", .{});
    try file.writeAll(bad_eps);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "bad.eps");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);
    try std.testing.expectEqual(FileFormat.eps, result.format);
    try std.testing.expect(!result.is_valid);
}

test "validateAep accepts valid AEP file structure" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Minimal valid AEP: RIFX + size + "Egg!" + one dummy chunk
    var aep_data: [28]u8 = undefined;

    // RIFX header
    @memcpy(aep_data[0..4], "RIFX");
    // File size minus 8 (big-endian)
    std.mem.writeInt(u32, aep_data[4..8], 20, .big);
    // Format type
    @memcpy(aep_data[8..12], "Egg!");

    // One dummy chunk: "LIST" + size 8 + some data
    @memcpy(aep_data[12..16], "LIST");
    std.mem.writeInt(u32, aep_data[16..20], 8, .big);
    @memcpy(aep_data[20..24], "test");
    @memset(aep_data[24..28], 0);

    const file = try tmp_dir.dir.createFile("test.aep", .{});
    try file.writeAll(&aep_data);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test.aep");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);
    if (!result.is_valid) {
        std.debug.print("\nAEP validation failed: {s}\n", .{result.error_message orelse "no message"});
    }
    try std.testing.expectEqual(FileFormat.aep, result.format);
    try std.testing.expect(result.is_valid);
}

test "validateAep rejects file with wrong format marker" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // RIFX but wrong format marker
    var bad_aep: [12]u8 = undefined;
    @memcpy(bad_aep[0..4], "RIFX");
    std.mem.writeInt(u32, bad_aep[4..8], 4, .big);
    @memcpy(bad_aep[8..12], "XXXX"); // Wrong marker

    const file = try tmp_dir.dir.createFile("bad.aep", .{});
    try file.writeAll(&bad_aep);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "bad.aep");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);
    // Should not detect as AEP since Egg! marker is wrong
    try std.testing.expect(result.format != .aep or !result.is_valid);
}

test "validateAepFromBuffer matches file validation" {
    // Minimal valid AEP buffer
    var aep_data: [28]u8 = undefined;
    @memcpy(aep_data[0..4], "RIFX");
    std.mem.writeInt(u32, aep_data[4..8], 20, .big);
    @memcpy(aep_data[8..12], "Egg!");
    @memcpy(aep_data[12..16], "LIST");
    std.mem.writeInt(u32, aep_data[16..20], 8, .big);
    @memcpy(aep_data[20..24], "test");
    @memset(aep_data[24..28], 0);

    const result = validateAepFromBuffer(&aep_data);
    try std.testing.expectEqual(FileFormat.aep, result.format);
    try std.testing.expect(result.is_valid);
}

test "validatePrproj accepts gzip-compressed PRPROJ" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Minimal valid gzip-compressed PRPROJ
    // gzip header: magic (2) + compression method (1) + flags (1) + mtime (4) + xfl (1) + os (1)
    var prproj_data: [20]u8 = undefined;
    prproj_data[0] = 0x1f; // Gzip magic byte 1
    prproj_data[1] = 0x8b; // Gzip magic byte 2
    prproj_data[2] = 0x08; // Compression method (deflate)
    prproj_data[3] = 0x00; // Flags
    @memset(prproj_data[4..8], 0); // MTIME
    prproj_data[8] = 0x00; // XFL
    prproj_data[9] = 0xff; // OS (unknown)
    @memset(prproj_data[10..20], 0); // Dummy compressed data

    const file = try tmp_dir.dir.createFile("test.prproj", .{});
    try file.writeAll(&prproj_data);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test.prproj");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);
    if (!result.is_valid) {
        std.debug.print("\nPRPROJ validation failed: {s}\n", .{result.error_message orelse "no message"});
    }
    try std.testing.expectEqual(FileFormat.prproj, result.format);
    try std.testing.expect(result.is_valid);
}

test "validatePrproj accepts legacy XML PRPROJ" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Legacy uncompressed XML PRPROJ
    const xml_content = "<?xml version=\"1.0\"?><Project></Project>";

    const file = try tmp_dir.dir.createFile("legacy.prproj", .{});
    try file.writeAll(xml_content);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "legacy.prproj");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);
    try std.testing.expectEqual(FileFormat.prproj, result.format);
    try std.testing.expect(result.is_valid);
}

test "validatePrproj rejects invalid compression method" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Invalid: gzip magic but wrong compression method
    var bad_prproj: [20]u8 = undefined;
    bad_prproj[0] = 0x1f;
    bad_prproj[1] = 0x8b;
    bad_prproj[2] = 0x07; // Wrong compression method (not deflate)
    @memset(bad_prproj[3..20], 0);

    const file = try tmp_dir.dir.createFile("bad.prproj", .{});
    try file.writeAll(&bad_prproj);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "bad.prproj");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);
    // Should either be detected as gzip (not prproj) or be invalid
    try std.testing.expect(result.format != .prproj or !result.is_valid);
}

test "validatePrprojFromBuffer matches file validation" {
    // Valid gzip-compressed PRPROJ buffer
    var prproj_data: [20]u8 = undefined;
    prproj_data[0] = 0x1f;
    prproj_data[1] = 0x8b;
    prproj_data[2] = 0x08;
    prproj_data[3] = 0x00;
    @memset(prproj_data[4..20], 0);

    const result = validatePrprojFromBuffer(&prproj_data);
    try std.testing.expectEqual(FileFormat.prproj, result.format);
    try std.testing.expect(result.is_valid);
}

test "validatePrprojFromBuffer accepts XML format" {
    const xml_content = "<?xml version=\"1.0\"?>";
    const result = validatePrprojFromBuffer(xml_content);
    try std.testing.expectEqual(FileFormat.prproj, result.format);
    try std.testing.expect(result.is_valid);
}

test "validateIndd accepts valid INDD file structure" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Minimal valid INDD: two 4096-byte master pages, each with 16-byte magic + sequence number
    const indd_magic = [16]u8{ 0x06, 0x06, 0xED, 0xF5, 0xD8, 0x1D, 0x46, 0xE5, 0xBD, 0x31, 0xEF, 0xE7, 0xFE, 0x74, 0xB7, 0x1D };
    var indd_data: [8192]u8 = [_]u8{0} ** 8192;
    // Primary master page: magic at offset 0, seq=0 at offset 28
    @memcpy(indd_data[0..16], &indd_magic);
    // Duplicate master page: magic at offset 4096, seq=0 at offset 4124
    @memcpy(indd_data[4096..4112], &indd_magic);

    const file = try tmp_dir.dir.createFile("test.indd", .{});
    try file.writeAll(&indd_data);    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test.indd");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);
    if (!result.is_valid) {
        std.debug.print("\nINDD validation failed: {s}\n", .{result.error_message orelse "no message"});
    }
    try std.testing.expectEqual(FileFormat.indd, result.format);
    try std.testing.expect(result.is_valid);
}

test "validateIndd rejects file with wrong magic bytes" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Invalid: wrong magic bytes
    var bad_indd: [32]u8 = undefined;
    bad_indd[0] = 0x00; // Wrong magic
    bad_indd[1] = 0x00;
    bad_indd[2] = 0x00;
    bad_indd[3] = 0x00;
    @memset(bad_indd[4..16], 0);
    @memcpy(bad_indd[16..24], "DOCUMENT");
    @memset(bad_indd[24..32], 0);

    const file = try tmp_dir.dir.createFile("bad.indd", .{});
    try file.writeAll(&bad_indd);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "bad.indd");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);
    try std.testing.expect(!result.is_valid or result.format != .indd);
}

test "validateInddFromBuffer matches file validation" {
    // Valid INDD buffer — just needs magic at offset 0
    const indd_magic = [16]u8{ 0x06, 0x06, 0xED, 0xF5, 0xD8, 0x1D, 0x46, 0xE5, 0xBD, 0x31, 0xEF, 0xE7, 0xFE, 0x74, 0xB7, 0x1D };
    var indd_data: [32]u8 = [_]u8{0} ** 32;
    @memcpy(indd_data[0..16], &indd_magic);

    const result = validateInddFromBuffer(&indd_data);
    try std.testing.expectEqual(FileFormat.indd, result.format);
    try std.testing.expect(result.is_valid);
}
test "validateIdml accepts valid IDML file structure" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Minimal valid ZIP file (IDML is ZIP-based)
    // ZIP local file header
    var idml_data: [30]u8 = undefined;
    idml_data[0] = 'P'; // ZIP signature
    idml_data[1] = 'K';
    idml_data[2] = 0x03;
    idml_data[3] = 0x04;
    @memset(idml_data[4..30], 0); // Rest of local file header

    const file = try tmp_dir.dir.createFile("test.idml", .{});
    try file.writeAll(&idml_data);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test.idml");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);
    if (!result.is_valid) {
        std.debug.print("\nIDML validation failed: {s}\n", .{result.error_message orelse "no message"});
    }
    try std.testing.expectEqual(FileFormat.idml, result.format);
    try std.testing.expect(result.is_valid);
}

