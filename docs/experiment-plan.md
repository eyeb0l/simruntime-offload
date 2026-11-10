# Experiment plan

Status: batches 0–2 were run on 2026-11-10; results are in
[results/2026-11-10/batches-0-2.md](results/2026-11-10/batches-0-2.md). Batch 2
stopped at a stop condition (step 2.9: the image could not be unmounted
cleanly), so the second half of 2.9 and step 2.8 are outstanding. A follow-up on the attach method and on ejecting is in
[results/2026-11-10/attach-stack-and-eject.md](results/2026-11-10/attach-stack-and-eject.md);
it supersedes the `hdiutil` commands shown below. Later batches
have not been run and each needs approval. No step in batches 0–2 uses `sudo`.

Background and the reasoning behind the choice of approach are in
[technical-assessment.md](technical-assessment.md). The harness referred to
below is [`experiments/sro.sh`](../experiments/sro.sh); its read-only and
dry-run paths have been exercised, its mutating paths have not.

## Proposed experimental implementation

Approach C from the assessment: keep the runtime's compressed disk image on the
SSD, attach it read-only as an ordinary disk image, and expose the runtime
bundle inside it to CoreSimulator through a symlink in the per-user profile
directory.

```
SSD (APFS volume, selected by volume UUID)
└── SimRuntimes/<build>/<n>.dmg + SHA256SUMS        ← the only large data

~/Library/Application Support/simruntime-offload/mnt/<build>/    ← read-only mount of that image
~/Library/Developer/CoreSimulator/Profiles/Runtimes/offload-<build>.simruntime
        → …/mnt/<build>/Library/Developer/CoreSimulator/Profiles/Runtimes/<name>.simruntime
```

Properties this is meant to have, each of which the experiments must confirm
or refute:

- no root, no LaunchDaemon, no change to anything under `/Library` or `/System`;
- zero steady-state internal bytes for the runtime;
- corruption on the SSD is detectable (SHA-256 at staging, UDIF checksums at
  attach) and the image is re-downloadable;
- with the SSD absent the link dangles and the runtime is simply unavailable;
- removal is `rm` of one symlink and `hdiutil detach` of one image.

If the mechanism holds up, the intended deliverable is a small Swift
command-line tool plus a per-user LaunchAgent using `StartOnMount` (launchd
starts the job whenever any filesystem mounts, so a late-arriving SSD is
handled without polling). Swift is chosen for direct access to DiskArbitration
and for shipping as a single auditable binary with no interpreter dependency.
That work does not start until batches 1–3 have produced evidence.

## Batch 0 — baseline workflow check

Purpose: prove the existing setup works *before* anything changes, so later
failures can be attributed.

| Step | Command | Effect |
|---|---|---|
| 0.1 | `xcrun simctl create sro-baseline com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro com.apple.CoreSimulator.SimRuntime.iOS-27-2` | Creates one throwaway device (a few MB in `~/Library/Developer/CoreSimulator/Devices`). |
| 0.2 | `xcrun simctl boot <udid>` then `xcrun simctl bootstatus <udid> -b` | Boots it; record time to boot. |
| 0.3 | Build and launch a minimal fixture app from this repository with `xcodebuild … -destination id=<udid>` and `simctl install` / `simctl launch` | Exercises the Xcode build-and-run path. |
| 0.4 | `xcrun simctl shutdown <udid>`; `xcrun simctl delete <udid>` | Removes the throwaway device. |

Your existing device is not booted or modified. Rollback: step 0.4.

## Batch 1 — first safe test: SSD soak and image staging

Purpose: find out whether the SSD can hold and return an 8.3 GB image
bit-for-bit, and how fast, **without any interaction with CoreSimulator**. This
is the first test because every later result is uninterpretable if the storage
itself is unsound.

It uses the image of the installed iOS 27.2 build 24B114 as a *read-only
source*. That runtime is not modified, moved or deleted. (It is also not the
build Xcode currently selects: the iOS 27.2 SDK maps to 24B8117.)

| Step | Command | Effect |
|---|---|---|
| 1.1 | `diskutil verifyVolume /Volumes/sparkle` | Read-only consistency check of the SSD's APFS volume. |
| 1.2 | `SRO_VOLUME_UUID=<volume UUID> experiments/sro.sh stage FAA4FBF3-277D-405D-9155-EEBD7FD6B7E6` | Copies the image to `/Volumes/sparkle/SimRuntimes/24B114/`, compares SHA-256 of source and copy, runs `hdiutil verify`. Timed. |
| 1.3 | `diskutil unmount /Volumes/sparkle` then `diskutil mount <volume UUID>` | A clean software unmount and remount with nothing using the volume, so the next read comes from the device rather than the page cache. |
| 1.4 | `shasum -a 256` of the staged image again; compare with `SHA256SUMS` | Cold read-back check and read throughput. |
| 1.5 | `log show --last 30m --predicate 'sender == "IOUSBMassStorageDriver" OR eventMessage CONTAINS "disk6"'` (tightened as needed) | Looks for I/O errors or bus resets during the soak. |

