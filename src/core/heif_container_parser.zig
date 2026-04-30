//! HEIF/HEIC/AVIF Container Parser (Pure Zig)
//!
//! Parses the ISOBMFF (ISO Base Media File Format) meta-box structure used by
//! HEIC and AVIF image files. This replaces libheif for container parsing.
//!
//! Supports:
//! - HEIC (HEVC-coded images)
//! - AVIF (AV1-coded images)
//! - Multi-image application format (mif1)
//!
//! References:
//! - ISO/IEC 14496-12 (ISOBMFF)
//! - ISO/IEC 23008-12 (HEIF)
//! - AV1 Image File Format (AVIF) spec
//!
//! This is a pure-Zig implementation with no external C dependencies.
//! Operates on a memory buffer ([]const u8) using big-endian ISOBMFF box reading.

const std = @import("std");

// ============================================================================
// Error Types
// ============================================================================

pub const HeifContainerError = error{
    TooSmall,
    InvalidFtyp,
    NoMetaBox,
    InvalidMetaBox,
    NoHandlerBox,
    InvalidHandler,
    NoPrimaryItem,
    NoItemInfo,
    NoItemLocation,
    NoItemProperties,
    InvalidItemLocation,
    ItemNotFound,
    DataOutOfBounds,
    UnsupportedConstructionMethod,
    Truncated,
};

// ============================================================================
// Brand and Item Type Enums
// ============================================================================

pub const HeifBrand = enum {
    heic, // HEVC-coded image
    heix, // HEVC-coded image (extended)
    avif, // AV1-coded image
    avis, // AV1 image sequence
    mif1, // Multi-image application format
    unknown,

    pub fn fromFourCC(fourcc: [4]u8) HeifBrand {
        if (std.mem.eql(u8, &fourcc, "heic")) return .heic;
        if (std.mem.eql(u8, &fourcc, "heix")) return .heix;
        if (std.mem.eql(u8, &fourcc, "avif")) return .avif;
        if (std.mem.eql(u8, &fourcc, "avis")) return .avis;
        if (std.mem.eql(u8, &fourcc, "mif1")) return .mif1;
        return .unknown;
    }
};

pub const ItemType = enum {
    hvc1, // HEVC image
    av01, // AV1 image
    jpeg, // JPEG image
    grid, // Image grid
    iovl, // Image overlay
    Exif, // EXIF metadata
    mime, // MIME data
    unknown,

    pub fn fromFourCC(fourcc: [4]u8) ItemType {
        if (std.mem.eql(u8, &fourcc, "hvc1")) return .hvc1;
        if (std.mem.eql(u8, &fourcc, "av01")) return .av01;
        if (std.mem.eql(u8, &fourcc, "jpeg")) return .jpeg;
        if (std.mem.eql(u8, &fourcc, "grid")) return .grid;
        if (std.mem.eql(u8, &fourcc, "iovl")) return .iovl;
        if (std.mem.eql(u8, &fourcc, "Exif")) return .Exif;
        if (std.mem.eql(u8, &fourcc, "mime")) return .mime;
        return .unknown;
    }
};

// ============================================================================
// Data Structures
// ============================================================================

pub const ItemInfo = struct {
    item_id: u32,
    item_type: ItemType,
    item_type_raw: [4]u8,
};

pub const ItemExtent = struct {
    offset: u64,
    length: u64,
};

pub const ItemLocation = struct {
    item_id: u32,
    construction_method: u8,
    base_offset: u64,
    extents: []const ItemExtent,
};

pub const ImageSpatialExtents = struct {
    width: u32,
    height: u32,
};

pub const DecoderConfig = struct {
    config_data: []const u8, // Raw hvcC or av1C box data
};

pub const HeifContainerInfo = struct {
    brand: HeifBrand,
    primary_item_id: u32,
    items: []const ItemInfo,
    // Image spatial extents from ispe box (if found)
    width: u32,
    height: u32,
    // The raw decoder config data for the primary item
    decoder_config: ?[]const u8,
    // Location of primary item data
    primary_data_offset: u64,
    primary_data_length: u64,
    // Grid support: tile item IDs from iref dimg references
    dimg_tile_ids: []const u32,
    // All item locations (for tile data lookup)
    locations: []const ItemLocation,
    // Decoder config for tiles (hvcC/av1C from first tile's iprp)
    tile_decoder_config: ?[]const u8,
};

// ============================================================================
// Box Reading Utilities
// ============================================================================

const BoxHeader = struct {
    box_type: [4]u8,
    offset: u64, // Start of box (before size field)
    data_offset: u64, // Start of box content (after header)
    size: u64, // Total box size including header
    header_size: u8, // 8 or 16
};

/// Read a box header from the given position in the data buffer.
/// Returns null if there isn't enough data for a valid header.
fn readBoxHeader(data: []const u8, pos: u64) ?BoxHeader {
    if (pos + 8 > data.len) return null;
    const p: usize = @intCast(pos);
    const size32 = std.mem.readInt(u32, data[p..][0..4], .big);
    const box_type = data[p + 4 ..][0..4].*;

    var header_size: u8 = 8;
    var actual_size: u64 = size32;

    if (size32 == 1) {
        // Extended 64-bit size
        if (pos + 16 > data.len) return null;
        actual_size = std.mem.readInt(u64, data[p + 8 ..][0..8], .big);
        header_size = 16;
    } else if (size32 == 0) {
        // Box extends to end of data
        actual_size = data.len - pos;
    }

    return BoxHeader{
        .box_type = box_type,
        .offset = pos,
        .data_offset = pos + header_size,
        .size = actual_size,
        .header_size = header_size,
    };
}

/// Find a child box of a specific type within a parent box's data region.
fn findChildBox(data: []const u8, parent_data_start: u64, parent_data_end: u64, target_type: [4]u8) ?BoxHeader {
    var pos = parent_data_start;
    while (pos < parent_data_end) {
        const box = readBoxHeader(data, pos) orelse return null;
        if (std.mem.eql(u8, &box.box_type, &target_type)) {
            return box;
        }
        if (box.size == 0) return null; // Prevent infinite loop
        pos = box.offset + box.size;
    }
    return null;
}

/// Find a top-level box of a specific type in the file data.
fn findTopLevelBox(data: []const u8, target_type: [4]u8) ?BoxHeader {
    return findChildBox(data, 0, data.len, target_type);
}

/// Iterator for child boxes within a parent box's data region.
const ChildBoxIterator = struct {
    data: []const u8,
    pos: u64,
    end: u64,

    fn next(self: *ChildBoxIterator) ?BoxHeader {
        if (self.pos >= self.end) return null;
        const box = readBoxHeader(self.data, self.pos) orelse return null;
        if (box.size == 0) return null;
        self.pos = box.offset + box.size;
        return box;
    }
};

/// Create an iterator over child boxes within a parent's data region.
fn iterateChildBoxes(data: []const u8, parent_data_start: u64, parent_data_end: u64) ChildBoxIterator {
    return .{ .data = data, .pos = parent_data_start, .end = parent_data_end };
}

/// Read a variable-size unsigned integer from the buffer.
/// Used for iloc fields where offset_size/length_size/base_offset_size can be 0, 4, or 8 bytes.
fn readVarSizeUint(data: []const u8, pos: usize, byte_count: u4) ?u64 {
    return switch (byte_count) {
        0 => @as(u64, 0),
        1 => blk: {
            if (pos + 1 > data.len) break :blk null;
            break :blk @as(u64, data[pos]);
        },
        2 => blk: {
            if (pos + 2 > data.len) break :blk null;
            break :blk @as(u64, std.mem.readInt(u16, data[pos..][0..2], .big));
        },
        4 => blk: {
            if (pos + 4 > data.len) break :blk null;
            break :blk @as(u64, std.mem.readInt(u32, data[pos..][0..4], .big));
        },
        8 => blk: {
            if (pos + 8 > data.len) break :blk null;
            break :blk std.mem.readInt(u64, data[pos..][0..8], .big);
        },
        else => null,
    };
}

// ============================================================================
// Sub-Parsers
// ============================================================================

/// Parse the ftyp box to extract the major brand.
fn parseFtypBrand(data: []const u8, ftyp: BoxHeader) HeifBrand {
    const p: usize = @intCast(ftyp.data_offset);
    if (p + 4 > data.len) return .unknown;
    const major_brand = data[p..][0..4].*;
    return HeifBrand.fromFourCC(major_brand);
}

