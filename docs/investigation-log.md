# Investigation log

Chronological record of hypotheses, evidence, experiments, rejected approaches,
open uncertainties and decisions. Newest session last. Conclusions are
consolidated in [technical-assessment.md](technical-assessment.md); this file
records how they were reached.

Evidence labels: **V** verified on this machine · **S** static analysis of
shipped code · **R** third-party report · **H** hypothesis.

---

## Session 1 — 2026-11-10 — Phase 1 and read-only Phase 2

Environment: macOS 27.2.1 (26B131), Xcode 27.2 (27B52), CoreSimulator 1174.21,
Apple M3, SIP enabled. No system state was modified. No command was run with
elevated privileges.

### Starting hypotheses

| # | Hypothesis (from the brief and the gist) | Outcome |
|---|---|---|
| H1 | Runtime images live in `/Library/Developer/CoreSimulator/Images` and mount under `…/Volumes`. | **Refuted here.** Both runtimes are MobileAsset assets in `/System/Library/AssetsV2`, mounted by `cryptexd` under `/private/var/run`. (V) |
| H2 | Mounting external storage at those two paths moves the bulk of runtime data off the internal disk. | **Refuted here** for runtimes installed the normal way: it would move 2 KB. (V) |
| H3 | Symlinks fail because `simdiskimaged` validates mount parents. | **Partly confirmed, and incomplete.** Three independent layers defeat symlinks; see assessment §3. (V, S, H) |
| H4 | A supported relocation setting may exist. | **Not found.** 48 CoreSimulator defaults and the Xcode download defaults were enumerated; none relocates image storage. (S) |

### Evidence collected

1. **Baseline** (V). `scripts/collect-baseline.sh` → `docs/baseline/2026-11-10/`.
   Two iOS 27.2 runtimes (24B114, 24B8117), 7.7 GiB each, kind "Patchable
   Cryptex Disk Image", state Ready. One device, runtime policy "System". The
   iOS 27.2 SDK (24B8118) selects 24B8117. Internal disk 245 GB, 71 GiB free.
   External: USB 10 Gb/s, Realtek RTL9210 bridge, APFS container with one
   volume, 255.7 GB free, ownership disabled, SMART not supported. Volume UUID
   `<volume UUID>`.
2. **Where the bytes are** (V). `stat` device numbers show
   `/System/Library/AssetsV2` and `/Library/Developer/CoreSimulator` are both
   on the internal Data volume. `/usr/share/firmlinks` lists AssetsV2.
   `rootless.conf` labels it `MobileAsset`; the directory carries the
   `restricted` flag.
3. **The image itself** (V). `hdiutil imageinfo`: UDIF, LZFSE-compressed,
   unencrypted, GUID partition scheme, 8.31 GB compressed, 19.05 GB expanded.
   Readable by an unprivileged user. No quarantine attribute on the file.
   `launchd_sim` inside the runtime is signed by "macOS Software Signing" (a
   normal Apple signature). The runtime contains a pre-built dyld shared cache
   (3.7 GB); `/Library/Developer/CoreSimulator/Caches/dyld` is empty.
4. **Protection of the CoreSimulator tree** (V). As an unprivileged user,
   `touch` under `/Library/Developer/CoreSimulator/**` fails with `EPERM`;
   under `/Library/Developer` and `/Library/Developer/PrivateFrameworks` it
   fails with `EACCES`. Directory flags and ACLs are identical in both cases,
   so the difference is a MAC policy, not POSIX permissions.
5. **`simdiskimaged`** (V for entitlements and launchd state; S for the rest).
   Root, started on demand by CoreSimulatorService (launchd: "submitted by",
   `managed_by = com.apple.CoreSimulator.CoreSimulatorService`), not from a
   plist in `/Library/LaunchDaemons`. Entitlements include
   `com.apple.private.security.storage.CoreSimulator.heritable`, cryptex
   install/mount/unmount, and access to the four simulator-runtime asset
   types. Its embedded sandbox profile restricts `file-mount` to four literal
   subpaths of `/Library/Developer/CoreSimulator/`. XPC operations include
   `DirectoryConfiguration`, `AddImage`, `RelocateRuntimeImage`,
   `TriggerScanAndMount`, `RegisterLegacyRuntime`.
