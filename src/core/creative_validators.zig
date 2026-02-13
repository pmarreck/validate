//! Creative suite / Adobe / NLE format validators extracted from format_validation.zig.
//! Covers Premiere Pro (.prproj), InDesign (.indd), IDML (.idml), Final Cut Pro (.fcpxml),
//! DaVinci Resolve (.drp), Sketch (.sketch), Illustrator (.ai), PostScript/EPS (.eps),
//! and After Effects (.aep).

const std = @import("std");
const Allocator = std.mem.Allocator;
const format_validation = @import("format_validation.zig");
const ValidationResult = format_validation.ValidationResult;
const FileFormat = format_validation.FileFormat;
const ValidationDepth = format_validation.ValidationDepth;
const DoctypeStrippedResult = format_validation.DoctypeStrippedResult;
const stripDoctypeDeclaration = format_validation.stripDoctypeDeclaration;
const xml = @import("xml");
const errmsg = @import("error_messages.zig");

// ============ Premiere Pro (.prproj) Validator ============

pub fn validatePrproj(file: std.fs.File) ValidationResult {
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

pub fn validatePrprojDeep(allocator: Allocator, path: []const u8) ValidationResult {
    // Read file
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return ValidationResult.invalidCode(.prproj, .failed_to_open, "PRPROJ file");
    };
    defer file.close();

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
        const gzip_result = format_validation.validateGzipDeep(allocator, path);
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

    const xml_data = allocator.alloc(u8, @intCast(file_size)) catch {
        return ValidationResult.invalidCode(.prproj, .failed_to_allocate, "memory for XML");
    };
    defer allocator.free(xml_data);

    const xml_read = file.readAll(xml_data) catch {
        return ValidationResult.invalidCode(.prproj, .failed_to_read, "XML data");
    };

    if (xml_read != file_size) {
        return ValidationResult.invalidCode(.prproj, .incomplete, "XML read");
    }

    // Validate XML structure using the xml module
    // Strip DOCTYPE declarations to avoid DTD validation issues
    const preprocessed = stripDoctypeDeclaration(xml_data);
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

pub fn validateIndd(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.indd, .failed_to_seek, "to start");

    var header: [24]u8 = undefined;
    const bytes_read = file.read(&header) catch {
        return ValidationResult.invalidCode(.indd, .failed_to_read, "INDD header");
    };

    if (bytes_read < 24) {
        return ValidationResult.invalidCode(.indd, .file_too_small, "INDD format");
    }

    // Check magic bytes: 06 06 ED F5
    if (header[0] != 0x06 or header[1] != 0x06 or header[2] != 0xED or header[3] != 0xF5) {
        return ValidationResult.invalidCode(.indd, .invalid_magic, "INDD");
    }

    // Check for "DOCUMENT" at byte 16
    if (!std.mem.eql(u8, header[16..24], "DOCUMENT")) {
        return ValidationResult.invalidCode(.indd, .missing, "DOCUMENT identifier");
    }

    // INDD is proprietary binary - structural validation only
    return ValidationResult.structuralOnly(.indd);
}

pub fn validateInddDeep(allocator: Allocator, path: []const u8) ValidationResult {
    _ = allocator;
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return ValidationResult.invalidCode(.indd, .failed_to_open, "INDD file");
    };
    defer file.close();

    // Structural validation is all we can do for proprietary format
    const result = validateIndd(file);
    if (!result.is_valid) return result;

    // Return structural depth since we can't validate all bytes without Adobe's spec
    return ValidationResult.structuralOnly(.indd);
}

pub fn validateInddFromBuffer(data: []const u8) ValidationResult {
    if (data.len < 24) {
        return ValidationResult.invalidCode(.indd, .buffer_too_small, "INDD");
    }

    // Check magic bytes: 06 06 ED F5
    if (data[0] != 0x06 or data[1] != 0x06 or data[2] != 0xED or data[3] != 0xF5) {
        return ValidationResult.invalidCode(.indd, .invalid_magic, "INDD");
    }

    // Check for "DOCUMENT" at byte 16
    if (!std.mem.eql(u8, data[16..24], "DOCUMENT")) {
        return ValidationResult.invalidCode(.indd, .missing, "DOCUMENT identifier");
    }

    return ValidationResult.structuralOnly(.indd);
}

// ============ IDML Validator ============

