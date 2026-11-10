# Technical assessment

Status: consolidated after nine sessions of investigation and experiment on
2026-11-10, and updated after the native tool was built and system-tested the
same day (§4, §7). This replaces the initial assessment written before any
experiment was run; that version is in the repository history (the first
commit after the initial one).

Scope of validity: **macOS 27.2.1 (26B131), Xcode 27.2 (27B52), CoreSimulator
1174.21, Apple silicon, one machine.** The storage design for Simulator
runtimes changed in Xcode 14, 16, 26 and 27, so nothing here should be assumed
to hold on another version without re-testing.

## Evidence labels

| Label | Meaning |
|---|---|
| **V** | Verified by direct observation on this machine. |
| **S** | Read from shipped code (disassembly, embedded strings, entitlements, scripts). Shows what the code does, not that it was seen running. |
| **R** | Reported by a third party; not reproduced here. |
| **H** | Hypothesis. |

The full record, including refuted hypotheses and mistakes, is in
[investigation-log.md](investigation-log.md) and the files under
[results/2026-11-10/](results/2026-11-10/).

## 1. Verdict

**A Simulator runtime can be stored and run entirely from an external SSD on
this OS, with no copy on the internal disk, at the same speed as an internally
stored one, through restarts and reconnections.** (V)

It is done without touching any directory Apple protects, without disabling or
weakening SIP, and with one privileged action: creating one directory.

It is **not** something Xcode knows about. Xcode's Components pane continues to
offer the platform for download, and Xcode cannot manage a runtime registered
this way. Whether that is acceptable is a product judgement, not a technical
unknown.

Two things remain untested and could still change the verdict: behaviour over
days and weeks, and behaviour across an Xcode update (§7).

## 2. How runtime storage works on this OS

| Fact | Evidence |
|---|---|
| Runtimes installed through Xcode or `xcodebuild -downloadPlatform` are MobileAsset downloads under `/System/Library/AssetsV2/com_apple_MobileAsset_<platform>SimulatorRuntime/<sha1>.asset/`. | V |
| That store is on the internal Data volume, protected by SIP against root, and its path is hard-coded in `mobileassetd` and `simdiskimaged`. It cannot be relocated. | V, S |
| Runtimes for iOS 18 and later are offered only through MobileAsset. No setting restores DMG delivery; `-exportPath` exports after installing internally. | S; V for the index |
| A MobileAsset download needs one image's worth of internal space at its peak, not two. | V |
| The runtime is a compressed, unencrypted, read-only UDIF image (about 8 GB, expanding to 19 GB). Mounting it consumes no further storage. | V |
| Its binaries carry ordinary Apple signatures and it ships its own dyld shared cache, so it runs from a plain disk-image mount; the cryptex mount Apple uses is not required. | V |
| `/Library/Developer/CoreSimulator/**` is under a mandatory access control: writes fail with `EPERM` even for root. | V |
| `simdiskimaged` (root, sandboxed) owns image registration and mounting there. Its sandbox allows mounts only under four literal paths in that tree. | V, S |

The existing community workaround mounts external storage over
`…/CoreSimulator/Images` and `…/Volumes`. On this OS those directories hold a
2 KB registry and nothing else, so it would relocate nothing. (V) Its further
weaknesses are listed in §8.

## 3. The mechanism that works

```
external volume (identified by APFS volume UUID)
└── SimRuntimes/<build>/<n>.dmg + SHA256SUMS          the only large data

/private/tmp/simruntime-offload-<uid>/<build>/           read-only mount of that image
/Library/Developer/DeviceKit/Runtimes/offload-<build>.simruntime
        → …/<build>/Library/Developer/CoreSimulator/Profiles/Runtimes/<name>.simruntime
```

CoreSimulator discovers the runtime through its profile-directory monitor,
which follows symlinks and checks the suffix of the resolved path. `simdiskimaged`
is not involved. (S, V)

Each element is the way it is for a reason found by experiment:

