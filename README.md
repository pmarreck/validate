# validate

Deterministic, byte-level validation across a wide range of file formats.

## Components
- Zig library (core validation)
- C FFI (stable-enough for integration, but not yet 1.0)
- C CLI wrapper: `validate`

## Status
The C FFI mirrors the current Zig validation API for ease of integration. It is expected to evolve before a 1.0 release.

## Build
```bash
zig build
```

## Tests
```bash
./test
```