6. **Volume discovery in CoreSimulator** (S; control flow re-read
   independently). Trust decision order and realpath-based comparison as
   described in assessment §2.4. `allowUntrustedMountDirectories` derives from
   `os_variant_allows_internal_security_policies`, not from a default.
7. **Profile-directory discovery** (S; re-read independently).
   `-[SimServiceContext _loadProfilesAtPath:…]`: directory listing →
   `sim_realPath` → `hasSuffix:` on the resolved path → load bundle.
   `-[SimProfilesPathMonitor monitorDefaultProfilePaths]` includes a path built
   from `NSHomeDirectory()`.
8. **Download path** (S; V for the cached index and for log lines). The cached
   downloadable index has no DMG source for any simulator runtime from iOS 18
   onwards; all are `mobileAsset` / `cryptexDiskImage`. The process that asks
   MobileAsset to download is Xcode or `xcodebuild` itself. `-exportPath`
   exports after installing, producing an `.exportedBundle` directory (a copy
   of `AssetData/` plus metadata), not a `.dmg`. `-importPlatform` stages a
   full copy in `$TMPDIR`; `simctl runtime add` stages in `/private/tmp`.
9. **Boot-time behaviour** (V, from the unified log). After the last reboot the
   daemon's first cryptex mount attempt failed ("Failed to install cryptex for
   mounting"), it fell back to a plain disk-image attach under
   `/Library/Developer/CoreSimulator/Volumes/iOS_<build>`, then preferred the
   cryptex variant once available. About 29 s from daemon start to both
   runtimes Ready. This shows the plain-disk-image route is exercised in
   normal operation on this OS.
10. **Prior art** (R). No Apple-supported relocation exists; Apple DTS lists
    only Xcode itself, Derived Data, Archives and the compilation cache as
    movable. One detailed third-party experiment (XCodeVault, Xcode 26.5,
    Intel) mounted an external APFS volume at `…/Images`: it served runtimes,
    but imports copied through internal staging, and attaching the drive after
    login produced a silent split between what `simctl` listed and what was
    mounted; the author shelved it. A symlink of the AssetsV2 runtime
    directory (Xcode 26.3) broke all downloads. No report was found of
    external storage working with Xcode 27.

### How the work was divided

Three Opus subagents ran in parallel, all read-only: public prior art and
Apple documentation; static analysis of CoreSimulator.framework, `simctl` and
CoreSimulatorService; static analysis of Xcode's download path plus log
reconstruction. I analysed `simdiskimaged`'s embedded strings and sandbox
profile directly and then re-derived, from the disassembly, the two subagent
claims the proposed design depends on (items 6 and 7). Subagent claims not
re-derived are labelled S or R in the assessment according to their source,
and none is treated as V.

### Rejected approaches

| Approach | Reason |
|---|---|
| Symlink any CoreSimulator system directory | Defeated at three layers (assessment §3). |
| Redirect or symlink the MobileAsset store | SIP-protected against root; path hard-coded; reported to break downloads. Would require weakening SIP. |
| Force DMG delivery via a default | No such branch exists; disabling MobileAsset makes runtimes unavailable rather than delivered differently. (S) |
| `simctl runtime add --legacy` | Gated on AppleInternal at three layers. (S) |
| Daemon "mount in place" strategy | Needs a root client of private XPC; registrations outside managed storage are dropped on rescan. (S) |
| Copy the unpacked bundle to the SSD | 2.3× the space and no integrity seal. |
| Adopt the gist as-is | Relocates nothing on this OS; see assessment §4. |
| Derive code from the gist | It has no licence. |

### Decisions

| Decision | Rationale |
|---|---|
| Investigate approach C (attach + per-user symlink) first, then B, then A. | Lowest privilege and smallest blast radius first; C changes nothing the system owns. |
| Keep the compressed DMG, not an unpacked copy, on the SSD. | Smaller, read-only, checksummed, and identical to what Apple ships. |
| Identify the SSD by APFS volume UUID. | `/dev/diskN` and volume names are both unstable. |
| First test (batch 1) involves no CoreSimulator interaction. | Storage soundness must be established before any result that depends on it. |
| Use a distinct build (iOS 27.0) as the disposable runtime. | Avoids two registrations of one build, which CoreSimulator de-duplicates in ways not yet understood. |
| Write an experiment harness in shell now; defer the Swift tool. | The mechanism is unproven. A reviewed script makes experiments repeatable without committing to an architecture. |
| Do not commit yet. | Left for you to review; the repository is on `main`. |