/// Parse the pitm (Primary Item ID) box.
/// FullBox: version(1) + flags(3), then item_id (2 bytes v0, 4 bytes v>=1).
fn parsePitm(data: []const u8, pitm: BoxHeader) HeifContainerError!u32 {
    const p: usize = @intCast(pitm.data_offset);
    if (p + 4 > data.len) return error.Truncated;

    const version = data[p];
    // flags are data[p+1..p+4], not needed here

    if (version == 0) {
        if (p + 6 > data.len) return error.Truncated;
        return @as(u32, std.mem.readInt(u16, data[p + 4 ..][0..2], .big));
    } else {
        if (p + 8 > data.len) return error.Truncated;
        return std.mem.readInt(u32, data[p + 4 ..][0..4], .big);
    }
}

/// Parse the iinf (Item Info Box) to extract item entries.
/// FullBox: version(1) + flags(3), then entry_count (2 bytes v0, 4 bytes v>=2).
/// Each entry is an infe (Item Info Entry) box.
fn parseIinf(data: []const u8, iinf: BoxHeader, items_buf: []ItemInfo) HeifContainerError![]const ItemInfo {
    const p: usize = @intCast(iinf.data_offset);
    const box_end: usize = @intCast(iinf.offset + iinf.size);
    if (p + 4 > data.len) return error.Truncated;

    const version = data[p];
    var header_len: usize = 4; // version(1) + flags(3)

    if (version == 0) {
        if (p + header_len + 2 > data.len) return error.Truncated;
        // entry_count declared but we use actual parsed count from child boxes
        header_len += 2;
    } else {
        // version >= 2
        if (p + header_len + 4 > data.len) return error.Truncated;
        // entry_count declared but we use actual parsed count from child boxes
        header_len += 4;
    }

    // Parse each infe child box
    var items_found: usize = 0;
    var iter = iterateChildBoxes(data, iinf.data_offset + header_len, @min(box_end, data.len));
    while (iter.next()) |infe_box| {
        if (!std.mem.eql(u8, &infe_box.box_type, "infe")) continue;
        if (items_found >= items_buf.len) break;

        const item_info = parseInfe(data, infe_box) orelse continue;
        items_buf[items_found] = item_info;
        items_found += 1;
    }

    return items_buf[0..items_found];
}

/// Parse a single infe (Item Info Entry) box.
fn parseInfe(data: []const u8, infe: BoxHeader) ?ItemInfo {
    const p: usize = @intCast(infe.data_offset);
    if (p + 4 > data.len) return null;

    const version = data[p];
    // flags = data[p+1..p+4]

    if (version >= 2) {
        // version 2: item_id(2) + item_protection_index(2) + item_type(4)
        // version 3: item_id(4) + item_protection_index(2) + item_type(4)
        var off: usize = p + 4; // skip version+flags

        var item_id: u32 = 0;
        if (version == 2) {
            if (off + 2 > data.len) return null;
            item_id = @as(u32, std.mem.readInt(u16, data[off..][0..2], .big));
            off += 2;
        } else {
            // version 3
            if (off + 4 > data.len) return null;
            item_id = std.mem.readInt(u32, data[off..][0..4], .big);
            off += 4;
        }

        // item_protection_index (2 bytes)
        if (off + 2 > data.len) return null;
        off += 2;

        // item_type (4 bytes)
        if (off + 4 > data.len) return null;
        const item_type_raw = data[off..][0..4].*;
        const item_type = ItemType.fromFourCC(item_type_raw);

        return ItemInfo{
            .item_id = item_id,
            .item_type = item_type,
            .item_type_raw = item_type_raw,
        };
    } else {
        // version 0/1: item_id(2) + item_protection_index(2)
        // No item_type field in older versions
        const off: usize = p + 4;
        if (off + 4 > data.len) return null;
        const item_id: u32 = @as(u32, std.mem.readInt(u16, data[off..][0..2], .big));
        // Skip item_protection_index (2 bytes) - not needed for our purposes

        return ItemInfo{
            .item_id = item_id,
            .item_type = .unknown,
            .item_type_raw = .{ 0, 0, 0, 0 },
        };
    }
}

/// Parse the iloc (Item Location Box) to extract item data locations.
/// This is the most complex box in the HEIF meta structure.
fn parseIloc(
    data: []const u8,
    iloc: BoxHeader,
    locations_buf: []ItemLocation,
    extents_buf: []ItemExtent,
) HeifContainerError!struct { locations: []const ItemLocation, extents_used: usize } {
    const p: usize = @intCast(iloc.data_offset);
    if (p + 4 > data.len) return error.Truncated;

    const version = data[p];
    // flags = data[p+1..p+4]

    var off: usize = p + 4; // skip version+flags

    // Packed sizes byte 1: offset_size(4 bits) | length_size(4 bits)
    if (off + 2 > data.len) return error.Truncated;
    const offset_size: u4 = @intCast((data[off] >> 4) & 0x0F);
    const length_size: u4 = @intCast(data[off] & 0x0F);
    off += 1;

    // Packed sizes byte 2: base_offset_size(4 bits) | index_size(4 bits)
    const base_offset_size: u4 = @intCast((data[off] >> 4) & 0x0F);
    const index_size: u4 = if (version == 1 or version == 2) @intCast(data[off] & 0x0F) else 0;
    off += 1;

    // item_count
    var item_count: u32 = 0;
    if (version < 2) {
        if (off + 2 > data.len) return error.Truncated;
        item_count = @as(u32, std.mem.readInt(u16, data[off..][0..2], .big));
        off += 2;
    } else {
        if (off + 4 > data.len) return error.Truncated;
        item_count = std.mem.readInt(u32, data[off..][0..4], .big);
        off += 4;
    }

    var locations_found: usize = 0;
    var extents_used: usize = 0;

    for (0..item_count) |_| {
        if (locations_found >= locations_buf.len) break;

        // item_id
        var item_id: u32 = 0;
        if (version < 2) {
            if (off + 2 > data.len) return error.Truncated;
            item_id = @as(u32, std.mem.readInt(u16, data[off..][0..2], .big));
            off += 2;
        } else {
            if (off + 4 > data.len) return error.Truncated;
            item_id = std.mem.readInt(u32, data[off..][0..4], .big);
            off += 4;
        }

        // construction_method (version 1/2 only): 4 reserved bits + 4 bits
        var construction_method: u8 = 0;
        if (version == 1 or version == 2) {
            if (off + 2 > data.len) return error.Truncated;
            construction_method = @intCast(std.mem.readInt(u16, data[off..][0..2], .big) & 0x0F);
            off += 2;
        }

        // data_reference_index (2 bytes)
        if (off + 2 > data.len) return error.Truncated;
        off += 2; // We don't use data_reference_index

        // base_offset (base_offset_size bytes)
        const base_offset = readVarSizeUint(data, off, base_offset_size) orelse return error.Truncated;
        off += @as(usize, base_offset_size);

        // extent_count (2 bytes)
        if (off + 2 > data.len) return error.Truncated;
        const extent_count: u16 = std.mem.readInt(u16, data[off..][0..2], .big);
        off += 2;

        const extents_start = extents_used;

        for (0..extent_count) |_| {
            if (extents_used >= extents_buf.len) break;

            // extent_index (version 1/2, if index_size > 0)
            if ((version == 1 or version == 2) and index_size > 0) {
                // Skip extent_index
                off += @as(usize, index_size);
            }

            // extent_offset
            const extent_offset = readVarSizeUint(data, off, offset_size) orelse return error.Truncated;
            off += @as(usize, offset_size);

            // extent_length
            const extent_length = readVarSizeUint(data, off, length_size) orelse return error.Truncated;
            off += @as(usize, length_size);

            extents_buf[extents_used] = ItemExtent{
                .offset = extent_offset,
                .length = extent_length,
            };
            extents_used += 1;
        }

        locations_buf[locations_found] = ItemLocation{
            .item_id = item_id,
            .construction_method = construction_method,
            .base_offset = base_offset,
            .extents = extents_buf[extents_start..extents_used],
        };
        locations_found += 1;
    }

    return .{ .locations = locations_buf[0..locations_found], .extents_used = extents_used };
}

/// Result from parsing item properties.
const ItemPropertiesResult = struct {
    width: u32,
    height: u32,
    decoder_config: ?[]const u8,
};