| Choice | Why | Evidence |
|---|---|---|
| Keep the compressed image, not an unpacked copy | 8 GB instead of 19 GB; read-only; checksummed; identical to what Apple ships | V |
| Attach with `diskutil image attach`, never `hdiutil attach` | `hdiutil` uses the legacy stack, which serialises reads through one user-space helper: 881 against 6,704 concurrent reads/s on the same SSD, and a 219 s first boot against 41 s. `hdiutil attach` is deprecated on macOS 27. | V |
| Mount under `/private/tmp/…` | The mount must be readable by `CoreDeviceService`, which is App-Sandboxed and drives Xcode's live device view. Mounted in the user's Library, builds and `simctl` work but Xcode's device view times out. `/private/tmp` is the one unprivileged location that service is entitled to. The system's temporary-file cleaner does not cross mount points. | V; S for the cleaner |
| Link from `/Library/Developer/DeviceKit/Runtimes` | A link in the per-user profile directory works for building and running but leaves Device Hub labelling the simulators "unavailable", because the sandboxed service's home is its container. `DeviceKit` is a monitored profile location outside the protected tree. Tested in all four combinations of location and fresh/stale service. | V |
| Create the link only after the mount exists; remove it when the volume is absent | A dangling link makes every `simctl` invocation print a warning. | V |
| A per-user LaunchAgent with `StartOnMount`, whose executable is the tool itself | No polling; a late-arriving volume is handled within seconds. A shell script cannot be the agent: launchd-run `/bin/bash` is refused access to a removable volume without a prompt, whereas a distinct executable gets a one-time consent prompt. | V |
| Run the agent at normal priority | At background priority it started 80 s after login and its first attach took 56 s; at normal priority, 14 s and 1–3 s. | V, two runs |
| Identify the volume by APFS volume UUID | `/dev/diskN` and volume names are both unstable. | — |

## 4. Verified behaviour

| Behaviour | Result |
|---|---|
| Internal storage for an offloaded runtime | 0 bytes. The runtime store went from 15.5 GiB to empty. |
| First boot of a new device | 41 s from the SSD; 39 s from an internal runtime. |
| Later boots | 7–10 s. |
| Uncached reads through the image, 32 threads | 6,704 reads/s from the SSD; 2,483 from the internal cryptex mount. |
| `simctl` create, boot, install, launch, shutdown | Work. |
| `xcodebuild` for a device and for the generic simulator destination | Builds succeed with no iOS runtime installed internally. |
| Xcode Run, with live device view | Works. |
| Device Hub (Devices and Simulators) | Simulators shown as available, with a Start button. |
| SDK-to-runtime matching | Still selects the offloaded build. |
| Restart with the SSD connected | Both runtimes back about 21 s after login. |
| Restart without the SSD | Simulators cleanly unavailable; no errors or warnings. |
| SSD connected after login, Xcode open | Both runtimes registered 2 s after the volume mounted; Xcode recovered without a relaunch. |
| Deleted internal runtimes after a restart | Stayed deleted. |
| Eject before unplugging | 12 s; no mounts or links left. |
| Re-attach after eject | Under 1 s; device boots in 8 s. |
| Cable pulled with a simulator running | The simulator dies at once; services keep running; the kernel removes the dead mount; nothing to clean up. |
| Reconnection after that | Runtime registered again in 1 s; device boots; images and filesystem verify clean. |
| Restore to the internal disk by `simctl runtime add` | 35–40 s, one image of space; Xcode shows the platform as installed again. |

The rows above were established with the shell harness. With the native tool,
`simruntime-offload` 0.1.0:

