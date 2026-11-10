import Foundation

public enum FileKind: Equatable, Sendable {
    case missing
    case directory
    case file
    case symbolicLink
}

public struct Ownership: Equatable, Sendable {
    public let owner: UInt32
    /// Permission bits only, for example `0o700`.
    public let mode: UInt16

    public init(owner: UInt32, mode: UInt16) {
        self.owner = owner
        self.mode = mode
    }
}

/// Read-only questions about the machine. A protocol so that `Doctor` can be
/// tested against any combination of answers.
public protocol SystemProbing {
    func macOSVersion() -> Version
    /// `nil` when Xcode's command-line tools cannot be run.
    func xcodeVersion() -> Version?
    func coreSimulatorVersion() -> Version?
    /// `nil` when the status could not be determined.
    func systemIntegrityProtectionEnabled() -> Bool?
    /// Whether `diskutil image attach` exists. The older `hdiutil attach` is
    /// not an acceptable substitute: it makes simulator boots five times slower.
    func modernImageAttachAvailable() -> Bool
    func fileKind(at path: String) -> FileKind
    func isWritable(_ path: String) -> Bool
    func ownership(of path: String) -> Ownership?
    func agentLoaded(label: String, userID: UInt32) -> Bool
}

/// Answers from the real machine. Changes nothing.
public struct SystemProbe: SystemProbing {
    private let runner: ProcessRunning

    public init(runner: ProcessRunning = SystemProcessRunner()) {
        self.runner = runner
    }

    public func macOSVersion() -> Version {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return Version([version.majorVersion, version.minorVersion, version.patchVersion])
    }

    public func xcodeVersion() -> Version? {
        guard let result = try? runner.run("/usr/bin/xcodebuild", ["-version"]), result.succeeded else {
            return nil
        }
        return SystemProbe.parseXcodeVersion(result.outputText)
    }

    /// Parses the first line of `xcodebuild -version`, for example `Xcode 27.2`.
    static func parseXcodeVersion(_ output: String) -> Version? {
        for line in output.split(separator: "\n") where line.hasPrefix("Xcode ") {
            return Version(String(line.dropFirst("Xcode ".count)))
        }
        return nil
    }

    public func coreSimulatorVersion() -> Version? {
        let url = URL(fileURLWithPath: Paths.coreSimulatorInfoPropertyList)
        guard
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let dictionary = plist as? [String: Any],
            let text = dictionary["CFBundleVersion"] as? String
        else { return nil }
        return Version(text)
    }

    public func systemIntegrityProtectionEnabled() -> Bool? {
        guard let result = try? runner.run("/usr/bin/csrutil", ["status"]), result.succeeded else {
            return nil
        }
        return SystemProbe.parseIntegrityProtectionStatus(result.outputText)
    }

    static func parseIntegrityProtectionStatus(_ output: String) -> Bool? {
        if output.contains("status: enabled") { return true }
        if output.contains("status: disabled") { return false }
        return nil
    }

    public func modernImageAttachAvailable() -> Bool {
        // With no arguments the subcommand prints its usage, whatever its exit
        // status; an unknown verb prints diskutil's general usage instead.
        guard let result = try? runner.run("/usr/sbin/diskutil", ["image", "attach"]) else {
            return false
        }
        return (result.outputText + result.errorText).contains("diskutil image attach")
    }

    public func fileKind(at path: String) -> FileKind {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let type = attributes[.type] as? FileAttributeType
        else { return .missing }
        switch type {
        case .typeDirectory: return .directory
        case .typeSymbolicLink: return .symbolicLink
        default: return .file
        }
    }

    public func isWritable(_ path: String) -> Bool {
        access(path, W_OK) == 0
    }

    public func ownership(of path: String) -> Ownership? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return Ownership(owner: info.st_uid, mode: UInt16(info.st_mode & 0o7777))
    }

    public func agentLoaded(label: String, userID: UInt32) -> Bool {
        let result = try? runner.run("/bin/launchctl", ["print", "gui/\(userID)/\(label)"])
        return result?.succeeded ?? false
    }
}