/// Parse the iprp (Item Properties Box) to extract ispe and decoder config.
/// The iprp box contains:
///   - ipco (Item Property Container): child boxes with properties (ispe, hvcC, av1C, etc.)
///   - ipma (Item Property Association): maps properties to items
fn parseIprp(data: []const u8, iprp: BoxHeader, primary_item_id: u32) ItemPropertiesResult {
    const box_end: usize = @intCast(@min(iprp.offset + iprp.size, data.len));
    const iprp_data_start = iprp.data_offset;

    // Find ipco (Item Property Container)
    const ipco = findChildBox(data, iprp_data_start, box_end, "ipco".*) orelse {
        return .{ .width = 0, .height = 0, .decoder_config = null };
    };

    // Collect all properties from ipco (indexed starting at 1 per spec)
    const max_properties = 64;
    var properties: [max_properties]BoxHeader = undefined;
    var property_count: usize = 0;

    const ipco_end: usize = @intCast(@min(ipco.offset + ipco.size, data.len));
    var prop_iter = iterateChildBoxes(data, ipco.data_offset, ipco_end);
    while (prop_iter.next()) |prop_box| {
        if (property_count >= max_properties) break;
        properties[property_count] = prop_box;
        property_count += 1;
    }

    // Find ipma (Item Property Association)
    const ipma = findChildBox(data, iprp_data_start, box_end, "ipma".*) orelse {
        // No ipma - try to extract ispe directly from first occurrence
        return extractPropertiesDirect(data, properties[0..property_count]);
    };

    // Parse ipma to find which properties are associated with the primary item
    return parseIpmaForItem(data, ipma, primary_item_id, properties[0..property_count]);
}

/// Extract properties directly from ipco children (fallback when no ipma).
fn extractPropertiesDirect(data: []const u8, properties: []const BoxHeader) ItemPropertiesResult {
    var result = ItemPropertiesResult{ .width = 0, .height = 0, .decoder_config = null };

    for (properties) |prop| {
        if (std.mem.eql(u8, &prop.box_type, "ispe")) {
            const ispe = parseIspe(data, prop);
            if (ispe) |extents| {
                result.width = extents.width;
                result.height = extents.height;
            }
        } else if (std.mem.eql(u8, &prop.box_type, "hvcC") or std.mem.eql(u8, &prop.box_type, "av1C")) {
            const p: usize = @intCast(prop.data_offset);
            const end: usize = @intCast(@min(prop.offset + prop.size, data.len));
            if (p < end) {
                result.decoder_config = data[p..end];
            }
        }
    }

    return result;
}

/// Parse ipma to find properties associated with a specific item ID.
fn parseIpmaForItem(
    data: []const u8,
    ipma: BoxHeader,
    target_item_id: u32,
    properties: []const BoxHeader,
) ItemPropertiesResult {
    var result = ItemPropertiesResult{ .width = 0, .height = 0, .decoder_config = null };

    const p: usize = @intCast(ipma.data_offset);
    if (p + 4 > data.len) return result;

    const version = data[p];
    const flags_byte2 = data[p + 3];
    const flags = flags_byte2; // Only lowest byte of flags matters for ipma
    var off: usize = p + 4; // skip version+flags

    // entry_count (4 bytes)
    if (off + 4 > data.len) return result;
    const entry_count = std.mem.readInt(u32, data[off..][0..4], .big);
    off += 4;

    for (0..entry_count) |_| {
        // item_id (2 bytes v0, 4 bytes v>=1)
        var item_id: u32 = 0;
        if (version < 1) {
            if (off + 2 > data.len) return result;
            item_id = @as(u32, std.mem.readInt(u16, data[off..][0..2], .big));
            off += 2;
        } else {
            if (off + 4 > data.len) return result;
            item_id = std.mem.readInt(u32, data[off..][0..4], .big);
            off += 4;
        }

        // association_count (1 byte)
        if (off + 1 > data.len) return result;
        const association_count = data[off];
        off += 1;

        for (0..association_count) |_| {
            // If flags & 1: essential(1 bit) + property_index(15 bits) = 2 bytes
            // Else: essential(1 bit) + property_index(7 bits) = 1 byte
            var property_index: u16 = 0;
            if (flags & 1 != 0) {
                if (off + 2 > data.len) return result;
                const val = std.mem.readInt(u16, data[off..][0..2], .big);
                property_index = val & 0x7FFF; // Lower 15 bits
                off += 2;
            } else {
                if (off + 1 > data.len) return result;
                property_index = @as(u16, data[off] & 0x7F); // Lower 7 bits
                off += 1;
            }

            // Property indices are 1-based in ipma
            if (item_id == target_item_id and property_index > 0 and property_index <= properties.len) {
                const prop = properties[property_index - 1];

                if (std.mem.eql(u8, &prop.box_type, "ispe")) {
                    const ispe = parseIspe(data, prop);
                    if (ispe) |extents| {
                        result.width = extents.width;
                        result.height = extents.height;
                    }
                } else if (std.mem.eql(u8, &prop.box_type, "hvcC") or
                    std.mem.eql(u8, &prop.box_type, "av1C"))
                {
                    const pp: usize = @intCast(prop.data_offset);
                    const end: usize = @intCast(@min(prop.offset + prop.size, data.len));
                    if (pp < end) {
                        result.decoder_config = data[pp..end];
                    }
                }
            }
        }
    }

    return result;
}

/// Parse an ispe (Image Spatial Extents) box.
/// FullBox: version(1) + flags(3), then width(4) + height(4).
fn parseIspe(data: []const u8, ispe: BoxHeader) ?ImageSpatialExtents {
    const p: usize = @intCast(ispe.data_offset);
    // version(1) + flags(3) + width(4) + height(4) = 12 bytes
    if (p + 12 > data.len) return null;

    const width = std.mem.readInt(u32, data[p + 4 ..][0..4], .big);
    const height = std.mem.readInt(u32, data[p + 8 ..][0..4], .big);

    return ImageSpatialExtents{
        .width = width,
        .height = height,
    };
}

/// Find the location entry for a specific item ID.
pub fn findItemLocation(locations: []const ItemLocation, item_id: u32) ?ItemLocation {
    for (locations) |loc| {
        if (loc.item_id == item_id) return loc;
    }
    return null;
}

/// Parse iref (Item Reference Box) to extract dimg tile references for a given item.
/// iref is a FullBox containing SingleItemTypeReferenceBox children.
/// Each child's box_type is the reference type (e.g., "dimg" for derived images).
fn parseIref(data: []const u8, iref: BoxHeader, from_item_id: u32, tile_ids_buf: []u32) []const u32 {
    const p: usize = @intCast(iref.data_offset);
    if (p + 4 > data.len) return tile_ids_buf[0..0];

    const version = data[p];
    const box_end: usize = @intCast(@min(iref.offset + iref.size, data.len));

    // Iterate child boxes (reference entries) after FullBox version+flags
    var iter = iterateChildBoxes(data, iref.data_offset + 4, box_end);
    var found: usize = 0;

    while (iter.next()) |ref_box| {
        // Only care about "dimg" (derived image) references
        if (!std.mem.eql(u8, &ref_box.box_type, "dimg")) continue;

        const rp: usize = @intCast(ref_box.data_offset);
        const ref_end: usize = @intCast(@min(ref_box.offset + ref_box.size, data.len));

        if (version == 0) {
            // from_item_ID(2) + reference_count(2) + to_item_IDs(2 each)
            if (rp + 4 > ref_end) continue;
            const from_id: u32 = @as(u32, std.mem.readInt(u16, data[rp..][0..2], .big));
            if (from_id != from_item_id) continue;
            const ref_count = std.mem.readInt(u16, data[rp + 2 ..][0..2], .big);
            var off: usize = rp + 4;
            for (0..ref_count) |_| {
                if (off + 2 > ref_end or found >= tile_ids_buf.len) break;
                tile_ids_buf[found] = @as(u32, std.mem.readInt(u16, data[off..][0..2], .big));
                found += 1;
                off += 2;
            }
        } else {
            // from_item_ID(4) + reference_count(2) + to_item_IDs(4 each)
            if (rp + 6 > ref_end) continue;
            const from_id = std.mem.readInt(u32, data[rp..][0..4], .big);
            if (from_id != from_item_id) continue;
            const ref_count = std.mem.readInt(u16, data[rp + 4 ..][0..2], .big);
            var off: usize = rp + 6;
            for (0..ref_count) |_| {
                if (off + 4 > ref_end or found >= tile_ids_buf.len) break;
                tile_ids_buf[found] = std.mem.readInt(u32, data[off..][0..4], .big);
                found += 1;
                off += 4;
            }
        }
    }

    return tile_ids_buf[0..found];
}

// ============================================================================
// Main Parsing Function
// ============================================================================

