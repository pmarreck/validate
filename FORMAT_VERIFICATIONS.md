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

## Why Some Formats Cannot Achieve Full Validation

Every format that caps at **Structure** rather than **Checksum** or **Full Decode** has a specific technical reason. This table documents those reasons so that structural-only depth is never treated as "we just haven't gotten to it yet" — these are fundamental limitations of the formats themselves.

| Format | Max Depth | Why Full Validation Is Impossible |
|--------|-----------|----------------------------------|
| **VMDK** | Structure | VMware's format contains **zero checksums or hashes** anywhere in the spec. Integrity relies entirely on structural consistency (magic, version, flag sanity, grain-size power-of-2, overhead bounds). The only corruption sentinel is a 4-byte newline-detection field (bytes 73–76) that catches FTP text-mode transfers — but a random bit flip in grain data is invisible. VMware's own consistency tools work the same way: they verify structural invariants, not data integrity. The optional Redundant Grain Directory (RGD) provides a second copy of the grain directory for crash recovery, but even that is a structural redundancy, not a checksum. |
| **WIM/ESD** | Structure | WIM has an **optional** integrity table (SHA-1 over ~10MB chunks), but it is absent in the vast majority of WIM files in the wild. When present, verifying it requires reading the entire multi-gigabyte file and computing SHA-1 over each chunk — prohibitively expensive for a file validator that processes hundreds of thousands of files. Our structural validation covers the 208-byte header (magic, version, flags, part numbers, reserved-zero fields, resource header offset bounds), which catches truncation, header corruption, and interrupted writes (`WRITE_IN_PROGRESS` flag). Future: if we add streaming hash verification for large-file mode, WIM could reach Checksum when the integrity table is present. |
| **Toast** | Structure | Roxio Toast disc images are essentially renamed ISO 9660 images, sometimes with an Apple Partition Map (APM) prefix. **ISO 9660 has no internal checksums.** The only cross-validation possible is comparing the PVD's declared volume space size against the actual file size (catches truncation). The Application Identifier field can confirm Toast provenance but doesn't verify data. Some Toast files are hybrid APM+ISO, but APM partition entries also lack checksums. This is a fundamental limitation inherited from the ISO 9660 and APM specs. |
| **CDG** | Structure | CD+Graphics is a raw dump of subchannel data from audio CDs — a flat stream of 24-byte packets with **no file header, no magic bytes, no checksums, and no framing**. The parity fields (bytes 2–3 and 20–23 of each packet) are physical CD EDC/ECC from the disc drive hardware; no known software validates them in ripped `.cdg` files, and software-generated CDG files leave them zeroed. Identification relies entirely on extension + size divisibility by 24. Validation checks CDG command presence and tile coordinate bounds, but a bit flip in pixel data or color table entries is undetectable. |
| **RealMedia** | Structure | RealNetworks' container format uses a simple chunk-based structure with **no CRC, hash, or checksum fields** anywhere in the spec. Not in the file header, not in chunk headers, not in media packets. The only integrity verification possible is structural: chunk sizes must not exceed file bounds, `num_streams` must match MDPR chunk count, `data_offset`/`index_offset` must point to correct chunk types. A corrupted media packet would parse structurally but produce garbage audio/video. Even the embedded RealAudio sub-headers (`.ra\xFD`) contain no checksums. |
| **MSI** | Structure | MSI files are OLE2/CFBF containers. While OLE2 has internal FAT/DIFAT structure that can be validated, the MSI-specific data inside (installer tables, CAB streams, etc.) uses no additional checksums beyond what the OLE2 container provides. MSI detection itself is the challenge — we identify it by characteristic stream names (`_Tables`, `_SummaryInformation`) or the MSI CLSID, rather than a unique magic byte sequence. The OLE2 FAT structure validation catches sector-level corruption but not payload bit flips. |
| **QOI** | Full | QOI has a mandatory 8-byte end marker (`\x00`×7 + `\x01`) that proves the encoder completed without truncation. Validate verifies this end marker at EOF. |
| **DPX** | Structure | SMPTE 268M defines a header with file size and image dimensions but **no checksum field**. DPX was designed for post-production pipelines where data integrity was assured by the storage/transport layer. |
| **TGA** | Structure | Truevision TGA has an 18-byte header with no checksum. The optional v2 footer provides a signature but no data integrity verification. |