### Remaining uncertainties

Listed as open questions 1–8 in the assessment. The ones that could invalidate
the direction entirely:

- whether CoreSimulator and simulator processes may read through a disk image
  whose backing file is on a removable volume (TCC);
- whether Xcode treats a bundle-registered runtime as an installed platform,
  or instead keeps offering to download it again;
- whether a deleted MobileAsset runtime stays deleted across a reboot.

### Limitations of this session

- The REA disassembler provider could not start: macOS denied Apple Events
  permission to drive Hopper. Analysis used `otool`, `objdump`, `nm`,
  `strings` and static `lldb`. `simdiskimaged` is stripped Swift, so its
  internal logic (mount-point validation, handling of attachments it did not
  create) was read only at the level of strings, the sandbox profile and call
  structure.
- The unified log retains roughly eleven days; the original installation of
  the two runtimes is reconstructed from file timestamps only.
- "Verify that existing workflows function normally" (Phase 2, item 6) was
  limited to `simctl` listing commands. Booting a device is deferred to
  experiment batch 0 because it changes state.
- SSD health could not be read (no SMART through the USB bridge).

---

## Session 2 — 2026-11-10 — experiment batches 0–2

Approved by the project owner ("run all of them", covering batches 0, 1 and 2
and the conditional service restart). Full results:
[results/2026-11-10/batches-0-2.md](results/2026-11-10/batches-0-2.md).

### Hypotheses tested

| # | Hypothesis | Outcome |
|---|---|---|
| H5 | The SSD can store and return an 8.3 GB image bit-for-bit. | **Confirmed** twice (24B114, 24A434), including a cold read after remount. (V) |
| H6 | A MobileAsset download needs more than one image's worth of internal space at its peak. | **Refuted.** Peak equals final size. (V) |
| H7 | Deleting the internal registration reclaims the space immediately. | **Confirmed** within the session; persistence across a reboot not yet tested. (V) |
| H8 | A symlinked bundle on an attached image is discovered without a restart. | **Confirmed for new processes; refuted for the running service** when the same build had just been deleted (stale entry, P1). (V) |
| H9 | A device boots from a plain disk-image mount backed by the SSD. | **Confirmed.** (V) |
| H10 | With the volume gone the runtime simply becomes unavailable. | **Confirmed** for a requested unmount: graceful unload, clear errors. Abrupt removal untested. (V) |
| H11 | Detaching is a clean `hdiutil detach`. | **Refuted.** `SimLaunchHost` keeps a dylib mapped (P2). (V) |

### Decisions

| Decision | Rationale |
|---|---|
| Applied the pre-approved restart of the per-user CoreSimulator service once. | Device creation was impossible while the service held the stale entry; no simulator was booted; the root daemon was left alone. |
| Did not force the unmount or restart `SimLaunchHost`. | "Detach refused" is a stop condition in the approved plan, and neither action was approved. The image was left mounted and unregistered. |
| Used `simctl launch` after the Device panel command timed out twice. | The launch is itself a required test, and the plan names `simctl launch`. |
| Measure internal usage by directory size, not free space. | Swap on the shared APFS container moved free space by 5 GB during an unrelated step. |

### New uncertainties

- Why the first boot took 219 s (legacy disk-image stack, cold cache, or
  machine load).
- Whether restarting `SimLaunchHost` is a safe and sufficient way to release a
  runtime volume, and whether CoreSimulator recovers from it transparently.
- What happens to `SimLaunchHost` and to CoreSimulator if the volume disappears
  without an unmount request.
- Whether Xcode's interface accepts the runtime as an installed platform.

---

## Session 3 — 2026-11-10 — attach stack and eject

Approved: restart `SimLaunchHost`, eject normally, re-attach with
`diskutil image attach`, repeat boot timings. Full results:
[results/2026-11-10/attach-stack-and-eject.md](results/2026-11-10/attach-stack-and-eject.md).

### Hypotheses tested