pub fn validateIdml(file: std.fs.File) ValidationResult {
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

    // IDML is a ZIP container - basic structural validation passes
    // Deep validation will check for designmap.xml and CRC integrity
    return ValidationResult.okWithDepth(.idml, .full);
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

pub fn validateFcpxml(file: std.fs.File) ValidationResult {
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

pub fn validateFcpxmlDeep(allocator: Allocator, path: []const u8) ValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return ValidationResult.invalidCode(.fcpxml, .failed_to_open, "FCPXML file");
    };
    defer file.close();

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

    const xml_data = allocator.alloc(u8, @intCast(file_size)) catch {
        return ValidationResult.invalidCode(.fcpxml, .failed_to_allocate, "memory");
    };
    defer allocator.free(xml_data);

    const xml_read = file.readAll(xml_data) catch {
        return ValidationResult.invalidCode(.fcpxml, .failed_to_read, "XML data");
    };

    if (xml_read != file_size) {
        return ValidationResult.invalidCode(.fcpxml, .incomplete, "read");
    }

    // Use XML parser to validate structure
    const preprocessed = stripDoctypeDeclaration(xml_data);
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

pub fn validateDrp(file: std.fs.File) ValidationResult {
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

pub fn validateDrpDeep(allocator: Allocator, path: []const u8) ValidationResult {
    // Use ZIP deep validation for the container integrity
    const zip_result = format_validation.validateZipDeep(allocator, path);
    if (!zip_result.is_valid) {
        return ValidationResult.invalid(.drp, zip_result.error_message orelse "Invalid ZIP structure");
    }

    // Now check for project.xml in the archive
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return ValidationResult.invalidCode(.drp, .failed_to_open, "DRP file");
    };
    defer file.close();

    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCode(.drp, .failed_to_get, "file size");
    };

    if (file_size > 500 * 1024 * 1024) {
        // For very large files, trust the ZIP validation
        return ValidationResult.okWithDepth(.drp, .full);
    }

    // Read the file to find project.xml in the central directory
    const data = allocator.alloc(u8, @intCast(file_size)) catch {
        return ValidationResult.invalidCode(.drp, .failed_to_allocate, "memory");
    };
    defer allocator.free(data);

    const read_len = file.readAll(data) catch {
        return ValidationResult.invalidCode(.drp, .failed_to_read, "file");
    };

    if (read_len != file_size) {
        return ValidationResult.invalidCode(.drp, .incomplete, "read");
    }

    // Look for project.xml in the file names
    // Simple check: search for "project.xml" in the data
    if (std.mem.indexOf(u8, data, "project.xml") != null) {
        return ValidationResult.okWithDepth(.drp, .full);
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

pub fn validateSketch(file: std.fs.File) ValidationResult {
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

pub fn validateSketchDeep(allocator: Allocator, path: []const u8) ValidationResult {
    // Use ZIP deep validation for the container integrity
    const zip_result = format_validation.validateZipDeep(allocator, path);
    if (!zip_result.is_valid) {
        return ValidationResult.invalid(.sketch, zip_result.error_message orelse "Invalid ZIP structure");
    }

    // Now check for required Sketch files in the archive
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return ValidationResult.invalidCode(.sketch, .failed_to_open, "Sketch file");
    };
    defer file.close();

    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCode(.sketch, .failed_to_get, "file size");
    };

    if (file_size > 500 * 1024 * 1024) {
        // For very large files, trust the ZIP validation
        return ValidationResult.okWithDepth(.sketch, .full);
    }

    // Read the file to find document.json and meta.json in the central directory
    const data = allocator.alloc(u8, @intCast(file_size)) catch {
        return ValidationResult.invalidCode(.sketch, .failed_to_allocate, "memory");
    };
    defer allocator.free(data);

    const read_len = file.readAll(data) catch {
        return ValidationResult.invalidCode(.sketch, .failed_to_read, "file");
    };

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

pub fn validateAi(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.ai, .failed_to_seek, "to start");

    var header: [16]u8 = undefined;
    const bytes_read = file.read(&header) catch return ValidationResult.invalidCode(.ai, .failed_to_read, "AI header");
    if (bytes_read < 5) {
        return ValidationResult.invalidCode(.ai, .file_too_small, "AI header");
    }

    // Check if it's PDF-based (modern AI files)
    if (std.mem.startsWith(u8, header[0..bytes_read], "%PDF-")) {
        // Delegate to PDF validator
        file.seekTo(0) catch return ValidationResult.invalidCode(.ai, .failed_to_seek, "to start");
        const pdf_result = format_validation.validatePdf(file);
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

pub fn validateAiDeep(allocator: Allocator, path: []const u8) ValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => ValidationResult.invalid(.ai, "File not found"),
            error.AccessDenied => ValidationResult.invalid(.ai, "Access denied"),
            else => ValidationResult.invalidCode(.ai, .failed_to_open, "file"),
        };
    };
    defer file.close();

    var header: [16]u8 = undefined;
    const bytes_read = file.read(&header) catch return ValidationResult.invalidCode(.ai, .failed_to_read, "header");

    // If PDF-based, use deep PDF validation
    if (std.mem.startsWith(u8, header[0..bytes_read], "%PDF-")) {
        const pdf_result = format_validation.validatePdfDeep(allocator, path);
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
        const pdf_result = format_validation.validatePdfFromBuffer(data);
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

pub fn validateEps(file: std.fs.File) ValidationResult {
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

pub fn validateEpsDeep(allocator: Allocator, path: []const u8) ValidationResult {
    _ = allocator;
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => ValidationResult.invalid(.eps, "File not found"),
            error.AccessDenied => ValidationResult.invalid(.eps, "Access denied"),
            else => ValidationResult.invalidCode(.eps, .failed_to_open, "file"),
        };
    };
    defer file.close();

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
pub fn validatePostScript(file: std.fs.File, format: FileFormat) ValidationResult {
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

pub fn validateAep(file: std.fs.File) ValidationResult {
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

pub fn validateAepDeep(allocator: Allocator, path: []const u8) ValidationResult {
    _ = allocator;
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => ValidationResult.invalid(.aep, "File not found"),
            error.AccessDenied => ValidationResult.invalid(.aep, "Access denied"),
            else => ValidationResult.invalidCode(.aep, .failed_to_open, "file"),
        };
    };
    defer file.close();

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
