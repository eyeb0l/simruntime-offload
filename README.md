<img src="assets/icon.svg" width="64" height="64" alt="">

# simruntime-offload

An investigation into storing and running Xcode Simulator runtimes from
external storage, reliably enough that it could be trusted for everyday
development.

**Status: the mechanism is proven on one machine; the native tool is feature
complete but has had no system test pass and no release.** Every command
exists and has been run for real on one machine, where its login agent keeps
two runtimes served from an external SSD on macOS 27.2 / Xcode 27.2. Do not
run any of it on a machine you care about without reading the assessment
first.

```
swift build
swift test                                  # unit tests, plus one test that mounts a tiny synthetic image
.build/debug/simruntime-offload doctor      # can the tool work on this Mac? changes nothing
.build/debug/simruntime-offload list        # what is on the internal disk and what is offloaded
.build/debug/simruntime-offload offload <build> --volume <UUID> --dry-run
.build/debug/simruntime-offload eject --dry-run
.build/debug/simruntime-offload restore <build> --dry-run
.build/debug/simruntime-offload uninstall --dry-run
```

Every command that changes the machine takes `--dry-run`, which prints the
plan and changes nothing.

## Documents

- [Technical assessment](docs/technical-assessment.md) — what is proven, how
  runtime storage works on this OS, the hazards found, and what is untested.
- [Design](docs/design.md) — proposal for the native tool. For review.
- [Investigation log](docs/investigation-log.md) — hypotheses, evidence,
  rejected approaches, decisions and mistakes, session by session.
- [`docs/results/`](docs/results) — the write-up of each experiment.
- [Experiment plan](docs/experiment-plan.md) — the original plan; historical.
- [`docs/baseline/`](docs/baseline) — sanitised diagnostic snapshots of the
  development machine. Machine-specific; to be removed before any public
  release.

## Layout

| Path | Purpose |
|---|---|
| `Sources/`, `Tests/` | The native tool: a Swift package with no dependencies. |
| `experiments/sro.sh` | The harness the mechanism was developed with. Superseded by the native tool; kept as the record of how the mechanism was found. |
| `experiments/agent/` | The native launcher the login agent needs. |
| `experiments/bench/` | Read benchmarks used to compare disk-image stacks. |
| `fixtures/HelloSim/` | Minimal iOS app used to test build, install and launch. |
| `scripts/collect-baseline.sh` | Read-only diagnostic collection, with personal identifiers redacted. |

Licensed under the [MIT License](LICENSE).

Created in [T3 Code](https://t3.codes).