| # | Hypothesis | Outcome |
|---|---|---|
| H12 | Restarting `SimLaunchHost` lets the volume eject normally. | **Refuted.** The visible holder goes away; the eject still fails. (V) |
| H13 | The slow boot is the old SSD and its USB enclosure (project owner's suggestion). | **Refuted.** Raw SSD: 671 MB/s, 0.42 ms. Through DiskImages2 it beat the internal cryptex mount under concurrency. (V) |
| H14 | The slow boot is the legacy `hdiutil` stack. | **Confirmed.** 881 against 6,704 concurrent reads/s; first boot 41 s against 219–224 s. (V) |
| H15 | The dyld shared cache is rejected because files appear user-owned. | **Refuted.** The cache is mapped in running apps. (V) |
| H16 | The slow first boot is a one-off first-use cost. | **Refuted.** Reproduced on a second device. (V) |
| H17 | The remaining hold is the kernel's shared-region grace period and lapses by itself. | **Refuted.** Still held after seven minutes. (V) |
| H18 | The hold comes from executing from the volume, not from mounting it. | **Supported.** Read-only use ejects cleanly, 4 of 4; after booting, 0 of 18. (V) |

### Decisions

| Decision | Rationale |
|---|---|
| Harness switched to `diskutil image attach` / `diskutil eject`. | Measured 7.6× difference under concurrency; `hdiutil attach` is deprecated on this OS. |
| Worked around the stuck mount with an APFS clone of the image rather than forcing it. | A clone is a distinct file at no storage cost, so the comparison could proceed without an unapproved forced unmount. |
| Left iOS 27.0 registered from the SSD. | So the Xcode interface check (plan step 2.8) can be done. |
| Deleted two of the three throwaway devices. | They were created by these tests and held about 6 GB. |

### Open

- What holds a used runtime volume (root process or kernel), and whether a
  forced unmount after unregistering and restarting `SimLaunchHost` is safe.
- Everything that needs a reboot or a physical disconnection.
- Xcode's interface.

---

## Session 4 — 2026-11-10 — holder identified, forced eject, Xcode interface

Approved: one read-only `sudo lsof`; forced unmount of the idle mount, then the
full eject sequence on the working mount. Full results:
[results/2026-11-10/eject-and-xcode.md](results/2026-11-10/eject-and-xcode.md).

### Hypotheses tested

| # | Hypothesis | Outcome |
|---|---|---|
| H19 | The invisible holder is a root process rather than the kernel. | **Confirmed:** `spindump`, with simulator binaries mapped. (V) |
| H20 | The hold is inherent to running simulators from a volume. | **Refuted.** It depends on whether `spindump` sampled them; a later mount ejected normally after four boots. (V) |
| H21 | A forced unmount, after unregistering and restarting `SimLaunchHost`, is safe. | **Supported:** three clean runs, no host-process crash, runtimes intact. Small sample. (V) |
| H22 | Simulator-daemon crash reports on the SSD-hosted runtime indicate a defect of SSD hosting. | **Not supported.** The internal runtime produces comparable crashes under the same pattern. (V, imperfect control) |
| H23 | Xcode treats a bundle-registered runtime as an installed platform. | **Partly.** Usable as a run destination; invisible to Components; shown as "unavailable" in Devices and Simulators. (V, by the project owner) |

### Decisions

| Decision | Rationale |
|---|---|
| Eject order in the harness: unregister → restart helper → normal eject → forced unmount only with `--force`. | A normal eject often works; force is needed only when diagnostics hold the volume. Restarting the helper first avoids the bus-error crash that Apple's own delete path causes. |
| Screenshots supplied by the project owner are described, not stored. | They show unrelated project and device names. |

### Open

- Offloading the SDK-matching runtime: does Xcode demand a download?
- The "unavailable" label in Devices and Simulators.
- Reboot behaviour, late-arriving SSD, abrupt disconnection.
- A deleted internal runtime staying deleted across a reboot.

### Session 4, addendum — Xcode's live device view

| # | Hypothesis | Outcome |
|---|---|---|
| H24 | Xcode's "unavailable" label and display timeout come from a component with a different view of the runtime. | **Confirmed.** The sandboxed `CoreDeviceService` could not read the runtime bundle under `~/Library/Application Support`. (V) |
| H25 | Mounting under `/private/tmp`, which that sandbox allows, fixes it. | **Supported at the log level**; interface confirmation pending. (V) |

Decision: the harness now mounts under `/private/tmp/simruntime-offload-<uid>/`
by default (`SRO_MOUNT_ROOT` overrides). Lesson recorded: command-line success
(`simctl`, `xcodebuild`) does not establish that Xcode's interface works,
because different processes with different sandboxes are involved.

H25 was then confirmed in Xcode's interface by the project owner: the live
device view connected and an app ran on the SSD-hosted device. One defect
remains: the device is labelled "unavailable" while shut down (H26, untested:
the sandboxed service's own runtime list is built from its container home and
omits the symlinked runtime).

---

## Session 5 — 2026-11-10 — SDK-matching runtime offloaded; root variant blocked

Approved: offload 24B8117; test the root-mounted trusted-directory variant.
Full results:
[results/2026-11-10/sdk-runtime-offload-and-root-variant.md](results/2026-11-10/sdk-runtime-offload-and-root-variant.md).

| # | Hypothesis | Outcome |
|---|---|---|
| H27 | Root can create a mount point under `/Library/Developer/CoreSimulator/Volumes`. | **Refuted.** `EPERM` as root. (V) |
| H28 | After offloading, the SDK still selects the offloaded build and builds work. | **Confirmed** for `simctl` matching and `xcodebuild`. (V) |
| H29 | Xcode accepts the offloaded build as the installed iOS 27.2 platform. | **Open.** Masked by the internal 24B114; needs the Components pane. |
| H30 | A dangling runtime link is harmless. | **Partly.** No functional effect, but a warning on every `simctl` call. (V) |

Decisions: approach B is set aside (root is not sufficient; the alternatives
are disproportionate). `/Library/Developer/DeviceKit/Runtimes` is recorded as
an untested candidate for a home-independent registration. The harness gained
an eject retry and stale-link replacement.

Mistake recorded: a device was shut down and its runtime force-unmounted while
the project owner's Xcode debugger was attached to an app on it.

---

## Session 6 — 2026-11-10 — login agent; last internal runtime removed; DeviceKit

Full results:
[results/2026-11-10/agent-rc-delete-devicekit.md](results/2026-11-10/agent-rc-delete-devicekit.md).

| # | Hypothesis | Outcome |
|---|---|---|
| H31 | A shell-script LaunchAgent can attach an image from a removable volume. | **Refuted.** Refused without a prompt; attributed to `/bin/bash`. (V) |
| H32 | A native launcher as the job's executable gets a consent prompt instead. | **Confirmed.** (V) |
| H33 | `StartOnMount` re-attaches after an unrelated mount, without polling. | **Confirmed**, 3 s. (V) |
| H34 | `simctl runtime delete` always reclaims the asset. | **Refuted.** A superseded build needed scan-and-mount and a second delete. (V) |
| H35 | Builds work with no internally installed iOS runtime. | **Confirmed** for `xcodebuild`; Xcode's interface not yet observed. (V) |
| H36 | `/Library/Developer/DeviceKit/Runtimes` is loaded as a runtime directory. | **Confirmed.** (V) |
| H26 | A home-independent registration clears Xcode's "unavailable" label. | **Open**; needs the interface, probably after `CoreDeviceService` restarts. |

Decisions: the agent's executable is a native launcher; links now live in
`/Library/Developer/DeviceKit/Runtimes` on this machine; the harness's default
link directory is unchanged until H26 is settled.

Mistakes recorded: the SSD copy of 24B114 was removed without gating on the
internal delete's success; the errexit bug in `sync`.

---

## Session 7 — 2026-11-10 — restart with the SSD connected

Full results: [results/2026-11-10/restart-with-ssd.md](results/2026-11-10/restart-with-ssd.md).

| # | Hypothesis | Outcome |
|---|---|---|
| H37 | The agent restores both runtimes after a restart. | **Confirmed**, but only 2.5 minutes after login. (V) |
| H38 | A deleted internal runtime stays deleted across a restart. | **Confirmed** on Xcode 27.2. (V) |
| H39 | The slow first attach was a consent prompt. | **Refuted**; no prompt appeared. Cause open; background-priority throttling suspected. |
| H26 | A home-independent registration clears Xcode's "unavailable" label. | **Label cleared after the restart**, but confounded with `CoreDeviceService` being fresh. |

Open: live recovery of Xcode's interface when runtimes arrive late; the cause
of the login delay; which change cleared the label; Xcode's "Get" badge on the
generic simulator destination.

---

## Session 8 — 2026-11-10 — restart without the SSD, then reconnecting

Full results: [results/2026-11-10/restart-without-ssd.md](results/2026-11-10/restart-without-ssd.md).

| # | Hypothesis | Outcome |
|---|---|---|
| H40 | With the SSD absent at login the system fails predictably. | **Confirmed.** Simulators unavailable, no errors. (V) |
| H41 | A late-arriving SSD is picked up without polling. | **Confirmed.** 2 s from mount to both runtimes registered. (V) |
| H42 | Xcode's interface recovers without a relaunch when runtimes arrive. | **Confirmed** by the project owner. (V) |

Open: whether the login-time delay seen in session 7 is gone; abrupt
disconnection; which change cleared the "unavailable" label; behaviour over
days (temporary-file cleanup) and across an Xcode update.

---

## Session 9 — 2026-11-10 — login delay re-test; which change cleared the label

**Login delay (third restart, SSD connected).** Agent started 14 s after login
(80 s before the priority change); attaches took 3 s and 1 s; both runtimes
registered about 21 s after login (2.5 minutes before). The project owner
reports the simulators appearing shortly after Xcode and Device Hub opened.
H39's replacement — background-priority throttling — is supported by two
consistent runs. (V)

**Root or not.** Links moved back to the per-user directory, with
`CoreDeviceService` restarted first so that it started with no runtimes, as at
login.

| Registration | `CoreDeviceService` | Device Hub label | Run from Xcode |
|---|---|---|---|
| per-user directory | stale (running since boot) | unavailable | works |
| `DeviceKit/Runtimes` | stale (started before the directory existed) | unavailable | works |
| `DeviceKit/Runtimes` | fresh (restart) | **available** | works |
| per-user directory | fresh (restarted) | **unavailable** | works |

H26 is **confirmed**: the home-independent location is what clears the label.
A fresh service is also needed the first time, because a service that started
before `DeviceKit/Runtimes` existed is not watching it. The per-user route is
functional but leaves Device Hub showing the simulators as unavailable.

Decision: the links stay in `/Library/Developer/DeviceKit/Runtimes` and the
agent is configured for it. A public tool therefore has one privileged setup
step (creating that directory); everything afterwards is unprivileged.

---

## Session 10 — 2026-11-10 — the two design validations

Results: [restore-by-reimport.md](results/2026-11-10/restore-by-reimport.md),
[abrupt-disconnection.md](results/2026-11-10/abrupt-disconnection.md).

| # | Hypothesis | Outcome |
|---|---|---|
| H43 | `simctl runtime add` restores an offloaded runtime from the SSD. | **Confirmed**, 35–40 s, registered as a plain disk image. (V) |
| H44 | Xcode then regards the platform as installed. | **Confirmed** by the project owner. (V) |
| H45 | Deleting an imported runtime frees its space. | **Refuted** until `scan-and-mount` clears an inbox clone. (V) |
| H46 | Pulling the cable with a simulator running leaves dead mounts or hung services to repair. | **Refuted.** The kernel removes the mount; services keep running; `Sync` restores the runtime on reconnection. (V, one run) |

Decisions: `restore` is re-import; `scan-and-mount` follows every add and
delete; no special repair path for disconnection.

24B8117 was internal for the duration of the disconnection test and is served
from the SSD again.

---

## Session 11 — 2026-11-10 — native tool, build steps 1–3

Decisions taken by the project owner: the design's recommendations are
accepted; MIT licence.

Built, with 79 tests passing: the package skeleton, preflight and `doctor`;
CoreSimulator, volume and manifest readers and `list`; the image attacher, the
link registry and the reconcile logic. Run on this machine, `doctor` passes
every check and `list` reports both runtimes as active on the external volume.

One deviation from the design: volume lookup uses `diskutil info -plist`
rather than DiskArbitration (design updated with the reason).

One defect found by the integration test before it could matter: the
mount-point check compared a path as written with the kernel's canonical path,
so it failed for any path through a symlink such as `/var`. It now
canonicalises with realpath(3).

Nothing built so far changes the machine when run as a command. The harness
and its agent are still what serve the runtimes.
