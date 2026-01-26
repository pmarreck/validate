# validate

Data silently rots.

- Facebook reports **hundreds of CPUs** showing silent data corruption across **hundreds of thousands of machines** over 18+ months. [Silent Data Corruptions at Scale](Silent%20Data%20Corruption%20at%20Scale.md)
- Backblaze saw a **1.57% annualized failure rate** across **~301k data drives** in 2024 - thousands of failures in one year. [Backblaze 2024 Drive Stats](https://www.backblaze.com/blog/backblaze-drive-stats-for-2024/)
- Drive capacity keeps rising (**24TB HDDs shipping**, and **20TB+** now a significant share of large fleets). [Seagate Exos X24 Data Sheet](https://www.seagate.com/content/dam/seagate/en/content-fragments/products/datasheets/exos-x24/exos-x24-DS2080-2307US-en_US.pdf) [Backblaze Q3 2025 Drive Stats](https://ir.backblaze.com/news/news-details/2025/Backblaze-Q3-2025-Drive-Stats-Rethinking-Failure-Celebrating-High-Capacity-Drive-Strength/default.aspx)
- Specs still allow unrecoverable read errors (**<1 in 10^15 bits read** for Exos X24). That's ~1 error per 125TB read - a single multi-drive scrub can reach that territory. [Seagate Exos X24 Data Sheet](https://www.seagate.com/content/dam/seagate/en/content-fragments/products/datasheets/exos-x24/exos-x24-DS2080-2307US-en_US.pdf)

If you aren't actively validating, you likely already have corrupt files that are being quietly re-copied to the cloud or your NAS as "good" backups. Family photos, legal documents, old projects, and cherished media are exactly the kind of files that get silently damaged and then preserved in that damaged state.

That's why validate exists: deterministic, byte-level validation across a wide range of file formats (100+, see [FORMAT_VERIFICATIONS.md](FORMAT_VERIFICATIONS.md)).

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
