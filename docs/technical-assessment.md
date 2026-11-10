# Initial technical assessment

Status: Phase 1 complete, Phase 2 read-only baseline complete. Nothing on the
machine has been modified. Date: 2026-11-10.

Scope of validity: macOS 27.2.1 (26B131), Xcode 27.2 (27B52), CoreSimulator
1174.21, Apple silicon. Much of what follows is version-specific and several
points are known to differ on Xcode 26.x and earlier.

## Evidence labels

Every finding carries one of these labels. They are not interchangeable.

| Label | Meaning |
|---|---|
| **V** | Verified by direct observation on this machine (command output, file contents, logs). |
| **S** | Read from shipped code by static analysis (disassembly, embedded strings and profiles). Establishes what the code does, not that it was seen running. |
| **R** | Reported by a third party. Not reproduced here. |
| **H** | Hypothesis. Plausible, untested. |

## 1. Conclusions

1. **The existing workaround relocates nothing on this system.** Runtimes
   installed through Xcode or `xcodebuild -downloadPlatform` are MobileAsset
   assets under `/System/Library/AssetsV2`, a SIP-protected path on the internal
   Data volume. The two directories the gist mounts over hold a 2 KB registry
   file and nothing else. (V)
2. **The MobileAsset store cannot be relocated.** Its path is hard-coded in
   `mobileassetd` and in `simdiskimaged`, it is protected by SIP against root,
   and the one public attempt to redirect it broke all downloads. (V, S, R)
3. **Every new runtime must transit the internal disk.** Runtimes for iOS 18 and
   later are offered only through MobileAsset; no setting restores DMG delivery.
   `-exportPath` copies out *after* installing internally. Peak internal usage
   during acquisition is therefore unavoidable; only steady-state usage can be
   reduced. (S, V for the index contents)
4. **CoreSimulator has two discovery paths that do not depend on where the image
   file lives**, and both look usable for external storage:
   - volumes mounted beneath a *trusted mount directory*
     (`/Library/Developer/CoreSimulator/Volumes`), and
   - `.simruntime` bundles, including symlinked ones, in
     `~/Library/Developer/CoreSimulator/Profiles/Runtimes`. (S)
5. **The runtime image is self-contained and can be mounted as an ordinary disk
   image.** It is an unencrypted, compressed UDIF image; its binaries carry
   normal Apple signatures rather than depending on the cryptex trust cache; it
   ships its own dyld shared cache. `simdiskimaged` itself falls back to plain
   disk-image mounting when a cryptex mount fails. (V)
6. **A design is therefore plausible in which the 8.3 GB image sits on the SSD
   and is attached read-only from there, with zero steady-state internal
   cost.** Whether it is *reliable* is unproven. Nothing in this document shows
   a simulator booting from external storage on this OS.

## 2. System map

### 2.1 Components

| Component | Runs as | Role | Evidence |
|---|---|---|---|
| Xcode / `xcodebuild` + `DVTDownloads.framework` | user | Reads the downloadable index, asks MobileAsset to download a runtime, then asks CoreSimulator to register it in place. | S; V in logs for `xcodebuild` |
| `mobileassetd` (+ `nsurlsessiond`) | root | Downloads and unpacks the asset into `/System/Library/AssetsV2/com_apple_MobileAsset_<platform>SimulatorRuntime/<sha1>.asset/`. | V |
| `com.apple.CoreSimulator.CoreSimulatorService` | user | Owns devices and the runtime list. Starts `simdiskimaged` on demand (launchd shows it as *submitted by* the service, not as a LaunchDaemon plist). Runs `SimVolumeManager`, which watches DiskArbitration for volumes appearing. | V, S |
| `simdiskimaged` | root, sandboxed | Owns the image registry (`Images/images.plist`), stages, verifies, mounts and deletes runtime images, drives cryptex personalisation, builds dyld caches. | V, S |
| `cryptexd` | root | Mounts personalised runtime images at `/private/var/run/com.apple.security.cryptexd/mnt/<bundle-id>-<version>.<suffix>`. | V |
| `diskarbitrationd`, DiskImages2 | root | Attach disk images and mount their volumes. | V |

### 2.2 The storage classes involved

These are frequently conflated. They have different sizes, owners and
relocation prospects.

