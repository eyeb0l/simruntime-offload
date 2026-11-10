# Results: batches 0–2 (2026-11-10)

Plan: [experiment-plan.md](../../experiment-plan.md). Environment as in
[technical-assessment.md](../../technical-assessment.md). No step used `sudo`.

**Outcome in one line:** a simulator booted and ran an app from a runtime whose
image lives only on the external SSD, with zero internal bytes for that
runtime — but three problems surfaced that a trustworthy tool must solve, and
the batch stopped at a planned stop condition (the image could not be
unmounted cleanly).

## State left on the machine

| Item | State |
|---|---|
| Existing runtimes 24B114 and 24B8117 | Unchanged, both `Ready`. |
| `/Volumes/sparkle/SimRuntimes/` | Two verified images: 24B114 (7.7 GiB, a copy; the internal original is untouched) and 24A434 (7.5 GiB, now the only copy). |
| iOS 27.0 image | **Still mounted** read-only at `~/Library/Application Support/simruntime-offload/mnt/24A434`. Not registered with CoreSimulator (symlink removed). |
| `~/Library/Developer/CoreSimulator/Profiles/Runtimes/` | Exists, empty. |
| Device `sro-offload` (`18A6419E-…`) | Shut down; listed as unavailable because its runtime is not registered. 3.2 GB of device data. |
| CoreSimulatorService | Restarted once (step 2.6). `simdiskimaged` was not restarted. |

Do not unplug the SSD while the image is mounted.

## Batch 0 — baseline (pass)

| Measure | Result |
|---|---|
| First boot of a new device on iOS 27.2 (24B8117, internal) | 39 s, of which 31 s data migration |
| `xcodebuild` build of the fixture for that device | succeeded, 43 s (cold) |
| Install and launch | succeeded; the app displayed "Version 27.2 (Build 24B8117)" |

The throwaway device was deleted afterwards.

## Batch 1 — SSD soak and staging (pass, with one check inconclusive)

| Step | Result |
|---|---|
| `diskutil verifyVolume` | Volume and container "appear to be OK". Note: it unmounts and remounts the volume to do this, which the plan described as read-only. |
| Copy 8.31 GB + SHA-256 of source and copy + `hdiutil verify` | 2 min 3 s in total; hashes identical; UDIF checksum valid |
| Cold read-back after a clean unmount and remount | SHA-256 identical; 20 s, about 415 MB/s including hashing |
| Kernel log scan for I/O errors | **Inconclusive.** Kernel messages are not visible to an unprivileged `log show`, so the absence of errors proves nothing. The checksums are the evidence. |

## Batch 2 — serving a disposable runtime from the SSD

### Space accounting (verified)

Measured as the size of the AssetsV2 simulator-runtime directory, because
container free space is confounded by swap (swap grew from 1 GB to 6 GB during
batch 0 alone).

| Point | AssetsV2 runtime directory |
|---|---|
| Before download | 16,236,992 KiB |
| After downloading iOS 27.0 | 24,118,504 KiB (+7.52 GiB) |
| After `simctl runtime delete` | 16,236,996 KiB |
| At the end, with the runtime having been served from the SSD | 16,236,996 KiB |

- Download took 128 s. Free space sampled every 5 s fell by 7.73 GiB at its
  lowest point, the same as the final figure: **there is no second temporary
  copy during a MobileAsset download.**
- `simctl runtime delete` took 4 s and purged the asset immediately.
- Nothing was written to `/Library/Developer/CoreSimulator/{Images,Volumes,Caches}`
  or `~/Library/Developer/CoreSimulator/Caches` at any point.
- Internal cost of the SSD-hosted runtime: **0 bytes**. The device created on
  it costs 3.2 GB of ordinary device data, as any device does.

### What worked

| Question | Result | Evidence |
|---|---|---|
| Is a symlinked bundle picked up? | Yes. A fresh `simctl` process listed iOS 27.0 three seconds after the link was created. | V |
| Does a device boot from a plain disk-image mount on external storage? | Yes. `SIMULATOR_ROOT` was on the offload mount; build 24A434. | V |
| Does the Xcode build path work against it? | `xcodebuild … -destination id=<udid> build` succeeded; `simctl install` and `simctl launch` succeeded; the app displayed "Version 27.0 (Build 24A434)" ([screenshot](hellosim-on-ssd-runtime.png)). | V |
| Did TCC block access through the image? | No denial was logged and nothing failed for that reason. One run, from a terminal that already had access to the volume; not yet a general answer. | V, narrow |
| Does CoreSimulator drop the runtime cleanly when the volume is asked to unmount? | Yes. It unloaded the bundle, regenerated its runtime list and approved the unmount ([log](graceful-unload.log)). The device became "unavailable, runtime profile not found" and a boot attempt failed with "Unable to boot device because we cannot determine the runtime bundle." | V |
| Were the existing runtimes disturbed? | No. Both stayed `Ready` throughout, including across the service restart. | V |

