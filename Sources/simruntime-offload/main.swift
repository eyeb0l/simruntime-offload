import Foundation
import SimRuntimeOffloadCore

let toolVersion = "0.1.0-dev"

let usage = """
    simruntime-offload — serve Xcode Simulator runtimes from an external volume

    Usage:
      simruntime-offload doctor [--json]    check whether the tool can work on this Mac; changes nothing
      simruntime-offload list               runtimes on the internal disk and on external volumes; changes nothing
      simruntime-offload setup [--dry-run]  adopt existing state and install the login agent
      simruntime-offload sync               attach what is available, tidy what is not; what the agent runs
      simruntime-offload --version
      simruntime-offload help

    This is a development build. Offloading, restoring and ejecting are still
    done with the harness in experiments/. See docs/design.md for the plan.
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
    let checks = Doctor(paths: paths, probe: SystemProbe()).run()
    guard Doctor.passed(checks) else {
        printError("setup: this Mac does not pass the preflight checks:")
        for check in checks where check.status == .failure {
            printError("  \(check.summary)")
            if let remedy = check.remedy { printError("    \(remedy)") }
        }
        return 1
    }

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

    // 3. Adopt what the experiment harness recorded, if anything.
    let store = ManifestStore(paths: paths)
    do {
        let existing = try store.load()
        if let harness = store.harnessRuntimes() {
            let volumes = Volumes()
            let adopted = Adoption(paths: paths, volumeLookup: volumes.volume(uuid:)).manifest(
                adopting: harness, existing: existing, runtimes: (try? Simulators().runtimes()) ?? [])
            if adopted == existing {
                print("Manifest: up to date (\(existing.runtimes.count) runtime(s)).")
            } else {
                let builds = adopted.runtimes.map { $0.build }.joined(separator: ", ")
                print("Manifest: \(action.lowercased()) record \(builds) from the experiment harness.")
                if !dryRun { try store.save(adopted) }
            }
        } else {
            print("Manifest: \(existing.runtimes.count) runtime(s); nothing to adopt.")
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

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
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
