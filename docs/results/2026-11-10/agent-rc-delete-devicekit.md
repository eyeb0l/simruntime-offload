# Results: login agent, deleting the last internal runtime, the DeviceKit location (2026-11-10, session 6)

Requested: write the login agent; delete the release-candidate runtime
(24B114); test `/Library/Developer/DeviceKit` as a registration location.

## 1. Login agent

`experiments/sro.sh` gained a manifest (`enable`/`disable`), a `sync` command
and `agent install|uninstall|status`. The agent is a per-user LaunchAgent with
`RunAtLoad` and `StartOnMount`; nothing in it is privileged.

| Test | Result |
|---|---|
| `sync` with everything attached | No-op, exit 0. |
| `sync` with a manifest entry whose volume is absent and a dangling link | Link removed; other runtimes untouched. |
| `sync` after detaching a runtime | Re-attached and re-linked. |
| Agent as a shell script under launchd | **Failed:** `diskutil image attach` → "Operation not permitted", immediately and with no prompt. |
| Agent as a small native launcher under launchd | Blocked on a consent prompt, then attached once the prompt was allowed. |
| Unrelated volume mounted while a runtime was detached | launchd started the agent; runtime re-attached within 3 s. |

### Why a shell-script agent cannot work

A background job's file access is attributed to the job's own executable. With
`/bin/bash` as that executable, access to a removable volume was refused
without asking. With `experiments/agent/sro-agent.swift` as the job — a
launcher that only runs `sro.sh sync` from its own directory, and takes no
arguments — the system asked once ("sro-agent would like to access files on a
removable volume"). This is a concrete requirement for the eventual tool: its
background component must be its own signed executable.

Caveat: the launcher is ad-hoc signed, so rebuilding it may invalidate the
consent and prompt again.

### A harness bug this exposed

`sync` calls the attach routine inside a shell condition, where `set -e` is
suspended; after the failed attach the routine carried on. The attach now
fails explicitly.

## 2. Deleting 24B114, the last internally stored runtime

| Step | Result |
|---|---|
| `simctl runtime delete` | **Partial failure (exit 30):** "Removed the runtime, but did not reclaim its MobileAsset". Registration gone, 7.7 GiB still on disk. |
| `simctl runtime scan-and-mount` (the recovery the error message prescribes) | Re-registered the orphan under a new identifier, mounted as a plain disk image at `/Library/Developer/CoreSimulator/Volumes/iOS_24B114`. The SSD-hosted mounts were not disturbed. |
| `simctl runtime delete` again | Succeeded; asset purged. |

- Likely cause (H): the daemon's purge looks the asset up in MobileAsset's
  catalogue, and a superseded release candidate is no longer listed.
- This is the "orphaned asset" failure reported publicly. Here the documented
  two-step recovery worked; a tool should perform it automatically and must
  verify reclaimed space by measuring, not by exit status.
- Mistake recorded: the command sequence removed the SSD test copy of 24B114
  without checking that the internal delete had succeeded. No data was lost.

**Internal runtime storage is now 8 KiB**, from 15.5 GiB at the start of the
day. With no iOS runtime installed internally: `simctl` matching still selects
24B8117, `xcodebuild` builds for the generic simulator destination, and both
devices are listed as available destinations.

Xcode's Components pane (observed before 24B114 was deleted) showed the iOS
27.2 row with a "Get" button. Xcode does not count a runtime registered this
way as installed platform support. Whether its interface now blocks or nags is
not yet observed.

## 3. The DeviceKit location

One privileged action: `mkdir /Library/Developer/DeviceKit/Runtimes`, owned by
the user.

| Test | Result |
|---|---|
| Move the iOS 27.0 link from the per-user directory to `DeviceKit/Runtimes` | Registered again within seconds: "adding profile path `/Library/Developer/DeviceKit/Runtimes`". |
| Boot the test device and launch the app | 7 s; `CoreDeviceService` loaded the runtime with no "Ignoring runtime override" error. |
| Move the iOS 27.2 link as well; reinstall the agent with that link directory | Both runtimes registered from `DeviceKit/Runtimes`; `sync` reports both attached. |

So the location is honoured (V), which the code only suggested. It does **not** clear the "unavailable" label in Xcode's Devices and
Simulators window: the project owner reports both simulators still labelled
unavailable, although the usual simulator boots and runs from Xcode. Whether
that is stale state is to be settled by the restart tests. `CoreDeviceService` has been running since boot and still
logs warnings about the deleted internal runtimes, so its view may be stale
until it restarts.

Trade-offs of this location:
- It is system-wide, so it does not depend on any process's home directory.
- It needs root once, to create the directory. Making it user-owned lets an
  unprivileged agent add and remove links, at the cost that this user can
  register runtimes that other users' simulators would load. On a single-user
  machine that is immaterial; a public tool must state it.
- The directory belongs to Xcode's system resources. Whether an Xcode update
  removes an extra subdirectory there is unknown.

## State left on the machine

| Item | State |
|---|---|
| Internal runtimes | None. |
| Served from the SSD | iOS 27.2 (24B8117) and iOS 27.0 (24A434), mounted under `/private/tmp/simruntime-offload-<uid>/`, linked from `/Library/Developer/DeviceKit/Runtimes`. |
| SSD | Verified images of those two builds (15 GiB). |
| Agent | Installed and loaded: `~/Library/LaunchAgents/dev.simruntime-offload.agent.plist`; log in `~/Library/Logs/simruntime-offload/agent.log`. |
| Privileged changes | One directory, `/Library/Developer/DeviceKit/Runtimes`. Remove with `sudo rmdir` once empty. |
