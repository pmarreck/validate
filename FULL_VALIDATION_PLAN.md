# Full Validation Implementation Plan

**Goal**: Every format must have TRUE full byte-level validation. No structural-only validators.

**Principle**: If a format has checksums/CRCs, we MUST verify them. If it has compressed data, we MUST decompress it. A single corrupt byte in the payload MUST be detected.

---

## Priority Levels

- **P0** - CRITICAL: Audio in video containers (affects nearly every video file)
- **P1** - HIGH: Extremely common formats (PNG, GIF, MP3, GZIP, etc.)
- **P2** - MEDIUM: Common formats (PDF, WAV, archives, compression)
- **P3** - LOWER: Scientific/specialized formats
- **P4** - FUTURE: Complex proprietary formats

---

## P0: CRITICAL (Audio in Containers + Major Archives)

| Format | Current State | Required Work |
|--------|--------------|---------------|
| **AAC in MP4/MOV** | Placeholder `ok(.aac, 0)` | Extract ASC from esds, parse stsz/stco/stsc, decode samples |
| **Opus in MKV/WebM** | Placeholder `ok(.opus, 0)` | Walk Clusters, extract SimpleBlocks, decode Opus packets |
| **7-Zip** | Header CRCs only | LZMA decompress encoded header, read per-file CRCs (decompressed), decompress each file, verify |
| **RAR4/RAR5** | Header CRCs only | LZMA/PPMd decompress, verify per-file CRC32 |

---

## P1: HIGH PRIORITY (Very Common Formats)

| Format | Current State | Required Work |
|--------|--------------|---------------|
| **PNG** | Has chunk CRCs but DOESN'T VERIFY | Calculate CRC32 per chunk, decompress IDAT, verify ADLER32 |
| **GIF** | Magic only | Parse LSD, validate image blocks, decompress LZW, verify trailer |
| **GZIP** | Header only | Full zlib decompress, verify CRC32 + ISIZE |
| **MP3** | Frame sync only | Compute CRC16 for protected frames, or full decode |
| **FLAC** | Structural when no MD5 | Full decode, compute MD5 if not present |
| **TIFF** | Magic only (buffer path) | Parse IFDs, validate strips/tiles, decompress |
| **Theora** | Counts frames only | Integrate libtheora or bitstream parser |
| **VP8/VP9** | Header parsing only | libvpx full decode |

---

## P2: MEDIUM PRIORITY (Common Formats)

| Format | Current State | Required Work |
|--------|--------------|---------------|
| **PDF** | Header + %%EOF | Parse xref, validate objects, decompress streams |
| **WAV** | Structural for large files | Full validation regardless of size |
| **AIFF** | Chunk headers only | Full COMM/SSND validation, AIFF-C decompress |
| **WebP** | RIFF signature only | VP8/VP8L bitstream validation |
| **BMP** | Magic only | Full DIB header, color table, pixel data validation |
| **BZIP2** | Header only (large) | Full decompress, verify block + stream CRCs |
| **TAR** | Structure only | Header checksum per entry, size validation |
| **XZ** | Partial | Ensure all LZMA2 blocks decompressed, verify CRCs |
| **ZSTD** | Partial | Full decompress, always verify checksum if present |
| **DMG** | Data fork CRC only | Verify master checksum |
| **ISO 9660** | PVD only | Path table, directory records, file extents |

---

## P3: LOWER PRIORITY (Scientific/Specialized)

| Format | Current State | Required Work |
|--------|--------------|---------------|
| **HDF5** | Superblock only | Object tree traversal, dataset chunks, fletcher32 |
| **Parquet** | Thrift skeleton | Footer metadata, row groups, page CRCs |
| **NetCDF** | Header + dimensions | Variable data arrays, fill values, consistency |
| **EXR** | Magic + version | Attributes, scanlines/tiles, PIZ/ZIP/RLE decompress |
| **PSD** | Structure only | ZIP compression mode 2 decompress, layer data |
| **EML/MBOX** | MIME headers only | Decode base64, validate each attachment |
| **FLV** | Structural for >4GB | Full tag validation regardless of size |
| **Vorbis** | OGG CRCs verified | Full Vorbis bitstream decode |

---

## P4: FUTURE (Complex/Proprietary)

| Format | Current State | Required Work |
|--------|--------------|---------------|
| **glTF/GLB** | JSON structure only | Accessor data, buffer views, mesh geometry |
| **Blender** | DNA1 block only | Complete DNA structure, all data blocks |
| **SQLite** | Header only (basic) | PRAGMA integrity_check or equivalent |
| **DWG** | Header only | Complex proprietary - may need library |
| **InDesign** | Header only | Document structure - proprietary |

---

## Implementation Strategy

### For formats with CRCs/checksums:
1. Read the stored checksum
2. Compute checksum over the relevant data
3. Compare - mismatch = FAIL

### For formats with compression:
1. Decompress all compressed data
2. Decoder errors = FAIL (corrupt bitstream)
3. If CRC exists after decompress, verify it

### For codecs (video/audio):
1. Full decode through library (libvpx, libtheora, etc.) OR
2. Bitstream parsing with DCT/entropy validation OR
3. ffmpeg fallback as universal decoder

---

## Testing Requirement

For EVERY format implementation:

```bash
# Create test files
valid.{ext}           # Known good file
corrupt_header.{ext}  # Corrupted header bytes - should FAIL
corrupt_payload.{ext} # Corrupted payload bytes - MUST FAIL (key test!)
corrupt_crc.{ext}     # Wrong checksum - should FAIL
```

**The corrupt_payload test is the litmus test.** If we can't detect a single flipped bit in the payload, validation is incomplete.

---

## Notes

- Pure Zig preferred for portability
- External libs (libvpx, libtheora, etc.) acceptable for complex codecs
- ffmpeg is universal fallback but heavy dependency
- Some proprietary formats may have limited validation possible