### Video/Media Containers Without Checksums

| Format | Max Depth | Why Full Validation Is Impossible |
|--------|-----------|----------------------------------|
| **FLV** | Structure | Adobe's Flash Video container has a simple tag-based structure with **no checksums**. Tags contain type, size, timestamp, and stream ID — all structural. Payload integrity depends entirely on the codec stream inside. |
| **ASF/WMV/WMA** | Structure | Microsoft's Advanced Systems Format uses 128-bit GUIDs for object identification and has object size fields, but **no CRC or hash anywhere in the spec**. ASF was designed for streaming where transport-layer integrity (TCP) was assumed. |
| **DV** | Structure | DV is a fixed-structure format (DIF blocks of 80 bytes in defined sections) with **no checksums**. It relies on physical tape error correction. A corrupted byte in video data is invisible at the container level. |
| **IVF** | Structure | IVF is a minimal testing container (from the WebM project) with a 32-byte file header and 12-byte frame headers. **No checksums by design** — it's a thin wrapper around raw VP8/VP9/AV1 frames for codec testing. |
| **MPEG-TS** | Structure | Transport Stream has 188-byte packet sync bytes and 4-bit continuity counters but **no payload checksums**. MPEG-TS was designed for broadcast where FEC (forward error correction) at the physical layer handles corruption. The sync byte (0x47) and continuity counter catch packet-level loss but not bit-level payload corruption. |
| **MPEG-PS** | Structure | Program Stream has pack headers with SCR timestamps and system headers, but **no CRC or hash** over PES packet payloads. Like TS, it relies on the transport/storage layer for data integrity. |

### Other Structural-Only Formats

| Format | Max Depth | Why Full Validation Is Impossible |
|--------|-----------|----------------------------------|
| **PBM/PGM/PPM/PAM** | Structure | Netpbm formats are intentionally minimal ASCII/binary image formats with **no metadata, no checksums, no compression**. The entire spec is a magic number + dimensions + raw pixel data. A corrupted pixel byte is indistinguishable from a legitimate pixel value. |
| **Adobe InDesign** | Structure | INDD uses a proprietary binary format with a unique magic sequence but **no publicly documented checksums**. We now validate 4096-byte page alignment, dual master page magic (primary + duplicate), and sequence number consistency — but the format contains no checksum fields, so payload corruption within the database pages remains undetectable. |
| **Adobe After Effects** | Structure | AEP files use RIFX (big-endian RIFF) containers. RIFF has chunk IDs and sizes but **no per-chunk checksums**. |
| **Adobe Illustrator** | Structure | Modern AI files are PDF-based (validated as PDF when possible) or PostScript-based. Legacy PS-based AI files have no checksum mechanism. |
| **RTF** | Structure | RTF is a plain-text markup format. Validation is limited to brace matching (`{`/`}`) and control word syntax. **No checksums exist** — RTF is just tagged text. |
| **WordPerfect** | Structure | WPD has a header signature and document area offset but **no checksums** in the publicly known spec. The format is proprietary and largely undocumented beyond the header. |
| **Reaper** | Structure | RPP files are UTF-8 text with bracket-delimited sections. **No checksums** — it's a human-readable text format, like a structured config file. |
| **Access MDB/ACCDB** | Structure | Jet/ACE database format has page structures but page-level checksums are **not present in MDB** (Jet 3.x/4.0) and only optionally present in ACCDB. Unlike SQLite (which has per-page checksums), Access relied on the filesystem for data integrity. |
| **STL/DXF/STEP** | Structure | CAD interchange formats (STL, DXF, STEP) are often plain-text or minimal-binary formats designed for cross-tool portability. **None include checksums** — they rely on the file system. STL's binary variant has a triangle count but no data integrity verification. |
| **MBOX** | Structure | MBOX is a plain-text concatenation of email messages delimited by "From " lines. **No checksums** — it predates modern integrity mechanisms, designed when filesystem reliability was assumed. |
| **YAML** | Structure | YAML is a text serialization format. We currently only detect structure (not full parse) because the Zig ecosystem lacks a mature YAML parser. This is a **tooling limitation, not a format limitation** — full parse would achieve Integrity. |

