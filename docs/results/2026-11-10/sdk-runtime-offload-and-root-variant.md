# Results: offloading the SDK-matching runtime; the root-mounted variant (2026-11-10, session 5)

Approved scope: (1) offload iOS 27.2 build 24B8117, the runtime the installed
SDK selects; (2) test mounting under the trusted volumes directory as root.

## 1. Root-mounted variant: blocked

| Step | Result |
|---|---|
| `sudo mkdir /Library/Developer/CoreSimulator/Volumes/sro_24A434` | **"Operation not permitted"**, as root |

Nothing was created or attached, and no further privileged command was run.

- This verifies directly (V) that the protection on
  `/Library/Developer/CoreSimulator/**` is a mandatory access control that
  root does not bypass. Previously that was a third-party report.
- Approach B as specified is therefore not available to a plain root helper.
  The remaining ways in are each a significant escalation and were not tried:
  granting Full Disk Access to the calling program (reported by a third party
  to lift the restriction), or mounting a holder volume *over* the `Volumes`
  directory itself, which hides a directory `simdiskimaged` uses.
- A different candidate surfaced from the code (S): CoreSimulator's profile
  monitor also watches `/Library/Developer/DeviceKit`, with the same four
  subdirectory names including `Runtimes`. That directory exists, is
  root-owned and is **not** under the protected tree (writes fail with the
  ordinary `EACCES`). A link in `/Library/Developer/DeviceKit/Runtimes` would
  be independent of any process's home directory. Whether a `Runtimes` folder
  there is actually loaded is unverified: the framework's static lists name
  `DeviceKit` only for `Chrome`. Testing it needs root for a new purpose.

## 2. Offloading the SDK-matching runtime

| Step | Result |
|---|---|
| Copy 24B8117 to the SSD; SHA-256 of source and copy; UDIF checksum; second hash of the copy | All match (`74d6fe0b…`). Small asset metadata files copied alongside. |
| `simctl runtime delete` of the internal copy | Succeeded. Runtime store: 16,236,996 → 8,116,416 KiB (**7.74 GiB freed**). |
| Side effect of the stock delete | `SimLaunchHost` crashed with a bus error again — the third time today this has coincided with `simctl runtime delete`. |
| Restart of the per-user CoreSimulator service | Needed, as before, to clear the stale entry. No simulator was booted. |
| Attach from the SSD and register | iOS 27.2 (24B8117) listed again within seconds, served from `/private/tmp/simruntime-offload-<uid>/24B8117`. |
| SDK-to-runtime matching (`simctl runtime match list`) | `iphoneos27.2` still chooses 24B8117. |
| New device with the default "System" runtime policy | Booted on 24B8117 from the SSD; first boot 32 s (39 s for the internal baseline earlier). |
| `xcodebuild build` for that device and for the generic simulator destination | Both succeeded. No "platform is not installed" error. |

### What this does and does not show

- The offloaded build remains the one the SDK selects, and command-line
  builds are unaffected.
- **It does not yet show what Xcode does when no iOS 27.2 runtime is installed
  internally**, because the release-candidate build 24B114 is still installed
  and may be satisfying Xcode's platform check. Only Xcode's Components pane
  can show how it now regards iOS 27.2.
- **A new risk for existing devices.** A device with the "System" policy
  follows whichever iOS 27.2 build is available. With the SSD attached that is
  24B8117; without it, the device would silently resolve to the internal 24B114
  and boot data last used on a newer build with an older one.

## 3. A dangling link

With a link whose target does not exist in the per-user runtimes directory:
other runtimes are unaffected, but **every `simctl` invocation prints
"Malformed bundle does not contain an identifier at …"**. A tool must remove
its links when the volume is absent rather than leave them dangling. The
harness now replaces a stale link on attach.

## 4. A harness defect found on the way

`sro.sh detach --force` was run while Xcode's debugger still had an app alive
on the device. `simctl shutdown` had returned, the booted-device check passed,
the first eject was refused by the still-exiting process, and the script went
straight to a forced unmount. It ended the debugging session. The harness now
retries a normal eject for about ten seconds before considering force.

## State left on the machine

| Item | State |
|---|---|
| Internal runtimes | 24B114 only (7.7 GiB). 24B8117's internal copy is deleted. |
| Served from the SSD | iOS 27.0 (24A434) and iOS 27.2 (24B8117), both mounted under `/private/tmp/simruntime-offload-<uid>/` and registered. |
| SSD | Verified images of 24A434, 24B8117 and 24B114. |
| Devices | The owner's device (untouched, never booted by these tests) and `sro-offload-3`. |
| After a reboot or logout | The two SSD-hosted runtimes are **not** re-attached automatically. Until `experiments/sro.sh attach 24B8117` (and `24A434`) is run, iOS 27.2 devices resolve to 24B114 and `simctl` prints a warning per stale link. |
