import Foundation
import SimRuntimeOffloadCore

let toolVersion = "0.1.2"

let usage = """
    simruntime-offload — serve Xcode Simulator runtimes from an external volume

    Usage:
      simruntime-offload doctor [--json]    check whether the tool can work on this Mac; changes nothing
      simruntime-offload list               runtimes on the internal disk and on external volumes; changes nothing
      simruntime-offload setup [--dry-run]  check the link directory and install the login agent
      simruntime-offload offload <runtime> [--volume <UUID>] [--dry-run]
                                            copy a runtime to the volume, verify it, remove the internal
                                            copy and serve it from the volume
      simruntime-offload restore <runtime> [--delete-image] [--force-unmount] [--dry-run]
                                            import a runtime back to the internal disk from its image
                                            on the volume, and stop serving it from there
      simruntime-offload eject [--force-unmount] [--dry-run]
                                            release every offloaded runtime and the volume, to unplug it
      simruntime-offload uninstall [--leave-runtimes-on-volume] [--force-unmount] [--dry-run]
                                            restore every runtime, then remove the agent and all state
      simruntime-offload sync [--dry-run]   attach what is available, tidy what is not; what the agent runs
      simruntime-offload --version
      simruntime-offload help

    <runtime> is a build number, as shown by `list`.

    Every command that changes anything takes --dry-run, which prints what it
    would do and changes nothing.

    setup and offload refuse on a macOS, Xcode or CoreSimulator version this
    release was not validated on. --allow-unvalidated-version overrides that,
    at your own risk. The other commands never refuse on version.
    """

/// One of the two escape hatches. Accepted anywhere on the command line, and
/// honoured only by the commands that check versions: `doctor`, `setup` and
/// `offload`. The login agent never passes it.
let allowUnvalidatedVersion = CommandLine.arguments.contains("--allow-unvalidated-version")
let arguments = Array(CommandLine.arguments.dropFirst()).filter { $0 != "--allow-unvalidated-version" }

func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func runDoctor(arguments: [String]) -> Int32 {
    var asJSON = false
    for argument in arguments {
        switch argument {
        case "--json": asJSON = true
        default:
            printError("doctor: unknown option \(argument)")
            return 64
        }
    }

    let paths = Paths(home: NSHomeDirectory(), userID: getuid())
    let checks = Doctor(paths: paths, probe: SystemProbe(), allowUnvalidatedVersion: allowUnvalidatedVersion).run()

    if asJSON {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(checks) else {
            printError("doctor: could not encode the results")
            return 70
        }
        print(String(decoding: data, as: UTF8.self))
    } else {
        for check in checks {
            let label: String
            switch check.status {
            case .ok: label = "ok     "
            case .note: label = "note   "
            case .warning: label = "warning"
            case .failure: label = "FAILED "
            }
            print("\(label)  \(check.summary)")
            if let remedy = check.remedy {
                print("         \(remedy)")
            }
        }
        print("")
        print(Doctor.passed(checks)
            ? "simruntime-offload can work on this Mac."
            : "simruntime-offload will not act on this Mac until the failed checks are resolved.")
    }
    return Doctor.passed(checks) ? 0 : 1
}

/// Sizes as Xcode shows them: decimal gigabytes.
func formatSize(_ bytes: Int64?) -> String {
    guard let bytes else { return "" }
    return String(format: "%.2f GB", Double(bytes) / 1_000_000_000)
}

func describe(_ state: OffloadState) -> String {
    switch state {
    case .active: return "active"
    case .volumeAbsent: return "volume not connected"
    case .imageMissing: return "image missing from the volume"
    case .notAttached: return "not attached"
    case .notLinked: return "attached but not linked"
    case .notRegistered: return "linked but not registered with CoreSimulator"
    case .staged: return "operation interrupted; run sync for recovery guidance"
    }
}

