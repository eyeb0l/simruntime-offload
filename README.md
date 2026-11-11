<img src="assets/icon.svg" width="64" height="64" alt="">

# simruntime-offload

Keeps Xcode Simulator runtimes on an external volume and serves them from
there, so that they take no space on the internal disk. An iOS runtime is
about 8 GB; a Mac with a 256 GB disk and three of them installed notices.

```
$ simruntime-offload offload 24B8117 --volume <UUID>
$ simruntime-offload list
On the internal disk
  (none)

Served from an external volume
  24A434   iOS 27.0  active  on "External"
  24B8117  iOS 27.2  active  on "External"
```

## Read this first

This is version 0.1.2 of a tool that depends on behaviour Apple does not
document. It was developed and tested on **one Mac**. Know what that means
before trusting it.

**Where it works**

- Validated on exactly one combination: **macOS 27.2, Xcode 27.2,
  CoreSimulator 1174, Apple silicon**. `setup` and `offload` refuse to run on
  anything else unless you pass `--allow-unvalidated-version`.
- How Xcode stores runtimes changed in Xcode 14, 16, 26 and 27. An update can
  break this without warning. What an Xcode or macOS update does to a machine
  set up this way **has not been tested**.
- Not tested: use over more than a day; any platform but iOS; more than one
  volume; a second user account; Intel Macs; encrypted or network volumes;
  unplugging the disk during a build, a debug session or an offload.

**What you give up**

- **Xcode does not know.** Settings ▸ Components shows "Get" for an offloaded
  platform, and the "Any iOS Simulator Device" destination carries a "Get"
  badge. Your simulators are listed, build, run and debug normally. Do not
  click "Get": it downloads the runtime to the internal disk again.
- **No disk, no simulators.** With the volume unplugged, simulators on
  offloaded runtimes are unavailable until it is back. Nothing breaks; they
  return within seconds of reconnecting.
- **A new runtime still lands on the internal disk first.** Xcode can only
  download there. Offloading moves it afterwards, so you need the space
  briefly.
- **Eject before unplugging**, with `simruntime-offload eject`. The runtime
  images on the disk are mounted, and they have to be released before the disk
  can go. Pulling the cable with a simulator running kills that simulator at
  once. In the one test of this, nothing else was harmed and everything
  recovered on reconnection.
- **Up to about a minute after a restart** passes before offloaded runtimes
  appear, while macOS is still starting everything else.
- **Each simulator's own data stays internal**, in your Library. Only the
  runtimes move.

**What it asks of your Mac**

- One directory created with `sudo`, once: `/Library/Developer/DeviceKit/Runtimes`,
  owned by you. Without it everything works except that Xcode's device list
  labels the simulators "unavailable". On a Mac with several accounts, it lets
  your account register runtimes that other accounts' simulators would load.
- A login agent, running as you, that attaches the runtimes at login and when
  the volume mounts. macOS will ask once whether it may access a removable
  volume. Releases are signed with a Developer ID, so upgrading from one to
  the next should not ask again (not yet tested). A build from source is not,
  and macOS may ask again after each rebuild.
- Nothing else. No SIP changes, no daemon, no helper running as root, no
  kernel or system extension, nothing written to any directory Apple protects.

`restore` imports a verified image back to the internal disk offline, provided
its volume is connected and the internal disk has enough space. `uninstall`
restores all runtimes before removing the agent and state. It retains one empty
coordination file, `~/Library/Application Support/simruntime-offload.lock`, so
concurrent commands cannot acquire different locks during cleanup.

## How it works

Xcode keeps a downloaded runtime as a disk image in a protected system
directory that cannot be relocated. But CoreSimulator also loads any runtime it
finds in a few *profile directories*, and it follows symbolic links there.

So the tool copies the runtime's image to your volume, verifies the copy,
deletes the original through CoreSimulator's own command, attaches the image
read-only at a private mount point, and puts one symbolic link to the runtime
inside it in a profile directory. CoreSimulator then lists the runtime as if it
were installed.

[The technical assessment](docs/technical-assessment.md) has the detail: where
runtimes live, what was tried and failed, the ten hazards a tool has to handle,
and the measurements. A simulator boots from the external copy as fast as from
an internal one (first boot 38–41 s against 35–39 s on the test machine).

## Install

Requires Xcode 27.2 and its command-line tools. There are no other
dependencies.

From a release, for Apple silicon: download the `.zip` and its `.sha256` from
the repository's Releases. The program is signed with a Developer ID and
notarised by Apple.

```
shasum -a 256 -c simruntime-offload-<version>-macos-arm64.zip.sha256
unzip simruntime-offload-<version>-macos-arm64.zip
sudo cp simruntime-offload-<version>-macos-arm64/simruntime-offload /usr/local/bin/
```

From source:

```
git clone <this repository>
cd simruntime-offload
swift build -c release
sudo cp .build/release/simruntime-offload /usr/local/bin/
```

`setup` keeps its own copy of the program for the login agent, so where you
put this one does not matter. **After upgrading, run `setup` again** to update
that copy and its job definition. Do not run old and new tool versions together.
The current source writes manifest format 2; it reads format 1, but older
releases cannot read format 2.

## Use

```
simruntime-offload doctor
```

Checks versions, System Integrity Protection, the attach command, the link
directory and the agent. It changes nothing. Start here.

```
simruntime-offload setup
```

Tells you the two `sudo` commands that create the shared link directory (it
never runs `sudo` itself), and installs the login agent. Run it again after
creating the directory.

