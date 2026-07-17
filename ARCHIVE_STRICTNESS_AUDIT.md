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

## Findings

| Component | Required invariants | Status |
|---|---|---|
| TIFF LZW (`tiffz`) | EOD code and exact decoded extent for each strip/tile | Open: decoder currently reaches EOF without proving EOD, and its caller discards decoded length. |
| ZIP | Entry size and CRC | Pending audit |
| GZip/zlib/Deflate | End-of-stream, checksum, declared size where applicable | Pending audit |
| 7z / RAR / CAB / TAR | Container-specific stream boundaries and checksums | Pending audit |

## Compatibility rule

An implementation may intentionally tolerate a documented historical writer
quirk only when a mainstream reader accepts it and the exact cause is surfaced
as WARN. It must not cause unrelated truncation, size discrepancies, or
checksum mismatches to pass.