| Item | Location on this machine | Size | Writable by | Relocatable? |
|---|---|---|---|---|
| Runtime image (compressed DMG) | `/System/Library/AssetsV2/…/<sha1>.asset/AssetData/Restore/<n>.dmg` | 7.7 GiB each (V) | `mobileassetd` only (SIP label `MobileAsset`) | Not in place. Readable by any user, so it can be *copied* out. (V) |
| Mounted runtime volume | `/private/var/run/com.apple.security.cryptexd/mnt/…` | 18.5 GB logical, **0 bytes of extra storage** — it is the DMG, decompressed on read (V) | n/a (sealed, read-only) | Mount point is chosen by the mounter. |
| Image registry | `/Library/Developer/CoreSimulator/Images/images.plist` | 2 KB (V) | `simdiskimaged` | No need. |
| Personalisation manifests | `/Library/Developer/CoreSimulator/Cryptex/Personalization/*.manifest` | 3 KB each (V) | `simdiskimaged` | No need. |
| Imported-image store | `/Library/Developer/CoreSimulator/Images/` and/or `…/Cryptex/Images/` | empty here (V) | `simdiskimaged` | Mount-over only (see §3). Which of the two Xcode 27 uses for imports is disputed (R). |
| dyld shared cache | inside the runtime image for iOS 27.2 (3.7 GB of the 18.5 GB) (V); otherwise `/Library/Developer/CoreSimulator/Caches/dyld/` (S) | 0 internal here (V) | `simdiskimaged` | Hard-coded (S). Older runtimes without a built-in cache would generate ~7 GB internally (R). |
| Device data | `~/Library/Developer/CoreSimulator/Devices` | 2.6 GB (V) | user | Separate problem; custom device sets on external volumes are reported blocked by TCC (R). Out of scope for now. |

### 2.3 Protection mechanisms

| Mechanism | Protects | Evidence |
|---|---|---|
| SIP (`rootless.conf` label `MobileAsset`, `restricted` flag, `com.apple.rootless` xattr) | `/System/Library/AssetsV2` — firmlinked to the Data volume, not on the sealed system volume | V |
| A mandatory access control policy on `/Library/Developer/CoreSimulator/**` | Writes fail with `EPERM` ("Operation not permitted") where plain POSIX permissions would give `EACCES`. The sibling `/Library/Developer/PrivateFrameworks` gives the ordinary `EACCES`. `simdiskimaged` holds `com.apple.private.security.storage.CoreSimulator.heritable`. | V for the errno difference and the entitlement; **H** that the entitlement is what gates it, and that root is also denied (R says root is denied unless the caller has Full Disk Access) |
| `simdiskimaged`'s sandbox profile (embedded in the binary) | `file-mount` allowed only under `/Library/Developer/CoreSimulator/{Images,Volumes,Cryptex/Images,Cryptex/Volumes}/`; read/write only under `/Library/Developer/CoreSimulator/`, `/private/tmp/`, `…/Library/Caches/com.apple.dt.Xcode/Downloads/` and a few others; read-only on the four `AssetsV2/…SimulatorRuntime/` directories | S |
| CoreSimulator's mount-point trust test | See §2.4 | S |
| TCC "Removable Volumes" | Files on external volumes. CoreSimulatorService may *prompt* for it; `simctl runtime add` checks it on the source path. | S; R that the prompt can fail for external device sets |

### 2.4 How a runtime becomes visible

There are three independent discovery routes. All three end in the same loader.

1. **Registered images** (`simdiskimaged`). On first use in a login session it
   reads `images.plist`, scans the four AssetsV2 runtime directories and its own
   image directories, mounts what it finds, and drops any registry entry whose
   resolved path lies outside its managed storage ("Ignoring image … because it
   points outside of our managed storage area"). (S; boot sequence V in logs,
   ~29 s from daemon start to both runtimes ready)