func runList(arguments: [String]) -> Int32 {
    guard arguments.isEmpty else {
        printError("list: unknown option \(arguments[0])")
        return 64
    }
    let paths = Paths(home: NSHomeDirectory(), userID: getuid())
    let simulators = Simulators()
    let volumes = Volumes()
    let inventory: Inventory
    do {
        inventory = InventoryBuilder(paths: paths, volumeLookup: volumes.volume(uuid:)).build(
            manifest: try ManifestStore(paths: paths).load(),
            images: try simulators.images(), runtimes: try simulators.runtimes())
    } catch {
        printError("list: \(error)")
        return 1
    }

    print("On the internal disk")
    if inventory.internalImages.isEmpty {
        print("  (none)")
    }
    for image in inventory.internalImages {
        print("  \(image.build)  version \(image.version)  \(formatSize(image.sizeBytes))  \(image.kind), \(image.state)")
    }

    print("")
    print("Served from an external volume")
    if inventory.offloaded.isEmpty {
        print("  (none)")
    }
    for item in inventory.offloaded {
        let volume = item.volume.map { "\"\($0.name)\"" } ?? "volume \(item.runtime.volumeUUID)"
        print("  \(item.runtime.build)  \(item.displayName)  \(describe(item.state))  on \(volume)")
    }
    return 0
}

func timestamp() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: Date())
}

func describe(_ result: SyncOutcome.Result) -> String {
    switch result {
    case .wouldAttach: return "would attach and link"
    case .wouldLink: return "would link the attached image"
    case .wouldRemoveDanglingLink: return "would remove the dangling link"
    case .alreadyActive: return "already active"
    case .attached: return "attached and linked"
    case .linked: return "was attached; linked"
    case .removedDanglingLink: return "volume not connected; removed the dangling link"
    case .waitingForVolume: return "volume not connected; nothing to do"
    case .needsAttention(let reason): return "needs attention: \(reason)"
    case .failed(let reason): return "FAILED: \(reason)"
    }
}

/// What the login agent runs. Output goes to the agent's log, so every line
/// is timestamped.
func runSync(arguments: [String]) -> Int32 {
    var dryRun = false
    var agent = false
    for argument in arguments {
        switch argument {
        case "--dry-run": dryRun = true
        case "--agent": agent = true
        default:
            printError("sync: unknown option \(argument)")
            return 64
        }
    }
    let paths = Paths(home: NSHomeDirectory(), userID: getuid())
    func log(_ message: String, error: Bool = false) {
        let line = "[\(timestamp())] \(message)"
        if agent && !dryRun {
            do { try AgentLog(paths: paths).append(line) }
            catch { printError("\(line) (could not write agent log: \(error))") }
        } else if error {
            printError(line)
        } else {
            print(line)
        }
    }
    let outcomes: [SyncOutcome]
    do {
        let volumes = Volumes()
        outcomes = try Sync(paths: paths, volumeLookup: volumes.volume(uuid:))
            .run(dryRun: dryRun, registeredRuntimes: { try Simulators().runtimes() })
    } catch SyncError.alreadyRunning {
        // Expected: launchd starts the agent for the mounts a sync itself makes.
        log("another operation is running; leaving it to finish")
        return 0
    } catch {
        log("sync: \(error)", error: true)
        return 1
    }
    if outcomes.isEmpty { log("nothing is offloaded; nothing to sync") }
    if dryRun { log("Dry run: nothing was changed.") }
    var failed = false
    for outcome in outcomes {
        log("\(outcome.build): \(describe(outcome.result))")
        if case .failed = outcome.result { failed = true }
    }
    return failed ? 1 : 0
}

