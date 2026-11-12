---
name: simruntime-offload
description: Diagnose missing Simulator runtimes, misleading Xcode download prompts, or external-volume issues on Macs using simruntime-offload, and manage offloaded runtimes when requested. Ordinary simulator builds, runs and tests need no special workflow.
---

# Simulator runtime offload

`simruntime-offload` serves Xcode Simulator runtimes from an external volume.
Attached runtimes work with normal simulator tools; use the environment's usual
build, test and device-control workflow. No offload preflight is needed when
simulators are working.

## When a runtime appears missing

- Xcode Settings > Components and the generic simulator destination can show
  **Get** even while specific simulators work. This alone does not mean the
  runtime is missing. Downloading it again creates an internal copy.
- Check usable runtimes with `xcrun simctl list runtimes -j`. The different
  command `xcrun simctl runtime list -j` inventories internally registered
  images; it is not a complete inventory of offloaded runtimes.
- If this Mac uses the tool, run these read-only diagnostics before attempting
  a runtime download, reinstall or simulator reset:

  ```sh
  simruntime-offload list
  simruntime-offload doctor
  ```

- A disconnected volume makes its runtimes unavailable. Reconnection normally
  restores them automatically within seconds; attachment after login can take
  about a minute. Inspect the reported state rather than repeatedly resetting
  simulator services. The log is
  `~/Library/Logs/simruntime-offload/agent.log`.
- Initial setup or an upgrade may be waiting for macOS removable-volume access
  consent. Report that prompt to the person using the Mac. For an interrupted
  operation, follow the diagnostic's recovery command; `sync --dry-run` can
  preview reconciliation without changing anything.

## When managing runtime storage

- Only runtime images are offloaded. Simulator device and app data stay on the
  internal disk; new runtime downloads also land there before offloading.
- Use the tool's commands instead of manually editing mounts, runtime links or
  its manifest. Every mutating command accepts `--dry-run`.
- Offload, restore and eject require all simulators to be shut down. Coordinate
  with other simulator work before doing so; a failed build alone does not
  justify shutting down unrelated devices or restarting services.
- Use `simruntime-offload eject` before disconnecting the volume. Do not add
  `--force-unmount`, `--delete-image` or `--allow-unvalidated-version` merely to
  get past a failure; those options change the operation's safety assumptions.

For command details and recovery, read the installed tool's `help` and the
project [README](../../README.md).
