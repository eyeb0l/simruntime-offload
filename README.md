<img src="assets/icon.svg" width="64" height="64" alt="">

# simruntime-offload

An investigation into storing and running Xcode Simulator runtimes from
external storage, reliably enough that it could be trusted for everyday
development.

**Status: research. There is no working tool yet, and nothing here should be
run on a machine you care about without reading the documents below.**

## Documents

- [Technical assessment](docs/technical-assessment.md) — how runtime storage
  works on macOS 27.2 / Xcode 27.2, why symlinks fail, an evaluation of the
  existing sparsebundle workaround, and the candidate approaches.
- [Experiment plan](docs/experiment-plan.md) — the proposed experimental
  implementation and the tests that would confirm or refute it.
- [Investigation log](docs/investigation-log.md) — hypotheses, evidence,
  rejected approaches, decisions and open uncertainties.
- [`docs/baseline/`](docs/baseline) — sanitised diagnostic snapshots of the
  development machine. Machine-specific; to be removed before any public
  release.

## Layout

| Path | Purpose |
|---|---|
| `scripts/collect-baseline.sh` | Read-only diagnostic collection, with personal identifiers redacted. |
| `experiments/sro.sh` | Experiment harness for the attach-and-link approach. Unprivileged; supports `--dry-run`. Not the deliverable. |

Created in [T3 Code](https://t3.codes).