func runSetup(arguments: [String]) -> Int32 {
    var dryRun = false
    for argument in arguments {
        switch argument {
        case "--dry-run": dryRun = true
        default:
            printError("setup: unknown option \(argument)")
            return 64
        }
    }
    let paths = Paths(home: NSHomeDirectory(), userID: getuid())
    let action = dryRun ? "Would" : "Will"

    // 1. Never set up on a machine the tool has not been validated for.
    guard preflightPassed(for: "setup", paths: paths) else { return 1 }

    // 2. The link directory. Creating the shared one is the single privileged
    //    step, and it is left to the user to run, so that nothing here ever
    //    asks for a password.
    let registry = Registry(paths: paths)
    if registry.linkDirectory == paths.sharedLinkDirectory {
        print("Link directory: \(paths.sharedLinkDirectory)")
    } else {
        print("""
            Link directory: \(paths.perUserLinkDirectory)
              Runtimes linked here build and run, but Xcode's Device Hub labels their
              simulators "unavailable". To fix that, create the shared directory once
              and run setup again:
                sudo mkdir \(paths.sharedLinkDirectory)
                sudo chown \(NSUserName()) \(paths.sharedLinkDirectory)
              On a Mac with several accounts, note that this lets your account register
              runtimes that other accounts' simulators would also load.
            """)
    }

    // 3. The manifest. Nothing to create: it is written by the first offload.
    do {
        print("Manifest: \(try ManifestStore(paths: paths).load().runtimes.count) runtime(s).")
    } catch {
        printError("setup: \(error)")
        return 1
    }

    // 4. The login agent, running an installed copy of this program.
    guard let executable = Bundle.main.executablePath else {
        printError("setup: could not determine the path of this program")
        return 70
    }
    let agent = Agent(paths: paths)
    let identical = FileManager.default.contentsEqual(atPath: executable, andPath: paths.installedExecutable)
    print(identical
        ? "Agent program: \(paths.installedExecutable) is current."
        : "Agent program: \(action.lowercased()) install this build at \(paths.installedExecutable).")
    print("Agent: \(action.lowercased()) (re)load \(Paths.agentLabel); it runs `sync` at login, on volume mounts and once a minute.")
    if dryRun {
        print("")
        print("Dry run: nothing was changed.")
        return 0
    }
    do {
        let lock = try StateLock.acquire(paths: paths)
        defer { lock.release() }
        let copied = try agent.installExecutable(from: executable)
        try agent.install()
        if copied {
            print("""
                  The agent's program changed, so macOS may ask once more whether
                  simruntime-offload may access files on a removable volume. Allow it;
                  the agent cannot attach your runtimes otherwise.
                """)
        }
    } catch {
        printError("setup: \(error)")
        return 1
    }

    print("")
    print("Done. `simruntime-offload doctor` and `simruntime-offload list` show the result.")
    return 0
}

/// Runs the preflight checks and reports failures. Commands that change
/// anything call this first.
func preflightPassed(for command: String, paths: Paths) -> Bool {
    let checks = Doctor(paths: paths, probe: SystemProbe(), allowUnvalidatedVersion: allowUnvalidatedVersion).run()
    if Doctor.passed(checks) {
        // An override is never silent.
        for check in checks where check.id == "versions" && check.status == .warning {
            printError("\(command): warning: \(check.summary)")
        }
        return true
    }
    printError("\(command): this Mac does not pass the preflight checks:")
    for check in checks where check.status == .failure {
        printError("  \(check.summary)")
        if let remedy = check.remedy { printError("    \(remedy)") }
    }
    return false
}

