# validate

Deterministic, byte-level validation across a wide range of file formats (100+, see FORMAT_VERIFICATIONS.md).

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
