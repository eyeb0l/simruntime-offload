<img src="assets/icon.svg" width="64" height="64" alt="">

# simruntime-offload

An investigation into storing and running Xcode Simulator runtimes from
external storage, reliably enough that it could be trusted for everyday
development.

**Status: the mechanism is proven on one machine; the native tool is under
construction.** Its read-only commands (`doctor`, `list`) work. Offloading is
still done by a shell harness in `experiments/`, which serves two runtimes from
an external SSD on macOS 27.2 / Xcode 27.2. Do not run either on a machine you
care about without reading the assessment first.

```
swift build
swift test                                  # unit tests, plus one test that mounts a tiny synthetic image
.build/debug/simruntime-offload doctor      # can the tool work on this Mac? changes nothing
.build/debug/simruntime-offload list        # what is on the internal disk and what is offloaded
```

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
| `experiments/sro.sh` | The harness: stage, attach, detach, sync, eject and a login agent. Not the deliverable. |
| `experiments/agent/` | The native launcher the login agent needs. |
| `experiments/bench/` | Read benchmarks used to compare disk-image stacks. |
| `fixtures/HelloSim/` | Minimal iOS app used to test build, install and launch. |
| `scripts/collect-baseline.sh` | Read-only diagnostic collection, with personal identifiers redacted. |

Licensed under the [MIT License](LICENSE).

Created in [T3 Code](https://t3.codes).
