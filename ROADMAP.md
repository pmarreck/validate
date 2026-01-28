# Roadmap (Fairly Certain)

## High Priority (Current Sprint)

1. **Ground Truth Examples**: Complete valid + corrupted samples for ALL claimed formats
   - Many formats still missing ground truth examples
   - Each format needs: 1 valid sample + 5 corrupted variants
   - Run `scripts/corruption_test.sh` to verify coverage
   - See `ground_truth_examples/` for current state

2. **Investigate Remaining Hang Issues**: ~/Documents validation sometimes hangs
   - Observed: validation stops making progress after ~34k files
   - Added regression test: "PNG with .ico extension should not hang"
   - Need to identify if issue is threading-related or specific file-related
   - Consider adding progress heartbeat/timeout detection

## Medium Priority

- Expand validation coverage for additional formats (document + prioritize by prevalence).
- Strengthen full/deep validation paths for existing formats (decode fidelity and error reporting).
- Add deterministic regression tests for key formats (corpus-driven).
- Provide stable, well-documented CLI/FFI usage examples.
- Add CI for multi-platform builds and tests.
