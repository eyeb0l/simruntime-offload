# Offloading a runtime with the native tool

2026-11-10. macOS 27.2.1, Xcode 27.2, CoreSimulator 1174.21. Tool at build
step 5 (release build). Evidence labels as in the technical assessment.

## What was tested

A runtime that had never been touched by the harness was downloaded and then
offloaded with `simruntime-offload offload` alone. The two runtimes already
served from the volume were left alone throughout.

| | |
|---|---|
| Runtime | iOS 27.1, build 24A94425, 7,874,743,137 bytes |
| Downloaded with | `xcodebuild -downloadPlatform iOS -buildVersion 27.1` |
| Registered as | Patchable Cryptex Disk Image under `/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime/<sha1>.asset` |
| Simulators booted | none |

## Result

`offload 24A94425` (the volume defaulted to the one already in use) finished
in 54 s and exited 0:

1. copied the image to `SimRuntimes/24A94425/043-77717-424.dmg` on the volume;
2. reported the SHA-256 of both copies as equal, and `hdiutil verify` as passing;
3. deleted the internal copy and found it gone at the first check, with no
   retry needed;
4. restarted the per-user CoreSimulator service;
5. attached the copy and found the runtime listed from the offload mount.

Checked afterwards, independently of the tool (V):

| Check | Observed |
|---|---|
| `simctl runtime list` | 0 disk images |
| Internal asset directory | gone; only the catalogue XML files remain |
| Both daemon inboxes | empty |
| Free space on the internal Data volume | 66 GiB before, 74 GiB after |
| `shasum -a 256` of the copy | equals the value in `SHA256SUMS` and in the manifest |
| Extended attributes on the copy | `com.apple.provenance` and `com.apple.diskimages.recentcksum` only; both were added on the volume (by the system and by `hdiutil verify`), not carried from the source |
| Mounts | three, all `diskutil image` attachments under `/private/tmp/simruntime-offload-501/` |
| `simctl list runtimes` | iOS 27.0, 27.1 and 27.2, all available |
| Manifest | third entry, not staged, with checksum, size, name and time |
| `doctor` | every check ok |

A device created on the offloaded runtime booted in 38 s, and Settings
launched and rendered (screenshot taken through the device panel, not kept).

## Things the run showed

**The agent and `offload` do collide.** The agent's log has "another sync is
running; leaving it to finish" at the very second `offload` attached the image: the
attach is itself a mount event, so launchd started the agent while `offload`
held the lock. This is the expected behaviour of the lock, now seen for real.
The converse case, the agent holding the lock when `offload` wants it, is why
`offload` now waits and retries rather than failing after the internal copy is
gone. (V for the first; unit-tested only for the second.)

**`setup` would have forgotten the new runtime.** After the offload, `doctor`
warned that the harness and the manifest listed different runtimes and
recommended `setup`, which at that point rebuilt the manifest from the
harness's two entries. Running it would have dropped the third runtime from
the manifest while leaving its image attached. Found before it was run; the
manifest is now authoritative once it exists, and the warning is gone.

**The old agent did not understand "staged".** The agent installed at step 4
ignores the `staged` field, so during the window between the copy and the
delete it could have attached the volume's copy of a build still registered
internally. The agent was replaced with the step 5 build before the run for
that reason. Anyone upgrading across this change must re-run `setup` first;
there are no such users, but the release notes for a first tagged version
should not need this caveat, which is an argument for not tagging before the
manifest format has settled.

**This build of iOS 27.1 supports one device type.** 24A94425 lists a single
supported device type, and creating an "iPhone 18 Pro" on it fails with
"Incompatible device". That is a property of the runtime, not of offloading:
`supportedDeviceTypes` is read from the runtime bundle.

## Not explained

The first boot of the new device printed "Data Migration Failed" from
`simctl bootstatus`, and then completed; the device was healthy afterwards
(SpringBoard running, 22 apps installed, Settings usable). Neither of the
other two runtimes has printed this. There is no control: the internal copy of
this runtime was already gone, so the message cannot be attributed to the
runtime itself or to its being served from the volume. `restore` (build step
6) will put this runtime back on the internal disk, which is the control. (H)

The second boot of the same device (3 s) printed it again, so it is not a
first-boot effect.

## The native `eject`

Run three ways, with the project owner present for the real ones.

| Run | Result |
|---|---|
| With a simulator booted | Refused, naming the simulator; mounts and links unchanged. (V) |
| Immediately after `simctl shutdown` of a device that had 1,053 files open under the mounts | Exit 0 in 23 s. All three runtimes unregistered and ejected at the first attempt, then the volume. No mounts, no links, no runtimes listed, services still running, no new crash report. (V) |
| Again, after the fix below | Same, 23 s. (V) |

The retry and the forced unmount were not needed in either run and remain
covered by unit tests only.

**Defect found: "eject" released one volume, not the disk.** The first real
run used `diskutil eject <volume UUID>`, which unmounted the volume and left
the physical disk attached. On this disk, which has one volume, that is still
safe to unplug. On a disk with a second mounted volume the tool would have
printed "Safe to unplug" with that volume still mounted. `eject` now resolves
the physical disk behind the volume (the disk its APFS container's physical
store is a slice of) and ejects that, which unmounts everything on it or fails;
it refuses outright if the volume reports itself internal; and it releases a
disk that is attached even when the tool's own volume is already unmounted.

**This enclosure stays listed after an eject.** `diskutil eject disk6` prints
"Disk disk6 ejected" and exits 0, yet `diskutil list external` still shows the
disk and its container, with the volume unmounted, and `diskutil mount <UUID>`
brings it back without touching the cable. Whether that is this USB bridge or
general behaviour for non-removable-media USB disks on this OS was not
investigated. Every volume is unmounted and the OS reports the disk ejected,
which is what "safe to unplug" claims. (V for the observation, H for the cause)

**Remounting in software restores everything.** After the first eject,
`diskutil mount <UUID>` was followed 5 s later by the agent's log lines
"attached and linked" for all three runtimes, and `simctl` listed all three
6 s after the mount. (V, one run)

**Where the 23 s goes.** Each runtime is handled in turn: remove the link, wait
a second, restart `SimLaunchHost`, eject the image. Restarting the helper once
for all runtimes would be faster; it was left alone because the sequence as it
stands is the one that has been tested.

**A physical replug restores everything.** After the second eject the project
owner unplugged the disk and plugged it back in. The agent logged "attached and
linked" for all three runtimes in the same second; `simctl` lists all three;
Device Hub shows the simulators as available; `diskutil verifyVolume` exits 0;
and all three images still match their `SHA256SUMS`. (V, one run)

## Not tested in this run

- The retry path of the delete (`scan-and-mount`, delete again). The delete
  worked first time here. It is covered by unit tests modelled on the earlier
  release-candidate failure.
- An interruption during the copy or between the copy and the delete.
- A volume other than the one already in use.
