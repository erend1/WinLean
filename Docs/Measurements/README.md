# Measurements

This folder holds the write-ups that rules reference when they declare a measured benefit:

```json
"benefit": { "type": "Performance", "value": "Moderate", "measurement": "Measured", "measurementFile": "Docs/Measurements/<rule-id>.md" }
```

WinLean makes no performance claim without a measurement. A write-up is required for every
`Performance` benefit and for `BackgroundActivity` benefits of value `Moderate` or `High`
(see [../Rules.md](../Rules.md#benefit)); validation rejects such rules without one.

## What a write-up contains

- **Rule and claim**: the rule id and the effect that is claimed, stated as something
  measurable (for example "idle CPU load", "running services", "commit charge").
- **Environment**: disposable VM or dedicated test machine, hardware, Windows product,
  edition, version, build and UBR, power source, and what else was running.
- **Method**: how the system was brought into a comparable state before each measurement
  (restart, wait until idle, same uptime), the tool (`.\WinLean.ps1 -Benchmark`, see
  [../Benchmarking.md](../Benchmarking.md), or another reproducible tool with its exact
  settings), and the number of runs before and after.
- **Results**: the individual runs, not only averages, so the spread is visible.
- **Conclusion**: whether the difference exceeds the run-to-run variation, and the benefit
  value (`Low`, `Moderate`, `High`) this supports. A difference within the noise is not a
  measured benefit.
- **Reproduction**: the commands to repeat the measurement.

A single before/after pair is not a measurement: background activity varies from minute to
minute. Use several runs under the same conditions.

No measurements exist yet; no shipped rule claims a measured benefit.