```
simruntime-offload list
diskutil info /Volumes/<name> | grep "Volume UUID"
simruntime-offload offload <build> --volume <UUID> --dry-run
simruntime-offload offload <build> --volume <UUID>
```

`<build>` is the build number `list` shows, such as `24B8117`. The volume is
named by UUID because names are not unique and device nodes change. After the
first offload, `--volume` can be omitted while only one volume is in use.

Shut down every simulator first; `offload` also refuses booting or
shutting-down devices. Keep them shut down throughout the operation: state is
rechecked after verification and before destructive steps, but another app can
start a simulator independently of this tool's lock. It copies the
image, compares the SHA-256 of both copies, runs the disk image's own
verification, and only then removes the internal one, checking that the space
really was released. About a minute per runtime on a fast SSD.

```
simruntime-offload eject
```

Before unplugging. Releases every runtime and ejects the disk. If something
still holds a runtime it stops and says so rather than forcing;
`--force-unmount` exists for when you have decided to. If nothing remains
offloaded, the command reports a no-op; eject any connected disk in Finder
before unplugging it. Plugging the disk back in needs nothing: the agent
re-attaches everything.

```
simruntime-offload restore <build>
simruntime-offload restore <build> --delete-image
```

Imports the runtime back to the internal disk and stops serving it from the
volume. The image stays on the volume unless you ask for it to be deleted, and
offloading the same runtime again reuses it instead of copying.

```
simruntime-offload uninstall
simruntime-offload uninstall --leave-runtimes-on-volume
```

Restores every runtime, then removes the agent and everything the tool wrote.
It never deletes an image from the volume. The second form skips the restore,
which leaves those runtimes installed nowhere until you re-import an image with
`xcrun simctl runtime add`; it works with the volume unplugged.

Every command that changes anything accepts `--dry-run`, including `sync`.
A dry run does not create a lock, mount directory, link or log.

## What it will not do

- Delete an internal runtime before its copy has passed both checks.
- Report space as freed without looking.
- Unmount, eject or restart a service without first checking all simulators are shut down.
- Force an unmount unless you passed `--force-unmount`.
- Act on a volume chosen by name.
- Delete an image from your volume unless you passed `--delete-image`.
- Ask for your password.

## When something is wrong

- `simruntime-offload doctor` and `simruntime-offload list` describe the state
  of the machine and what to run next.
- `eject` reports success only after ejection or a successful disk listing
  confirms the volume is absent. A lookup failure, unknown identity or unknown
  physical disk stops the command without saying it is safe to unplug.
- The agent's log is `~/Library/Logs/simruntime-offload/agent.log`, capped at
  1 MiB with one previous log, `agent.log.1`. Besides login and mount events,
  the agent retries once a minute so lock contention cannot lose a reconnect.
- System commands have deadlines: 60 seconds normally, 180 seconds for image
  attachment (including the consent prompt), 300 seconds for image tools and
  900 seconds for imports. A timed-out import remains staged until `restore`
  reconciles its registration; the agent does not attach a second copy.
- A runtime shown as "operation interrupted" needs recovery. For a new
  interrupted offload, rerun `offload <build>`: its journal, saved checksum and
  disk-image verification let it finish even after internal deletion. For an
  interrupted restore, or a staged entry from an older release without a
  journal, run `restore <build>`. `sync` gives the appropriate command.
- After installing or upgrading, the agent's first attach waits for you to
  answer macOS's prompt about access to a removable volume, and nothing is
  served until you do. While it waits, other commands report that another
  operation is still running. If the agent logs that an attach was not
  permitted, access was refused or withdrawn: System Settings ▸ Privacy &
  Security ▸ Files and Folders.
- After an Xcode or macOS update, `doctor` will say the version is not
  validated. Runtimes already offloaded keep being served, and `restore`,
  `eject` and `uninstall` keep working whatever the version.

## Testing

```
swift test
```

Unit tests, plus tests that create and attach a small synthetic disk image.
They need no runtime and no external disk, and change nothing outside a
temporary directory. Set `SRO_SKIP_INTEGRATION` to skip the ones that attach.
CI runs them all on every pull request, on GitHub's macOS 27 image with Xcode
27.2, and fails if any was skipped.

```
scripts/system-test.sh .build/release/simruntime-offload <build> <UUID>
```

Takes one runtime you can afford to lose through its whole life on a real
machine, checking the machine after every step. This, with
[the checklist](docs/system-test-checklist.md) of what needs a person, is how a
new macOS or Xcode version gets validated.

## Documents

- [Technical assessment](docs/technical-assessment.md): what is proven, how
  runtime storage works on this OS, the hazards, and what is untested.
- [Design](docs/design.md): the tool's design, and where the build departed
  from it.
- [Investigation log](docs/investigation-log.md): hypotheses, evidence,
  rejected approaches, decisions and mistakes, session by session.
- [`docs/results/`](docs/results): the write-up of each experiment.
- [Changelog](CHANGELOG.md).

## Layout

| Path | Purpose |
|---|---|
| `Sources/`, `Tests/` | The tool: a Swift package with no dependencies. |
| `scripts/system-test.sh` | The system test. |
| `scripts/collect-baseline.sh` | Read-only diagnostic collection, with personal identifiers redacted. |
| `fixtures/HelloSim/` | A minimal iOS app used to test build, install and launch. |
| `experiments/` | The shell harness and benchmarks the mechanism was found with. Not part of the tool. |

Licensed under the [MIT License](LICENSE).

Created in [T3 Code](https://t3.codes).