func runOffload(arguments: [String]) -> Int32 {
    var runtime: String?
    var volumeUUID: String?
    var dryRun = false
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--dry-run": dryRun = true
        case "--volume":
            index += 1
            guard index < arguments.count else {
                printError("offload: --volume needs a volume UUID")
                return 64
            }
            volumeUUID = arguments[index]
        default:
            guard !argument.hasPrefix("-"), runtime == nil else {
                printError("offload: unexpected argument \(argument)")
                return 64
            }
            runtime = argument
        }
        index += 1
    }
    guard let runtime else {
        printError("offload: name the runtime to offload (a build number or identifier from `list`)")
        return 64
    }

    let paths = Paths(home: NSHomeDirectory(), userID: getuid())
    guard preflightPassed(for: "offload", paths: paths) else { return 1 }

    let simulators = Simulators()
    let volumes = Volumes()
    var lastDecile = -1
    let offloader = Offloader(
        paths: paths,
        simulators: simulators,
        volumeLookup: volumes.volume(uuid:),
        imageStore: ImageStore(),
        services: Services(userID: paths.userID),
        sync: { lock in
            try Sync(paths: paths, volumeLookup: volumes.volume(uuid:))
                .run(holding: lock, registeredRuntimes: { try simulators.runtimes() })
        },
        report: { event in
            switch event {
            case .copying(let source, let destination):
                print("Copying \(source)\n     to \(destination)")
            case .copyProgress(let done, let total):
                let decile = total > 0 ? Int(done * 10 / total) : 0
                if decile != lastDecile {
                    lastDecile = decile
                    print("  \(decile * 10)%")
                }
            case .reusingVerifiedCopy(let path):
                print("A copy is already at \(path); comparing it with the original.")
            case .verified(let sha256):
                print("Verified. SHA-256 \(sha256)")
            case .removingInternalCopy:
                print("Removing the internal copy.")
            case .retryingRemoval:
                print("macOS kept the internal copy; rescanning and removing it again.")
            case .reclaimed:
                print("The internal copy is gone.")
            case .restartingCoreSimulator:
                print("Restarting the CoreSimulator service so it forgets the old location.")
            case .attaching:
                print("Attaching the copy on the volume.")
            case .done(let name):
                print("Done. \(name) is now served from the external volume.")
            }
        })

    do {
        let plan = try offloader.plan(runtime: runtime, volumeUUID: volumeUUID)
        print("Runtime:  build \(plan.image.build), version \(plan.image.version), \(formatSize(plan.image.sizeBytes)), \(plan.image.kind)")
        print("Volume:   \"\(plan.volume.name)\" (\(plan.volume.uuid))")
        print("Copy to:  \(plan.destination)")
        if dryRun {
            print("")
            if plan.isResuming {
                print("Dry run: would verify the saved image, confirm the internal copy is gone,")
                print("restart the CoreSimulator service and attach the copy. Nothing was changed.")
            } else if FileManager.default.fileExists(atPath: plan.destination) {
                print("Dry run: a file is already there. It would be compared with the internal image and")
                print("used only if identical; then the internal copy would be removed, the CoreSimulator")
                print("service restarted and the copy attached. Nothing was changed.")
            } else {
                print("Dry run: would copy and verify the image, remove the internal copy, restart the")
                print("CoreSimulator service and attach the copy. Nothing was changed.")
            }
            return 0
        }
        print("")
        try offloader.run(plan)
        return 0
    } catch {
        printError("offload: \(error)")
        return 1
    }
}

func runEject(arguments: [String]) -> Int32 {
    var forceUnmount = false
    var dryRun = false
    for argument in arguments {
        switch argument {
        case "--force-unmount": forceUnmount = true
        case "--dry-run": dryRun = true
        default:
            printError("eject: unknown option \(argument)")
            return 64
        }
    }
    let paths = Paths(home: NSHomeDirectory(), userID: getuid())
    let simulators = Simulators()
    let volumes = Volumes()
    do {
        let manifest = try ManifestStore(paths: paths).load()
        if manifest.runtimes.isEmpty {
            print("Nothing is offloaded; nothing to eject.")
            return 0
        }
        if dryRun {
            let fileSystem = FileSystem()
            for runtime in manifest.runtimes {
                let mounted = fileSystem.isMountPoint(paths.mountPoint(forBuild: runtime.build))
                print("Would unregister \(runtime.build)\(mounted ? " and eject its image" : " (not attached)").")
            }
            for uuid in Set(manifest.runtimes.map(\.volumeUUID)) {
                if let volume = volumes.volume(uuid: uuid) {
                    print("Would eject the disk holding \"\(volume.name)\".")
                }
            }
            print("")
            print("Dry run: nothing was changed.")
            return 0
        }
        let outcome = try Ejector(
            paths: paths,
            simulators: simulators,
            attacher: Attacher(),
            services: Services(userID: paths.userID),
            volumeLookup: volumes.confirmedVolume(uuid:),
            ejectVolume: volumes.eject(uuid:),
            report: { event in
                switch event {
                case .unregistering(let build): print("Unregistering \(build).")
                case .ejected(let build, let attempts):
                    print("Ejected \(build)\(attempts > 1 ? " (attempt \(attempts))" : "").")
                case .forcing(let build): print("Forcing the unmount of \(build), as requested.")
                case .ejectedVolume(let name): print("Ejected the disk holding \"\(name)\".")
                }
            }
        ).run(forceUnmount: forceUnmount)
        print("")
        switch outcome {
        case .nothingToEject:
            print("Nothing is offloaded now; no disks were ejected. Eject the disk in Finder before unplugging it.")
        case .safeToUnplug:
            print("Safe to unplug. Plugging the disk back in re-attaches the runtimes.")
        }
        return 0
    } catch {
        printError("eject: \(error)")
        return 1
    }
}

