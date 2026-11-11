import Foundation

public enum AgentError: Error, Equatable, CustomStringConvertible {
    case couldNotLoad(message: String)

    public var description: String {
        switch self {
        case .couldNotLoad(let message):
            return "launchd would not load the login agent: \(message)"
        }
    }
}

/// The per-user LaunchAgent that runs `sync` at login and whenever any volume
/// is mounted.
///
/// It is an agent, not a daemon: everything it does is unprivileged. Its
/// program is the tool itself and never a shell script, because macOS
/// attributes a background job's file access to the job's executable, and for
/// `/bin/bash` access to a removable volume is refused without a prompt.
public struct Agent {
    private let paths: Paths
    private let runner: ProcessRunning
    private let files = FileManager.default

    public init(paths: Paths, runner: ProcessRunning = SystemProcessRunner()) {
        self.paths = paths
        self.runner = runner
    }

    private var domain: String { "gui/\(paths.userID)" }
    private var service: String { "\(domain)/\(Paths.agentLabel)" }

    /// The job definition. `StartOnMount` means no polling: launchd starts the
    /// job when a volume appears. It runs at normal priority because at
    /// background priority it started over a minute after login.
    func propertyList(program: String) -> [String: Any] {
        [
            "Label": Paths.agentLabel,
            "ProgramArguments": [program, "sync"],
            "RunAtLoad": true,
            "StartOnMount": true,
            "ProcessType": "Interactive",
            "StandardOutPath": paths.agentLog,
            "StandardErrorPath": paths.agentLog,
        ]
    }

    public var isLoaded: Bool {
        (try? runner.run("/bin/launchctl", ["print", service]))?.succeeded ?? false
    }

    /// Copies `executable` to its installed location unless an identical copy
    /// is already there. Returns whether anything was copied.
    ///
    /// An unchanged copy is left alone on purpose: a build from source is
    /// ad-hoc signed, so a new copy is a new identity and costs the user a new
    /// consent prompt. Releases are Developer ID signed and keep one identity.
    @discardableResult
    public func installExecutable(from executable: String) throws -> Bool {
        let destination = paths.installedExecutable
        if files.contentsEqual(atPath: executable, andPath: destination) { return false }
        try files.createDirectory(
            atPath: (destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        // Copy beside the destination and rename over it, so the agent never
        // sees a half-written program.
        let staging = destination + ".new"
        try? files.removeItem(atPath: staging)
        try files.copyItem(atPath: executable, toPath: staging)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging)
        _ = try files.replaceItemAt(URL(fileURLWithPath: destination), withItemAt: URL(fileURLWithPath: staging))
        return true
    }

    /// Writes the job definition and (re)loads it. Loading runs `sync` once.
    public func install() throws {
        try files.createDirectory(atPath: paths.logDirectory, withIntermediateDirectories: true)
        try files.createDirectory(
            atPath: (paths.agentPropertyList as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: propertyList(program: paths.installedExecutable), format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: paths.agentPropertyList), options: .atomic)

        // Unloading a job that is not loaded fails; that is expected.
        _ = try? runner.run("/bin/launchctl", ["bootout", service])
        let result = try runner.run("/bin/launchctl", ["bootstrap", domain, paths.agentPropertyList])
        guard result.succeeded else {
            throw AgentError.couldNotLoad(
                message: result.errorText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Unloads the job and removes its definition and the installed copy.
    public func uninstall() throws {
        _ = try? runner.run("/bin/launchctl", ["bootout", service])
        for path in [paths.agentPropertyList, paths.installedExecutable] where files.fileExists(atPath: path) {
            try files.removeItem(atPath: path)
        }
    }
}