| Behaviour | Result |
|---|---|
| `offload` of a freshly downloaded runtime | 54 s for 7.9 GB: copy, two checksums, image verification, delete, attach. Internal store empty afterwards. |
| `offload` of a runtime whose image is still on the volume | 22 s; the image is compared and reused, not copied. |
| `restore` | 40 s; the others untouched. |
| `eject` | 13 s for two runtimes and 23 s for three in 0.1.0. In 0.1.1, with the launch helper restarted once rather than per runtime: 2.5–3.5 s for two, over four runs, one of them straight after shutting down a simulator on each runtime. First attempt every time. |
| Remount or replug after `eject` | Every runtime back within seconds, with no other action. |
| `uninstall`, then `setup` and offloading again | 85 s out, about 50 s back, for two runtimes; nothing of the tool left in between. |
| First boot of a new device, same runtime | 38 s from the volume; 35 s from the internal disk. |
| The scripted system test | 9 steps, all checks passed. |
| Restart with the disk connected | Both runtimes attached by the native agent 1.5 min after boot, with the machine still heavily loaded. |

See `results/2026-11-10/native-offload.md`, `native-restore.md`,
`native-uninstall.md` and `system-test-0.1.0.md`.

## 5. Hazards a tool must handle

Each of these was hit in practice.

| # | Hazard | Handling |
|---|---|---|
| 1 | **Stale registration.** After `simctl runtime delete`, the running CoreSimulatorService ignores the volume's disappearance, keeps the runtime registered at the dead path, and rejects a re-registration of the same build as a duplicate. | Restart the per-user service after the delete, only when no simulator is booted. Not needed after a login. |
| 2 | **Delete may not reclaim the asset.** `simctl runtime delete` can exit with "did not reclaim its MobileAsset", leaving the image on disk. Seen with a superseded release candidate. | Run `simctl runtime scan-and-mount`, delete again, and verify by measuring the store, not by exit status. |
| 3 | **`SimLaunchHost` keeps a library mapped** from every runtime it has loaded, blocking unmount; Apple's own delete path unmounts anyway and crashes it with a bus error. | Restart that helper before ejecting. |
| 4 | **`spindump` may hold the volume.** If the system sampler has sampled simulator processes it keeps their binaries mapped indefinitely. Conditional: often absent. | Try a normal eject with retries; force only as a last, explicit step. |
| 5 | **`simctl shutdown` returns before processes exit**, notably under a debugger. | Retry the eject for about ten seconds before concluding the volume is held. |
| 6 | **Sandboxed helpers constrain the mount location.** Success from the command line does not imply Xcode's interface works. | Fixed location; any change must be re-validated against Xcode's device view. |
| 7 | **Background access to a removable volume** is attributed to the job's executable. | The agent's executable is the tool; consent is asked once. With ad-hoc signing a rebuild may ask again. |
| 8 | **Free space is a misleading measure.** Swap on the shared APFS container moved it by 5 GB during an unrelated step. | Measure directory sizes. |
| 10 | **An import leaves a clone in the daemon's inbox.** After `simctl runtime add`, deleting the runtime does not free its space: a clone in `…/Cryptex/Images/Inbox` keeps the blocks. | Run `simctl runtime scan-and-mount` after every add and delete; verify by measurement. |
| 9 | **A gap after login.** The runtime cannot exist before the volume is mounted and the image attached. | About 21 s here. Applications started in the gap must recover; Xcode does. |

## 6. Approaches that do not work

| Approach | Why not | Evidence |
|---|---|---|
| Symlinking any CoreSimulator system directory | The tree is MAC-protected; the daemon's sandbox and both trust checks resolve symlinks. | V, S |
| Redirecting the MobileAsset store | SIP-protected, hard-coded, reported to break all downloads. | V, S, R |
| Forcing DMG delivery by a setting | No such branch; disabling MobileAsset makes runtimes unavailable. | S |
| Mounting under `/Library/Developer/CoreSimulator/Volumes` (the trusted volumes directory) | Root cannot create a mount point there. Would need Full Disk Access or mounting over a system directory. | V |
| A volume mounted under `/Volumes` | Not a trusted mount directory on customer macOS; the allow-untrusted switch is an internal-build check. | S |
| `simctl runtime add --legacy`, daemon "mount in place" | Internal-only, or root with private XPC and dropped on rescan. | S |
| A shell-script login agent | Refused access to the removable volume without a prompt. | V |
| `hdiutil attach` | Works, five times slower to boot. | V |

