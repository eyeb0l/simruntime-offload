# Results: attach stack and eject (2026-11-10, session 3)

Follow-up to [batches-0-2.md](batches-0-2.md). Approved scope: restart the
`SimLaunchHost` helper and eject normally; then re-attach with
`diskutil image attach` and repeat the boot timings. No `sudo`, no forced
unmount.

## 1. The slow boot was the attach method, not the SSD

Hypothesis under test: the 219 s first boot was caused by an old SSD in a USB
enclosure. **Refuted.** The cause was `hdiutil attach`.

### Uncached reads (`experiments/bench/readbench.py`, `F_NOCACHE`)

Same file each time: the 1.7 GB `dyld_sim_shared_cache_arm64.01` of build
24B114, read through each path. Single reader.

| Path | Sequential | Random 64 KiB, median | p95 |
|---|---|---|---|
| SSD, raw image file (no disk-image layer) | 671 MB/s | 0.42 ms | 0.81 ms |
| Internal disk, raw image file | 2,004 MB/s | 0.13 ms | 0.15 ms |
| Internal, cryptex mount (how installed runtimes are served) | 660 MB/s | 1.10 ms | 1.66 ms |
| SSD, `diskutil image attach` | 1,074–1,092 MB/s | 0.33–0.34 ms | 0.89–1.02 ms |
| SSD, `hdiutil attach` | 892 MB/s | 0.47 ms | 1.55 ms |

Through a mounted image the figures are of decompressed data, so they can
exceed the raw device rate. With one reader the two stacks differ by about 20%.

### Concurrent small reads (`experiments/bench/parbench.py`)

Random 16 KiB reads spread across 4,001 files under `PrivateFrameworks`, which
is closer to what a booting simulator does.

| Path | 1 thread | 32 threads |
|---|---|---|
| Internal, cryptex mount | 663 reads/s | 2,483 reads/s |
| SSD, `diskutil image attach` | 997 reads/s | **6,704 reads/s** |
| SSD, `hdiutil attach` | 791 reads/s | **881 reads/s** |

`hdiutil attach` uses the legacy DiskImages stack, which services reads through
a single user-space process (`diskimages-helper`) and does not scale with
concurrency. `diskutil image attach` uses the kernel-backed DiskImages2 stack.
macOS 27 already prints a deprecation warning for `hdiutil attach`/`detach`.

Caveat: `F_NOCACHE` applies to the file being read, not to the image's backing
file, so some backing blocks may have been cached. The legacy runs came after
the DiskImages2 runs and so had, if anything, the warmer cache.

### Boot and launch, end to end

| Measure | Internal baseline (24B8117) | SSD, `hdiutil` | SSD, `diskutil image attach` |
|---|---|---|---|
| First boot of a new device | 39 s | 219 s, 224 s | **41 s** |
| …of which data migration | 31 s | 147 s | 34 s |
| Install + first launch of the fixture | a few seconds | 164 s | 16 s |
| Later boot of the same device | — | 36 s | 8 s |
| Device panel `agent-device open` | worked | timed out twice (90 s) | worked, 16 s |

The legacy result was reproduced on a second new device with the machine
quieter, so it was not a one-off or a load artefact.

Two other candidates were eliminated on the way:
- *The prebuilt dyld shared cache was not being used.* Through a user mount the
  runtime's files appear owned by the user rather than root (`noowners`), which
  could plausibly make the loader reject the cache. It does not: a running app
  had both cache files mapped and only eight individual libraries.
- *A one-off first-use cost.* A second new device was just as slow.

**Consequence:** the harness now uses `diskutil image attach` and
`diskutil eject`. With that change, a simulator on the SSD-hosted runtime
performed on a par with one on an internally stored runtime in these tests.

## 2. Ejecting a runtime volume that has been used

| Situation | Normal eject |
|---|---|
| Image attached and only read (benchmarks), either stack | Succeeds instantly (4 of 4) |
| Simulators have booted from it; all shut down; runtime unregistered | Fails: `SimLaunchHost.arm64` has `liblaunch_sim.dylib` mapped |
| …and `SimLaunchHost` restarted (no user-visible holder remains) | **Still fails** |
| …retried every 30 s for 7 minutes, no CoreSimulator activity | Still fails (14 of 14) |

- Restarting the helper is safe in itself: CoreSimulatorService logged one
  "Lost connection … (interrupted)", reconnected on the next request, and both
  existing runtimes stayed `Ready`. `simdiskimaged` was not affected.
- CoreSimulator is not the objector: it logs "Approving unmount" each time.
  Spotlight is disabled on the volume. No process owned by the user has a file
  open on it.
- So the remaining hold belongs to a root process or to the kernel. It cannot
  be identified without privileges. It is not the kernel's 120-second
  shared-region grace period (`vm.shared_region_destroy_delay`), since it
  outlasted that several times over.
- The same behaviour occurs with both attach stacks, so it is a property of
  having executed a runtime from the volume, not of how it was attached.
- Apple's daemon appears to live with the same thing: `simdiskimaged` carries
  an "Unmounting …, attempt=…, force=…" retry path (S), and the system log shows
  it forcing a cryptex unmount before a purge (R, from the session-1 log
  reconstruction).

**Consequence:** on this OS there is probably no clean, unforced way to release
a runtime volume once it has been used, short of logging out. A tool's "eject"
would therefore be: refuse if any simulator is booted → unregister → wait for
CoreSimulator to unload → restart `SimLaunchHost` → forced unmount. The forced
step has not been tested and needs approval.

## 3. Recovery and re-registration

With the volume still mounted, re-creating the symlink re-registered iOS 27.0
within three seconds, without restarting the service. The existing device went
from "unavailable" back to bootable, booted in 8 s and launched the app.
`xcodebuild -showdestinations` lists it as an available iOS 27.0 simulator
destination. ([screenshot](hellosim-on-ssd-runtime-di2.png))

The stale-registration problem (P1 in batches 0–2) did not recur here, because
no registration of the same build by another route was involved.

*The holder was later identified and the forced path tested: see
[eject-and-xcode.md](eject-and-xcode.md). The state table below is superseded
by the one there.*

## State left on the machine

| Item | State |
|---|---|
| Existing runtimes 24B114, 24B8117 | Unchanged, `Ready`. Runtime store size unchanged at 16,236,996 KiB. |
| iOS 27.0 from the SSD | **Registered and working**, served from `…/mnt/24A434-di2` (DiskImages2). |
| `…/mnt/24A434` | A second, idle mount of the same image via the legacy stack. Unregistered; cannot be ejected without force. |
| SSD | `SimRuntimes/24A434` (image), `SimRuntimes/24A434-di2` (APFS clone, no extra space), `SimRuntimes/24B114` (copy of an installed build). |
| Devices | `sro-offload-3` on iOS 27.0, shut down. The two earlier throwaway devices were deleted. |
| Processes restarted | `SimLaunchHost` three times. Nothing else. |

Do not unplug the SSD while either image is mounted.
