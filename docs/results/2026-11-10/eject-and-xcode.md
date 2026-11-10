# Results: identifying the holder, forced eject, and Xcode's interface (2026-11-10, session 4)

Follow-up to [attach-stack-and-eject.md](attach-stack-and-eject.md). Approved
scope: one read-only `sudo lsof`; a forced unmount of the idle mount and, if
clean, the full eject sequence on the working mount.

## 1. What holds a used runtime volume

One privileged, read-only command (`sudo lsof <mount point>` for both mounts):

| Process | Owner | What it held |
|---|---|---|
| `spindump` (running since 16:18) | root | 31 memory-mapped files across the two mounts: simulator daemon executables (`lsd`, `securityd`, `passd`, `healthd`, `cloudd`, …) and, on one mount, the simulator's dyld shared cache |
| `mds` | root | three directory handles on each mount root |
| `SimLaunchHost.arm64` | user | `liblaunch_sim.dylib` (already known) |

- `spindump` is the system sampling daemon. It maps the binaries of processes
  it has sampled in order to symbolicate them, and keeps them mapped while it
  lives. Simulator daemons are sampled when they exceed CPU or wake-up limits,
  which the slow legacy-attach boots made likely.
- `mds` is not the blocker: it holds the same handles on volumes that ejected
  cleanly.
- The hold is therefore **conditional and incidental**, not a property of
  CoreSimulator. A later mount that simulators booted from four times ejected
  normally, because `spindump` had not sampled anything running from it.

## 2. Forced unmount

| Test | Result |
|---|---|
| Forced unmount of the idle, unregistered legacy mount, then eject of its device | Clean. |
| Full sequence on the working mount: unregister → restart `SimLaunchHost` → forced unmount → eject | Clean; 0.8 s end to end. |
| Re-attach (`diskutil image attach`) and re-register | 0.7 s; the existing device booted in 8 s and launched the app. |
| The same cycle driven by `experiments/sro.sh detach` / `attach` | Clean; the normal eject sufficed, so the forced step was not reached. |

After each: `spindump`, CoreSimulatorService and `simdiskimaged` kept their
PIDs; both installed runtimes stayed `Ready`; no crash report from any host
process.

### Apple's own delete path is rougher than this

`SimLaunchHost.arm64` has two crash reports from today, both `EXC_BAD_ACCESS`
/ bus error, at 11:37:59 and 16:28:18. Those are the two moments a runtime was
deleted through `simctl runtime delete` (the first before this project
started). So the stock delete path unmounts a runtime underneath the helper and
crashes it. Restarting the helper *before* unmounting, as the sequence above
does, produced no such crash.

### Crash reports from inside the simulator

`UsageTrackingAgent` and `assetsd` (processes inside the SSD-hosted simulator)
left crash reports when the device was shut down 20 s after boot. A control on
the internal iOS 27.2 runtime with the same boot-and-shutdown pattern produced
crash reports from `dmd`, `ind`, `tccd`, `dtdeviceinfod` and `routined`. Daemon
crashes at an early shutdown are ordinary simulator behaviour and are **not
evidence of a problem with SSD hosting**. The control is imperfect: it is a
different iOS build, because no internal copy of 27.0 exists any more.

## 3. Xcode's interface

Observed by the project owner with iOS 27.0 registered from the SSD
(screenshots not kept in the repository; they show unrelated project names).

| Place in Xcode | What it shows |
|---|---|
| Run-destination menu | `sro-offload-3` (27.0) is listed under Simulators as a normal destination. |
| Settings ▸ Components | iOS 27.0 does **not appear at all**: not as an installed platform, and with no "Get" button. The two internal iOS 27.2 builds appear as usual. |
| Devices and Simulators window | "sro-offload-3 is unavailable." |

Interpretation:
- The Components pane is built from the disk-image registry
  (`simctl runtime list`), which a bundle-registered runtime is not part of. A
  tool cannot rely on Xcode to show or manage offloaded runtimes.