## 7. Limitations and what is untested

**Known limitations**

- **Xcode does not regard the platform as installed.** Settings ▸ Components
  shows "Get" for iOS 27.2 and nothing under Other Installed Platforms, and
  the generic "Any iOS Simulator Device" destination carries a "Get" badge.
  Specific simulators are selectable and work. Clicking "Get" would install a
  second, internal copy. No way to satisfy this check without an internal copy
  has been found.
- **Every new runtime transits the internal disk.** Acquisition is still
  through Xcode; only steady-state storage is saved.
- **No simulators while the volume is absent.** There is no internal fallback
  unless one is deliberately kept.
- **One privileged setup step**, creating `/Library/Developer/DeviceKit/Runtimes`.
  Without it the tool still works, with Device Hub showing "unavailable".
- **Device data is not relocated.** Each simulator's own data
  (about 3 GB each here) stays in the user's Library.

- **A new or upgraded agent waits for consent.** macOS asks again for access
  to removable volumes when the agent's program changes, and until the prompt
  is answered nothing is attached. Seen as a 50 s stall after reinstalling.

**Observed once and not explained**

- For about two minutes, some minutes after two offloads and during a runtime
  download, `xcodebuild` listed no simulator destinations although `simctl`
  and `devicectl` listed the simulators as available. It cleared by itself.
  Restarting the CoreSimulator service did not reproduce it.

**Untested**

| Item | Why it matters |
|---|---|
| A restart without the disk, and an abrupt disconnection, with the native tool's agent | Both were tested with the harness's agent (§4). The native agent has been through a restart with the disk connected, and through eject, remount and replug. |
| Abrupt disconnection during a build, a debug session or an `offload` copy | Tested once, with an idle app; survivable and self-healing in that case. |
| Days and weeks of use | Temporary-file cleanup is understood from its script (S) but not observed over time. |
| An Xcode or macOS update | `DeviceKit` belongs to Xcode's system resources; an update may remove the extra directory, and CoreSimulator's discovery rules may change. |
| Other platforms and more than one volume | Only iOS, two builds, one SSD. |
| Intel Macs, universal runtimes, older macOS | `diskutil image attach` and every discovery rule here are version-specific. |
| A second user account | The `DeviceKit` directory is system-wide and here is user-owned. |

## 8. The existing workaround

<https://gist.github.com/niteshpurohit/8453bade166b8a83470ae516c3673a77>
(May 2026, no licence stated).

Its insight — mount over the expected path instead of symlinking — is sound for
the Xcode 14–15 layout it assumes. On Xcode 27 it relocates nothing (§2), and
independently of that it: swaps the daemon's registry along with the storage;
allocates a second sparsebundle that stores nothing; force-kills services and
force-detaches without checking for booted simulators; renames protected
directories with no restore; identifies the disk by name; polls every 30 s as
root and logs to predictable paths in `/tmp`; has no ordering with respect to
the daemon's first scan; and uses `hdiutil attach`, which this investigation
found to be the slow path.

It carries no licence, so under GitHub's terms it may be forked on GitHub but
not redistributed as a derivative. Nothing in this repository is derived from
its text; it is cited as prior art.

## 9. Method notes

- Static analysis used `otool`, `nm`, `strings` and `lldb` in static mode. The
  REA disassembler provider was unavailable (macOS denied it Apple Events
  permission to drive Hopper), so `simdiskimaged`, which is stripped Swift, was
  read only at the level of strings, entitlements, its embedded sandbox profile
  and call structure.
- Three subagents did parallel read-only research in session 1. Their claims
  were treated as S or R; the ones the design rests on were re-derived or
  tested directly.
- Privileged commands run in total: one `lsof`, one failed `mkdir`, one
  `mkdir` + `chown`.
- Everything that changed the machine was approved in advance, with the
  exceptions recorded as mistakes in the log.
