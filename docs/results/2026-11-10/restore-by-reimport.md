# Results: restoring a runtime by re-import (2026-11-10, session 10)

Design validation 1: can `xcrun simctl runtime add` put an offloaded runtime
back on the internal disk from its image on the external volume?

## Procedure and results

For each runtime: remove it from the manifest, detach it (so the build is never
registered twice), then `xcrun simctl runtime add <image on the SSD>`.

| | iOS 27.0 (24A434), trial | iOS 27.2 (24B8117) |
|---|---|---|
| Time for the add | 35 s | 40 s |
| Registered as | "Disk Image", signature Verified, Ready | same |
| Stored at | `/Library/Developer/CoreSimulator/Images/<uuid>.dmg` | same |
| Mounted at | `/Library/Developer/CoreSimulator/Volumes/iOS_<build>` (plain disk-image mount, not cryptex) | same |
| Internal space used | 7.4 GiB | 7.8 GiB |
| SDK matching | — | still the chosen runtime for `iphoneos27.2` |
| Device boot | 9 s; app launched | not booted (the owner's device) |
| Image on the SSD | untouched | untouched |

So restore by re-import works, offline, in well under a minute, and costs one
image of internal space. A re-imported runtime is a plain "Disk Image"
registration, which is not identical to the MobileAsset cryptex registration it
had originally.

## A hazard found: the import leaves a clone in an inbox

Each add left a second file, a clone of the image, at
`/Library/Developer/CoreSimulator/Cryptex/Images/Inbox/<uuid>.dmg`. While the
registered image exists the clone costs nothing. But after
`simctl runtime delete` of the imported runtime, the clone alone kept all
7.5 GiB allocated: the store reported no images and the space was not
returned. It sits in the MAC-protected tree, where nothing but the daemon can
remove it.

`xcrun simctl runtime scan-and-mount` made the daemon clean its inbox within
three seconds, and the space came back (Data volume 134.01 → 126.50 GiB). It
did not disturb the runtimes served from the SSD.

Consequence for the tool: after every add and every delete, run
`scan-and-mount`, then verify by measurement. This joins hazard 2 in the
assessment (a delete that does not reclaim its asset); both have the same
remedy.

## Xcode's view of a re-imported runtime

Observed by the project owner: with 24B8117 re-imported, Settings ▸ Components
shows **iOS 27.2 as installed platform support** (8.32 GB, with the "Update"
button it had before any of this work), not "Get". Re-import is therefore a
complete restore as far as Xcode is concerned.

## Returning to the offloaded state

Afterwards the internal import was deleted, `scan-and-mount` run, and the
runtime served from the SSD again: Data volume 134.53 → 126.79 GiB, the
internal stores empty, `iphoneos27.2` still matched to 24B8117. This also shows
the offload path works for a "Disk Image" registration, not only for a
MobileAsset one.