**Formats with partial integrity coverage (not listed above):** Some formats like MPEG-TS have sync bytes and continuity counters but no payload checksums — these provide structural validation that catches gross corruption (packet loss, desync) but not bit-level payload corruption. These are documented inline in their respective table rows.

---

## Images

| Format | Extensions | Basic Validation | Deep Validation | Max Depth | GT |
|--------|------------|------------------|-----------------|-----------|-----|
| **PNG** | .png | Signature, chunk structure, IEND terminator | CRC32 per chunk | Checksum | — |
| **JPEG** | .jpg, .jpeg | SOI/EOI markers, segment structure | Full decode via libjpeg-turbo | Full Decode | — |
| **JPEG XL** | .jxl | Codestream (FF 0A) or container signature | First-party strict validation via exact-pinned libjxlz; preserves valid/corrupt/unsupported/indeterminate. The current `bicycles.jxl` fixture remains indeterminate, so no full-family claim is permitted yet. | Partial (blocked) | 1 |
| **GIF** | .gif | Header (GIF87a/89a), trailer (0x3B), block structure | Full LZW decode via zigimg | Full Decode | 1 |
| **BMP** | .bmp | Header, DIB header, pixel data bounds | Row-by-row pixel data bounds traversal (proves all rows readable). **BMP spec has no data checksums — pixel-data bit flips are fundamentally undetectable.** | Structure | 1 |
| **WebP** | .webp | RIFF container, VP8/VP8L/VP8X chunks | Full decode via libwebp | Full Decode | 1 |
| **TIFF** | .tiff, .tif | Header (II/MM), IFD structure, tag validation | Full decode via zigimg | Full Decode | 1 |
| **HEIC/HEIF** | .heic, .heif | ISOBMFF structure, ftyp brand validation | Pure Zig HEIF container + H.265 NAL/SPS/PPS + per-tile CABAC arithmetic decode (NAL length/type, tile count). Note: CABAC absorbs corruption — 0%/0% detection (fundamental limitation) | Full Decode | 1 |
| **AVIF** | .avif | ISOBMFF structure, ftyp brand validation | Pure Zig HEIF container + AV1 OBU validation | Full Decode | 1 |
| **SVG** | .svg | XML declaration, `<svg>` root element | Full XML parse | Integrity | — |
| **OpenEXR** | .exr | Signature (76 2F 31 01), header structure | Required attribute validation (channels, compression, windows) | Integrity | — |
| **QOI** | .qoi | Signature (qoif), width/height/channels/colorspace | Header field validation + mandatory 8-byte end marker at EOF (proves encoder completed without truncation) | Structure | — |
| **DPX** | .dpx | Signature (SDPX/XPDS), version, endian detection | Full SMPTE 268M header: file_size field cross-checked against actual file size (truncation detection), image dimensions | Structure | — |
| **TGA** | .tga, .targa | 18-byte header, image type, dimensions | TGA v2 footer signature detection ('TRUEVISION-XFILE.\0'), extension/developer area offset bounds checking | Structure | — |
| **PBM/PGM/PPM/PAM** | .pbm, .pgm, .ppm, .pam | P1–P7 magic + whitespace, complete header parser for all variants | Exact data size calculation from dimensions for binary formats (P4/P5/P6/P7), truncation detection | Structure | — |

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
| **Adobe InDesign** | .indd | Magic (0606EDF5 x16) on both primary and duplicate master pages | 4096-byte page alignment, 16-byte magic verified on both master pages, sequence number consistency cross-check | Structure | — |
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
| **MPEG Audio Layer II** | .mp2, .mpa | minimp3 | Public Domain | ✅ Full Decode | Same MPEG audio frame structure as MP3; reuses MP3 validator | — |
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
| **AMR** | .amr | Pure Zig | — | ✅ Structural | Full frame structure walk: NB (8 modes + SID/comfort noise) and WB (9 modes) frame sizes, reserved frame types rejected (NB: 12–14, WB: 10–14), streaming truncation tolerated | — |
| **AU/SND** | .au, .snd | Pure Zig | — | ✅ Structural | Sun/NeXT header, encoding/rate/channel validation; data_size field cross-checked against actual file size (truncation detection) | — |
| **TTA** | .tta | Pure Zig | — | ✅ Checksum | TTA1 header CRC-32 verified; deep path also verifies seek table CRC-32 and per-frame CRC-32 covering all audio bytes | — |
| **CAF** | .caf | Pure Zig | — | ✅ Structural | Full chunk walk: required desc chunk verified, printable ASCII chunk type enforcement, size bounds checking | — |
| **DTS** | .dts | Pure Zig | — | ✅ Full Decode | Sync word + frame header + boundary chaining | 1 |

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
| **RealMedia** | .rm, .rmvb, .ra | ".RMF" magic (big-endian), file_version, num_headers | Chunk walk (PROP/MDPR/CONT/DATA/INDX), num_streams == MDPR count cross-check, data_offset/index_offset bounds verification | Structure | 1 |

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
| **Word 97-2003** | .doc | OLE2/CFBF header, FAT structure, stream detection | FIB parsing + Table stream cross-validation + CLX/Piece Table with full PCD decode (FcCompressed Latin-1/UTF-16LE physical offset verification) + PlcBteChpx/PlcBtePapx CP monotonicity + BTE page number bounds | Full | 5 |
| **Excel 97-2003** | .xls | OLE2/CFBF header, FAT structure, Workbook stream | BIFF8 record chain + BoundSheet8 cross-validation + SST string parsing + formula token validation + cell record cross-validation | Full | 4 |
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
| **PAR2** | .par2 | Parity archive magic, packet structure | MD5 per packet | Checksum | — |
| **WARC** | .warc | WARC/ version header, record structure | SHA-1 block digest verification | Checksum | — |
| **BinHex** | .hqx | BinHex 4.0 header, 6-bit encoding | Header/data/resource CRC16 | Checksum | — |
| **BagIt** | directory | bagit.txt version/encoding, bag-info.txt | SHA-256/SHA-512/MD5 manifest verification (streaming 64KB hash) | Checksum | 1 |
| **Microsoft Cabinet** | .cab | Magic (MSCF), reserved fields zero, version 1.3, cbCabinet vs file size | CFDATA XOR-fold checksum verification on every data block | Checksum | 1 |
| **StuffIt** | .sit | SIT!/rLau magic (classic), "StuffIt (c)" text header (v5), installer variants (ST46/50/60/65/in/i2/i3/i4), optional MacBinary prefix | CRC-16/IBM (poly 0xA001) per entry header (classic); CRC-16/CCITT (poly 0x1021) per entry (v5) | Checksum | 1 |
| **StuffIt X** | .sitx | "StuffIt!" magic (8 bytes) | Element stream walk to type-0 terminator; per-element CRC-32 where present | Checksum | 1 |
| **Compact Pro** | .cpt | Header magic, archive structure | — | Structure | — |
| **BLIP Archive** | .blar | BLAR\x02 magic, outer container checksum | LP envelope parsing, outer BLAKE3-128/xxHash64/CRC-32 container checksum, per-file DATA checksum | Full | — |
| **BLIP Mini-Archive** | .mblar | BLAR\x02 magic (flat files only), outer container checksum | Same as BLAR: LP envelope parsing, outer + per-file checksums | Full | — |

