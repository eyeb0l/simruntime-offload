import Foundation
import SimRuntimeOffloadCore

let toolVersion = "0.1.0-dev"

let usage = """
    simruntime-offload — serve Xcode Simulator runtimes from an external volume

    Usage:
      simruntime-offload doctor [--json]    check whether the tool can work on this Mac; changes nothing
      simruntime-offload list               runtimes on the internal disk and on external volumes; changes nothing
      simruntime-offload setup [--dry-run]  adopt existing state and install the login agent
      simruntime-offload offload <runtime> [--volume <UUID>] [--dry-run]
                                            copy a runtime to the volume, verify it, remove the internal
                                            copy and serve it from the volume
      simruntime-offload eject [--force-unmount] [--dry-run]
                                            release every offloaded runtime and the volume, to unplug it
      simruntime-offload sync               attach what is available, tidy what is not; what the agent runs
      simruntime-offload --version
      simruntime-offload help

    <runtime> is a build number or image identifier, as shown by `list`.

    This is a development build. Restoring a runtime to the internal disk is
    not implemented yet. See docs/design.md for the plan.
    """

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
    let checks = Doctor(paths: paths, probe: SystemProbe()).run()

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
    case .staged: return "copied to the volume; internal copy not yet removed"
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
        let (manifest, source) = try ManifestStore(paths: paths).loadIncludingHarness()
        inventory = InventoryBuilder(paths: paths, volumeLookup: volumes.volume(uuid:)).build(
            manifest: manifest, source: source,
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
    if inventory.manifestSource == .harness {
        print("")
        print("These are recorded by the experiment harness; `setup` will adopt them.")
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
    guard arguments.isEmpty else {
        printError("sync: unknown option \(arguments[0])")
        return 64
    }
    let paths = Paths(home: NSHomeDirectory(), userID: getuid())
    let outcomes: [SyncOutcome]
    do {
        let manifest = try ManifestStore(paths: paths).load()
        if manifest.runtimes.isEmpty {
            print("[\(timestamp())] nothing is offloaded; nothing to sync")
            return 0
        }
        let volumes = Volumes()
        outcomes = try Sync(paths: paths, volumeLookup: volumes.volume(uuid:))
            .run(manifest: manifest, registeredRuntimes: { try Simulators().runtimes() })
    } catch SyncError.alreadyRunning {
        // Expected: launchd starts the agent for the mounts a sync itself makes.
        print("[\(timestamp())] another sync is running; leaving it to finish")
        return 0
    } catch {
        printError("[\(timestamp())] sync: \(error)")
        return 1
    }
    var failed = false
    for outcome in outcomes {
        print("[\(timestamp())] \(outcome.build): \(describe(outcome.result))")
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

    // 3. Adopt what the experiment harness recorded, but only when there is
    //    no manifest yet. Once one exists it is authoritative: the harness's
    //    list knows nothing of what this tool has offloaded since, and
    //    following it again would forget those runtimes.
    let store = ManifestStore(paths: paths)
    do {
        let existing = try store.load()
        let hasManifest = FileManager.default.fileExists(atPath: paths.manifest)
        if !hasManifest, let harness = store.harnessRuntimes() {
            let volumes = Volumes()
            let adopted = Adoption(paths: paths, volumeLookup: volumes.volume(uuid:)).manifest(
                adopting: harness, existing: existing, runtimes: (try? Simulators().runtimes()) ?? [])
            let builds = adopted.runtimes.map { $0.build }.joined(separator: ", ")
            print("Manifest: \(action.lowercased()) record \(builds) from the experiment harness.")
            if !dryRun { try store.save(adopted) }
        } else {
            print("Manifest: \(existing.runtimes.count) runtime(s).")
        }
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
    print("Agent: \(action.lowercased()) (re)load \(Paths.agentLabel); it runs `sync` at login and whenever a volume mounts.")
    if dryRun {
        print("")
        print("Dry run: nothing was changed.")
        return 0
    }
    do {
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
    let checks = Doctor(paths: paths, probe: SystemProbe()).run()
    if Doctor.passed(checks) { return true }
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
        sync: { manifest in
            try Sync(paths: paths, volumeLookup: volumes.volume(uuid:))
                .run(manifest: manifest, registeredRuntimes: { try simulators.runtimes() })
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
            print("Dry run: would copy and verify the image, remove the internal copy, restart the")
            print("CoreSimulator service and attach the copy. Nothing was changed.")
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
        try Ejector(
            paths: paths,
            simulators: simulators,
            attacher: Attacher(),
            services: Services(userID: paths.userID),
            volumeLookup: volumes.volume(uuid:),
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
        ).run(manifest: manifest, forceUnmount: forceUnmount)
        print("")
        print("Safe to unplug. Plugging the disk back in re-attaches the runtimes.")
        return 0
    } catch {
        printError("eject: \(error)")
        return 1
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
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
