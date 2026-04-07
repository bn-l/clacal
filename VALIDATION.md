# Validation Suite

This repo now has a Swift-canonical pacing validation suite. The source of truth is the production pacing logic in `UsageOptimiser` and the shared kernel under `Sources/Clacal/Validation/`.

## What exists

- `PacingKernel.swift`
  - Pure pacing math shared by production and validation.
  - Emits structured explanations for weekly/session/daily decisions.
- `PacingReplay.swift`
  - Deterministic replay runner for synthetic poll traces.
  - Validates invariants and expected completed-week history.
- `PacingFixtures.swift`
  - Hand-authored regression fixtures for the real failure classes seen so far.
- `PacingSweep.swift`
  - Generated matrix over usage profile, artifact profile, cadence, learned schedule shape, empirical-history mode, and timezone.
- `PacingReport.swift`
  - Writes markdown summaries plus JSON payloads for replay and sweep runs.

## Local entrypoints

- `just validate-fast`
  - Runs the deterministic fixture and kernel suites.
  - Writes reports to `.build/validation/fast/`.
- `just validate-sweep`
  - Runs the generated sweep in strict mode.
  - Writes reports to `.build/validation/sweep/`.
  - Fails if any scenario violates the current invariants.

## Notes

- The suite uses checked-in synthetic traces only.
- The heavy sweep is intentionally stricter than ordinary tests.
- `swift build --build-tests` is enough to compile the full validation stack without executing it.