## DAW Project Formats

| Format | Extensions | Basic Validation | Deep Validation | Max Depth | GT |
|--------|------------|------------------|-----------------|-----------|-----|
| **Ableton Live** | .als | Gzip-compressed XML detection | Full gzip CRC32 verification | Checksum | — |
| **Reaper** | .rpp | UTF-8 text, `<REAPER_PROJECT` header | Bracket structure parsing | Structure | — |
| **Logic Pro X** | .logicx | ZIP-based package structure | CRC32 per entry | Checksum | — |
| **FL Studio** | .flp | FLhd/FLdt chunk structure | Full TLV event parsing | Full Decode | — |
| **Studio One** | .song | ZIP-based, metainfo.xml detection | CRC32 per entry | Checksum | — |
| **Bitwig** | .bwproject | Size check + ZIP rejection only | — | ⚠️ Stub | — |
| **Cubase** | .cpr | RIFF magic (RIFF....NSEQ or RIFF....NRSP), header bounds | Full RIFF chunk tree walk: chunk IDs + sizes bounded to file, LIST sub-containers recursed | Structure | — |
| **Pro Tools** | .ptx, .ptf | XOR-decrypted header, BITCODE signature (0x97A5B6C8) | ZMARK block structure walk: block IDs + sizes bounded, full session block chain | Structure | — |
| **GarageBand** | .band | macOS bundle detection (.band directory), projectData presence | Alternatives/ directory detection, plist header verification (bplist00 binary or XML plist) | Structure | — |
| **Reason** | .reason | 'Propellerheads Reason Song File\x1A' magic (32 bytes) | IFF-like chunk walk after magic: chunk IDs + sizes bounded to file | Structure | — |