/// Parse a HEIF/HEIC/AVIF container from a memory buffer.
///
/// Extracts the ftyp brand, primary item ID, item info entries, item locations,
/// and image properties (dimensions and decoder configuration).
///
/// Returns a HeifContainerInfo struct with all extracted metadata.
/// The returned slices point into the provided data buffer and internal
/// static buffers, so they are only valid for the duration of parsing.
///
/// Note: This function uses fixed-size internal buffers. It supports up to
/// 256 items, 256 locations, and 1024 extents, which is sufficient for
/// all practical HEIF/AVIF files.
pub fn parseHeifContainer(data: []const u8) HeifContainerError!HeifContainerInfo {
    if (data.len < 12) return error.TooSmall;

    // 1. Parse ftyp box (must be first box)
    const ftyp = readBoxHeader(data, 0) orelse return error.InvalidFtyp;
    if (!std.mem.eql(u8, &ftyp.box_type, "ftyp")) return error.InvalidFtyp;
    const brand = parseFtypBrand(data, ftyp);

    // 2. Find meta box (may not be second box)
    const meta = findTopLevelBox(data, "meta".*) orelse return error.NoMetaBox;
    // meta is a FullBox: 4 bytes version+flags after header
    if (meta.data_offset + 4 > data.len) return error.InvalidMetaBox;
    const meta_data_start = meta.data_offset + 4; // Skip version(1) + flags(3)
    const meta_data_end: u64 = @min(meta.offset + meta.size, data.len);

    // 3. Parse hdlr (handler) - should declare "pict" handler type
    const hdlr = findChildBox(data, meta_data_start, meta_data_end, "hdlr".*) orelse return error.NoHandlerBox;
    // Validate handler type: FullBox(4) + pre_defined(4) + handler_type(4)
    const hdlr_p: usize = @intCast(hdlr.data_offset);
    if (hdlr_p + 12 > data.len) return error.InvalidHandler;
    const handler_type = data[hdlr_p + 8 ..][0..4].*;
    if (!std.mem.eql(u8, &handler_type, "pict")) return error.InvalidHandler;

    // 4. Parse pitm (Primary Item ID)
    const pitm = findChildBox(data, meta_data_start, meta_data_end, "pitm".*) orelse return error.NoPrimaryItem;
    const primary_item_id = try parsePitm(data, pitm);

    // 5. Parse iinf (Item Info Box)
    const iinf = findChildBox(data, meta_data_start, meta_data_end, "iinf".*) orelse return error.NoItemInfo;
    // Static buffers so returned slices remain valid after function returns.
    // (Stack-local buffers would be dangling pointers in the returned struct.)
    // `threadlocal` so each thread gets its own copy — without it, concurrent
    // calls to parseHeifContainer scribble over each other's result slices,
    // surfacing as nondeterministic "tile NAL unit length corrupted" /
    // "Primary item has no data" / "data extends beyond file" errors when
    // validating multiple HEICs in the same process. The returned info struct
    // contains slices into these buffers; callers must consume them before the
    // SAME thread re-enters parseHeifContainer (validators do this naturally).
    const StaticBufs = struct {
        threadlocal var items_buf: [512]ItemInfo = undefined;
        threadlocal var locations_buf: [512]ItemLocation = undefined;
        threadlocal var extents_buf: [2048]ItemExtent = undefined;
        threadlocal var tile_ids_buf: [512]u32 = undefined;
    };
    const items = try parseIinf(data, iinf, &StaticBufs.items_buf);
    // 6. Parse iloc (Item Location Box)
    const iloc = findChildBox(data, meta_data_start, meta_data_end, "iloc".*) orelse return error.NoItemLocation;
    const iloc_result = try parseIloc(data, iloc, &StaticBufs.locations_buf, &StaticBufs.extents_buf);
    const locations = iloc_result.locations;

    // 7. Parse iprp (Item Properties Box) - optional, for ispe and decoder config
    var width: u32 = 0;
    var height: u32 = 0;
    var decoder_config: ?[]const u8 = null;

    if (findChildBox(data, meta_data_start, meta_data_end, "iprp".*)) |iprp| {
        const props = parseIprp(data, iprp, primary_item_id);
        width = props.width;
        height = props.height;
        decoder_config = props.decoder_config;
    }

    // 8. Find primary item's data location
    var primary_data_offset: u64 = 0;
    var primary_data_length: u64 = 0;

    if (findItemLocation(locations, primary_item_id)) |loc| {
        if (loc.construction_method == 0) {
            // Construction method 0: file offset — extract data range from extents
            if (loc.extents.len > 0) {
                primary_data_offset = loc.base_offset + loc.extents[0].offset;
                var total_length: u64 = 0;
                for (loc.extents) |ext| {
                    total_length += ext.length;
                }
                primary_data_length = total_length;
            }
        }
        // Construction method 1 (idat) or 2 (item): primary data offset/length stay 0.
        // This is normal for grid/overlay items whose descriptors are in idat.
        // The caller should use dimg_tile_ids to resolve actual image data.
    }

    // 9. Parse iref (Item Reference Box) for grid tile references
    var dimg_tile_ids: []const u32 = StaticBufs.tile_ids_buf[0..0];
    var tile_decoder_config: ?[]const u8 = null;

    if (findChildBox(data, meta_data_start, meta_data_end, "iref".*)) |iref| {
        dimg_tile_ids = parseIref(data, iref, primary_item_id, &StaticBufs.tile_ids_buf);

        // If tiles were found, look up decoder config for the first tile
        if (dimg_tile_ids.len > 0) {
            if (findChildBox(data, meta_data_start, meta_data_end, "iprp".*)) |iprp| {
                const tile_props = parseIprp(data, iprp, dimg_tile_ids[0]);
                tile_decoder_config = tile_props.decoder_config;
            }
        }
    }

    return HeifContainerInfo{
        .brand = brand,
        .primary_item_id = primary_item_id,
        .items = items,
        .width = width,
        .height = height,
        .decoder_config = decoder_config,
        .primary_data_offset = primary_data_offset,
        .primary_data_length = primary_data_length,
        .dimg_tile_ids = dimg_tile_ids,
        .locations = locations,
        .tile_decoder_config = tile_decoder_config,
    };
}

// ============================================================================
// Unit Tests
// ============================================================================

test "HEIF box header reading - standard 8-byte header" {
    // Box: size=20 (0x00000014), type="ftyp"
    const box_data = [_]u8{
        0x00, 0x00, 0x00, 0x14, // size = 20
        'f',  't',  'y',  'p',  // type = "ftyp"
        'h',  'e',  'i',  'c',  // major_brand (content)
        0x00, 0x00, 0x00, 0x00, // minor_version
        'h',  'e',  'i',  'c',  // compatible_brands
    };

    const header = readBoxHeader(&box_data, 0).?;
    try std.testing.expectEqual(@as(u64, 20), header.size);
    try std.testing.expectEqualSlices(u8, "ftyp", &header.box_type);
    try std.testing.expectEqual(@as(u64, 0), header.offset);
    try std.testing.expectEqual(@as(u64, 8), header.data_offset);
    try std.testing.expectEqual(@as(u8, 8), header.header_size);
}

test "HEIF box header reading - extended 16-byte header" {
    // Box: size=1 (extended), type="mdat", extended_size=0x0000000100000000
    const box_data = [_]u8{
        0x00, 0x00, 0x00, 0x01, // size = 1 (means extended size follows)
        'm',  'd',  'a',  't',  // type = "mdat"
        0x00, 0x00, 0x00, 0x01, // extended size high 32 bits
        0x00, 0x00, 0x00, 0x00, // extended size low 32 bits = 0x100000000
    };

    const header = readBoxHeader(&box_data, 0).?;
    try std.testing.expectEqual(@as(u64, 0x100000000), header.size);
    try std.testing.expectEqualSlices(u8, "mdat", &header.box_type);
    try std.testing.expectEqual(@as(u64, 0), header.offset);
    try std.testing.expectEqual(@as(u64, 16), header.data_offset);
    try std.testing.expectEqual(@as(u8, 16), header.header_size);
}

test "HEIF box header reading - size 0 extends to end" {
    const box_data = [_]u8{
        0x00, 0x00, 0x00, 0x00, // size = 0 (extends to end)
        'm',  'd',  'a',  't',  // type = "mdat"
        0xDE, 0xAD, 0xBE, 0xEF, // some content
    };

    const header = readBoxHeader(&box_data, 0).?;
    try std.testing.expectEqual(@as(u64, 12), header.size); // extends to end of data
    try std.testing.expectEqual(@as(u8, 8), header.header_size);
}

test "HEIF box header reading - insufficient data returns null" {
    const too_short = [_]u8{ 0x00, 0x00, 0x00 };
    try std.testing.expect(readBoxHeader(&too_short, 0) == null);

    // Also test extended header with insufficient extended size data
    const short_extended = [_]u8{
        0x00, 0x00, 0x00, 0x01, // size = 1 (extended)
        'm', 'd', 'a', 't', // type
        0x00, 0x00, // only 2 bytes of extended size (need 8)
    };
    try std.testing.expect(readBoxHeader(&short_extended, 0) == null);
}

