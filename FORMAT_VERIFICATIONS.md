# validate Format Verification Reference

This document lists all file formats that this project can validate, along with the depth of integrity checking performed.

## Validation Depth Levels

Internally, validation has only **two depths** (see `ValidationDepth` enum in `format_validation.zig`):

| Level | Description | Corruption Detection |
|-------|-------------|----------------------|
| **Structure** | Headers, magic bytes, offsets, bounds checking | ⚠️ Payload corruption may go **UNDETECTED** |
| **Full** | Checksum verified, decompressed, or fully decoded | ✅ Payload corruption **WILL** be detected |

### The Critical Distinction

**Structure** validation only checks that:
- Magic bytes are correct
- Header fields are valid
- Offsets and sizes don't exceed file bounds
- Container structure is well-formed (e.g., braces match, chunks don't overlap)

A random bit flip in the *payload* would NOT cause structural validation to fail.

**Full** validation means every byte was verified via one of:
- **Checksum/hash** (CRC32, MD5, header checksums) - the math covers all bytes
- **Decompression** (gzip, zlib, bzip2) - the algorithm verified the data while decompressing
- **Full decode** (JPEG pixels decoded, XML fully parsed, audio samples rendered)

A random bit flip in the payload WOULD cause full validation to fail.

### Display Labels in Tables Below

For clarity, the tables below use more specific labels:

| Table Label | Maps To | Examples |
|-------------|---------|----------|
| ⚠️ Stub | `structural` + WARN | Magic/size check only — format recognized but no real corruption detection |
| Structure | `structural` | Bounds checking, brace matching, header parsing |
| Checksum | `full` | CRC32 verified, MD5 verified, header checksum |
| Decompress | `full` | Gzip/zlib/bzip2 decompression succeeded |
| Full Decode | `full` | JPEG pixels decoded, audio samples rendered |
| Integrity | `full` | Database page checksums, full XML parse |

---

## Images

| Format | Extensions | Basic Validation | Deep Validation | Max Depth | GT |
|--------|------------|------------------|-----------------|-----------|-----|
| **PNG** | .png | Signature, chunk structure, IEND terminator | CRC32 per chunk | Checksum | — |
| **JPEG** | .jpg, .jpeg | SOI/EOI markers, segment structure | Full decode via libjpeg-turbo | Full Decode | — |
| **JPEG XL** | .jxl | Codestream (FF 0A) or container signature | Full decode via libjxl | Full Decode | 1 |
| **GIF** | .gif | Header (GIF87a/89a), trailer (0x3B), block structure | Full LZW decode via zigimg | Full Decode | 1 |
| **BMP** | .bmp | Header, DIB header, pixel data bounds | Full pixel decode via zigimg | Full Decode | 1 |
| **WebP** | .webp | RIFF container, VP8/VP8L/VP8X chunks | Full decode via libwebp | Full Decode | 1 |
| **TIFF** | .tiff, .tif | Header (II/MM), IFD structure, tag validation | Full decode via zigimg | Full Decode | 1 |
| **HEIC/HEIF** | .heic, .heif | ISOBMFF structure, ftyp brand validation | Pure Zig HEIF container + H.265 NAL/SPS/PPS validation | Full Decode | 1 |
| **AVIF** | .avif | ISOBMFF structure, ftyp brand validation | Pure Zig HEIF container + AV1 OBU validation | Full Decode | 1 |
| **SVG** | .svg | XML declaration, `<svg>` root element | Full XML parse | Integrity | — |
| **OpenEXR** | .exr | Signature (76 2F 31 01), header structure | Required attribute validation (channels, compression, windows) | Integrity | — |
| **QOI** | .qoi | Signature (qoif), width/height/channels/colorspace | Header field validation | Structure | — |
| **DPX** | .dpx | Signature (SDPX/XPDS), version, endian detection | File size validation, image dimensions | Structure | — |
| **TGA** | .tga, .targa | 18-byte header, image type, dimensions | Optional TGA v2 footer ("TRUEVISION-XFILE.") | Structure | — |
| **PBM/PGM/PPM/PAM** | .pbm, .pgm, .ppm, .pam | P1-P7 magic + whitespace, header parsing | Width/height validation | Structure | — |

## RAW Camera Formats

| Format | Extensions | Basic Validation | Deep Validation | Max Depth | GT |
|--------|------------|------------------|-----------------|-----------|-----|
| **Adobe DNG** | .dng | TIFF-based header, IFD structure | Full decode via zigimg | Full Decode | — |
| **Canon RAW** | .cr2 | TIFF-based header, IFD structure | Full decode via zigimg | Full Decode | — |
| **Nikon RAW** | .nef | TIFF-based header, IFD structure | Full decode via zigimg | Full Decode | — |
| **Sony RAW** | .arw | TIFF-based header, IFD structure | Full decode via zigimg | Full Decode | — |

## Creative/Design Applications

| Format | Extensions | Basic Validation | Deep Validation | Max Depth | GT |
|--------|------------|------------------|-----------------|-----------|-----|
| **Adobe Photoshop** | .psd | Signature (8BPS), header structure | Full layer/channel decode with RLE decompression | Full Decode | — |
| **Adobe Illustrator** | .ai | PDF-based (modern) or PostScript-based (legacy) | Extension-based format override | Structure | — |
| **Encapsulated PostScript** | .eps | PostScript magic, BoundingBox detection | Structural validation | Structure | — |
| **Adobe After Effects** | .aep | RIFX container, magic bytes | RIFF chunk parsing | Structure | — |
| **Adobe Premiere Pro** | .prproj | Gzip-compressed XML (modern) or plain XML (legacy) | Gzip CRC32 + full XML parse | Full Decode | — |
| **Adobe InDesign** | .indd | Magic (0606EDF5) + "DOCUMENT" signature | Proprietary binary structure | Structure | — |
| **InDesign Markup** | .idml | ZIP container with XML content | CRC32 per entry | Checksum | — |
| **AutoCAD DWG** | .dwg | "AC" + version code (e.g., AC1032 = 2018) | Section locator validation, encryption detection | Integrity | — |
| **Blender** | .blend | "BLENDER" magic + pointer/endian/version | DNA1 block validation (SDNA/NAME sections) | Integrity | — |
| **DaVinci Resolve** | .drp | ZIP container with project.xml | CRC32 + project.xml presence | Checksum | — |
| **Final Cut Pro XML** | .fcpxml | XML with "fcpxml" root element | Full XML parse | Integrity | — |
| **Sketch** | .sketch | ZIP container structure | CRC32 + document.json/meta.json presence | Checksum | — |

## 3D Model Formats

| Format | Extensions | Basic Validation | Deep Validation | Max Depth | GT |
|--------|------------|------------------|-----------------|-----------|-----|
| **Wavefront OBJ** | .obj | Header comment detection, vertex/face structure | Full vertex/face/normal parsing | Integrity | — |
| **glTF** | .gltf | JSON with required asset property | Full JSON parse | Integrity | — |
| **glTF Binary** | .glb | Magic (glTF), version, length | JSON chunk parse + BIN chunk | Integrity | — |
| **WOFF** | .woff | Signature (wOFF), header structure | Table validation, checksum | Checksum | — |
| **WOFF2** | .woff2 | Signature (wOF2), header structure | Full table validation | Integrity | — |

## Audio

| Format | Extensions | Library | License | Validation | Notes | GT |
|--------|------------|---------|---------|------------|-------|-----|
| **FLAC** | .flac | Pure Zig | — | ✅ Full Decode | MD5 audio hash | — |
| **MP3** | .mp3 | minimp3 | Public Domain | ✅ Full Decode | CRC + decode | — |
| **AAC** | .m4a, .aac, .mka | Pure Zig | — | ✅ Syntax Validated | AAC-LC bitstream syntax + spectral Huffman validation | — |
| **Opus** | .opus, .ogg | libopus | BSD-3 | ✅ Full Decode | Full libopus decode + OGG page CRC32 | — |
| **Vorbis** | .ogg | libvorbis | BSD-3 | ✅ Full Decode | Full libvorbis decode + OGG page CRC32 | — |
| **Theora Video** | .ogv | Pure Zig | — | ✅ CRC Verified | OGG page CRC32 (no bitstream decode) | 1 |
| **Speex** | .ogg | Pure Zig | — | ✅ CRC Verified | OGG page CRC32 (no bitstream decode) | — |
| **FLAC-in-OGG** | .ogg | Pure Zig | — | ✅ CRC Verified | OGG page CRC32 (no bitstream decode) | — |
| **ALAC** | .m4a | Pure Zig | — | ✅ Full Decode | Apple Lossless | 1 |
| **AC-3** | .ac3, .eac3 | Pure Zig | — | ✅ Checksum | Dolby Digital CRC | 2 |
| **E-AC-3** | .eac3 | Pure Zig | — | ✅ Checksum | Dolby Digital Plus CRC | 2 |
| **WAV** | .wav | Pure Zig | — | ✅ Full Decode | RIFF chunk parsing | 1 |
| **AIFF** | .aiff, .aif | Pure Zig | — | ✅ Structure | IFF chunk parsing (no audio decode) | — |
| **Monkey's Audio** | .ape | — | — | ✅ Structural | Proprietary SDK | — |
| **WavPack** | .wv | Pure Zig | — | ✅ Checksum | MD5 sub-block detection | 1 |
| **MIDI** | .mid, .midi | Pure Zig | — | ✅ Full Decode | Track parsing, event validation | 3 |
| **DSF/DFF (DSD)** | .dsf, .dff | Pure Zig | — | ✅ Structural | Super Audio CD | — |
| **AMR** | .amr | Pure Zig | — | ✅ Structural | AMR-NB/WB magic, frame type validation | — |
| **AU/SND** | .au, .snd | Pure Zig | — | ✅ Structural | Sun/NeXT header, encoding/rate/channel validation | — |
| **TTA** | .tta | Pure Zig | — | ✅ Checksum | TTA1 header CRC32 verification | — |
| **CAF** | .caf | Pure Zig | — | ✅ Structural | Apple Core Audio, version/desc chunk validation | — |
| **DTS** | .dts | — | ⚠️ GPL | ⚠️ Blocked | Blu-ray surround | — |

**Legend:** ✅ = Implemented | ⚠️ = Blocked (GPL dependency) | **GT** = Ground Truth examples verified

## Tracker/Module Formats

| Format | Extensions | Basic Validation | Deep Validation | Max Depth | GT |
|--------|------------|------------------|-----------------|-----------|-----|
| **ProTracker MOD** | .mod | Sample count, pattern validation, magic ID | libopenmpt full decode + audio render | Full Decode | 1 |
| **FastTracker XM** | .xm | Header signature, version, module structure | libopenmpt full decode + audio render | Full Decode | 1 |
| **Impulse Tracker** | .it | IMPM signature, header structure | libopenmpt full decode + audio render | Full Decode | 1 |
| **Scream Tracker** | .s3m | SCRM signature, header structure | libopenmpt full decode + audio render | Full Decode | 1 |

## Video Containers

| Format | Extensions | Basic Validation | Deep Validation | Max Depth | GT |
|--------|------------|------------------|-----------------|-----------|-----|
| **MP4** | .mp4 | ISOBMFF atom structure, ftyp brand | Box scan + video frame decode | Integrity* | — |
| **QuickTime** | .mov | ISOBMFF atom structure, ftyp brand | Box scan + video frame decode | Integrity* | 2 |
| **Matroska** | .mkv | EBML header, segment structure | Element scan + video frame decode | Integrity* | — |
| **WebM** | .webm | EBML header, webm DocType | Element scan + video frame decode | Integrity* | 1 |
| **AVI** | .avi | RIFF/AVI header, chunk structure | Video frame decode (MJPEG, H.264, MPEG-1/2, MPEG-4 Part 2) | Integrity* | 1 |
| **MPEG-TS** | .ts, .m2ts | 188-byte sync, packet structure | PAT/PMT parsing | Structure | 1 |
| **MPEG-PS** | .mpg, .mpeg, .vob | Pack/System header detection | PES header parsing | Structure | 1 |
| **SWF (Flash)** | .swf | FWS/CWS/ZWS headers | CWS zlib decompression + RECT validation | Decompress | — |
| **FLV** | .flv | FLV header + tag structure | Tag parsing with bounds checking | Structure | — |
| **ASF/WMV/WMA** | .asf, .wmv, .wma | 16-byte ASF GUID, object size, sub-object count | Header object structure validation | Structure | — |
| **DV** | .dv, .dif | DIF block structure, section type validation | Block number/sequence validation | Structure | — |
| **IVF** | .ivf | DKIF signature, version, codec fourcc | Frame count, dimensions validation | Structure | — |

*Video containers reach Integrity level when video frames can be decoded (supported codecs: H.264, H.265, AV1, VP9, ProRes, MPEG-1/2, MJPEG). Falls back to Structure for unsupported codecs or files >100MB.

## Video Codecs

| Codec | Containers | Library | License | Validation | Notes | GT |
|-------|------------|---------|---------|------------|-------|-----|
| **H.264/AVC** | MP4, MKV, MOV | Pure Zig | — | ✅ Full Decode | NAL/SPS/PPS/slice + CAVLC/CABAC entropy decode | — |
| **H.265/HEVC** | MP4, MKV, MOV | Pure Zig | — | ✅ Full Decode | NAL/VPS/SPS/PPS validation | — |
| **AV1** | MP4, MKV, WebM | Pure Zig | — | ✅ Full Decode | OBU sequence/frame header validation | — |
| **VP9** | WebM, MKV | Pure Zig | — | ✅ Full Decode | Frame header parsing | — |
| **VP8** | WebM | Pure Zig | — | ✅ Full Decode | DCT coefficient decode via boolean arithmetic coder + IDCT | 2 |
| **Theora** | OGG (.ogv) | Pure Zig | — | ✅ CRC Verified | OGG page CRC32 + header parse | 1 |
| **ProRes** | MOV | Pure Zig | — | ✅ Full Decode | DCT decode validation, all profiles | 2 |
| **Motion JPEG** | MOV, AVI | libjpeg-turbo | BSD | ✅ Full Decode | Frame-by-frame JPEG | — |
| **MPEG-1** | MPEG-PS, TS | Pure Zig | — | ✅ Full Decode | DCT decode validation, VCDs | 2 |
| **MPEG-2** | MPEG-PS, TS, VOB | Pure Zig | — | ✅ Full Decode | DCT decode validation for DVDs | — |
| **MPEG-4 Part 2** | AVI, MP4 | Pure Zig | — | ✅ Full Decode | DivX/Xvid DCT decode validation | 1 |
| **WMV9/VC-1** | WMV, ASF | — | ⚠️ GPL | ⚠️ Blocked | Windows Media | — |

**Legend:** ✅ = Implemented | ⚠️ = Blocked (GPL dependency) | **GT** = Ground Truth examples verified

## Documents

| Format | Extensions | Basic Validation | Deep Validation | Max Depth | GT |
|--------|------------|------------------|-----------------|-----------|-----|
| **PDF** | .pdf | Header (%PDF-), xref table, %%EOF trailer | Embedded images (JPEG/JBIG2/JPEG2000), fonts (TrueType/CFF/Type1) decoded | Full Decode | 6 |
| **RTF** | .rtf | Header signature ({\rtf), control words | Brace matching validation | Structure | — |

## Office Formats (Modern - ZIP-based)

| Format | Extensions | Basic Validation | Deep Validation | Max Depth | GT |
|--------|------------|------------------|-----------------|-----------|-----|
| **Word (OOXML)** | .docx | ZIP structure, [Content_Types].xml, word/ | CRC32 per entry | Checksum | — |
| **Excel (OOXML)** | .xlsx | ZIP structure, [Content_Types].xml, xl/ | CRC32 per entry | Checksum | — |
| **PowerPoint (OOXML)** | .pptx | ZIP structure, [Content_Types].xml, ppt/ | CRC32 per entry | Checksum | — |

## Office Formats (Legacy - OLE2/CFBF)

| Format | Extensions | Basic Validation | Deep Validation | Max Depth | GT |
|--------|------------|------------------|-----------------|-----------|-----|
| **Word 97-2003** | .doc | OLE2/CFBF header, FAT structure, stream detection | FIB parsing (FibBase, FibRgLw97, FibRgFcLcb97) + Table stream cross-validation + CLX/Piece Table consistency | Full | 5 |
| **Excel 97-2003** | .xls | OLE2/CFBF header, FAT structure, Workbook stream | FAT/DIFAT/mini-FAT + directory validation (container only) | Structure | 1 |
| **PowerPoint 97-2003** | .ppt | OLE2/CFBF header, FAT structure, PowerPoint stream | FAT/DIFAT/mini-FAT + directory validation (container only) | Structure | 1 |

**Note:** Full byte-level validation of legacy Office streams is planned someday, but each format’s spec is roughly 600–1000 pages, so deeper support may take time.

## OpenDocument Formats (ZIP-based)

| Format | Extensions | Basic Validation | Deep Validation | Max Depth | GT |
|--------|------------|------------------|-----------------|-----------|-----|
| **OpenDocument Text** | .odt | ZIP structure, mimetype, content.xml | CRC32 per entry | Checksum | — |
| **OpenDocument Spreadsheet** | .ods | ZIP structure, mimetype, content.xml | CRC32 per entry | Checksum | — |
| **OpenDocument Presentation** | .odp | ZIP structure, mimetype, content.xml | CRC32 per entry | Checksum | — |

## Apple iWork (ZIP-based)

| Format | Extensions | Basic Validation | Deep Validation | Max Depth | GT |
|--------|------------|------------------|-----------------|-----------|-----|
| **Pages** | .pages | ZIP structure, package contents | CRC32 per entry | Checksum | — |
| **Keynote** | .key | ZIP structure, package contents | CRC32 per entry | Checksum | — |
| **Numbers** | .numbers | ZIP structure, package contents | CRC32 per entry | Checksum | — |

## Legacy Word Processors

| Format | Extensions | Basic Validation | Deep Validation | Max Depth | GT |
|--------|------------|------------------|-----------------|-----------|-----|
| **WordPerfect** | .wpd | Header signature (0xFF 'WPC') | — | Structure | — |
| **ClarisWorks/AppleWorks** | .cwk | Magic bytes only (BOBO) | — | ⚠️ Stub | — |
| **MacWrite** | .mwd | Version/magic bytes only | — | ⚠️ Stub | — |

## Archives

| Format | Extensions | Basic Validation | Deep Validation | Max Depth | GT |
|--------|------------|------------------|-----------------|-----------|-----|
| **ZIP** | .zip | Local headers, central directory, EOCD | CRC32 per entry, deflate decode | Checksum | — |
| **Gzip** | .gz | Header (1F 8B), flags, trailer | Full decompress + CRC32 | Checksum | — |
| **Bzip2** | .bz2 | Header (BZh), stream structure | Full decompress + block/stream CRC32 | Checksum | — |
| **XZ** | .xz | Header (FD 37 7A 58 5A), stream structure | Decompress + CRC64 | Checksum | — |
| **Zstandard** | .zst | Magic (28 B5 2F FD), frame structure | Full decompress | Decompress | — |
| **Brotli** | .br | Stream structure detection | Full decompress via libbrotli | Full Decode | 1 |
| **7-Zip** | .7z | Signature, header structure | Start header + next header CRC32 | Checksum | — |
| **RAR** | .rar | Signature (Rar!), archive header | RAR4 CRC16 + RAR5 CRC32 header verification | Checksum | — |
| **Tar** | .tar | POSIX/GNU header, checksum field | Header checksum verified (first entry) | Checksum | — |
| **EPUB** | .epub | ZIP structure, META-INF/container.xml | CRC32 per entry | Checksum | — |

## DAW Project Formats

| Format | Extensions | Basic Validation | Deep Validation | Max Depth | GT |
|--------|------------|------------------|-----------------|-----------|-----|
| **Ableton Live** | .als | Gzip-compressed XML detection | Full gzip CRC32 verification | Checksum | — |
| **Reaper** | .rpp | UTF-8 text, `<REAPER_PROJECT` header | Bracket structure parsing | Structure | — |
| **Logic Pro X** | .logicx | ZIP-based package structure | CRC32 per entry | Checksum | — |
| **FL Studio** | .flp | FLhd/FLdt chunk structure | Full TLV event parsing | Full Decode | — |
| **Studio One** | .song | ZIP-based, metainfo.xml detection | CRC32 per entry | Checksum | — |
| **Bitwig** | .bwproject | Size check + ZIP rejection only | — | ⚠️ Stub | — |
| **Cubase** | .cpr | RIFF magic only (no chunk parsing) | — | ⚠️ Stub | — |
| **Pro Tools** | .ptx | Size check + ZIP rejection only | — | ⚠️ Stub | — |
| **GarageBand** | .band | Size check only | — | ⚠️ Stub | — |
| **Reason** | .reason | Size check + ZIP rejection only | — | ⚠️ Stub | — |

> **Note:** Bitwig, Pro Tools, GarageBand, and Reason use proprietary undocumented binary formats.
> These return WARN (not OK) — format is recognized but corruption detection is unreliable.
> Deep validation would require reverse-engineering these formats.

## Database

| Format | Extensions | Basic Validation | Deep Validation | Max Depth | GT |
|--------|------------|------------------|-----------------|-----------|-----|
| **SQLite** | .db, .sqlite, .sqlite3 | Header magic, page structure | `PRAGMA integrity_check` | Integrity | — |
| **Microsoft Access 97-2003** | .mdb | Magic (00 01 00 00) + "Standard Jet DB" | Structural validation | Structure | — |
| **Microsoft Access 2007+** | .accdb | Magic (00 01 00 00) + "Standard ACE DB" | Structural validation | Structure | — |

## Version Control

| Format | Extensions | Basic Validation | Deep Validation | Max Depth | GT |
|--------|------------|------------------|-----------------|-----------|-----|
| **Git Repository** | .git/ | `.git` directory + loose object SHA-1 verification | Packfile trailing SHA-1, pack index SHA-1, `.git/index` checksum | Integrity | — |

## Scientific Data Formats

| Format | Extensions | Basic Validation | Deep Validation | Max Depth | GT |
|--------|------------|------------------|-----------------|-----------|-----|
| **HDF5** | .h5, .hdf5 | Signature (89 HDF), superblock | Superblock version, offset/length sizes, root group address | Integrity | — |
| **Apache Parquet** | .parquet | Magic (PAR1), footer structure | Footer metadata (Thrift), field parsing | Integrity | — |
| **NetCDF** | .nc | Signature (CDF or HDF5-based) | Dimension/variable/attribute parsing, bounds validation | Integrity | — |
| **FITS** | .fits, .fit | SIMPLE=T header, END keyword | BITPIX/NAXIS validation, data array bounds | Integrity | — |
| **MATLAB** | .mat | Header text, version/endian indicator | Data element parsing, type validation, bounds | Integrity | — |
| **NIfTI** | .nii, .nii.gz | Header size (348/540), magic (n+1/ni1) | Dimension validation, datatype, voxel offset, data bounds | Integrity | — |

## Bioinformatics

| Format | Extensions | Basic Validation | Deep Validation | Max Depth | GT |
|--------|------------|------------------|-----------------|-----------|-----|
| **FASTA** | .fasta, .fa, .fna, .faa | Header line (>), sequence characters | Full sequence character validation (IUPAC + amino acids) | Integrity | — |
| **FASTQ** | .fastq, .fq | @header, sequence, +, quality scores | Multi-record parsing, seq/qual length match, quality encoding | Integrity | — |

## Medical Imaging

| Format | Extensions | Basic Validation | Deep Validation | Max Depth | GT |
|--------|------------|------------------|-----------------|-----------|-----|
| **DICOM** | .dcm, .dicom | Preamble + DICM magic at offset 128 | Transfer Syntax, meta info parsing, dataset element bounds | Integrity | — |

## Web Archives

| Format | Extensions | Basic Validation | Deep Validation | Max Depth | GT |
|--------|------------|------------------|-----------------|-----------|-----|
| **WARC** | .warc | WARC/ header, Content-Length validation | Multi-record parsing, required headers, Content-Length bounds | Integrity | — |

## Game Data Formats

| Format | Extensions | Basic Validation | Deep Validation | Max Depth | GT |
|--------|------------|------------------|-----------------|-----------|-----|
| **DOOM WAD** | .wad | IWAD/PWAD signature, directory structure | Directory entry bounds validation | Structure | — |
| **Quake PAK** | .pak | PACK signature, directory offset/size | Directory entry bounds validation | Structure | — |
| **Quake/Source BSP** | .bsp | Version whitelist only (no lump parsing) | — | ⚠️ Stub | — |
| **Valve VPK** | .vpk | Signature + version + tree size bounds only | — | ⚠️ Stub | — |

## Game ROM Formats

| Format | Extensions | Basic Validation | Deep Validation | Max Depth | GT |
|--------|------------|------------------|-----------------|-----------|-----|
| **NES/Famicom** | .nes | iNES header (NES + 0x1A), PRG/CHR ROM sizes | Size validation from header | Structure | — |
| **SNES** | .sfc, .smc | Internal header detection, ROM mapping | Full ROM checksum verification | Checksum | — |
| **Nintendo 64** | .z64, .n64, .v64 | Byte order detection, boot code validation | Header field validation | Structure | — |
| **Game Boy/Color** | .gb, .gbc | Nintendo logo, header checksum verification | — | Checksum | — |
| **Game Boy Advance** | .gba | Nintendo logo, header checksum verification | — | Checksum | — |
| **Nintendo DS** | .nds | Header structure, ARM code offsets | Header CRC-16 MODBUS verification | Checksum | — |
| **Sega Genesis** | .gen, .md, .bin | SEGA/SEGA MEGA DRIVE header detection | Header field + ROM address validation | Structure | — |
| **MAME CHD** | .chd | MComprHD signature, version, SHA1 hashes | — | Structure | — |

## IFF-Based Formats

| Format | Extensions | Basic Validation | Deep Validation | Max Depth | GT |
|--------|------------|------------------|-----------------|-----------|-----|
| **Generic IFF** | .iff | FORM header, type code, chunk structure | Chunk boundary validation | Structure | — |
| **Blorb** | .blorb, .gblorb, .zblorb | FORM/IFRS or FORM/IFZS, RIdx chunk required | RIdx + chunk iteration | Integrity | — |

## Crystallography/Chemistry

| Format | Extensions | Basic Validation | Deep Validation | Max Depth | GT |
|--------|------------|------------------|-----------------|-----------|-----|
| **PDB** | .pdb | HEADER/ATOM/HETATM record structure | Record type validation, ATOM coordinate parsing | Integrity | — |
| **CIF** | .cif | data_ block detection, tag structure | Tag parsing, loop structure, multi-block validation | Integrity | — |

## GIS/Geospatial

| Format | Extensions | Basic Validation | Deep Validation | Max Depth | GT |
|--------|------------|------------------|-----------------|-----------|-----|
| **ESRI Shapefile** | .shp | File code (9994), version, shape types | Bounding box, record parsing, shape type consistency | Integrity | — |
| **KML** | .kml | XML structure, `<kml>` namespace | Full XML parse | Integrity | — |
| **KMZ** | .kmz | ZIP structure containing .kml | CRC32 per entry | Checksum | — |

## CAD/Engineering

| Format | Extensions | Basic Validation | Deep Validation | Max Depth | GT |
|--------|------------|------------------|-----------------|-----------|-----|
| **AutoCAD DXF** | .dxf | Text (0/SECTION) or binary header | — | Structure | — |
| **STEP** | .stp, .step | ISO-10303-21; signature | — | Structure | — |
| **STL** | .stl | ASCII (solid/facet) or binary heuristic | — | Structure | — |

## Email

| Format | Extensions | Basic Validation | Deep Validation | Max Depth | GT |
|--------|------------|------------------|-----------------|-----------|-----|
| **EML** | .eml | RFC 822 headers, MIME structure | Base64 attachment decode + validation | Structure* | — |
| **MBOX** | .mbox | "From " separator lines, message structure | Message boundary parsing | Structure | — |

*EML attachment validation: Base64 attachments are decoded and format-validated. If any attachment fails validation, the entire EML is marked invalid.

## Text/Data Formats

| Format | Extensions | Basic Validation | Deep Validation | Max Depth | GT |
|--------|------------|------------------|-----------------|-----------|-----|
| **JSON** | .json | Full parse via std.json | — | Integrity | — |
| **TOML** | .toml | Full parse via TOML parser | — | Integrity | — |
| **INI** | .ini | Strict line-by-line syntax check | UTF-16 LE auto-detection | Integrity | 1 |
| **XML** | .xml, .xhtml, .xsl | Well-formed parse, tag stack validation | — | Integrity | — |
| **YAML** | .yaml, .yml | Structure detection only | — | Structure | — |
| **CSV** | .csv, .tsv | Delimiter detection, UTF-8 validation | Column consistency, quote escaping | Integrity | — |
| **Apple plist** | .plist | XML or binary detection | Binary: trailer/offset table; XML: full parse | Integrity | — |

## Plain Text Encodings

| Format | Extensions | Detection Method | Validation | Max Depth | GT |
|--------|------------|------------------|------------|-----------|-----|
| **Plain Text (UTF-8)** | .txt, .md, etc. | Valid UTF-8 sequences | Full UTF-8 validation | Integrity | 1 |
| **Plain Text (UTF-16)** | .txt | UTF-16 BOM or heuristic | UTF-16 codepoint validation | Integrity | — |
| **Plain Text (Latin-1)** | .txt | UTF-8 fallback | Byte validity (all 0x00-0xFF valid) | Integrity | — |
| **Plain Text (CP437)** | .nfo | Box-drawing chars (0xB0-0xDF) | Demoscene ASCII art detection | Integrity | 1 |

*CP437 detection looks for the characteristic box-drawing characters used in demoscene NFO files.*

## VM/Bytecode Formats

| Format | Extensions | Basic Validation | Deep Validation | Max Depth | GT |
|--------|------------|------------------|-----------------|-----------|-----|
| **Erlang BEAM** | .beam | FOR1/BEAM IFF signature | Chunk structure, atom table, code chunk | Integrity | — |

## Icon Formats

| Format | Extensions | Basic Validation | Deep Validation | Max Depth | GT |
|--------|------------|------------------|-----------------|-----------|-----|
| **Windows ICO** | .ico | Header (00 00 01 00), image count | Directory entries, image data bounds, PNG/BMP detection | Integrity | — |

## Disk Images

| Format | Extensions | Basic Validation | Deep Validation | Max Depth | GT |
|--------|------------|------------------|-----------------|-----------|-----|
| **ISO 9660** | .iso | Volume descriptor at sector 16, directory structure | Recursive file validation via buffer validators | Checksum | — |
| **UDF** | .iso, .udf | AVDP, VDS, FSD structure | Recursive file validation via buffer validators | Checksum | — |
| **DVD ISO** | .iso | VIDEO_TS directory detection | VOB validation via MPEG-PS parser, MPEG-2 DCT decode | Full Decode | — |
| **Blu-ray ISO** | .iso | BDMV directory structure, index.bdmv | M2TS packet validation (192-byte), sync/PID verification | Structure | — |
| **Apple DMG** | .dmg | Koly block signature at EOF | Data fork CRC32 checksum verification | Checksum | — |

## Partition Tables & Filesystems

| Format | Description | Basic Validation | Deep Validation | Max Depth | GT |
|--------|-------------|------------------|-----------------|-----------|-----|
| **GPT** | GUID Partition Table | Signature, header structure | Header CRC32 verification | Checksum | — |
| **APM** | Apple Partition Map | DDM + PM signatures | Partition enumeration | Structure | — |
| **HFS+** | Apple filesystem | Volume header, fork data | Journaling detection | Structure | — |

## Financial Data Formats

| Format | Extensions | Basic Validation | Deep Validation | Max Depth | GT |
|--------|------------|------------------|-----------------|-----------|-----|
| **QuickBooks Company** | .qbw | SQL Anywhere magic (5E BA 7A DA @ 0x14), MAUI legacy, page alignment | CRC-32 per 4096-byte page (v12+); structural only for v11 | Checksum | 4 |
| **QuickBooks Backup** | .qbb, .qbm | OLE2 compound file detection | OLE2 FAT/DIFAT/directory validation | Structure | — |
| **Quicken Data File** | .qdf | OLE2, ZIP, or legacy (AC 9E BD 8F) detection | OLE2 FAT or ZIP CRC-32 per entry (variant-dependent) | Checksum | 1 |
| **Open Financial Exchange** | .ofx, .qfx | SGML (OFXHEADER:) or XML (<?xml + <OFX>) | — | Structure | — |
| **Quicken Interchange** | .qif | !Type:, !Account, or !Option header | — | Structure | — |
| **Tax Exchange Format** | .txf | V### version line + application line | — | Structure | — |
| **NACHA/ACH** | .ach, .nacha | 94-char fixed records, type 1 header, priority code 01 | Entry hash (sum routing mod 10^10), batch/file counts, debit/credit totals, block count | Integrity | 1 |
| **SWIFT MT940** | .mt940, .sta, .940 | SWIFT envelope ({1:F01) or bare :20: tag | Balance arithmetic (opening + transactions = closing), currency consistency | Integrity | 1 |
| **BAI2** | .bai, .bai2 | 01, file header, version=2, / terminator | Cascading control totals: account (49) → group (98) → file (99), record counts at all levels | Integrity | 1 |

## Encrypted Files

| Format | Extensions | Basic Validation | Deep Validation | Max Depth | GT |
|--------|------------|------------------|-----------------|-----------|-----|
| **Encrypted ZIP** | .zip | Structure validated, encryption detected | Skipped (no password) | Structure | — |
| **Encrypted PDF (with password)** | .pdf | Structure validated, /Encrypt detected | Skipped (password required) | Structure | — |
| **Encrypted PDF (empty password)** | .pdf | Full validation via decryption | All embedded content decoded | Full Decode | — |

**Note:** Encrypted files are validated structurally. We cannot verify internal checksums without the decryption key. A separate upcoming product will offer parity-based protection/repair for encrypted bytes without exposing plaintext.

### Trivial Protection Circumvention Policy

This project intentionally circumvents trivial or ineffective protection mechanisms **solely to validate data integrity**. This includes:

| Protection Type | Mechanism | Circumvention |
|-----------------|-----------|---------------|
| **PDF empty-password encryption** | Encrypted streams, empty user password | Decrypt with empty password |
| **PDF owner-password-only** | Restricts print/copy, user can open | Decrypt and validate normally |

**Why we do this:**
- These protection mechanisms provide no actual security (empty password = no password)
- The "protection" merely adds processing overhead without preventing access
- Our goal is to validate data integrity, not enforce ineffective restrictions
- Files with trivial protection are marked with `NOTICE` in CLI output

**What we do NOT circumvent:**
- Files requiring an actual password to open
- Strong encryption (AES-256, etc.)
- Any protection that would require key guessing or brute force

**Repairable:** PDFs with trivial encryption can potentially be "repaired" by removing the encryption entirely, resulting in a smaller, faster file with identical content. This is flagged as `MalformationType.pdf_trivial_encryption`.

---

## Unknown/Fallback

| Condition | Validation | Depth |
|-----------|------------|-------|
| Unknown format with valid UTF-8 | Character encoding validation | Structure |
| Unknown format, not UTF-8 | No validation (future parity product can cover this) | — |

---

## Notes

### Continuous Improvement

This format list is continuously updated. We regularly add:
- **New formats** based on user requests and common use cases
- **Deeper validation** for existing formats as we implement additional checks

Updates are included in regular app updates at no extra cost.

### Request a Format

Don't see a format you need? Contact us! We prioritize formats based on user demand.

**Email:** [TBD - support email]
**Website:** [TBD - website URL]

### Validation Philosophy

- **Structure**: We verify the file's skeleton is intact (headers, chunk boundaries, required sections)
- **Checksum**: We verify any embedded integrity data the format provides
- **Full Decode**: We process the entire file through its codec/parser, catching subtle corruption
- **Integrity**: Database-level or format-complete verification (every byte covered)
- **GT (Ground Truth)**: Number of real-world example files we've verified our validator against

### Lenience & Repairability (Future Work)

Some formats are treated as **valid with warning** when the file is openable by popular readers but exhibits specific malformations. We do this because certain error types are **theoretically repairable** and may be automatically fixed in a future release (**not yet**).  
Example: truncated JBIG2 streams may be repairable in principle, but we currently only warn and do not attempt repair.

We don't perform **semantic validation**—we detect bitrot and corruption, not authoring errors. A valid JPEG with poor composition is still a valid JPEG.

### Deep Validation Trade-offs

Deep validation (Full Decode, Integrity) is more thorough but slower:
- **JPEG deep**: ~10-50ms per file (full decode via libjpeg-turbo)
- **FLAC deep**: ~100ms-1s per file (full MD5 verification)
- **ZIP deep**: Depends on archive size (decompresses all entries)

Basic (structural) validation is fast enough for real-time scanning of large libraries.

---

## Checksum Coverage Summary

Formats with built-in integrity verification:

| Format | Checksum Type | Coverage | Implementation |
|--------|--------------|----------|----------------|
| FLAC | MD5 | 100% audio | Pure Zig |
| OGG Vorbis | CRC32/page + full decode | 100% | libvorbis |
| OGG Opus | CRC32/page + full decode | 100% | libopus |
| PNG | CRC32/chunk | 100% | Pure Zig |
| ZIP | CRC32/entry | 100% | Pure Zig |
| GZIP | CRC32 | 100% | Pure Zig |
| 7-Zip | CRC32 | Start + next header | Pure Zig |
| MKV | CRC32/Cluster | Optional | Pure Zig |
| MP3 | CRC16/frame | ~5% (header only) | minimp3 |
| AC-3 | CRC16 | Frame header | Pure Zig |
| WavPack | MD5 | Optional | — |
| TTA | CRC32 | Header | Pure Zig |
| QBW | CRC32/page | 100% (v12+) | Pure Zig |
| NACHA | Entry hash + totals | 100% | Pure Zig |
| MT940 | Balance arithmetic | 100% | Pure Zig |
| BAI2 | Cascading control totals | 100% | Pure Zig |

---

## Implementation Notes

**Pure Zig (no external dependencies):** FLAC, WAV, AIFF, ALAC, AC-3, E-AC-3, AMR, AU/SND, TTA, CAF, ProRes, MPEG-1/2, MPEG-4 Part 2, VP8, VP9, Theora, DV, H.264, H.265/HEVC, AV1, AAC, HEIC, AVIF, PNG, QOI, DPX, TGA, PBM/PGM/PPM/PAM, ZIP, GZIP, BZIP2, 7-Zip, all container parsing

**BSD/MIT Licensed Libraries:** libopus, libvorbis, libjpeg-turbo, OpenJPEG, zigimg (GIF, BMP, TIFF, RAW), libwebp (WebP), libjxl (JPEG XL), libbrotli (Brotli)

**GPL Blocked:** WMV/VC-1, DTS, RealVideo/Audio - would require optional plugin architecture

**Note:** Six C library dependencies (OpenH264, libde265, dav1d, libvpx, libheif, libfdk-aac) were replaced with pure-Zig validators in February 2026. VideoToolbox (macOS hardware decoder) was also removed.

---

*Last updated: 2026-02-28*
