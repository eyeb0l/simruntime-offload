import Foundation
import SimRuntimeOffloadCore

let toolVersion = "0.1.0-dev"

let usage = """
    simruntime-offload — serve Xcode Simulator runtimes from an external volume

    Usage:
      simruntime-offload doctor [--json]   check whether the tool can work on this Mac; changes nothing
      simruntime-offload list              runtimes on the internal disk and on external volumes; changes nothing
      simruntime-offload --version
      simruntime-offload help

    This is a development build: only the read-only commands are implemented.
    See docs/design.md for what is planned.
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

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
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
