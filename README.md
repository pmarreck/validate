# validate

[![CI](https://github.com/pmarreck/validate/actions/workflows/ci.yml/badge.svg?branch=yolo)](https://github.com/pmarreck/validate/actions/workflows/ci.yml)
[![Mechatron Prime CI](https://img.shields.io/endpoint?url=https%3A%2F%2Fthelio-nixos.tail66c90.ts.net%2Fbadges%2Fvalidate.json&style=for-the-badge)](https://thelio-nixos.tail66c90.ts.net/mechatron-prime/)

Data silently rots.

- Facebook reports **hundreds of CPUs** showing silent data corruption across **hundreds of thousands of machines** over 18+ months. [Silent Data Corruptions at Scale](Silent%20Data%20Corruption%20at%20Scale.md)
- Drives are allowed to return unrecoverable read errors at measurable rates (e.g., **<1 in 10^15 bits read** for Seagate Exos X24). That's ~1 error per 125TB read. [Seagate Exos X24 Data Sheet](https://www.seagate.com/content/dam/seagate/en/content-fragments/products/datasheets/exos-x24/exos-x24-DS2080-2307US-en_US.pdf)
- Even SSDs cite nonzero uncorrectable bit error rates (e.g., **<1 in 10^17 bits read** for an Oracle NVMe SSD). [Oracle NVMe SSD Reliability Specs](https://docs.oracle.com/cd/E54943_01/html/E54944/goica.html)
- HDD cold-storage limits are explicit: WD Ultrastar DC HC650 specs list **storage temperature 0-70C** (non-operating **-40 to 70C**) and say a drive may not remain **inoperative for more than one year**. [WD Ultrastar DC HC650 OEM Specification (PDF)](https://manuals.plus/m/5dd73770531a1d593e592d64f03b5c74f63f745a9a64073f1c5bd78c3f97a472.pdf)
- Power-off retention is limited: JEDEC-based guidance for SSDs calls for client-class drives to retain data for **1 year at 30C after power-off**, while enterprise-class drives are only **3 months at 40C after power-off**. Drives left unpowered for a year or more are outside spec for enterprise SSDs and at the edge of spec for client SSDs. [ATP: How Temperature Affects Data Retention for SSDs](https://www.atpinc.com/blog/ssd-data-retention-temperature-thermal-throttling)
- Cosmic rays can flip bits in electronics. If errors exceed ECC capability, drives can surface uncorrectable read errors. [IBM Research on cosmic-ray soft errors](https://research.ibm.com/publications/cosmic-ray-soft-error-rates-of-16-mb-dram-memory-chips) [Oracle NVMe SSD Product Notes](https://docs.oracle.com/en/servers/options/nvme-ssd/f680/user-guide-f680-aic/known-issues-1.html)
- Temperature strongly accelerates bitrot risk: JEDEC specs cited by Curtiss-Wright note that client-class SSD retention at **BER <= 1e-15** drops to **500 hours at 52C** or **96 hours at 66C**. [Curtiss-Wright: The Effects of Extended Temperatures on Flash Endurance and Data Retention](https://defense-solutions.curtisswright.com/media-center/blog/extended-temperatures-flash-memory)
- Capacity keeps rising (**24TB HDDs shipping**), which means full reads and scrubs touch more bits and inevitably brush against those error rates. [Seagate Exos X24 Data Sheet](https://www.seagate.com/content/dam/seagate/en/content-fragments/products/datasheets/exos-x24/exos-x24-DS2080-2307US-en_US.pdf)

If you aren't actively validating, you likely already have corrupt files that are being quietly re-copied to the cloud or your NAS as "good" backups. Family photos, legal documents, old projects, and cherished media are exactly the kind of files that get silently damaged and then preserved in that damaged state.

Drive failures are obvious. Silent sector failures, copy errors, and transmission errors are not. That's why validate exists: deterministic, byte-level validation across a wide range of file formats (100+, see [FORMAT_VERIFICATIONS.md](FORMAT_VERIFICATIONS.md)).

### Why some formats resist corruption detection

Not all formats are equally detectable. Some formats include checksums (PNG, FLAC, ZIP) that make corruption trivially provable — a single flipped bit anywhere in the file will be caught. Others have no integrity mechanism at all (WAV, TIFF, raw images) and can only be validated structurally.

The most insidious case is **entropy-coded formats** like HEIC, JPEG, and H.264 video. These formats use arithmetic or Huffman coding where *every possible bit pattern decodes to a valid output*. A corrupted HEIC file doesn't crash the decoder — it silently produces a slightly wrong image. There are no invalid bitstream states for the decoder to catch, because the encoding is designed to use the entire code space efficiently. This is the fundamental tradeoff of high-efficiency compression: the same property that makes it compress well (no wasted bit patterns) also makes it corruption-opaque.

HEIC is arguably the worst case here because it is the **default photo format on every iPhone**. Billions of photos worldwide are stored in a format where a single bit flip in the CABAC-encoded data is mathematically undetectable without the original file to compare against. Even a full decode — parsing every arithmetic-coded symbol — cannot distinguish corruption from valid data, because corruption simply produces a different valid decode.

`validate` reports these realities honestly: formats are classified as "fully validated" only when every byte is covered by a checksum, decompression, or decode that would fail on corruption. Formats where corruption can hide in opaque payload data are reported as "structural" validation depth, regardless of how much parsing we perform. See [FORMAT_VERIFICATIONS.md](FORMAT_VERIFICATIONS.md#corruption-detection-rates-snipershotgun-experiments) for measured detection rates per format.

### When the decoder lies — VP8 error concealment

Some decoders go further than just "decode any bit pattern": they *actively hide* corruption from the caller. libvpx's VP8 decoder is a textbook case. Feed it a frame with mangled coefficients and it returns `VPX_CODEC_OK`, transparently patching up the damage via built-in **error concealment**. The caller — your video player, your transcoder, your backup-checker — is told everything is fine.

The damage is detectable, but only if you ask. libvpx exposes a runtime control, `VP8D_GET_FRAME_CORRUPTED`, that surfaces the internal flag the decoder set when it had to conceal something. Without that explicit query, every concealed frame validates as clean.

Without that query, validate's VP8 sniper detection sat at **0%**. With it, the same sample hits **88%** sniper / **90%** shotgun. The bytes were always damaged; the decoder just declined to mention it.

> **Your codec has error concealment. Your validator should not.**

This is exactly the silent-corruption pattern validate exists to catch — the reader said OK, but the bytes were not OK.

## Components
- Zig library (core validation)
- C FFI (stable-enough for integration, but not yet 1.0)
- C CLI wrapper: `validate`

## Status
The C FFI mirrors the current Zig validation API for ease of integration. It is expected to evolve before a 1.0 release.

## Build
```bash
./build
```
Runs `./test` first. When `DEBUG` is unset/0, dependencies build in ReleaseFast and `./build` defaults to `-Doptimize=ReleaseFast`.

## CLI
```bash
# Validate files or directories
validate <path> [path ...]
validate ~/Photos/vacation/

# Read paths from stdin (pipe, -, --stdin, or @stdin)
find . -name '*.jpg' | validate --json
validate --ndjson - < paths.txt

# JSON output for scripting
validate --json file.png          # JSON array
validate --ndjson file1 file2     # One JSON object per line

# Platform info
validate --about
```

### Options
| Flag | Description |
|------|-------------|
| `--json` | Output results as a JSON array |
| `--ndjson` | Output one JSON object per line (newline-delimited) |
| `--jobs N` | Number of parallel workers (0 = auto, default) |
| `-j N` | Alias for `--jobs` |
| `--about` | Print version and platform info |
| `--lang CODE` | Set output language (e.g., en, de, ja) |
| `--no-color` | Disable colored output |
| `--color` | Force colored output (even when piping) |
| `--simple-progress` | Use simple ASCII progress instead of TUI |
| `--shuffle` | Shuffle file order |
| `--append` | Append to output files instead of overwriting |
| `-`, `--stdin`, `@stdin` | Read file paths from stdin (newline-delimited) |
| `--strict` | Promote any WARN to FAIL globally — "is this byte-perfectly spec-compliant?" mode (opt-in) |
| `--no-strict` | In `--test-coverage`, disable the always-on strict default (legacy FAIL-only detection) |
| `--test-coverage N` | Run up to N corruption rounds against a file, report detection rate (see below) |
| `--modes LIST` | Corruption modes for `--test-coverage`: `sniper` (1 bit), `bolter` (1 byte XOR 0xFF), `shotgun` (4 KB random), `header`, `tail`, `zeroed`, `xor`, `sparse-noise`, `boundary`, `all`, `everything` |

### Corruption test modes: sniper, bolter, shotgun

`--test-coverage` perturbs a known-clean file and asks "did the validator notice?" — useful both for measuring validator strength per format and for confirming a new validator catches what it should.

| Mode | Granularity | What it does |
|------|-------------|--------------|
| **sniper** | 1 bit | Flip one random bit. Cheapest, hardest to detect (codecs often tolerate single-bit errors). |
| **bolter** | 1 byte | XOR one random byte with `0xFF` (flip all 8 bits of that byte). Intermediate granularity. Named after Warhammer 40K's bolter — single big projectile, not a single bullet, not a spray of pellets. |
| **shotgun** | 4 KB | Overwrite 4096 random bytes at a random offset. Easiest to detect; sometimes wipes enough structural metadata that the validator gives up gracefully (which only counts in strict mode — see next paragraph). |

**`--strict` is ON by default for `--test-coverage`** because the harness asks "did the validator notice ANY deviation?" — without it, a shotgun corruption that produces a depth-degraded WARN (rather than FAIL) gets miscounted as "undetected" even though the validator clearly noticed something. Concrete example from `deflate-last-strip.tiff`: shotgun detection is **69% non-strict** vs **100% strict**; the gap is purely WARN outcomes that the legacy metric didn't count. Disable with `--no-strict` to get the legacy semantics.
`--jobs 0` (default) uses all available cores (logical CPU count).
`MAX_FILES` limits the number of files scanned when validating a directory.
`MAX_VIDEO_SIZE` limits deep video validation to files under N MB (unset = no limit).
`MEM_TELEMETRY=1` logs per-file RSS memory samples (use `MEM_TELEMETRY_PATH` to log to a file, `MEM_TELEMETRY_EVERY=N` to sample every N files).
`UNKNOWN_OUT=/path` writes UNKNOWN entries to that path instead of stdout (supports `/dev/null`, `/dev/fd/1`, `/dev/fd/2`).
`ZIP_TELEMETRY=1` logs slow ZIP entry validation details to stderr (adjust threshold with `ZIP_SLOW_SECONDS`).
`PDF_TELEMETRY=1` logs slow PDF deep-validation breakdowns to stderr (adjust threshold with `PDF_SLOW_SECONDS`).

## Tests
```bash
./test
```

## Windows Tests
```bash
./test-windows
```
**On Linux (x86_64):** Uses Wine from the Nix flake devShell (automatically provided).

**On macOS:** Uses CrossOver. Requires a bottle named `windows-dev-test` (or set `CROSSOVER_BOTTLE`).
