# Results: restart with the SSD connected (2026-11-10, session 7)

Restart test 1 from the plan: restart with the SSD attached, agent installed,
both runtimes linked from `/Library/Developer/DeviceKit/Runtimes`.

## Timeline at login (from the agent log and CoreSimulator.log)

| Time | Event |
|---|---|
| 19:10:42 | Login. CoreSimulatorService starts with no runtimes; both devices `available = 0`. |
| 19:12:04 | Agent `sync` starts (about 80 s after login). It replaces both stale links. |
| 19:12:05 | Xcode starts (window restoration) and logs "Unable to discover any Simulator runtimes". |
| 19:13:00 | iOS 27.2 attached and linked — 56 s for this attach. The service, Xcode and `CoreDeviceService` all register it. |
| 19:13:03 | iOS 27.0 attached and linked — 3 s. Both devices `available = 1`. |

## Outcomes

| Question | Result |
|---|---|
| Do the mounts under `/private/tmp` come back? | Yes. The directory is emptied at boot; the agent recreated it and re-attached both images. |
| Do deleted internal runtimes stay deleted? | Yes. The runtime store is still empty (4 KiB). |
| Did the agent need a new consent prompt? | No prompt appeared. |
| Does Xcode recover when runtimes arrive after it has started? | Its process registered both within the same second as the service. The project owner, looking during or just after the gap, saw the simulators as unavailable and missing; on reopening Xcode they were present. Live recovery of the *interface* is therefore still unconfirmed. |
| Is the "unavailable" label gone? | **Yes.** Devices and Simulators now offers Start for the SSD-hosted device, and both simulators appear as run destinations. |

## Findings

1. **A gap after login.** For about two and a half minutes there were no
   runtimes, and an application started in that window sees no simulators. The
   agent was configured as a background-priority job, which launchd throttles
   under login load; that is the suspected cause of both the late start and the
   slow first attach, but it is not established. No consent prompt was
   involved. The agent now runs at normal priority and timestamps each step.
2. **The "unavailable" label was at least partly stale state.** It persisted
   through the move to the DeviceKit location and disappeared after a restart.
   Two things changed across that restart — a fresh `CoreDeviceService`, and
   registration from a home-independent directory — so this result does not say
   which one mattered. Separating them needs a test with the links back in the
   per-user directory and a fresh `CoreDeviceService`.
3. **Xcode still treats the iOS simulator platform as not installed.** With no
   internally installed runtime, Settings ▸ Components shows "Get" for iOS 27.2
   and "No Items" under Other Installed Platforms, and the generic "Any iOS
   Simulator Device" build destination carries a "Get" badge. Specific
   simulators are selectable and build. `xcodebuild` builds the generic
   destination without complaint.

## Changes made afterwards

- Agent `ProcessType` changed from `Background` to `Interactive`.
- `sync` output timestamps each step.
- `agent install` rebuilds the launcher only when its source changes, since it
  is ad-hoc signed and a rebuild may cost a new consent prompt.

## Follow-up: a one-step eject

The detach instructions given for the next test contained a literal `<build>`
placeholder, which the shell rejected. The harness now remembers its settings
in `~/Library/Application Support/simruntime-offload/config` and has an
`eject` command that detaches every manifest runtime and then ejects the
volume, with no arguments or environment variables. Run for real, it released
both runtimes with normal ejects and ejected the SSD in 12 s, leaving no
mounts, no links and both devices cleanly "unavailable".
