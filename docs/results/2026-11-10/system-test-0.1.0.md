# System test pass for 0.1.0

2026-11-10. macOS 27.2.1 (26B131), Xcode 27.2 (27B52), CoreSimulator 1174.21,
Apple M3. Release build of the tree that becomes 0.1.0. Evidence labels as in
the technical assessment.

## Scripted: `scripts/system-test.sh`

Run on a freshly downloaded, disposable iOS 27.1 runtime (24A94425), with the
two runtimes in everyday use served from the volume throughout.

**9 steps, every check ok, 284 s.** The full output is in
`system-test-0.1.0.log`.

| Step | Time |
|---|---|
| `offload --dry-run` changes nothing | 1 s |
| `offload`: copy, verify, delete, attach | 73 s |
| A new device boots from the offloaded runtime and launches Settings | 70 s |
| `sync` with nothing to do changes nothing | 2 s |
| A second `offload` is refused | 1 s |
| `restore --dry-run` changes nothing | 1 s |
| `restore`, keeping the image | 55 s |
| `offload` again, reusing the image | 41 s |
| `restore --delete-image` | 36 s |

After every step the script checked the state of the machine directly: the
image registration, the daemon's inboxes, the mount, the link, the checksum of
the image on the volume, and where CoreSimulator said the runtime was. At the
end it confirmed that everything about the other runtimes was as at the start.

The times include those checks, some of which wait, so they are longer than
the bare commands measured earlier in the day (54 s, 40 s, 22 s, 41 s).

## By hand, the same session

| Check | Result |
|---|---|
| `xcodebuild` build of `fixtures/HelloSim` for a named simulator on an offloaded runtime | Succeeded, 6 s. But see below. |
| Install and launch on that simulator | The app ran and displayed the runtime's version and build. |
| `eject` | 13 s for two runtimes; no mounts, no links, the disk ejected. |
| Remount in software (`diskutil mount`) with the newly installed agent | Both runtimes attached and linked 54 s after the mount. See below. |
| `uninstall`, `setup`, two offloads | Done earlier the same day on an earlier build; see `native-uninstall.md`. The uninstall code changed since only by losing the removal of the experiment harness's files. |

## Two things this pass turned up

**A new agent program waits for consent, and holds the lock while it does.**
The agent was reinstalled from the final build just before the eject. On the
remount it started at once and ran `diskutil image attach`, which then did
not return for about 50 s; both runtimes were attached the moment it did. That
is what answering macOS's prompt for access to a removable volume would look
like, though the prompt itself was not observed from this side. Two
consequences, now in the README: after installing or upgrading, nothing is
served until the prompt is answered; and during that wait the agent holds the
state lock, so `sync`, `eject` and `restore` report that another operation is
running. The message now says what the likely cause is. (V for the delay; H
for its cause)

**For about two minutes `xcodebuild` offered no simulator destinations.** At
21:30, six minutes after the second of two offloads and while the iOS 27.1
download was running, `xcodebuild -showdestinations` listed only "Any iOS
Simulator Device", and a build for a named simulator timed out after 61 s.
`simctl` and `devicectl` listed both simulators as available throughout. By
21:32 all destinations were back, with nothing done to bring them. Restarting
the per-user CoreSimulator service afterwards, which is what `offload` does,
did **not** reproduce it: the destinations were listed in the next second. The
cause is unknown. It was seen once; it is recorded here and in the assessment
rather than explained away. (V for the observation; no supported hypothesis)

## A restart with the native agent

Done by the project owner after the pass above, with the disk connected
(checklist R1 and R2).

| Observation | Value |
|---|---|
| System boot | 21:51 |
| Agent log: "attached and linked", both runtimes | 21:52:29 |
| Permission errors in the agent's log | none |
| As seen by the owner | simulators available "about a minute" after the restart, "while everything else was loading" |
| Afterwards | `list` shows both active; `doctor` all ok; two mounts; `simctl` lists both runtimes |

So the native agent comes through a login unaided. The time is longer than the
21 s measured for the harness's agent in session 9, but the two are not
comparable: that figure was from login, this one from boot, and the load
average three minutes after this boot was above 100. What can be said is that
runtimes are back within about a minute and a half of power-on. (V, one run)

## Not covered by this pass

From `docs/system-test-checklist.md`: Xcode's windows (X1 to X4) with this
build, a physical unplug and replug with this build (it was done with the
step 5 build), a restart without the disk (R3, R4), and disconnection without
eject (D1, D2), both last done with the harness.
