# Restoring a runtime with the native tool

2026-11-10. macOS 27.2.1, Xcode 27.2, CoreSimulator 1174.21. Tool at build
step 6 (release build). Evidence labels as in the technical assessment.

The subject was the disposable iOS 27.1 runtime (24A94425, 7,874,743,137
bytes) offloaded earlier the same day. The two runtimes the project owner uses
were served from the volume throughout and were not touched.

## The cycle

| Step | Command | Time | Result |
|---|---|---|---|
| 1 | `restore 24A94425` | 40 s | Registered as "Disk Image", Ready, at `/Library/Developer/CoreSimulator/Images/<uuid>.dmg`; mounted by CoreSimulator; offload mount and link gone; manifest entry gone; both inboxes empty; image on the volume kept. No service restart was needed. |
| 2 | Boot a new device from it | 35 s | Booted; Settings launched; 1,480 files open under the internal mount. |
| 3 | `offload 24A94425` | 22 s | Found the image already on the volume under its original name, compared checksums, reused it without copying; internal copy gone at the first check; served from the volume again. |
| 4 | `restore 24A94425 --delete-image` | 41 s | As step 1, then the image, its `SHA256SUMS` and the then-empty build directory were removed from the volume. The other two build directories were not touched and their images still match their checksums. |

All four exited 0. (V, one run each; steps 1 and 4 are the same path twice.)

Afterwards the runtime was deleted with `simctl runtime delete` and
`scan-and-mount`, and the test devices removed, leaving the machine as it was
before the runtime was downloaded: two runtimes served from the volume, none
on the internal disk.

## What the run showed

**The lock is needed in practice.** The agent's log has "another sync is
running; leaving it to finish" twice during each restore, and once during the
second offload. CoreSimulator mounting
the imported image is a mount event, so launchd starts the agent in the middle
of the restore. The staged mark would also have stopped it attaching the
build; either protection alone would have been enough here. (V)

**A re-imported image has a new file name.** The download was
`043-77717-424.dmg`; the import is `<uuid>.dmg`. As first written, `offload`
derived the destination from the source's name, so step 3 would have copied a
second 7.9 GB file beside the first and left the first orphaned. Found by
reading the plan before running it; `offload` now aims at the one image
already in the build's directory, reuses it if the checksums agree, and stops
if they do not.

**"Data Migration Failed" belongs to the runtime, not to offloading.** The
device in step 2, on the internal copy, printed the same message from
`simctl bootstatus` that the device on the volume's copy had printed, and
booted in 35 s against 38 s. Hypothesis H50 is refuted. Incidentally this is a
third first-boot comparison between internal and external, and again there is
no meaningful difference. (V)

**Deleting an imported image reclaimed its space at the first attempt**, in
step 3 and in the final clean-up, with `scan-and-mount` run each time as the
tool always does. The inbox-clone hazard did not show itself; whether that is
because the scan in step 1 had already cleared the clone is the likely reading
but was not isolated. (V for the outcome, H for the reason)

## `uninstall`

Run on the real machine as a dry run only, in both forms. It listed the three
restores it would perform, or the three runtimes it would stop serving, and
changed nothing (checked: manifest, mounts, links, agent all as before).

A real run was not made. It would restore the project owner's two runtimes to
the internal disk and remove her agent, which is hers to decide. Its logic is
covered by unit tests that run against real files in a scratch home directory
with only CoreSimulator, the attach commands and launchd faked.

## Not tested

- A real `uninstall`, in either form.
- An interrupted restore on the real machine (the resume path is unit-tested).
- `restore` with the image damaged, with the volume absent, or with too little
  internal space (each unit-tested; none provoked for real).
- Xcode's Components pane after a native `restore`. It was checked after the
  harness's restore, which uses the same `simctl runtime add`.
