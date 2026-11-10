import Foundation

/// A runtime image registered with CoreSimulator's disk-image daemon: one
/// that lives on the internal disk. From `xcrun simctl runtime list -j`.
public struct RuntimeImage: Equatable, Decodable, Sendable {
    public let identifier: String
    public let build: String
    public let version: String
    public let runtimeIdentifier: String
    /// For example "Patchable Cryptex Disk Image" (downloaded by Xcode) or
    /// "Disk Image" (imported with `simctl runtime add`).
    public let kind: String
    public let state: String
    /// The image file, or for a downloaded runtime its asset directory.
    public let path: String
    public let mountPath: String?
    public let sizeBytes: Int64?
    public let deletable: Bool?
}

/// A runtime CoreSimulator can use, however it was registered.
/// From `xcrun simctl list runtimes -j`.
public struct Runtime: Equatable, Sendable {
    public let identifier: String
    public let name: String
    public let version: String
    public let build: String
    public let bundlePath: String
    public let isAvailable: Bool
}

/// A simulator device. From `xcrun simctl list devices -j`.
public struct Device: Equatable, Sendable {
    public let udid: String
    public let name: String
    public let state: String
    public let runtimeIdentifier: String
    public let isAvailable: Bool

    public var isBooted: Bool { state == "Booted" }
}

public enum SimulatorsError: Error, Equatable, CustomStringConvertible {
    case commandFailed(command: String, status: Int32, message: String)
    case unreadableOutput(command: String)

    public var description: String {
        switch self {
        case .commandFailed(let command, let status, let message):
            return "`\(command)` failed with status \(status): \(message)"
        case .unreadableOutput(let command):
            return "could not understand the output of `\(command)`"
        }
    }
}

/// What the tool needs from CoreSimulator. A protocol so that the offload and
/// eject flows can be tested without a simulator.
public protocol SimulatorControlling {
    func images() throws -> [RuntimeImage]
    func runtimes() throws -> [Runtime]
    func devices() throws -> [Device]
    /// Asks CoreSimulator to delete a registered image. A failure here does not
    /// settle whether the image is gone; callers check.
    func deleteImage(identifier: String) throws
    /// Makes the disk-image daemon rescan its storage, which also clears its
    /// inbox of leftovers.
    func scanAndMount() throws
    /// Imports a runtime image, copying it to the internal disk. The file
    /// given is left where it is.
    func addImage(path: String) throws
}

/// CoreSimulator, through its command-line tool.
///
/// CoreSimulator has no public API. `simctl` is the supported interface, and
/// only its JSON output is parsed, never its human-readable text.
public struct Simulators: SimulatorControlling {
    private let runner: ProcessRunning

    public init(runner: ProcessRunning = SystemProcessRunner()) {
        self.runner = runner
    }

    public func images() throws -> [RuntimeImage] {
        try Simulators.parseImages(simctl(["runtime", "list", "-j"]))
    }

    public func runtimes() throws -> [Runtime] {
        try Simulators.parseRuntimes(simctl(["list", "runtimes", "-j"]))
    }

    public func devices() throws -> [Device] {
        try Simulators.parseDevices(simctl(["list", "devices", "-j"]))
    }

    public func deleteImage(identifier: String) throws {
        _ = try simctl(["runtime", "delete", identifier])
    }

    public func scanAndMount() throws {
        _ = try simctl(["runtime", "scan-and-mount"])
    }

    /// Never with `--move`: the image on the volume is the user's only other
    /// copy until the import has been checked.
    public func addImage(path: String) throws {
        _ = try simctl(["runtime", "add", path])
    }

    private func simctl(_ arguments: [String]) throws -> Data {
        let command = "xcrun simctl " + arguments.joined(separator: " ")
        let result = try runner.run("/usr/bin/xcrun", ["simctl"] + arguments)
        guard result.succeeded else {
            throw SimulatorsError.commandFailed(
                command: command,
                status: result.status,
                message: result.errorText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result.standardOutput
    }

    // MARK: Parsing

    static func parseImages(_ data: Data) throws -> [RuntimeImage] {
        guard let byIdentifier = try? JSONDecoder().decode([String: RuntimeImage].self, from: data) else {
            throw SimulatorsError.unreadableOutput(command: "xcrun simctl runtime list -j")
        }
        return byIdentifier.values.sorted { ($0.version, $0.build) < ($1.version, $1.build) }
    }

    static func parseRuntimes(_ data: Data) throws -> [Runtime] {
        struct Listing: Decodable {
            struct Entry: Decodable {
                let identifier: String
                let name: String
                let version: String
                let buildversion: String
                let bundlePath: String
                let isAvailable: Bool
            }
            let runtimes: [Entry]
        }
        guard let listing = try? JSONDecoder().decode(Listing.self, from: data) else {
            throw SimulatorsError.unreadableOutput(command: "xcrun simctl list runtimes -j")
        }
        return listing.runtimes.map {
            Runtime(
                identifier: $0.identifier, name: $0.name, version: $0.version,
                build: $0.buildversion, bundlePath: $0.bundlePath, isAvailable: $0.isAvailable
            )
        }
    }

    static func parseDevices(_ data: Data) throws -> [Device] {
        struct Listing: Decodable {
            struct Entry: Decodable {
                let udid: String
                let name: String
                let state: String
                let isAvailable: Bool
            }
            let devices: [String: [Entry]]
        }
        guard let listing = try? JSONDecoder().decode(Listing.self, from: data) else {
            throw SimulatorsError.unreadableOutput(command: "xcrun simctl list devices -j")
        }
        return listing.devices
            .flatMap { runtimeIdentifier, entries in
                entries.map {
                    Device(
                        udid: $0.udid, name: $0.name, state: $0.state,
                        runtimeIdentifier: runtimeIdentifier, isAvailable: $0.isAvailable
                    )
                }
            }
            .sorted { ($0.runtimeIdentifier, $0.name) < ($1.runtimeIdentifier, $1.name) }
    }
}
