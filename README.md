# validate

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
./zig-out/bin/validate <path> [--jobs N]
```
`--jobs 0` (default) uses all available cores.
`MAX_FILES` limits the number of files scanned when validating a directory.
`MEM_TELEMETRY=1` logs per-file RSS memory samples (use `MEM_TELEMETRY_PATH` to log to a file, `MEM_TELEMETRY_EVERY=N` to sample every N files).
`ZIP_TELEMETRY=1` logs slow ZIP entry validation details to stderr (adjust threshold with `ZIP_SLOW_SECONDS`).

## Tests
```bash
./test
```

## Windows Tests (CrossOver)
```bash
./test-windows
```
Requires a CrossOver bottle named `windows-dev-test` (or set `CROSSOVER_BOTTLE`).
Note: this is a temporary external dependency; we plan to make the runner self-contained via `flake.nix`.
