# Design: `simruntime-offload`

Status: **proposal for review.** Nothing in this document is built. The shell
harness in `experiments/` proved the mechanism; this is the design for the
tool that replaces it.

Background and evidence: [technical-assessment.md](technical-assessment.md).
Every design choice below that rests on an experiment cites the hazard number
from §5 of that document.

## 1. Goals and non-goals

**Goals**

1. Move an installed Simulator runtime to an external volume and serve it from
   there, with no internal copy.
2. Restore the machine to stock behaviour completely, on request.
3. Behave predictably when the volume is absent, late, or removed properly.
4. Never touch a directory Apple protects, never weaken a system protection,
   and keep privileged actions to one named, explained step.
5. Refuse to act on OS or Xcode versions it has not been validated against.
6. Be small enough to audit in an afternoon.

**Non-goals**

- Making Xcode's Components pane show an offloaded runtime as installed. No way
  to do that without an internal copy is known.
- Downloading runtimes. Acquisition stays with Xcode.
- Relocating simulator *device* data, Derived Data or anything else.
- Supporting macOS or Xcode versions before 27 in the first release.
- A graphical interface.

## 2. What the user sees

```
simruntime-offload setup                 one-time: choose a volume, create the link directory, install the agent
simruntime-offload doctor                check versions, volume, agent, consent and consistency; change nothing
simruntime-offload list                  installed and offloaded runtimes, where each lives, sizes
simruntime-offload offload <runtime>     copy to the volume, verify, remove the internal copy, serve from the volume
simruntime-offload restore <runtime>     put a runtime back on the internal disk and stop serving it
simruntime-offload eject                 release the volume so it can be unplugged
simruntime-offload uninstall             restore everything, remove the agent and all state
```

`<runtime>` is a build number (`24B8117`) or an image identifier as printed by
`list`. Every command that changes anything accepts `--dry-run` and prints the
exact operations it would perform. There is no `--force` that overrides a
safety check; the two escape hatches that exist are named for what they do
(§6).

Output is plain text for people and `--json` for scripts. Errors say what
failed, what state the machine is in, and what to run next.

## 3. Architecture

One Swift package, one executable. The same executable is the command-line
tool and, when started by launchd with the `agent` subcommand, the login
agent. No daemon, no helper tool, no kernel or system extension, no private
framework.

```
Sources/simruntime-offload/
  Commands/        one file per subcommand; argument parsing and user-facing text only
  Core/
    Preflight      version and capability checks; the compatibility table
    Volume         resolve a volume UUID to a mount point (DiskArbitration)
    ImageStore     staged images on the volume: copy, checksum, verify
    Attacher       attach and eject images (/usr/sbin/diskutil image …)
    Registry       the runtime links in the link directory
    Simulators     CoreSimulator through `xcrun simctl … -j`: list, delete, booted devices
    Services       restart SimLaunchHost / the per-user CoreSimulator service
    Manifest       what is offloaded, as JSON, on the internal disk
    Agent          install, remove and inspect the LaunchAgent
    Sync           the reconcile step shared by the agent and the CLI
  Support/         process execution, logging, errors
Tests/
```

**Why Swift.** Direct use of DiskArbitration; a single self-contained binary
with its own code identity, which the consent model requires (hazard 7); no
interpreter on the path of a login agent.

**Why it shells out for three things.** There is no public API for attaching a
disk image with the modern stack, for CoreSimulator, or for launchd job
control. The tool calls `/usr/sbin/diskutil image attach`, `xcrun simctl` and
`/bin/launchctl` by absolute path with argument arrays, never through a shell,
and parses only their structured (`--plist`, `-j`) output. Each wrapper is one
small file so that a change in one of those tools is a one-file fix.

**Why the agent is a one-shot, not a long-lived process.** launchd starts it at
login and on every mount (`RunAtLoad`, `StartOnMount`); it runs `Sync` once and
exits. Stateless and easy to reason about. The cost is a few no-op runs when
unrelated volumes mount, each a few milliseconds.

## 4. State

| What | Where | Notes |
|---|---|---|
| Runtime images | `<volume>/SimRuntimes/<build>/<file>.dmg`, `SHA256SUMS`, small asset metadata | The only large data. Portable: another Mac with the tool can adopt it. |
| Manifest | `~/Library/Application Support/simruntime-offload/manifest.json` | Build, runtime identifier, volume UUID, image path, SHA-256, size, date. Internal, so the tool can clean up while the volume is absent. |
| Mount points | `/private/tmp/simruntime-offload-<uid>/<build>/` | Per-user directory, mode 700, ownership checked before use. Emptied at reboot; recreated. (hazard 6) |
| Runtime links | `/Library/Developer/DeviceKit/Runtimes/offload-<build>.simruntime` | Fallback: `~/Library/Developer/CoreSimulator/Profiles/Runtimes/` when the user declines the privileged step. |
| Agent | `~/Library/LaunchAgents/dev.simruntime-offload.agent.plist` | Points at the installed binary. |
| Log | `~/Library/Logs/simruntime-offload/` | Timestamped; rotated by size. |