> **Note:** Bitwig uses a proprietary undocumented binary format and remains a stub validator.
> Pro Tools, GarageBand, and Reason have been reverse-engineered (clean-room) and now have structural validation.
> Pro Tools uses trivial XOR obfuscation (key derived from 2 cleartext header bytes), not real security.

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
| **Quake/Source BSP** | .bsp | Version whitelist (Quake 1/2/3 and VBSP/Source variants), lump count validation | Full lump directory parsing: lump offsets + sizes bounded to file size, overlap detection between lumps | Structure | — |
| **Valve VPK** | .vpk | Signature (0x55AA1234), version (1 or 2), tree size bounds | Full directory tree walk: extension/path/filename parsing, 0xFFFF terminators verified, v2 section sizes cross-validated | Structure | — |

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

## Karaoke Formats

| Format | Extensions | Basic Validation | Deep Validation | Max Depth | GT |
|--------|------------|------------------|-----------------|-----------|-----|
| **CD+Graphics** | .cdg | File size must be exact multiple of 24 bytes (packet size), CDG command packet presence check | Tile coordinate bounds validation (row ≤ 17, col ≤ 49), CDG-to-null packet ratio analysis | Structure | 1 |

## Windows Installer Formats

| Format | Extensions | Basic Validation | Deep Validation | Max Depth | GT |
|--------|------------|------------------|-----------------|-----------|-----|
| **Microsoft Installer** | .msi, .msp, .mst | OLE2/CFBF magic, MSI-specific stream detection (_Tables, _SummaryInformation, CLSID {000C1084-...}) | OLE2 FAT/DIFAT/directory validation | Structure | — |

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
| **Roxio Toast** | .toast | APM DDR signature ("ER") and/or ISO 9660 PVD ("CD001" at sector 16), Application Identifier check for Toast provenance | Volume size cross-check (PVD volume space size × block size vs file size) | Structure | 1 |
| **VMDK** | .vmdk | VMDK4 sparse (magic 0x564D444B), COWD/ESXi (magic 0x44574F43), descriptor-only (text "# Disk DescriptorFile") | Header flags, grainSize power-of-2, overHead bounds vs file size, newline sentinel corruption detection, uncleanShutdown flag | Structure | 1 |
| **WIM** | .wim | Magic "MSWIM\0\0\0", hdr_size=208, wim_version=0x10D00 | Resource header offset bounds, WRITE_IN_PROGRESS flag, single-compression-type rule, reserved-zero check, integrity table structure (if present) | Structure | 1 |
| **ESD** | .esd | Same as WIM but wim_version=0x0E00 + LZMS flag | Same as WIM | Structure | 1 |

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

