# Uninstalling, and installing again, with the native tool

2026-11-10. macOS 27.2.1, Xcode 27.2 (running throughout), CoreSimulator
1174.21. Tool at build step 6 (release build). Evidence labels as in the
technical assessment. Run with the project owner's approval, on the two
runtimes she uses: iOS 27.0 (24A434) and iOS 27.2 (24B8117).

## Before

Both runtimes served from the volume, none on the internal disk, the agent
loaded, no simulator booted. Both images matched their `SHA256SUMS`. The state
directory also held five files left by the experiment harness.

## `uninstall`

85 s, exit 0.

| Check afterwards | Observed |
|---|---|
| `simctl runtime list` | Both builds registered as "Disk Image", Ready, 15.3 GiB together |
| `simctl list runtimes` | Both available, from `/Library/Developer/CoreSimulator/Volumes/iOS_<build>` |
| Devices | Both still present, attached to the same runtime identifiers |
| LaunchAgent | Property list gone; `launchctl print` finds no such service |
| `~/Library/Application Support/simruntime-offload` | Gone, including the harness's five files |
| `~/Library/Logs/simruntime-offload` | Gone |
| `/private/tmp/simruntime-offload-501` | Gone, with its three per-build directories |
| Offload mounts | None |
| `/Library/Developer/DeviceKit/Runtimes` | Still there, empty; the tool printed `sudo rmdir …` and did not run it |
| Both daemon inboxes | Empty |
| Images on the volume | Both present and matching their checksums |
| "Left in place" | Nothing reported |

Everything the tool had installed was removed, each item named in its output,
and nothing else was. (V, one run)

## Installing again

| Step | Time | Result |
|---|---|---|
| `setup` | — | "Manifest: 0 runtime(s)"; agent installed and loaded. |
| `offload 24A434` with no `--volume` | — | Refused: no volume chosen and none in use to default to. |
| `offload 24A434 --volume <UUID>` | 25 s | Reused the image on the volume after comparing checksums. |
| `offload 24B8117` | 22 s | Defaulted to the volume now in use; reused the image. |

Afterwards: no disk images on the internal disk, both inboxes empty, both
runtimes listed, `iphoneos27.2` still matched to 24B8117, both devices
present, `doctor` all ok. The internal Data volume showed 72 GiB free before
the uninstall, 56 GiB after it, and 72 GiB again after the second offload.

The reinstalled agent was then tested by removing one runtime's link and
ejecting its image by hand, and starting the agent: it attached and linked the
runtime within 3 s. So the new agent program has the access it needs to the
removable volume. Whether macOS showed a consent prompt for it was not
observed from here. (V)

## What the run showed

**A leftover from the harness would have poisoned the next `setup`.** Found
before the run. `uninstall` as first written left the harness's
`runtimes.tsv` in the state directory, on the principle of removing only what
the tool put there. But `setup` adopts that file when there is no manifest,
and after an uninstall there is none: the next `setup` would have recorded
both builds as offloaded while they were installed on the internal disk, and
the agent would have attached second copies of them. `uninstall` now removes
the harness's files by name as well. Nobody but this machine has such files;
the adoption code that makes them dangerous should be removed before a
release rather than carried.

**The whole way out and back takes about two and a half minutes** for two
runtimes, with no network and no re-download, because the images stay on the
volume and are reused.

## Not tested

- `uninstall --leave-runtimes-on-volume` for real.
- An uninstall with the volume absent, or with too little internal space
  (both unit-tested; both stop before changing anything).
- Whether Xcode's Components pane changed during the cycle.
