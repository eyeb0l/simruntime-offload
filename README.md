<img src="assets/icon.svg" width="64" height="64" alt="">

# simruntime-offload

An investigation into storing and running Xcode Simulator runtimes from
external storage, reliably enough that it could be trusted for everyday
development.

**Status: the mechanism is proven on one machine; the tool is not built yet.**
A shell harness in `experiments/` serves two runtimes from an external SSD on
macOS 27.2 / Xcode 27.2. Do not run it on a machine you care about without
reading the assessment first.

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
| `experiments/sro.sh` | The harness: stage, attach, detach, sync, eject and a login agent. Not the deliverable. |
| `experiments/agent/` | The native launcher the login agent needs. |
| `experiments/bench/` | Read benchmarks used to compare disk-image stacks. |
| `fixtures/HelloSim/` | Minimal iOS app used to test build, install and launch. |
| `scripts/collect-baseline.sh` | Read-only diagnostic collection, with personal identifiers redacted. |

Created in [T3 Code](https://t3.codes).