## EDI (Electronic Data Interchange)

| Format | Extensions | Basic Validation | Deep Validation | Max Depth | GT |
|--------|------------|------------------|-----------------|-----------|-----|
| **X12 EDI** | .edi, .x12 | ISA segment parsing, self-describing delimiters | SE/GE/IEA control total cross-validation | Integrity | 1 |
| **UN/EDIFACT** | .edifact | UNA/UNB segment parsing, delimiter detection | UNT/UNZ message and interchange count validation | Integrity | 1 |

## PIM (Personal Information Management)

| Format | Extensions | Basic Validation | Deep Validation | Max Depth | GT |
|--------|------------|------------------|-----------------|-----------|-----|
| **iCalendar** | .ics | BEGIN/END nesting, VERSION/PRODID required | Component validation (VEVENT/VTIMEZONE), DTSTART format | Integrity | 1 |
| **vCard** | .vcf | BEGIN/END:VCARD envelope | Version-specific required properties (FN for v4, N+FN for v3) | Integrity | 1 |

## Crypto/Certificate Formats

| Format | Extensions | Basic Validation | Deep Validation | Max Depth | GT |
|--------|------------|------------------|-----------------|-----------|-----|
| **PEM** | .pem, .crt, .key | Header/footer matching (-----BEGIN/END-----) | Base64 validation + ASN.1 DER parsing inside | Integrity | 1 |
| **DER** | .der, .cer | ASN.1 tag 0x30 (SEQUENCE), length encoding | Recursive TLV parsing with depth limit | Integrity | 1 |

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

**Pure Zig (no external dependencies):** FLAC, WAV, AIFF, ALAC, AC-3, DTS, E-AC-3, AMR, AU/SND, TTA, CAF, ProRes, MPEG-1/2, MPEG-4 Part 2, VP8, VP9, Theora, DV, H.264, H.265/HEVC, AV1, AAC, HEIC, AVIF, PNG, QOI, DPX, TGA, PBM/PGM/PPM/PAM, ZIP, GZIP, BZIP2, 7-Zip, BagIt, X12 EDI, EDIFACT, iCalendar, vCard, PEM, DER, all container parsing

**BSD/MIT Licensed Libraries:** libopus, libvorbis, libjpeg-turbo, OpenJPEG, zigimg (GIF, BMP, TIFF, RAW), libwebp (WebP), exact-pinned first-party libjxlz (JPEG XL), libbrotli (Brotli)

**GPL Blocked:** WMV/VC-1, RealVideo/Audio - would require optional plugin architecture (DTS was previously blocked, now implemented in pure Zig)

**Note:** Six C library dependencies (OpenH264, libde265, dav1d, libvpx, libheif, libfdk-aac) were replaced with pure-Zig validators in February 2026. VideoToolbox (macOS hardware decoder) was also removed.

---

## Corruption Detection Rates

All per-format sniper (1-bit flip) and shotgun (4KB overwrite) detection rates live in the single canonical source:

**→ [`docs/corruption-detection-report.md`](docs/corruption-detection-report.md)**

That report is regenerated from the raw TSV data in `docs/corruption-sweep-results/` (100 trials per format per mode, PCG32 seed=42) and includes per-row run dates, sample file paths and sizes, integrity mechanism, and pre-launch action items for detected gaps. Referencing it here rather than duplicating keeps both sources in sync.
