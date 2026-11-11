# Changelog

## Unreleased

- Releases are published as a signed and notarised archive for Apple
  silicon. The program carries a Developer ID signature, so upgrading from
  one release to the next should not ask again for access to the volume.
  Builds from source are still ad-hoc signed.

## 0.1.1 — 2026-11-10

- `eject` restarts the simulator launch helper once for all runtimes instead
  of once per runtime. Restarting a helper that has only just been restarted
  takes about ten seconds, so every runtime after the first cost that much:
  13 s for two, 23 s for three. It now takes about 3 s however many there are.
  If an image stays in use, every runtime is unregistered by the time `eject`
  stops, not only the ones before it; `sync` serves them again.

## 0.1.0 — 2026-11-10

First version. Validated on macOS 27.2, Xcode 27.2, CoreSimulator 1174, Apple
silicon, on one machine.

Commands: `doctor`, `list`, `setup`, `offload`, `sync`, `eject`, `restore`,
`uninstall`.

- Serves a runtime from an external volume through a read-only attachment of
  its image and one symbolic link in a CoreSimulator profile directory.
- `offload` verifies the copy by SHA-256 and by disk-image verification before
  deleting the internal one, and confirms the deletion by inspection.
- A login agent re-attaches runtimes at login and whenever the volume mounts.
- `eject` releases every runtime and the physical disk; nothing is forced
  without `--force-unmount`.
- `restore` and `uninstall` return runtimes to the internal disk from their
  images, offline.
- `setup` and `offload` refuse on an unvalidated system version unless given
  `--allow-unvalidated-version`. The commands that undo things never refuse on
  version.

Known limitations are at the top of the README. Not yet tested: an Xcode or
macOS update, use over days, platforms other than iOS, more than one volume or
user.