Affected paths: `/Volumes/sparkle/SimRuntimes/` only.
Risks: the SSD may fail under sustained write — which is the thing being
measured. Internal data is only read.
Rollback: `rm -r /Volumes/sparkle/SimRuntimes`.
Not attempted: the image is **not attached** in this batch, so CoreSimulator
never sees a second copy of an installed build.

Limitation to record: SMART data is not available. The enclosure is a Realtek
RTL9210 USB–NVMe bridge and macOS exposes no SMART pass-through for it;
obtaining it would need a third-party kernel extension, which this project will
not install. End-to-end checksums are the substitute.

## Batch 2 — serve a disposable runtime from the SSD

Purpose: answer open questions 1–4 of the assessment with a runtime that
nothing else depends on.

Disposable runtime: **iOS 27.0 (24A434)**. It is a distinct build from both
installed runtimes, so there is no duplicate-build ambiguity, and it is still
iOS, so the same fixture app can be used.

| Step | Command | Effect |
|---|---|---|
| 2.1 | Record `df -k /System/Volumes/Data` and `du -sk` of the AssetsV2 runtime directory | Internal-space baseline. |
| 2.2 | `xcodebuild -downloadPlatform iOS -buildVersion 27.0` | Downloads ~8.05 GB to the **internal** disk and registers iOS 27.0. Unavoidable (assessment §1.3). 71 GiB are free. |
| 2.3 | `experiments/sro.sh stage <uuid of the 27.0 image>` | Copy to SSD and verify, as in batch 1. |
| 2.4 | `xcrun simctl runtime delete <uuid of the 27.0 image>` | Deletes the *disposable* runtime's internal registration and purges its asset. Record `df` again: the internal figure should return to the 2.1 baseline. |
| 2.5 | `experiments/sro.sh attach 24A434` | Attaches the SSD copy read-only under `~/Library/Application Support/simruntime-offload/mnt/24A434` and creates the symlink. |
| 2.6 | `xcrun simctl list runtimes -v`; read `~/Library/Logs/CoreSimulator/CoreSimulator.log` | Does iOS 27.0 appear, and without a service restart? Note any TCC prompt. |
| 2.7 | Create a throwaway device on iOS 27.0; boot; `bootstatus`; build, install and launch the fixture app; screenshot; shutdown | Open question 1. Record boot time against batch 0. |
| 2.8 | Open Xcode: is iOS 27.0 offered as a run destination? Does Settings ▸ Components show it as installed or offer "Get"? | Open question 4. Observation only — do not click "Get". |
| 2.9 | With every simulator shut down: `experiments/sro.sh detach 24A434`, then `simctl list runtimes` and `simctl list devices`; then `attach` again and boot again | Controlled absence and recovery, without touching the cable. |
| 2.10 | Record `df` and the contents of `/Library/Developer/CoreSimulator/{Images,Volumes,Caches/dyld}` and `~/Library/Developer/CoreSimulator/Caches` | Confirms nothing was silently written internally. |

Conditional step, needing approval in advance: if 2.6 shows the runtime is not
picked up live, restart the per-user CoreSimulator service
(`launchctl kickstart -k user/$(id -u)/com.apple.CoreSimulator.CoreSimulatorService`;
the job is in the `user/<uid>` domain, verified with `launchctl print`).
Consequence: every booted simulator shuts down (none will be booted at that
point) and the service restarts on the next `simctl` call. The root daemon is
not touched. A design that needs this restart is weaker, and that would be
recorded as a finding.

Affected paths: the three listed at the top of `sro.sh`, plus the disposable
runtime's own asset and one throwaway device.

Rollback, in order:
1. `xcrun simctl shutdown all`; delete the throwaway device.
2. `experiments/sro.sh detach 24A434`.
3. `rmdir ~/Library/Developer/CoreSimulator/Profiles/Runtimes ~/Library/Developer/CoreSimulator/Profiles`
   (both created by this batch; they do not exist today).
4. `rm -r ~/Library/Application\ Support/simruntime-offload /Volumes/sparkle/SimRuntimes`.
5. If step 2.4 had not been reached: `xcrun simctl runtime delete <uuid>` removes
   the disposable runtime.

After rollback, `xcrun simctl runtime list` must show exactly the two runtimes
in `docs/baseline/2026-11-10/runtimes-disk-images.txt`, both `Ready`.

### Stop conditions

Stop and report, without attempting repair, if any of these occur:

- either existing runtime leaves the `Ready` state, or its entry in
  `images.plist` changes;
- `simdiskimaged` or CoreSimulatorService crashes or logs faults referring to
  the offload mount;
- `hdiutil detach` refuses because something still holds the volume;
- the SSD reports I/O errors or a checksum fails;
- a TCC prompt appears that cannot be attributed to a specific step.

## Later batches (outline only)

- **Batch 3 — reboots.** Restart with the SSD connected; restart without it;
  reconnect after login. Requires you at the machine, and an attach-at-mount
  agent to exist first.
- **Batch 4 — approach B**, only if C fails or Xcode will not recognise the
  runtime. Needs `sudo` and writes under
  `/Library/Developer/CoreSimulator/Volumes`; will be specified separately.
- **Batch 5 — unclean disconnection.** Pulling the cable with a simulator
  booted. Not to be run without explicit approval.
- **Batch 6 — more runtimes and an Xcode update.** A second platform; behaviour
  across the next Xcode point release.
