# Corruption Detection Report

**Canonical document.** Supersedes `docs/corruption-detection-survey-2026-03-05.md` and the "Corruption Detection Rates" section of `FORMAT_VERIFICATIONS.md`. Those two sources had drifted; the table below is **generated** directly from the raw TSVs in `docs/corruption-sweep-results/` by `scripts/generate-corruption-report` — **do not hand-edit the table.** Per-format prose (the Mechanism column, section assignments, the PDF breakout) lives in the sidecar inputs under `docs/corruption-sweep-results/generated/`.

**Methodology** — three mutation modes, ordered by escalating blast radius:
- **sniper:** single random **bit** flip at a random byte offset. Measures per-byte coverage. Reversible (XOR the bit back).
- **bolter:** a single **byte** XOR'd with `0xFF` (all 8 bits flipped). Reversible. The middle tier between sniper and shotgun — in UTF-8-text formats a bolter almost always yields an invalid byte, so detection is near-total there.
- **shotgun:** **4,096** consecutive bytes overwritten with random data at a random offset. Simulates a disk-sector failure / media loss; **not** reversible.
- PCG32 PRNG, seed=42, 100 trials per format per mode.
- **Detection** = the `validate` CLI returns a non-zero exit code (a WARN-only result, e.g. the Latin-1 plain-text fallback, is exit 0 and so counts as *not* detected).
- Per-format sample = the largest ground-truth file ≥ 4,096 bytes in `ground_truth_examples/<fmt>/`. For formats where the validator's strong path depends on an internal encoding choice (EXR compression, PSD compression, MOV/AVI codec), the sample choice materially affects the number — see the per-format notes below.
- Wilson 95% CI at n=100 is ±1.8% at the extremes (0% or 100%) and up to ±10% near 50%.
- `n/a` in a cell means that mode was not measured for that row (shotgun needs a ≥ 4 KB sample; some formats have no bolter sweep yet). It is **never** a measured zero — a blank/0% would misrepresent unmeasured coverage.
- Harness: `scripts/corruption-experiment` (single-format) and `scripts/corruption-sweep` (batch). Re-run with `--count 38416` for ±0.5% precision.

**Run dates vary per row (see the "Run" column).** The bulk was swept 2026-03-06; coverage chew-throughs on 2026-04-23/25 pushed total format rows past 200; the bolter column and the ≥12 KB UTF-8 text-format re-sweep landed 2026-06-22. Rows whose ground-truth sample is < 4 KB are sniper/bolter-only by honest measurement, not by methodology gap.

---

## Canonical Results Table