### Problems found

**P1 — stale registration after delete (required the conditional restart).**
When the internal copy of iOS 27.0 was deleted, the running CoreSimulatorService
ignored the disappearance of its volume and kept the runtime registered at the
now-unmounted cryptex path. Thirty seconds later it rejected the SSD copy as a
duplicate of that stale entry ([log](stale-registration.log)). Fresh `simctl`
processes, which build their own list, showed the runtime as available, while
device creation — performed by the service — failed with "runtime path not
found". Restarting the per-user service
(`launchctl kickstart -k user/<uid>/com.apple.CoreSimulator.CoreSimulatorService`,
pre-approved, no simulators booted) fixed it; `simdiskimaged` kept its PID and
both existing runtimes stayed `Ready`.
*Consequence:* offloading a build in the same login session as deleting its
internal copy needs a service restart. This is very likely the same defect
behind public reports of deleted runtimes lingering until reboot.

**P2 — the volume cannot be unmounted cleanly (stop condition; not forced).**
After the runtime was unloaded and every simulator shut down, `hdiutil detach`
failed twice with "Resource busy". The holder is `SimLaunchHost.arm64`, a
per-user CoreSimulator XPC helper, which keeps
`RuntimeRoot/usr/lib/system/host/liblaunch_sim.dylib` mapped from each runtime
it has loaded and does not release it when the runtime is unloaded.
`simdiskimaged` contains an "Unmounting …, attempt=…, force=…" retry path,
which suggests Apple's own daemon resorts to forced unmounts for the same
reason. (S for that last point.)
*Consequence:* a clean eject needs either a restart of that helper or a forced
unmount; and pulling the cable with the helper holding a mapping is likely to
crash the helper at least. Neither was attempted.

**P3 — the first boot was slow.** *(Resolved: caused by `hdiutil attach`; see
[attach-stack-and-eject.md](attach-stack-and-eject.md).)* 219 s for the first boot on the SSD-hosted
runtime against 39 s for the baseline. The second boot took 36 s. App launch
took 27 s once and 144 s once. The cause is not established. Candidates, none
yet isolated:
- `hdiutil attach` uses the legacy DiskImages stack, which decompresses in a
  user-space helper (`diskimages-helper` was observed at 40% CPU). macOS 27
  marks `hdiutil attach`/`detach` deprecated in favour of
  `diskutil image attach` / `diskutil eject`.
- A cold cache: every block came off USB and through LZFSE for the first time.
- The machine was under memory pressure (4.4 GB of swap in use, load average
  7–8) from unrelated applications, so all timings here are noisy.

**P4 — the Device panel tooling timed out on this device.** `agent-device open`
failed twice with "Daemon request timed out" (90 s limit) on the SSD-hosted
device, having worked on the baseline device. Probably a symptom of P3. The
launch was verified with `simctl launch` instead, which is the operation the
test plan names.

### Not done

- **Step 2.8, Xcode GUI.** Whether Xcode lists iOS 27.0 as a run destination
  and what Settings ▸ Components shows was not observed; it needs someone at
  the screen while the runtime is attached.
- **Step 2.9, re-attach and boot again.** Blocked by P2.
- **Dangling-symlink behaviour.** The harness removes the link before
  detaching, so the case of a link whose target has vanished was not exercised.

## What this changes

- Approach C is confirmed as a working mechanism on macOS 27.2 / Xcode 27.2,
  not merely a reading of the code.
- It is not yet a reliable one. P1 and P2 both need a restart of a per-user
  CoreSimulator process at well-defined moments (after delete; before eject),
  which a tool can do safely only when no simulator is booted. P3 must be
  understood before anyone would accept the result for daily use.
- The harness should move from `hdiutil` to `diskutil image attach`, both
  because the former is deprecated on this OS and because it is the leading
  suspect for P3.