/// The pieces `restore` and `uninstall` share.
func makeRestorer(paths: Paths, report: @escaping (RestoreEvent) -> Void) -> Restorer {
    let simulators = Simulators()
    let volumes = Volumes()
    return Restorer(
        paths: paths,
        simulators: simulators,
        volumeLookup: volumes.volume(uuid:),
        imageStore: ImageStore(),
        attacher: Attacher(),
        services: Services(userID: paths.userID),
        sync: { lock in
            try Sync(paths: paths, volumeLookup: volumes.volume(uuid:))
                .run(holding: lock, registeredRuntimes: { try simulators.runtimes() })
        },
        report: report)
}

func printRestoreEvent(_ event: RestoreEvent) {
    switch event {
    case .verifyingImage: print("Checking the image on the volume against its recorded checksum.")
    case .alreadyInternal: print("This build is already installed on the internal disk; only stopping the copy on the volume.")
    case .releasing: print("Unregistering the copy on the volume and ejecting its image.")
    case .importing(let image): print("Importing \(image) to the internal disk.")
    case .imported: print("CoreSimulator reports the import ready.")
    case .restartingCoreSimulator: print("Restarting the CoreSimulator service so it lists the runtime from its new location.")
    case .removedImage(let path): print("Deleted \(path).")
    case .keptImage(let path): print("The image stays at \(path).")
    case .done(let name): print("Done. \(name ?? "The runtime") is installed on the internal disk again.")
    }
}

func runRestore(arguments: [String]) -> Int32 {
    var runtime: String?
    var deleteImage = false
    var forceUnmount = false
    var dryRun = false
    for argument in arguments {
        switch argument {
        case "--delete-image": deleteImage = true
        case "--force-unmount": forceUnmount = true
        case "--dry-run": dryRun = true
        default:
            guard !argument.hasPrefix("-"), runtime == nil else {
                printError("restore: unexpected argument \(argument)")
                return 64
            }
            runtime = argument
        }
    }
    guard let runtime else {
        printError("restore: name the runtime to restore (a build number from `list`)")
        return 64
    }

    // Deliberately not gated on the preflight checks: the way back must work
    // even on a system version this tool no longer recognises.
    let paths = Paths(home: NSHomeDirectory(), userID: getuid())
    let restorer = makeRestorer(paths: paths, report: printRestoreEvent)
    do {
        let plan = try restorer.plan(runtime: runtime)
        print("Runtime:  build \(plan.entry.build)\(plan.entry.name.map { ", \($0)" } ?? ""), \(formatSize(plan.entry.sizeBytes))")
        print("Image:    \(plan.image) on \"\(plan.volume.name)\"")
        if dryRun {
            print("")
            if plan.alreadyInternal {
                print("Dry run: this build is already on the internal disk, so nothing would be imported;")
                print("the copy on the volume would stop being served.")
            } else {
                print("Dry run: would check the image, stop serving it from the volume, and import it to")
                print("the internal disk.")
            }
            print(deleteImage ? "The image on the volume would then be deleted." : "The image on the volume would be kept.")
            print("Nothing was changed.")
            return 0
        }
        print("")
        try restorer.run(plan, deleteImage: deleteImage, forceUnmount: forceUnmount)
        return 0
    } catch {
        printError("restore: \(error)")
        return 1
    }
}

