# Results: abrupt disconnection (2026-11-10, session 10)

Design validation 2, explicitly approved: pull the SSD's cable, without
ejecting, while a simulator is running from a runtime stored on it.

Setup: the disposable device booted on iOS 27.0 served from the SSD, with the
fixture app running (168 simulator processes executing from the mount). The
runtime the owner uses was on the internal disk for the duration, so it could
not be affected.

## Timeline (CoreSimulator.log, agent log, crash reports)

| Time | Event |
|---|---|
| 19:48:59 | Cable pulled. The SSD volume and the image's volume both disappear. In the same second CoreSimulatorService logs "launchd_sim termination or bound port died": the simulator is gone. |
| 19:48:59–19:49:36 | No runtime for iOS 27.0. The device is listed as shut down and unavailable. Xcode stays responsive; its device view showed a blank screen briefly and then "unavailable" (observed by the owner). |
| 19:49:36 | Cable reconnected. launchd starts the agent, which finds the mount gone, replaces the stale link and re-attaches. `SimLaunchHost` crashes once with a bus error and is relaunched. |
| 19:49:37 | Runtime registered again, 1 s after the volume mounted. Device Hub shows the simulator as available. |

The simulator did not restart itself; it has to be started again, as after any
shutdown.

## What survived

| Item | Result |
|---|---|
| CoreSimulatorService, CoreDeviceService, `simdiskimaged` | Kept running; same PIDs before and after. |
| `SimLaunchHost` | One bus-error crash at reconnection, relaunched automatically. The same crash Apple's own `simctl runtime delete` causes. |
| Mounts | The kernel removed the dead image mount by itself. Nothing was left to clean up. |
| Crash reports | Three in total: `SimLaunchHost` and two simulator daemons. |
| The device | Booted afterwards in 7 s; its installed app intact. |
| Images on the SSD | Both still match their SHA-256. |
| SSD filesystem | `diskutil verifyVolume`: volume and container OK. |
| Xcode | Stayed responsive throughout; no error dialog reported. |

## What it means

- Pulling the cable is **survivable and self-healing** on this OS: the running
  simulator is lost, as it must be, and everything else recovers without
  intervention when the volume returns.
- The tool needs no special repair path for this case. The ordinary `Sync`
  already handles it, because the kernel removes the dead mount and the link
  is then merely stale.
- Unsaved state inside the running simulator is lost, exactly as if the
  simulator had been killed. Device data on the internal disk was not damaged
  in this run; one run is not proof that it never will be.
- The runtime image is read-only and nothing was being written to the SSD, so
  the SSD's own filesystem was not at risk in this test. A disconnection during
  an `offload` copy is a different case and is covered by copying to a
  `.partial` file and verifying before anything internal is deleted.

Limits of this test: one run, one simulator, an idle app, no debugger
attached, and no build in progress.