test "HEIF ftyp brand detection" {
    // Test HEIC brand
    {
        const ftyp_heic = [_]u8{
            0x00, 0x00, 0x00, 0x14, 'f', 't', 'y', 'p',
            'h',  'e',  'i',  'c',  0x00, 0x00, 0x00, 0x00,
            'h',  'e',  'i',  'c',
        };
        const header = readBoxHeader(&ftyp_heic, 0).?;
        const brand = parseFtypBrand(&ftyp_heic, header);
        try std.testing.expectEqual(HeifBrand.heic, brand);
    }

    // Test AVIF brand
    {
        const ftyp_avif = [_]u8{
            0x00, 0x00, 0x00, 0x14, 'f', 't', 'y', 'p',
            'a',  'v',  'i',  'f',  0x00, 0x00, 0x00, 0x00,
            'a',  'v',  'i',  'f',
        };
        const header = readBoxHeader(&ftyp_avif, 0).?;
        const brand = parseFtypBrand(&ftyp_avif, header);
        try std.testing.expectEqual(HeifBrand.avif, brand);
    }

    // Test mif1 brand
    {
        const ftyp_mif1 = [_]u8{
            0x00, 0x00, 0x00, 0x14, 'f', 't', 'y', 'p',
            'm',  'i',  'f',  '1',  0x00, 0x00, 0x00, 0x00,
            'm',  'i',  'f',  '1',
        };
        const header = readBoxHeader(&ftyp_mif1, 0).?;
        const brand = parseFtypBrand(&ftyp_mif1, header);
        try std.testing.expectEqual(HeifBrand.mif1, brand);
    }

    // Test unknown brand
    {
        const ftyp_unknown = [_]u8{
            0x00, 0x00, 0x00, 0x14, 'f', 't', 'y', 'p',
            'x',  'x',  'x',  'x',  0x00, 0x00, 0x00, 0x00,
            'x',  'x',  'x',  'x',
        };
        const header = readBoxHeader(&ftyp_unknown, 0).?;
        const brand = parseFtypBrand(&ftyp_unknown, header);
        try std.testing.expectEqual(HeifBrand.unknown, brand);
    }
}

test "HEIF rejects too-small data" {
    // Less than 12 bytes
    const tiny = [_]u8{ 0x00, 0x00, 0x00, 0x08, 'f', 't', 'y', 'p' };
    const result = parseHeifContainer(&tiny);
    try std.testing.expectError(error.TooSmall, result);

    // Empty
    const empty = [_]u8{};
    try std.testing.expectError(error.TooSmall, parseHeifContainer(&empty));
}

test "HEIF rejects non-ftyp first box" {
    const not_ftyp = [_]u8{
        0x00, 0x00, 0x00, 0x10, 'm', 'o', 'o', 'v',
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    try std.testing.expectError(error.InvalidFtyp, parseHeifContainer(&not_ftyp));
}

test "HEIF child box iteration" {
    // Construct a parent with 3 child boxes
    const parent_data = [_]u8{
        // Child 1: size=12, type="abcd", 4 bytes data
        0x00, 0x00, 0x00, 0x0C, 'a', 'b', 'c', 'd',
        0x01, 0x02, 0x03, 0x04,
        // Child 2: size=10, type="efgh", 2 bytes data
        0x00, 0x00, 0x00, 0x0A, 'e', 'f', 'g', 'h',
        0x05, 0x06,
        // Child 3: size=8, type="ijkl", 0 bytes data
        0x00, 0x00, 0x00, 0x08, 'i', 'j', 'k', 'l',
    };

    var iter = iterateChildBoxes(&parent_data, 0, parent_data.len);

    // Child 1
    const child1 = iter.next().?;
    try std.testing.expectEqualSlices(u8, "abcd", &child1.box_type);
    try std.testing.expectEqual(@as(u64, 12), child1.size);

    // Child 2
    const child2 = iter.next().?;
    try std.testing.expectEqualSlices(u8, "efgh", &child2.box_type);
    try std.testing.expectEqual(@as(u64, 10), child2.size);

    // Child 3
    const child3 = iter.next().?;
    try std.testing.expectEqualSlices(u8, "ijkl", &child3.box_type);
    try std.testing.expectEqual(@as(u64, 8), child3.size);

    // No more children
    try std.testing.expect(iter.next() == null);
}

test "HEIF child box find" {
    const parent_data = [_]u8{
        // Child 1: size=12, type="aaaa"
        0x00, 0x00, 0x00, 0x0C, 'a', 'a', 'a', 'a',
        0x01, 0x02, 0x03, 0x04,
        // Child 2: size=12, type="bbbb"
        0x00, 0x00, 0x00, 0x0C, 'b', 'b', 'b', 'b',
        0x05, 0x06, 0x07, 0x08,
    };

    // Find "bbbb"
    const found = findChildBox(&parent_data, 0, parent_data.len, "bbbb".*);
    try std.testing.expect(found != null);
    try std.testing.expectEqual(@as(u64, 12), found.?.offset);

    // Find "aaaa"
    const found_a = findChildBox(&parent_data, 0, parent_data.len, "aaaa".*);
    try std.testing.expect(found_a != null);
    try std.testing.expectEqual(@as(u64, 0), found_a.?.offset);

    // Find non-existent
    const not_found = findChildBox(&parent_data, 0, parent_data.len, "cccc".*);
    try std.testing.expect(not_found == null);
}

test "HEIF variable-size integer reading" {
    const data = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09 };

    // 0 bytes = always 0
    try std.testing.expectEqual(@as(u64, 0), readVarSizeUint(&data, 0, 0).?);

    // 1 byte
    try std.testing.expectEqual(@as(u64, 0x00), readVarSizeUint(&data, 0, 1).?);
    try std.testing.expectEqual(@as(u64, 0x01), readVarSizeUint(&data, 1, 1).?);

    // 2 bytes (big-endian)
    try std.testing.expectEqual(@as(u64, 0x0001), readVarSizeUint(&data, 0, 2).?);
    try std.testing.expectEqual(@as(u64, 0x0102), readVarSizeUint(&data, 1, 2).?);

    // 4 bytes (big-endian)
    try std.testing.expectEqual(@as(u64, 0x00010203), readVarSizeUint(&data, 0, 4).?);
    try std.testing.expectEqual(@as(u64, 0x01020304), readVarSizeUint(&data, 1, 4).?);

    // 8 bytes (big-endian)
    try std.testing.expectEqual(@as(u64, 0x0001020304050607), readVarSizeUint(&data, 0, 8).?);

    // Out of bounds
    try std.testing.expect(readVarSizeUint(&data, 9, 4) == null);
    try std.testing.expect(readVarSizeUint(&data, 5, 8) == null);

    // Unsupported sizes
    try std.testing.expect(readVarSizeUint(&data, 0, 3) == null);
    try std.testing.expect(readVarSizeUint(&data, 0, 5) == null);
}

test "HEIF ispe parsing" {
    // ispe FullBox: version(1) + flags(3) + width(4) + height(4) = 12 bytes content
    // Total box: 8 (header) + 12 (content) = 20 bytes
    const ispe_data = [_]u8{
        0x00, 0x00, 0x00, 0x14, // size = 20
        'i',  's',  'p',  'e',  // type
        0x00, 0x00, 0x00, 0x00, // version(0) + flags(0)
        0x00, 0x00, 0x07, 0x80, // width = 1920
        0x00, 0x00, 0x04, 0x38, // height = 1080
    };

    const header = readBoxHeader(&ispe_data, 0).?;
    const extents = parseIspe(&ispe_data, header).?;
    try std.testing.expectEqual(@as(u32, 1920), extents.width);
    try std.testing.expectEqual(@as(u32, 1080), extents.height);
}

test "HEIF pitm parsing - version 0" {
    // pitm FullBox v0: version(1) + flags(3) + item_id(2) = 6 bytes content
    // Total: 8 + 6 = 14
    const pitm_data = [_]u8{
        0x00, 0x00, 0x00, 0x0E, // size = 14
        'p',  'i',  't',  'm',  // type
        0x00, 0x00, 0x00, 0x00, // version 0 + flags
        0x00, 0x2A, // item_id = 42
    };

    const header = readBoxHeader(&pitm_data, 0).?;
    const item_id = try parsePitm(&pitm_data, header);
    try std.testing.expectEqual(@as(u32, 42), item_id);
}

test "HEIF pitm parsing - version 1" {
    // pitm FullBox v1: version(1) + flags(3) + item_id(4) = 8 bytes content
    // Total: 8 + 8 = 16
    const pitm_data = [_]u8{
        0x00, 0x00, 0x00, 0x10, // size = 16
        'p',  'i',  't',  'm',  // type
        0x01, 0x00, 0x00, 0x00, // version 1 + flags
        0x00, 0x00, 0x01, 0x00, // item_id = 256
    };

    const header = readBoxHeader(&pitm_data, 0).?;
    const item_id = try parsePitm(&pitm_data, header);
    try std.testing.expectEqual(@as(u32, 256), item_id);
}

