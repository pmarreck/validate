# Archive and codec strictness audit

This is the evidence ledger for decoders that Validate uses to establish deep
validation. A successful decode must prove every invariant the format exposes;
reader compatibility is not a reason to silently accept malformed data.

## Method

For each archive/container and embedded codec, record and test:

1. Required stream terminator or end marker.
2. Exact decoded byte/pixel extent when the container declares one.
3. Checksums, hashes, or CRCs when the format carries them.
4. Whether trailing compressed or decoded bytes are legal, consumed, and
   accounted for.
5. A reader-accepted compatibility exception, if one exists, as a specific
   WARN—not a broad weakening of FAIL.

Use deterministic corrupted fixtures plus sniper/bolter/shotgun sweeps. An
improvement is accepted only if clean corpus inputs still pass and the new
invariant catches its targeted malformed fixture.

## First-pass inventory

This is source evidence, not a claim that a family is fully audited.  Each
`Open` row becomes a failing, targeted regression before its implementation is
tightened.

| Component | Required invariants | Current evidence and next check |
|---|---|---|
| TIFF LZW (`tiffz`) | EOD code; exact decoded extent for each strip/tile | **Open / first remediation.** PDF, TIFF fallback, and `tiffz` all treat EOF before EOD as success despite advertising an incomplete-source error. The `lzwz` oracle requires that regression across TIFF/PDF/GIF, then `tiffz` will compare decoded chunk extent where geometry is unambiguous. |
| ZIP (`archive_validators.zig`) | EOCD, central/local header agreement, entry bounds, decompression end, CRC-32 and sizes | Deep path walks central directory and stream-verifies stored/Deflate entries. **Open:** make unsupported/encrypted/compressed-method policy and any legal trailing-data rule explicit per entry. |
| GZip / Deflate (`archive_validators.zig`, `zlib.zig`) | Deflate terminator, optional header CRC, trailer CRC-32 and ISIZE | Deep path checks FHCRC, streams the Deflate body, then checks trailer CRC/ISIZE without caller-proportional allocation. **Open:** test concatenated-member and trailing-byte policy as deliberate cases. |
| BZip2 (`bzip2.zig`) | Block markers, block CRCs, stream terminator and stream CRC | `validateStream` validates decompressed blocks while discarding output and returns specific block/stream-CRC and EOF errors. **Next:** mutation evidence and multi-stream policy. |
| XZ (`archive_validators.zig`) | Header/index/footer CRCs, block terminators, per-block Check | Deep decompression checks CRC32/CRC64 for a single block. SHA-256 Check is explicitly WARN/unverified; multi-block Check handling is not independently proved. **Open, high priority:** add multiblock and SHA-256 fixtures before calling this fully checked. |
| Zstandard (`archive_validators.zig`) | Complete frame terminator, declared content/checksum where present | Deep path rejects non-zero final decoder remainder as a truncated frame. **Open:** document/check checksum, skippable-frame, concatenated-frame, and trailing-byte semantics. |
| 7z (`sevenz_validator.zig` via `z7z`) | Start/next-header CRCs, folder decoding, file CRCs | `z7z.archive.verify` streams decoded data into its verification sink and validates payload CRCs. **Next:** encryption and unsupported-method classification are specific structural outcomes. |
| RAR (`rarz`) | Header CRC plus per-file CRC32/BLAKE2sp where available | Deep path delegates to `rarz`; it fully verifies unencrypted entries and reports encrypted content as a structural WARN. **Next:** record recovery-record and solid/multivolume limits. |
| CAB (`cab_validator.zig`) | CFFOLDER/CFDATA bounds and CFDATA checksums | Deep path walks every CFDATA payload and verifies non-zero checksums. **Open:** actual decompression/expanded-length validation and zero-checksum policy. |
| TAR (`archive_validators.zig`) | Every header checksum, declared-size bounds, padding, two zero end blocks | Walk validates entry headers, data padding, and non-zero bytes after EOA. **Open / concrete candidate:** it currently only verifies the second zero end block *if present*; a one-zero-block EOF may pass. Add the red fixture before deciding compatibility policy. |
| PAR2 / WARC / Compact Pro / BinHex / RPM / Brotli | Family-specific packet/hash, record-boundary, stream-end, and checksum rules | Inventory complete (`archive_validators.zig`, `brotli_validator.zig`); detailed source audit is pending after the LZW migration. Start with whichever has a checksum but currently reports structural depth. |

## Audit order

1. `lzwz` extraction and TIFF declared-extent proof (shared decoder bug).
2. TAR second-end-block regression (small, deterministic container invariant).
3. XZ multi-block and SHA-256 Check classification (current depth claim needs
   sharper evidence).
4. ZIP/GZip/Zstandard trailing/concatenation policy matrices.
5. Remaining family-by-family checksum/terminator matrix, each with a clean
   specificity corpus and deterministic corruption fixture.

## Compatibility rule

An implementation may intentionally tolerate a documented historical writer
quirk only when a mainstream reader accepts it and the exact cause is surfaced
as WARN. It must not cause unrelated truncation, size discrepancies, or
checksum mismatches to pass.
