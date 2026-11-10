# System test checklist

What `scripts/system-test.sh` cannot check, because it needs a person, a cable
or a restart. Run the script first; then these, in order. Each line says what
to do and what must be true afterwards.

Record the result of a pass in `docs/results/<date>/`, with the versions from
`simruntime-offload doctor`. A combination of macOS, Xcode and CoreSimulator
is added to `Preflight/Compatibility.swift` only after the script and this
checklist have both passed on it.

Starting state: at least one runtime offloaded, the agent installed, no
simulator booted.

## Xcode

| # | Do | Expect |
|---|---|---|
| X1 | Open Xcode ▸ Window ▸ Devices and Simulators ▸ Simulators | Simulators on offloaded runtimes are listed without "unavailable". |
| X2 | Open a project, choose a simulator on an offloaded runtime, Run | Builds, installs, launches; the live device view connects. |
| X3 | Set a breakpoint and hit it | The debugger stops there. |
| X4 | Settings ▸ Components | Known limitation: the offloaded platform shows "Get". Record what it shows; do not click it. |

## Eject and reconnect

| # | Do | Expect |
|---|---|---|
| E1 | Shut down all simulators; `simruntime-offload eject` | Exit 0, "Safe to unplug". `mount` shows nothing under `/private/tmp/simruntime-offload-<uid>`. |
| E2 | Unplug the disk; open Devices and Simulators | Simulators on offloaded runtimes unavailable; no error dialogs. |
| E3 | Plug the disk in | Within a few seconds `simruntime-offload list` shows every runtime "active", without relaunching Xcode. |
| E4 | Boot a simulator; `simruntime-offload eject` | Refuses, naming the simulator; nothing changed. |

## Restart

| # | Do | Expect |
|---|---|---|
| R1 | Restart with the disk connected; log in | Within about a minute of login, `list` shows every runtime "active". Note how long it took. |
| R2 | `tail ~/Library/Logs/simruntime-offload/agent.log` | "attached and linked" for each runtime after the login time; no "not permitted". |
| R3 | `eject`, unplug, restart without the disk; log in | `list` shows "volume not connected"; `xcrun simctl list` prints no warnings; no dangling links in the link directory. |
| R4 | Plug the disk in | As E3. |

## Disconnection without eject

Only with a disk and runtimes you can afford to lose.

| # | Do | Expect |
|---|---|---|
| D1 | Boot a simulator from an offloaded runtime; pull the cable | The simulator dies. `xcrun simctl list` still responds. |
| D2 | Plug the disk in | As E3. `diskutil verifyVolume` passes; each image matches its `SHA256SUMS`. |

## The way out

| # | Do | Expect |
|---|---|---|
| U1 | `simruntime-offload uninstall --dry-run` | Lists a restore for every runtime; changes nothing. |
| U2 | `simruntime-offload uninstall` | Every runtime "Disk Image, Ready" in `xcrun simctl runtime list`; the agent, `~/Library/Application Support/simruntime-offload`, the log directory and the mount root are gone; the images are still on the volume. |
| U3 | `setup`, then `offload` each runtime again | Each offload reuses its image without copying. |