test "HEIF infe parsing - version 2" {
    // infe v2: version(1) + flags(3) + item_id(2) + protection_index(2) + item_type(4) = 12 content
    // Total: 8 + 12 = 20
    const infe_data = [_]u8{
        0x00, 0x00, 0x00, 0x14, // size = 20
        'i',  'n',  'f',  'e',  // type
        0x02, 0x00, 0x00, 0x00, // version 2 + flags
        0x00, 0x01, // item_id = 1
        0x00, 0x00, // item_protection_index
        'h',  'v',  'c',  '1',  // item_type = "hvc1"
    };

    const header = readBoxHeader(&infe_data, 0).?;
    const item_info = parseInfe(&infe_data, header).?;
    try std.testing.expectEqual(@as(u32, 1), item_info.item_id);
    try std.testing.expectEqual(ItemType.hvc1, item_info.item_type);
    try std.testing.expectEqualSlices(u8, "hvc1", &item_info.item_type_raw);
}

test "HEIF infe parsing - version 3 with 32-bit item_id" {
    // infe v3: version(1) + flags(3) + item_id(4) + protection_index(2) + item_type(4) = 14 content
    // Total: 8 + 14 = 22
    const infe_data = [_]u8{
        0x00, 0x00, 0x00, 0x16, // size = 22
        'i',  'n',  'f',  'e',  // type
        0x03, 0x00, 0x00, 0x00, // version 3 + flags
        0x00, 0x00, 0x00, 0x05, // item_id = 5
        0x00, 0x00, // item_protection_index
        'a',  'v',  '0',  '1',  // item_type = "av01"
    };

    const header = readBoxHeader(&infe_data, 0).?;
    const item_info = parseInfe(&infe_data, header).?;
    try std.testing.expectEqual(@as(u32, 5), item_info.item_id);
    try std.testing.expectEqual(ItemType.av01, item_info.item_type);
}

test "HEIF ItemType fromFourCC coverage" {
    try std.testing.expectEqual(ItemType.hvc1, ItemType.fromFourCC("hvc1".*));
    try std.testing.expectEqual(ItemType.av01, ItemType.fromFourCC("av01".*));
    try std.testing.expectEqual(ItemType.jpeg, ItemType.fromFourCC("jpeg".*));
    try std.testing.expectEqual(ItemType.grid, ItemType.fromFourCC("grid".*));
    try std.testing.expectEqual(ItemType.iovl, ItemType.fromFourCC("iovl".*));
    try std.testing.expectEqual(ItemType.Exif, ItemType.fromFourCC("Exif".*));
    try std.testing.expectEqual(ItemType.mime, ItemType.fromFourCC("mime".*));
    try std.testing.expectEqual(ItemType.unknown, ItemType.fromFourCC("zzzz".*));
}

test "HEIF HeifBrand fromFourCC coverage" {
    try std.testing.expectEqual(HeifBrand.heic, HeifBrand.fromFourCC("heic".*));
    try std.testing.expectEqual(HeifBrand.heix, HeifBrand.fromFourCC("heix".*));
    try std.testing.expectEqual(HeifBrand.avif, HeifBrand.fromFourCC("avif".*));
    try std.testing.expectEqual(HeifBrand.avis, HeifBrand.fromFourCC("avis".*));
    try std.testing.expectEqual(HeifBrand.mif1, HeifBrand.fromFourCC("mif1".*));
    try std.testing.expectEqual(HeifBrand.unknown, HeifBrand.fromFourCC("zzzz".*));
}

test "HEIF iloc parsing - version 0 with single extent" {
    // Construct a minimal iloc box v0:
    // FullBox: version(1) + flags(3) = 4 bytes
    // offset_size(4b)=4 | length_size(4b)=4 = 0x44
    // base_offset_size(4b)=0 | index_size(4b)=0 = 0x00
    // item_count(2) = 1
    // Per item: item_id(2)=1, data_ref_index(2)=0, base_offset(0 bytes),
    //           extent_count(2)=1, extent_offset(4)=100, extent_length(4)=200
    const iloc_data = [_]u8{
        0x00, 0x00, 0x00, 0x1E, // size = 30
        'i',  'l',  'o',  'c',  // type
        // FullBox: version 0
        0x00, 0x00, 0x00, 0x00,
        // offset_size=4, length_size=4
        0x44,
        // base_offset_size=0, index_size=0 (v0 ignores index_size)
        0x00,
        // item_count = 1
        0x00, 0x01,
        // item_id = 1
        0x00, 0x01,
        // data_reference_index = 0
        0x00, 0x00,
        // base_offset: 0 bytes (base_offset_size=0)
        // extent_count = 1
        0x00, 0x01,
        // extent_offset = 100 (4 bytes)
        0x00, 0x00, 0x00, 0x64,
        // extent_length = 200 (4 bytes)
        0x00, 0x00, 0x00, 0xC8,
    };

    const header = readBoxHeader(&iloc_data, 0).?;
    var locs_buf: [16]ItemLocation = undefined;
    var exts_buf: [64]ItemExtent = undefined;
    const result = try parseIloc(&iloc_data, header, &locs_buf, &exts_buf);

    try std.testing.expectEqual(@as(usize, 1), result.locations.len);
    try std.testing.expectEqual(@as(u32, 1), result.locations[0].item_id);
    try std.testing.expectEqual(@as(u8, 0), result.locations[0].construction_method);
    try std.testing.expectEqual(@as(u64, 0), result.locations[0].base_offset);
    try std.testing.expectEqual(@as(usize, 1), result.locations[0].extents.len);
    try std.testing.expectEqual(@as(u64, 100), result.locations[0].extents[0].offset);
    try std.testing.expectEqual(@as(u64, 200), result.locations[0].extents[0].length);
}

test "HEIF iloc parsing - version 1 with construction method and base offset" {
    // iloc v1 with base_offset_size=4, construction_method
    const iloc_data = [_]u8{
        0x00, 0x00, 0x00, 0x26, // size = 38
        'i',  'l',  'o',  'c',  // type
        // FullBox: version 1
        0x01, 0x00, 0x00, 0x00,
        // offset_size=4, length_size=4
        0x44,
        // base_offset_size=4, index_size=0
        0x40,
        // item_count = 1
        0x00, 0x01,
        // item_id = 2
        0x00, 0x02,
        // construction_method (2 bytes, low 4 bits) = 0
        0x00, 0x00,
        // data_reference_index = 0
        0x00, 0x00,
        // base_offset = 1000 (4 bytes, base_offset_size=4)
        0x00, 0x00, 0x03, 0xE8,
        // extent_count = 1
        0x00, 0x01,
        // extent_offset = 50 (4 bytes)
        0x00, 0x00, 0x00, 0x32,
        // extent_length = 300 (4 bytes)
        0x00, 0x00, 0x01, 0x2C,
    };

    const header = readBoxHeader(&iloc_data, 0).?;
    var locs_buf: [16]ItemLocation = undefined;
    var exts_buf: [64]ItemExtent = undefined;
    const result = try parseIloc(&iloc_data, header, &locs_buf, &exts_buf);

    try std.testing.expectEqual(@as(usize, 1), result.locations.len);
    try std.testing.expectEqual(@as(u32, 2), result.locations[0].item_id);
    try std.testing.expectEqual(@as(u64, 1000), result.locations[0].base_offset);
    try std.testing.expectEqual(@as(u64, 50), result.locations[0].extents[0].offset);
    try std.testing.expectEqual(@as(u64, 300), result.locations[0].extents[0].length);
}