Nothing is written anywhere else. In particular nothing under
`/Library/Developer/CoreSimulator`, `/System`, or the user's simulator devices.

## 5. Flows

Each flow is a sequence of small steps, each of which verifies its own result
before the next begins, and each of which can be undone until the one marked
**point of no return**.

### 5.1 `setup`

1. Preflight (§7). Stop on any failure.
2. Choose the volume: list external APFS volumes with their UUIDs and free
   space; the user picks one. Record the UUID, never the name.
3. Explain the privileged step and ask. If accepted, run
   `sudo mkdir` and `chown` for `/Library/Developer/DeviceKit/Runtimes` (§6).
   If declined, use the per-user link directory and say what that costs.
4. Install the agent and start it once.
5. Run `doctor` and print the result.

### 5.2 `offload <runtime>`

1. Preflight. Resolve the runtime; refuse if any simulator using it is booted.
2. Check free space on the volume (image size plus headroom).
3. Copy the image to `<file>.partial` without extended attributes.
4. SHA-256 the source and the copy; compare. Verify the image's own checksum.
   On mismatch delete the partial file and stop.
5. Rename into place; write `SHA256SUMS`; add the manifest entry as *staged*.
6. **Point of no return.** `xcrun simctl runtime delete <id>`.
7. Measure the internal runtime store. If the asset was not reclaimed, run
   `simctl runtime scan-and-mount`, delete again, measure again (hazards 2
   and 10). If it is
   still present, stop and report: the runtime remains usable from its internal
   copy and nothing else is changed.
8. If no simulator is booted, restart the per-user CoreSimulator service (hazard 1).
   If one is booted, skip, and tell the user the offloaded runtime will appear
   after they next log in or restart that service.
9. `Sync` (5.4). Mark the manifest entry *active*.
10. Verify: the build is listed by `simctl list runtimes` from the offload
    mount. If not, report it; the image is safe on the volume either way.

### 5.3 `restore <runtime>`

Validated: re-import takes under a minute, needs no network, and Xcode then
shows the platform as installed.

1. Preflight. Refuse if a simulator using the runtime is booted. Check
   internal free space (image size plus headroom).
2. Remove the manifest entry, so the agent cannot re-attach it; unlink and
   eject the offload mount (as in 5.5, for this one runtime).
3. `xcrun simctl runtime add <image on the volume>`. Never with `--move`.
4. `xcrun simctl runtime scan-and-mount`, to clear the clone the import leaves
   in the daemon's inbox (hazard 10).
5. Verify: the build is registered as a disk image, state Ready.
6. The image on the volume is kept unless `--delete-image` is given.

If step 3 fails, re-add the manifest entry and run `Sync`, which returns the
machine to the offloaded state.

### 5.4 `Sync` (run by the agent and after every change)

For each manifest entry:

- **Volume present, image present, not mounted:** replace a stale link if
  there is one, attach read-only with the modern stack, find the bundle, create
  the link. If the attach is refused for lack of consent, say so plainly.
- **Mounted and linked:** nothing.
- **Mounted but not linked, or linked elsewhere:** report; do not guess.
- **Volume or image absent:** remove our dangling link.

Serialised by a lock. One runtime failing does not stop the others.

### 5.5 `eject`

1. Refuse if any simulator is booted, naming them.
2. For each mounted runtime: remove the link; wait for CoreSimulator to unload
   it; restart `SimLaunchHost` (hazard 3); eject, retrying for ten seconds (hazard 5).
3. If a volume is still held: identify the holder where possible and stop,
   unless `--force-unmount` was given, in which case force it (hazard 4).
4. Eject the external volume. Print "safe to unplug" only if every step
   succeeded.

This differs from the harness, whose `eject` forces automatically. A released
tool should make the user ask for force.

### 5.6 `uninstall`

`restore` every runtime (or, with `--leave-runtimes-on-volume`, just stop
serving them), remove the agent, the manifest, the log and the mount root, and
print the one command that removes the `DeviceKit/Runtimes` directory.

## 6. Privilege, consent and safety

**Privilege.** Exactly one action needs root: creating
`/Library/Developer/DeviceKit/Runtimes`. `setup` prints the command, explains
that it lets Device Hub see offloaded simulators as available, and runs it
through `sudo` only on confirmation. The tool never caches credentials, never
installs anything that runs as root, and works without this step.

That directory is made user-owned so the unprivileged agent can add and remove
links. The consequence, stated in `setup` and the README: on a Mac with several
accounts, this user can register runtimes that other users' simulators would
load. `setup --shared-link-directory=no` selects the per-user fallback instead.