- **The important case is still untested.** iOS 27.0 is not the version the
  installed SDK asks for. If the SDK-matching runtime (iOS 27.2) were
  offloaded, Components would presumably show "Get" for it, and Xcode might
  prompt to download it before building. That is the scenario most likely to
  defeat the scheme in daily use.
- The "unavailable" message conflicts with the run-destination menu and with
  `xcodebuild`, both of which treat the device as usable. Not yet explained; it
  needs a comparison with what the same window shows for the existing
  simulator, and an actual Run from Xcode on the SSD-hosted device.

## 4. Why Xcode's device view failed: a sandboxed helper and the mount location

A Run from Xcode on the SSD-hosted device built successfully and then failed
with "Connection timed out — Live device view took longer than expected to
connect" (`DeviceKitError` 4002, `FramebufferProviderStates: none`). The
Devices and Simulators window showed "is unavailable" for that device and a
Start button for the internal one.

Cause (V, from `~/Library/Logs/CoreSimulator/CoreSimulator.log`): Xcode 27's
live device view is served by `CoreDeviceService`, which is App-Sandboxed. On
every boot of an SSD-hosted device it logged

> Ignoring runtime override for <udid> (…/simruntime-offload/mnt/…/iOS 27.0.simruntime/).
> Bundle failed to load or initialize. … Malformed bundle does not contain an
> identifier at …

"Malformed bundle" is how a denied read presents: its sandbox does not cover
`~/Library/Application Support/…`. Xcode itself, `simctl` and `xcodebuild` are
not sandboxed, so they worked, which is why this was invisible from the command
line. The same error had been logged since the very first SSD boot.

`CoreDeviceService`'s entitlements grant read-write access to `/private/tmp/`,
and it reads Apple's own mount locations
(`/private/var/run/com.apple.security.cryptexd/mnt/…`,
`/Library/Developer/CoreSimulator/Volumes/…`). With the image re-attached at
`/private/tmp/simruntime-offload-<uid>/24A434` (no privileges needed), the
error disappeared: the service logged "Sending load request for liblaunch at
file:///private/tmp/simruntime-offload-…" and bootstrap lookups for the device,
as it does for internal runtimes.

**Status:** confirmed in Xcode by the project owner. With the mount under
`/private/tmp`, a Run from Xcode booted the SSD-hosted device, the live device
view connected, and a real project's app ran in it.

**Remaining defect:** while the device is shut down, the Devices and
Simulators window still says "is unavailable" and offers no Start button. It
can still be started by running to it. Likely cause (H, not verified): the
sandboxed service builds its own runtime list, and its home directory is its
container, so it never sees the per-user symlink; booting works because
CoreSimulatorService hands it the runtime path directly. If so, only a
discovery route that does not depend on the home directory — a volume under
the trusted directory `/Library/Developer/CoreSimulator/Volumes`, which needs
root — would clear the label.

**Design consequences:**
- The mount point is constrained by other processes' sandboxes, not only by
  CoreSimulator's discovery rules. Any location must be validated against
  `CoreDeviceService` at least.
- `/private/tmp` works without root but is world-writable and emptied at
  reboot. The harness creates a per-user, mode-700 directory and refuses one it
  does not own. Whether the system's periodic temporary-file cleanup interferes
  with a long-lived mount there is untested.
- The root-requiring alternative, `/Library/Developer/CoreSimulator/Volumes/`,
  is where Apple's own fallback mounts go and is known to be readable by this
  service. It remains the fallback if `/private/tmp` proves unsuitable.

## State left on the machine

| Item | State |
|---|---|
| Installed runtimes 24B114, 24B8117 | Unchanged, `Ready`. |
| iOS 27.0 | Registered and working from the SSD: one mount, `/private/tmp/simruntime-offload-<uid>/24A434`, via `diskutil image attach`. |
| SSD | `SimRuntimes/24A434` and `SimRuntimes/24B114`. The temporary clone was removed. |
| Devices | `sro-offload-3` on iOS 27.0, shut down. The control device was deleted. |
| Privileged actions | One `sudo lsof`. Nothing else ran as root. |