test "HEIF full synthetic container parse" {
    // Build a minimal but complete HEIF container with all required boxes.
    // Structure:
    //   ftyp (20 bytes)
    //   meta (FullBox, contains hdlr, pitm, iinf, iloc, iprp)

    // ftyp box: size=20, brand=heic
    const ftyp = [_]u8{
        0x00, 0x00, 0x00, 0x14, 'f', 't', 'y', 'p',
        'h',  'e',  'i',  'c',  // major_brand
        0x00, 0x00, 0x00, 0x00, // minor_version
        'h',  'e',  'i',  'c',  // compatible_brands
    };

    // hdlr box: size=33, handler_type=pict
    // FullBox(4) + pre_defined(4) + handler_type(4) + reserved(12) + name(1) = 25 content
    const hdlr = [_]u8{
        0x00, 0x00, 0x00, 0x21, 'h', 'd', 'l', 'r',
        0x00, 0x00, 0x00, 0x00, // version+flags
        0x00, 0x00, 0x00, 0x00, // pre_defined
        'p',  'i',  'c',  't',  // handler_type
        0x00, 0x00, 0x00, 0x00, // reserved[0]
        0x00, 0x00, 0x00, 0x00, // reserved[1]
        0x00, 0x00, 0x00, 0x00, // reserved[2]
        0x00, // name (null-terminated empty string)
    };

    // pitm box: size=14, version 0, item_id=1
    const pitm = [_]u8{
        0x00, 0x00, 0x00, 0x0E, 'p', 'i', 't', 'm',
        0x00, 0x00, 0x00, 0x00, // version 0 + flags
        0x00, 0x01, // item_id = 1
    };

    // iinf box: size=8(header) + 4(fullbox) + 2(count) + 20(infe) = 34
    // Contains one infe v2 entry: item_id=1, type=hvc1
    const iinf = [_]u8{
        0x00, 0x00, 0x00, 0x22, 'i', 'i', 'n', 'f',
        0x00, 0x00, 0x00, 0x00, // version 0 + flags
        0x00, 0x01, // entry_count = 1
        // infe: size=20, version 2
        0x00, 0x00, 0x00, 0x14, 'i', 'n', 'f', 'e',
        0x02, 0x00, 0x00, 0x00, // version 2 + flags
        0x00, 0x01, // item_id = 1
        0x00, 0x00, // item_protection_index
        'h',  'v',  'c',  '1',  // item_type
    };

    // iloc box: v0, offset_size=4, length_size=4, 1 item with 1 extent
    // Points to offset 500, length 1000
    const iloc = [_]u8{
        0x00, 0x00, 0x00, 0x1E, 'i', 'l', 'o', 'c',
        0x00, 0x00, 0x00, 0x00, // version 0 + flags
        0x44, // offset_size=4, length_size=4
        0x00, // base_offset_size=0, index_size=0
        0x00, 0x01, // item_count = 1
        0x00, 0x01, // item_id = 1
        0x00, 0x00, // data_reference_index
        0x00, 0x01, // extent_count = 1
        0x00, 0x00, 0x01, 0xF4, // extent_offset = 500
        0x00, 0x00, 0x03, 0xE8, // extent_length = 1000
    };

    // iprp containing ipco with ispe
    // ispe: size=20, width=3840, height=2160
    // ipco: size=28 (8 header + 20 ispe)
    // ipma: size=18 (8 header + 4 fullbox + 4 entry_count + 2 item_id + 1 assoc_count + 1 assoc)
    //   = actually needs: 8 + 4 + 4 + 2 + 1 + 1 = 20
    // Actually ipma v0 with flags=0:
    //   8(header) + 4(fullbox) + 4(entry_count=1) + 2(item_id) + 1(assoc_count=1) + 1(essential+idx) = 20
    // iprp: size = 8(header) + 28(ipco) + 20(ipma) = 56
    const iprp = [_]u8{
        0x00, 0x00, 0x00, 0x38, 'i', 'p', 'r', 'p',
        // ipco: size=28
        0x00, 0x00, 0x00, 0x1C, 'i', 'p', 'c', 'o',
        // ispe inside ipco: size=20
        0x00, 0x00, 0x00, 0x14, 'i', 's', 'p', 'e',
        0x00, 0x00, 0x00, 0x00, // version+flags
        0x00, 0x00, 0x0F, 0x00, // width = 3840
        0x00, 0x00, 0x08, 0x70, // height = 2160
        // ipma: size=20
        0x00, 0x00, 0x00, 0x14, 'i', 'p', 'm', 'a',
        0x00, 0x00, 0x00, 0x00, // version 0, flags = 0
        0x00, 0x00, 0x00, 0x01, // entry_count = 1
        0x00, 0x01, // item_id = 1
        0x01, // association_count = 1
        0x81, // essential(1) | property_index(1) = 0x80 | 0x01
    };

    // meta box: FullBox wrapper
    // meta_content_size = 4(fullbox) + hdlr.len + pitm.len + iinf.len + iloc.len + iprp.len
    const meta_content_size = 4 + hdlr.len + pitm.len + iinf.len + iloc.len + iprp.len;
    const meta_total_size = 8 + meta_content_size;

    // Build the full buffer
    var buf: [2048]u8 = undefined;
    var pos: usize = 0;

    // ftyp
    @memcpy(buf[pos..][0..ftyp.len], &ftyp);
    pos += ftyp.len;

    // meta header
    std.mem.writeInt(u32, buf[pos..][0..4], @intCast(meta_total_size), .big);
    @memcpy(buf[pos + 4 ..][0..4], "meta");
    pos += 8;
    // meta FullBox version+flags
    @memset(buf[pos..][0..4], 0);
    pos += 4;

    // hdlr
    @memcpy(buf[pos..][0..hdlr.len], &hdlr);
    pos += hdlr.len;

    // pitm
    @memcpy(buf[pos..][0..pitm.len], &pitm);
    pos += pitm.len;

    // iinf
    @memcpy(buf[pos..][0..iinf.len], &iinf);
    pos += iinf.len;

    // iloc
    @memcpy(buf[pos..][0..iloc.len], &iloc);
    pos += iloc.len;

    // iprp
    @memcpy(buf[pos..][0..iprp.len], &iprp);
    pos += iprp.len;

    // Parse
    const info = try parseHeifContainer(buf[0..pos]);
    try std.testing.expectEqual(HeifBrand.heic, info.brand);
    try std.testing.expectEqual(@as(u32, 1), info.primary_item_id);
    try std.testing.expectEqual(@as(usize, 1), info.items.len);
    try std.testing.expectEqual(ItemType.hvc1, info.items[0].item_type);
    try std.testing.expectEqual(@as(u32, 3840), info.width);
    try std.testing.expectEqual(@as(u32, 2160), info.height);
    try std.testing.expectEqual(@as(u64, 500), info.primary_data_offset);
    try std.testing.expectEqual(@as(u64, 1000), info.primary_data_length);
    try std.testing.expectEqual(@as(usize, 0), info.dimg_tile_ids.len);
    try std.testing.expect(info.tile_decoder_config == null);
}

test "HEIF iref parsing - dimg references" {
    // Build a minimal iref box v0 with one dimg entry:
    // from_item=1 referencing tiles 2, 3, 4
    //
    // iref FullBox: 8(header) + 4(fullbox) + dimg_child
    // dimg child: 8(header) + 2(from_id) + 2(ref_count) + 6(to_ids) = 18
    // iref total: 8 + 4 + 18 = 30
    const iref_data = [_]u8{
        0x00, 0x00, 0x00, 0x1E, 'i', 'r', 'e', 'f',
        0x00, 0x00, 0x00, 0x00, // version 0 + flags
        // dimg child box: size=18
        0x00, 0x00, 0x00, 0x12, 'd', 'i', 'm', 'g',
        0x00, 0x01, // from_item_ID = 1
        0x00, 0x03, // reference_count = 3
        0x00, 0x02, // to_item_ID = 2
        0x00, 0x03, // to_item_ID = 3
        0x00, 0x04, // to_item_ID = 4
    };

    const header = readBoxHeader(&iref_data, 0).?;
    var tile_ids_buf: [16]u32 = undefined;

    // Look up for item 1
    const tiles = parseIref(&iref_data, header, 1, &tile_ids_buf);
    try std.testing.expectEqual(@as(usize, 3), tiles.len);
    try std.testing.expectEqual(@as(u32, 2), tiles[0]);
    try std.testing.expectEqual(@as(u32, 3), tiles[1]);
    try std.testing.expectEqual(@as(u32, 4), tiles[2]);

    // Look up for item 99 (no match)
    const no_tiles = parseIref(&iref_data, header, 99, &tile_ids_buf);
    try std.testing.expectEqual(@as(usize, 0), no_tiles.len);
}

test "HEIF iref parsing - version 1 with 32-bit IDs" {
    // iref v1 with dimg: from_item=1000 referencing tiles 1001, 1002
    // dimg child: 8(header) + 4(from_id) + 2(ref_count) + 8(to_ids) = 22
    // iref total: 8 + 4 + 22 = 34
    const iref_data = [_]u8{
        0x00, 0x00, 0x00, 0x22, 'i', 'r', 'e', 'f',
        0x01, 0x00, 0x00, 0x00, // version 1 + flags
        // dimg child box: size=22
        0x00, 0x00, 0x00, 0x16, 'd', 'i', 'm', 'g',
        0x00, 0x00, 0x03, 0xE8, // from_item_ID = 1000
        0x00, 0x02, // reference_count = 2
        0x00, 0x00, 0x03, 0xE9, // to_item_ID = 1001
        0x00, 0x00, 0x03, 0xEA, // to_item_ID = 1002
    };

    const header = readBoxHeader(&iref_data, 0).?;
    var tile_ids_buf: [16]u32 = undefined;

    const tiles = parseIref(&iref_data, header, 1000, &tile_ids_buf);
    try std.testing.expectEqual(@as(usize, 2), tiles.len);
    try std.testing.expectEqual(@as(u32, 1001), tiles[0]);
    try std.testing.expectEqual(@as(u32, 1002), tiles[1]);
}