2. **Volumes** (`SimVolumeManager` in CoreSimulatorService). For each volume
   that appears, `-[SimDiskImageManager shouldLoadRuntimesAtDiskMountPoint:]`
   decides in this order: OS-build environment → accept; default
   `DisableRuntimeDiskImages` → reject; mount point under an *ignored*
   directory → reject; `allowUntrustedMountDirectories` → accept; mount point
   under a *trusted* directory → accept; otherwise reject. The lists come from
   `simdiskimaged`, not from user defaults. `allowUntrusted` is
   `os_variant_allows_internal_security_policies(…)`, i.e. false on customer
   macOS. Trusted directories are `/Library/Developer/CoreSimulator/Volumes` and
   the cryptexd mount directory. The comparison calls `realpath()` on both
   sides. On an accepted volume it loads
   `<mount>/Library/Developer/CoreSimulator/Profiles/{Runtimes,DeviceTypes}`.
   (S — control flow re-checked independently; list contents inferred from
   partly decoded Swift and consistent with what is on disk. V: the log shows
   "adding profiles for volume path `/private/var/run/com.apple.security.cryptexd/mnt/…`"
   and shows `/Volumes/sparkle` appearing without being scanned.)
3. **Profile directories** (`SimProfilesPathMonitor`). Five directories are
   watched unconditionally, including
   `~/Library/Developer/CoreSimulator/Profiles`. For each entry in `Runtimes/`,
   `-[SimServiceContext _loadProfilesAtPath:…]` calls `realpath()` and then
   checks that the *resolved* path ends in `.simruntime`. A symlink to a bundle
   on another volume is therefore followed. No trust test was found on this
   route. (S — re-checked independently)

## 3. Why symlinks fail and mounts succeed

The explanation is layered; any one layer is enough to defeat a symlink.