func runUninstall(arguments: [String]) -> Int32 {
    var leaveRuntimes = false
    var forceUnmount = false
    var dryRun = false
    for argument in arguments {
        switch argument {
        case "--leave-runtimes-on-volume": leaveRuntimes = true
        case "--force-unmount": forceUnmount = true
        case "--dry-run": dryRun = true
        default:
            printError("uninstall: unknown option \(argument)")
            return 64
        }
    }

    let paths = Paths(home: NSHomeDirectory(), userID: getuid())
    let volumes = Volumes()
    let uninstaller = Uninstaller(
        paths: paths,
        simulators: Simulators(),
        restorer: makeRestorer(paths: paths, report: printRestoreEvent),
        attacher: Attacher(),
        services: Services(userID: paths.userID),
        agent: Agent(paths: paths),
        volumeLookup: volumes.volume(uuid:),
        report: { event in
            switch event {
            case .restoring(let build): print("\nRestoring \(build).")
            case .restoredButNotListed(let build):
                print("\(build) is imported; CoreSimulator will list it after your next login.")
            case .stoppedServing(let build): print("Stopped serving \(build).")
            case .removedAgent: print("\nRemoved the login agent.")
            }
        })
    do {
        let plan = try uninstaller.plan(leaveRuntimesOnVolume: leaveRuntimes)
        if dryRun {
            for restore in plan.restores {
                print(restore.alreadyInternal
                    ? "Would stop serving \(restore.entry.build) from the volume (it is already on the internal disk)."
                    : "Would restore \(restore.entry.build) (\(formatSize(restore.entry.sizeBytes))) to the internal disk from \(restore.image).")
            }
            for runtime in plan.released {
                print("Would stop serving \(runtime.build); its image would stay on the volume and the runtime would no longer be installed anywhere.")
            }
            print("Would remove the login agent and this tool's own files in \(paths.stateDirectory),")
            print("\(paths.logDirectory) and \(paths.mountRoot). Anything else found there would be left and named.")
            print("No image on a volume would be deleted.")
            print("")
            print("Dry run: nothing was changed.")
            return 0
        }
        let summary = try uninstaller.run(plan, forceUnmount: forceUnmount)
        print("")
        for path in summary.removed { print("Removed \(path)") }
        for item in summary.left { print("Left in place: \(item)") }
        if !summary.imagesKept.isEmpty {
            print("")
            print("These images are still on the volume and are yours to keep or delete:")
            for image in summary.imagesKept { print("  \(image)") }
            if plan.leaveRuntimesOnVolume {
                print("To install one again: xcrun simctl runtime add <image>")
            }
        }
        if let directory = summary.sharedLinkDirectory {
            print("")
            print("One directory was created with sudo during setup and needs sudo to remove:")
            print("  sudo rmdir \(directory)")
        }
        print("")
        print("simruntime-offload is uninstalled.")
        return 0
    } catch let error as RestoreError {
        printError("uninstall: \(error)")
        if case .volumeNotConnected = error {
            printError("Connect the volume, or use --leave-runtimes-on-volume to uninstall without restoring.")
        }
        return 1
    } catch {
        printError("uninstall: \(error)")
        return 1
    }
}

switch arguments.first {
case "restore":
    exit(runRestore(arguments: Array(arguments.dropFirst())))
case "uninstall":
    exit(runUninstall(arguments: Array(arguments.dropFirst())))
case "offload":
    exit(runOffload(arguments: Array(arguments.dropFirst())))
case "eject":
    exit(runEject(arguments: Array(arguments.dropFirst())))
case "setup":
    exit(runSetup(arguments: Array(arguments.dropFirst())))
case "sync":
    exit(runSync(arguments: Array(arguments.dropFirst())))
case "doctor":
    exit(runDoctor(arguments: Array(arguments.dropFirst())))
case "list":
    exit(runList(arguments: Array(arguments.dropFirst())))
case "--version":
    print("simruntime-offload \(toolVersion)")
case "help", "--help", "-h":
    print(usage)
case .none:
    print(usage)
    exit(64)
case .some(let command):
    printError("unknown command: \(command)\n")
    printError(usage)
    exit(64)
}