**Consent.** The first attach by the agent triggers the system prompt for
access to a removable volume, attributed to the tool. `doctor` detects a
refused attach and explains how to grant access. With ad-hoc signing (a source
build, or Homebrew), each upgrade is a new identity and may prompt again; a
Developer ID–signed release would not. This is a distribution decision (§10).

**Invariants the code enforces**

1. Never delete an internal runtime before its copy on the volume has passed
   both checksums.
2. Never report space as freed without measuring it.
3. Never unmount, eject or restart a service while a simulator is booted.
4. Never force an unmount unless the user asked for exactly that.
5. Never act on a volume selected by name.
6. Never leave a dangling link.
7. Never write outside the paths in §4.
8. Never proceed on an unvalidated OS, Xcode or CoreSimulator version.

**Escape hatches**, both named for what they do, both logged:
`--force-unmount` (eject) and `--allow-unvalidated-version` (any command).

## 7. Compatibility

Preflight checks, all read-only:

- macOS, Xcode and CoreSimulator versions against a table compiled into the
  binary. The first release lists exactly the combination this was validated
  on. Anything else stops with a message naming the versions found and the
  versions supported.
- `diskutil image attach` exists.
- SIP is enabled (the tool is not designed for, or tested on, anything else).
- The link directory exists and is writable; `/Library/Developer/DeviceKit`
  exists.
- The agent is loaded and its executable is the current binary.

After every `Sync`, a functional check: the runtime is actually listed. A
version table can be wrong; this cannot.

**After an Xcode update** the first `doctor` or agent run sees an unvalidated
version and stops serving new changes, leaving existing mounts alone, until the
tool is updated or the user overrides. Failing safe matters more here than
convenience: the storage design has changed four times in five years.

## 8. Testing

| Level | What | How |
|---|---|---|
| Unit | Manifest read/write and migration; parsing of `simctl` and `diskutil` output; the `Sync` decision table; preflight version logic | XCTest with recorded fixtures and fake process runners. No machine state. |
| Integration | Attach, link, eject and stale-link handling against a small synthetic disk image, in a temporary link directory | XCTest; needs no runtime and no external disk; safe in CI. |
| System | The matrix in the assessment §4, plus the untested items in its §7 | Scripted where possible (`simctl`, `xcodebuild`); a written checklist for what needs a person (Xcode's interface, restarts, unplugging). |

The harness's benchmarks (`experiments/bench/`) are kept so the attach-stack
result can be re-measured on new OS versions.

## 9. To validate before or during the build

In priority order. The first three affect the design.

1. ~~Restore by re-import.~~ **Done:** works; Xcode shows the platform as
   installed. See [results](results/2026-11-10/restore-by-reimport.md).
2. ~~Abrupt disconnection.~~ **Done:** survivable and self-healing; no repair
   path needed beyond `Sync`. See
   [results](results/2026-11-10/abrupt-disconnection.md). Not yet tried during
   a build, a debug session or an `offload` copy.
3. **An Xcode point update.** Does `DeviceKit/Runtimes` survive, and do the
   discovery rules hold?
4. A week of ordinary use, including sleep, wake and a midnight temporary-file
   cleanup.
5. A second platform (watchOS or tvOS) and two volumes.
6. A second user account, for the shared link directory.

## 10. Decisions needed from you

| # | Decision | Recommendation |
|---|---|---|
| 1 | Name of the command | `simruntime-offload`, matching the repository; no short alias until there is demand. |
| 2 | Supported versions in the first release | macOS 27 with Xcode 27 only; state it prominently. |
| 3 | Link directory default | `DeviceKit/Runtimes` with the one privileged step, per-user as the declared fallback. |
| 4 | `eject` when the volume is held | Stop and explain; force only with `--force-unmount`. |
| 5 | Licence | MIT or Apache-2.0. Apache-2.0 if you want an explicit patent grant; otherwise MIT for simplicity. |
| 6 | Signing and distribution | Source build and Homebrew (ad-hoc) first; consider a Developer ID release later if repeated consent prompts prove annoying. |
| 7 | The shell harness | Keep under `experiments/` as the record of how the mechanism was found; remove the installed agent when the native one replaces it. |
| 8 | Order of work | Validation items 1 and 2 are done; build next. |

## 11. Build plan

1. Package skeleton, `Support`, `Preflight`, `doctor`. Unit tests.
2. `Simulators`, `Volume`, `Manifest`, `list`. Unit tests with fixtures.
3. `Attacher`, `Registry`, `Sync`. Integration tests with a synthetic image.
4. `Agent`, `setup`. Replace the harness's agent on this machine.
5. `offload`, `eject`.
6. `restore`, `uninstall`.
7. System test pass; README with limitations first; first tagged release.

Each step ends with the tool usable for what it covers and the machine in a
state the previous tool (the harness) can still manage.