1. **You cannot create the symlink.** Replacing
   `/Library/Developer/CoreSimulator/Images` with a link means renaming or
   removing a directory inside a MAC-protected tree (§2.3). (V for the
   protection; H that this is what produces the gist's reported "Operation not
   permitted")
2. **The daemon's sandbox is path-based and sees through links.** If the link
   existed, a mount or write under it would resolve to `/Volumes/<disk>/…`,
   outside the `file-mount` and `file-write*` allow-lists. The daemon would
   fail to create or use the mount point, which matches the reported
   `cannotSetupMountPoint` / `invalidParentDirectoryForMount` errors. (S for
   the profile; H for the causal link)
3. **Both trust checks canonicalise.** CoreSimulator's trusted-directory test
   and the daemon's managed-storage test both resolve symlinks before
   comparing, so a link cannot make an outside location count as inside. (S)

A mount is different in kind: it changes which filesystem backs a path without
changing the path. `/Library/Developer/CoreSimulator/Images/x.dmg` still
resolves to exactly that string, so path-based sandbox rules and `realpath()`
comparisons are satisfied. The MAC label on the covered directory presumably
does not extend to the root of the filesystem mounted over it. (H here; R on
Xcode 26.5/Intel that an external APFS volume mounted at `Images` served
runtimes and booted a device)

Note that an older report of explicit "Rejecting mount of symlink" strings in
`simdiskimaged` (Xcode 26.5, R) does not match this version: 1174.21 contains
no such string. (V)

## 4. Evaluation of the existing workaround

Source: <https://gist.github.com/niteshpurohit/8453bade166b8a83470ae516c3673a77>
(created 2026-05-19, one revision, no comments, no stated versions, **no
licence**).

### What is sound

- Mounting over the expected path rather than symlinking is the right
  primitive, for the reasons in §3.
- Re-mounting from a root LaunchDaemon is a reasonable way to survive reboots.

### What is version-dependent

- It assumes the Xcode 14–15 layout: image files in `Images/`, mounts in
  `Volumes/`. Since Xcode 16 downloads go to AssetsV2, and on this system
  nothing but the registry lives in `Images/`. Installed as written here, it
  would save **0 bytes** while adding failure modes. (V)
- It ignores `/Library/Developer/CoreSimulator/Cryptex/`, which newer versions
  use for cryptex images, personalisation manifests and relocated images. (V
  that the tree exists; R that imports land there on Xcode 27)

### What is fragile or wrong

| # | Issue | Consequence |
|---|---|---|
| 1 | Mounting over `Images/` also swaps `images.plist`, the daemon's registry. | The daemon's view of the world flips between two unrelated registries depending on whether the disk is present. A drive attached after the daemon has started leaves it serving stale state (R: observed as a silent "shadow" on Xcode 26.5). |
| 2 | The second sparsebundle (30 GB, over `Volumes/`) stores nothing. | Mount points consume no space; the mounted runtime is the DMG. It only adds a second point of failure. (V for the space claim) |
| 3 | `sudo killall -9` on CoreSimulatorService and `simdiskimaged`, and `hdiutil detach -force`, with no check for booted simulators. | Forced teardown under running simulators; risk of the daemon coming back mid-reconfiguration. |
| 4 | Existing `Images`/`Volumes` directories are renamed to `.backup.<timestamp>`. | Either fails with `EPERM` on a protected tree, or succeeds and strands every registered runtime. No restore step reverses it. |
| 5 | The volume is identified by the name `/Volumes/BK`. | Any disk with that name matches; a name collision mounts as `BK 1` and silently disables everything. |
| 6 | 30-second polling as root; logs written to predictable paths in world-writable `/tmp`. | Wasteful, and a root process writing to attacker-predictable `/tmp` paths is a privilege-escalation smell. |
| 7 | No ordering with respect to the daemon's first scan, and no rescan trigger (the daemon throttles rescans to one per 600 s by default). | Race at login: whichever happens first wins. |
| 8 | Imports are staged through `/private/tmp` on the internal disk before reaching the store. | A transient full-size internal copy per import; cross-volume, so never an APFS clone. (S) |
| 9 | A sparsebundle is a directory of 8 MB band files on a second filesystem layer. | An interrupted write or a failing SSD corrupts the inner APFS container; there is no integrity check. |
| 10 | Uninstall detaches and recreates empty directories. | Runtimes remain inside the sparsebundle, unregistered; the original state is not restored. |
| 11 | No licence. | Under GitHub's terms the default is all rights reserved: forking on GitHub is permitted, redistribution of a derivative elsewhere is not. This project should reimplement independently and cite the gist as prior art, not derive from its text. |

### Failure modes it does not address

Drive absent at boot; drive attached after login; drive removed while a
simulator is booted; Xcode or macOS update changing the layout; Xcode
re-downloading a runtime it believes is missing; TCC denying a background job
access to the external volume; the storage tree being MAC-protected against the
`sudo mkdir`/`chown` calls the installer makes.

## 5. Candidate approaches

| | A. Mount over the image store | B. Attach under the trusted volumes directory | C. Attach anywhere + symlinked bundle |
|---|---|---|---|
| Mechanism | External APFS volume or sparsebundle mounted at `…/CoreSimulator/Images` (and probably `…/Cryptex/Images`); runtimes added with `simctl runtime add`. | Runtime DMG kept on the SSD, attached read-only at `/Library/Developer/CoreSimulator/Volumes/<name>`. `SimVolumeManager` loads it. | Runtime DMG kept on the SSD, attached read-only at any path; a symlink in `~/Library/Developer/CoreSimulator/Profiles/Runtimes/` points at the inner `.simruntime`. |
| Root required | Yes, at every mount | Yes, at every mount; must also create a mount point inside the protected tree | **No** |
| Touches system-owned state | Yes: hides the daemon's registry | Shares a directory the daemon uses for its own fallback mounts | **No** — only the user's own Library |
| `simdiskimaged` involvement | Central | None intended; its reaction to foreign mounts there is unknown | None |
| Steady-state internal bytes | 0 if imports land in the mounted store | 0 | 0 |
| Transient internal bytes per runtime | Download (8.3 GB) + staging copy (8.3 GB) | Download only | Download only |
| Appears in `simctl runtime list` / Xcode "installed" | Yes | Probably not as a disk image; **unknown** to Xcode's Components UI | Listed by `simctl list runtimes`; **unknown** to Xcode's Components UI |
| Drive absent | Underlying internal directory reappears with a different registry | Mount point empty; runtime simply absent (H) | Dangling symlink; runtime simply absent (H) |
| Reliance on undocumented behaviour | Mount-over of a protected directory; registry swap | Trusted-directory rule | Per-user profile directory and symlink following — long-standing, but undocumented |
| Main unknowns | Cryptex mounting from an external store; registry divergence | Whether root can create the mount point; whether the daemon ejects foreign mounts | Whether TCC lets CoreSimulator and simulator processes read through the mount; whether Xcode treats the platform as installed |

Rejected without testing:

- **D. Redirect the MobileAsset store.** SIP-protected against root, path
  hard-coded in two daemons, and reported to break downloads. Would require
  weakening SIP, which is outside the project's boundaries.
- **E. In-place registration through the daemon's private "mount in place"
  strategy.** Reachable only by a root client speaking private XPC, and the
  daemon discards registrations outside managed storage on rescan. (S)
- **F. Copy the unpacked bundle to the SSD instead of keeping the DMG.** 19 GB
  instead of 8.3 GB, discards the sealed read-only volume, and exposes the
  runtime to bit-rot on a drive already described as unhealthy.
- **G. Disable disk-image runtimes** (`DisableRuntimeDiskImages`). Hides every
  normally installed runtime; a test instrument at most, not a solution.

### Recommended order of investigation

1. **C first.** It needs no privileges, changes nothing the system owns, and is
   reversed by deleting one symlink and detaching one image. If it works it is
   also the easiest design for other developers to audit.
2. **B second**, if C fails on trust or TCC grounds, or if Xcode will not
   recognise a bundle-registered runtime as installed.
3. **A last.** It is the only approach that keeps `simctl runtime add/delete`
   semantics, but it carries the most state-divergence risk and the gist's
   record gives no evidence about Xcode 27.

For B and C the common pipeline is: acquire through Xcode as normal → copy the
DMG from AssetsV2 to the SSD and verify it → delete the internal registration
(which purges the asset) → attach from the SSD.

## 6. Risks that apply to every approach

- **Xcode may consider an offloaded platform "not installed"** and offer, or
  start, a fresh download into AssetsV2. No background auto-update mechanism
  for runtimes was found (S), but an on-demand prompt is likely. A tool must
  detect a duplicate internal copy and report it rather than assume savings.
- **Deleted runtimes can reappear.** A defect where runtimes re-register from
  leftover MobileAsset content is listed as fixed in Xcode 27.2 (R). Savings
  must be measured after a reboot, not after the delete.
- **Updates change the layout.** The storage design changed in Xcode 14, 16, 26
  and 27. A tool must fingerprint the CoreSimulator version and refuse to act on
  versions it has not been validated against.
- **The SSD.** USB (10 Gb/s, Realtek RTL9210 bridge), SMART not exposed through
  the bridge to macOS's built-in tooling, ownership disabled on the volume. A
  read-only compressed image with a known checksum is the most defensible thing
  to keep on it: corruption is detectable and the image is re-downloadable.
- **Disconnection under load.** A simulator whose root filesystem vanishes will
  fail in undefined ways. Untested; requires explicit approval to test.

## 7. Open questions

1. Does a runtime attached as a plain disk image from the SSD boot a device?
2. Does CoreSimulator pick up a symlinked bundle without a service restart, and
   does it drop it cleanly when the target disappears?
3. Do TCC "Removable Volumes" rules apply to a disk image whose backing file is
   on a removable volume? (R suggests the image volume is treated as
   non-removable.)
4. Does Xcode's run-destination list, and its Components pane, accept a
   bundle-registered runtime as satisfying the iOS platform?
5. Does `simctl runtime delete` of the MobileAsset registration stay deleted
   across a reboot on 27.2?
6. Can root create a mount point under `/Library/Developer/CoreSimulator/Volumes`?
7. Does `simdiskimaged` interfere with attachments it did not create?
8. How does each approach behave when the SSD mounts late, or not at all?

Questions 1–4 are addressed by batch 2 of
[experiment-plan.md](experiment-plan.md); question 5 and 8 need the reboot
batch; 6 and 7 matter only if approach B is pursued.

### Update after experiment batches 0–2

Questions 1 and 2 are answered yes, and question 3 provisionally no (no TCC
denial in one run), by direct test: see
[results/2026-11-10/batches-0-2.md](results/2026-11-10/batches-0-2.md). Question
4 is answered for `xcodebuild` but not for Xcode's interface. Three new
problems take their place: a stale registration in the running service after a
delete, a per-user helper that keeps the runtime volume busy after unload, and
an unexplained slow first boot. Conclusion 6 in §1 should now read: the
mechanism works; its reliability is still unproven.

## 8. Tooling note

The REA disassembler provider (Hopper) could not be used: macOS denied REA
permission to send Apple Events to Hopper. Static analysis was done with
`otool`, `objdump`, `nm`, `strings` and `lldb` in static mode instead. Granting
the permission (System Settings ▸ Privacy & Security ▸ Automation) would make
the remaining Swift-heavy questions about `simdiskimaged` (items 6–7 above)
cheaper to answer by reading rather than by experiment.