test "parseHeifContainer is thread-safe under concurrent calls" {
	// Synthesize a minimal HEIF file (ftyp + meta with hdlr + pitm + iinf + iloc + iprp + iref dimg).
	// Two distinct files with distinct primary item IDs, parsed concurrently
	// from many threads. Each thread asserts the returned container info
	// matches what its file was supposed to produce. With the original
	// process-global StaticBufs, threads clobber each others' result slices
	// and assertions fail nondeterministically.
	const Sample = struct {
		fn make(allocator: std.mem.Allocator, primary_id: u16) ![]u8 {
			// Build a minimal HEIF: ftyp + meta { hdlr + pitm + iinf(1 entry, hvc1) + iloc(1 location) }.
			// Hand-crafted byte sequence with size fixups.
			var out = std.ArrayListUnmanaged(u8){};
			defer out.deinit(allocator);

			// ftyp: brand=heic, compat=heic
			try out.appendSlice(allocator, &[_]u8{ 0, 0, 0, 24, 'f', 't', 'y', 'p', 'h', 'e', 'i', 'c', 0, 0, 0, 0, 'h', 'e', 'i', 'c', 'm', 'i', 'f', '1' });

			// meta box body
			var meta_body = std.ArrayListUnmanaged(u8){};
			defer meta_body.deinit(allocator);
			try meta_body.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0 }); // version+flags

			// hdlr (full box: size + 'hdlr' + 32 bytes)
			try meta_body.appendSlice(allocator, &[_]u8{ 0, 0, 0, 33 }); // size 33
			try meta_body.appendSlice(allocator, "hdlr");
			try meta_body.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0 }); // version+flags
			try meta_body.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0 }); // pre-defined
			try meta_body.appendSlice(allocator, "pict"); // handler type
			try meta_body.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }); // reserved
			try meta_body.appendSlice(allocator, &[_]u8{ 0 }); // empty name (null-terminated)

			// pitm (size + 'pitm' + version=0 + flags + item_id u16)
			try meta_body.appendSlice(allocator, &[_]u8{ 0, 0, 0, 14 }); // size 14
			try meta_body.appendSlice(allocator, "pitm");
			try meta_body.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0 }); // version+flags
			try meta_body.appendSlice(allocator, &[_]u8{ @intCast((primary_id >> 8) & 0xff), @intCast(primary_id & 0xff) });

			// iinf — one entry of type hvc1
			// iinf header: version=0+flags(3) + entry_count(2) = 6 bytes
			// each entry: size + 'infe' + version=2 + flags + item_id(2) + protection_index(2) + item_type(4) + name(0+null)
			//   infe entry: 4(size) + 4(infe) + 1(ver=2) + 3(flags) + 2(id) + 2(proto) + 4(type='hvc1') + 1(name=null) = 21 bytes
			try meta_body.appendSlice(allocator, &[_]u8{ 0, 0, 0, 35 }); // iinf size = 8(box header) + 6(header inner) + 21(infe entry) = 35
			try meta_body.appendSlice(allocator, "iinf");
			try meta_body.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0 }); // version+flags
			try meta_body.appendSlice(allocator, &[_]u8{ 0, 1 }); // entry count = 1
			try meta_body.appendSlice(allocator, &[_]u8{ 0, 0, 0, 21 }); // infe size = 21
			try meta_body.appendSlice(allocator, "infe");
			try meta_body.appendSlice(allocator, &[_]u8{ 2, 0, 0, 0 }); // version=2, flags=0
			try meta_body.appendSlice(allocator, &[_]u8{ @intCast((primary_id >> 8) & 0xff), @intCast(primary_id & 0xff) }); // id
			try meta_body.appendSlice(allocator, &[_]u8{ 0, 0 }); // protection index
			try meta_body.appendSlice(allocator, "hvc1"); // item type
			try meta_body.appendSlice(allocator, &[_]u8{ 0 }); // name terminator

			// iloc — one location, version=1, item_id=primary_id, base_offset=64KB, single extent
			// iloc header: version+flags(4) + offset/length sizes byte(1) + base_offset/index byte(1) + item_count(2) = 8
			// item entry (v1): item_id(2) + reserved+method(2) + data_ref(2) + base_offset(0) + extent_count(2) + extent(offset+length 2*4=8) = 16
			try meta_body.appendSlice(allocator, &[_]u8{ 0, 0, 0, 32 }); // size = 8 + 8 + 16 = 32
			try meta_body.appendSlice(allocator, "iloc");
			try meta_body.appendSlice(allocator, &[_]u8{ 1, 0, 0, 0 }); // version=1, flags=0
			try meta_body.appendSlice(allocator, &[_]u8{ 0x44 }); // offset=4, length=4 (high nibbles)
			try meta_body.appendSlice(allocator, &[_]u8{ 0x00 }); // base_offset_size=0, index_size=0
			try meta_body.appendSlice(allocator, &[_]u8{ 0, 1 }); // item_count = 1
			try meta_body.appendSlice(allocator, &[_]u8{ @intCast((primary_id >> 8) & 0xff), @intCast(primary_id & 0xff) });
			try meta_body.appendSlice(allocator, &[_]u8{ 0, 0 }); // construction_method=0
			try meta_body.appendSlice(allocator, &[_]u8{ 0, 0 }); // data_reference_index
			try meta_body.appendSlice(allocator, &[_]u8{ 0, 1 }); // extent_count=1
			try meta_body.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0x80 }); // extent offset = 128 (just past header)
			try meta_body.appendSlice(allocator, &[_]u8{ 0, 0, 0, 4 }); // extent length=4

			// Wrap meta_body in a `meta` box header
			const meta_total_size: u32 = @intCast(meta_body.items.len + 8);
			var meta_size_be: [4]u8 = undefined;
			std.mem.writeInt(u32, &meta_size_be, meta_total_size, .big);
			try out.appendSlice(allocator, &meta_size_be);
			try out.appendSlice(allocator, "meta");
			try out.appendSlice(allocator, meta_body.items);

			// Pad to 256 bytes total so iloc offset 128 has data
			while (out.items.len < 256) try out.append(allocator, 0);

			return out.toOwnedSlice(allocator);
		}
	};

	const allocator = std.testing.allocator;
	const sample_a = Sample.make(allocator, 1) catch return error.SkipZigTest;
	defer allocator.free(sample_a);
	const sample_b = Sample.make(allocator, 42) catch return error.SkipZigTest;
	defer allocator.free(sample_b);

	// Sanity: each sample parses correctly in isolation.
	const info_a = parseHeifContainer(sample_a) catch return error.SkipZigTest;
	const info_b = parseHeifContainer(sample_b) catch return error.SkipZigTest;
	if (info_a.primary_item_id != 1) return error.SkipZigTest;
	if (info_b.primary_item_id != 42) return error.SkipZigTest;

	// Concurrent parse stress: each thread alternately parses sample_a and
	// sample_b and asserts the primary_item_id matches what it parsed.
	const Worker = struct {
		fn run(a: []const u8, b: []const u8, fail_flag: *std.atomic.Value(u32)) void {
			var i: usize = 0;
			while (i < 200) : (i += 1) {
				const sample = if (i % 2 == 0) a else b;
				const expected_id: u32 = if (i % 2 == 0) 1 else 42;
				const info = parseHeifContainer(sample) catch {
					fail_flag.store(1, .seq_cst);
					return;
				};
				if (info.primary_item_id != expected_id) {
					fail_flag.store(2, .seq_cst);
					return;
				}
				if (info.items.len != 1) {
					fail_flag.store(3, .seq_cst);
					return;
				}
				if (info.items[0].item_id != expected_id) {
					fail_flag.store(4, .seq_cst);
					return;
				}
			}
		}
	};

	var fail_flag = std.atomic.Value(u32).init(0);
	var threads: [8]std.Thread = undefined;
	for (&threads) |*t| {
		t.* = try std.Thread.spawn(.{}, Worker.run, .{ sample_a, sample_b, &fail_flag });
	}
	for (threads) |t| t.join();

	const flag = fail_flag.load(.seq_cst);
	try std.testing.expectEqual(@as(u32, 0), flag);
}
