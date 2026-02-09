# Roadmap (Fairly Certain)

## High Priority (Current Sprint)

1. **Ground Truth Examples**: Complete valid + corrupted samples for ALL claimed formats
   - ~100 formats now have ground truth examples
   - Each format needs: 1 valid sample + 5 corrupted variants
   - Run `scripts/corruption_test.sh` to verify coverage
   - See `ground_truth_examples/` for current state

2. ~~**Investigate Remaining Hang Issues**~~: RESOLVED
   - Added regression test: "PNG with .ico extension should not hang"
   - Fixed via dedicated output thread (2026-01-27)

## Experiments / Future Ideas

- **Cloud Upload Parity Survival Test**: Embed custom data (COM marker + APP15 marker) in a JPEG, import into Photos.app, let it sync to Apple/Google/Amazon Photos, re-download from each service's web interface, and compare to see which custom markers survive the round-trip. Tests feasibility of embedded parity data in files managed by cloud photo services.
- **Embedded Parity Data**: Investigate embedding Reed-Solomon parity data directly inside container formats (ISOBMFF uuid boxes, EBML Void elements, PNG ancillary chunks, etc.) so error-correction data travels with the file. See Entropy Shield project for the sidecar PAR2 approach.
- **C2PA / Content Credentials**: Explore JUMBF-based C2PA manifest support for provenance/authenticity verification.

## Medium Priority

- Expand validation coverage for additional formats (document + prioritize by prevalence).
- Strengthen full/deep validation paths for existing formats (decode fidelity and error reporting).
- Add deterministic regression tests for key formats (corpus-driven).
- Provide stable, well-documented CLI/FFI usage examples.
- Add CI for multi-platform builds and tests.
