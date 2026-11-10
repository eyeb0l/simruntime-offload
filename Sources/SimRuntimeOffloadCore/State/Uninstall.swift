import Foundation

public enum UninstallError: Error, Equatable, CustomStringConvertible {
    case simulatorsBooted([String])
    case notEnoughSpace(neededBytes: Int64, freeBytes: Int64)

    public var description: String {
        switch self {
        case .simulatorsBooted(let names):
            return "these simulators are booted: \(names.joined(separator: ", ")). Shut them down first; nothing was changed"
        case .notEnoughSpace(let needed, let free):
            return "restoring every runtime needs \(needed / 1_000_000_000) GB on the internal disk and \(free / 1_000_000_000) GB is free. Nothing was changed. Restore some individually, or use --leave-runtimes-on-volume"
        }
    }
}

/// What `uninstall` will do, worked out without changing anything.
public struct UninstallPlan: Equatable, Sendable {
    public let leaveRuntimesOnVolume: Bool
    /// Runtimes to import to the internal disk; empty when they are left.
    public let restores: [RestorePlan]
    /// Runtimes that will only stop being served.
    public let released: [OffloadedRuntime]
}

public enum UninstallEvent: Equatable, Sendable {
    case restoring(build: String)
    case restoredButNotListed(build: String)
    case stoppedServing(build: String)
    case removedAgent
}

/// What `uninstall` did, for the command line to report.
public struct UninstallSummary: Equatable, Sendable {
    public var removed: [String] = []
    /// Things of ours that could not be removed, or things in our directories
    /// that are not ours and were therefore left.
    public var left: [String] = []
    /// Images that remain on a volume, as absolute paths where the volume is
    /// connected and volume-relative ones where it is not.
    public var imagesKept: [String] = []
    /// The shared link directory, when it exists and is now empty. Removing
    /// it needs root, which this tool never asks for.
    public var sharedLinkDirectory: String?
}

/// Removes everything the tool installed.
///
/// By default every runtime is first restored to the internal disk, so that
/// uninstalling never costs the user a runtime. Nothing is deleted
/// recursively: named files are removed, and directories only when empty, so
/// anything unexpected in them stays and is reported.
public struct Uninstaller {
    private let paths: Paths
    private let simulators: SimulatorControlling
    private let restorer: Restorer
    private let releaser: Releaser
    private let agent: Agent
    private let fileSystem: FileSystemProbing
    private let volumeLookup: (String) -> Volume?
    private let store: ManifestStore
    private let files = FileManager.default
    private let report: (UninstallEvent) -> Void

    public init(
        paths: Paths,
        simulators: SimulatorControlling,
        restorer: Restorer,
        attacher: ImageAttaching,
        services: ServiceControlling,
        agent: Agent,
        fileSystem: FileSystemProbing = FileSystem(),
        volumeLookup: @escaping (String) -> Volume?,
        pause: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        report: @escaping (UninstallEvent) -> Void = { _ in }
    ) {
        self.paths = paths
        self.simulators = simulators
        self.restorer = restorer
        self.releaser = Releaser(
            paths: paths, attacher: attacher, services: services, fileSystem: fileSystem, pause: pause)
        self.agent = agent
        self.fileSystem = fileSystem
        self.volumeLookup = volumeLookup
        self.store = ManifestStore(paths: paths)
        self.report = report
    }

    public func plan(leaveRuntimesOnVolume: Bool) throws -> UninstallPlan {
        let manifest = try store.load()
        if !manifest.runtimes.isEmpty {
            let booted = try simulators.devices().filter(\.isBooted).map(\.name)
            guard booted.isEmpty else { throw UninstallError.simulatorsBooted(booted) }
        }
        if leaveRuntimesOnVolume {
            return UninstallPlan(leaveRuntimesOnVolume: true, restores: [], released: manifest.runtimes)
        }
        // Every restore is planned before any is started, so that a missing
        // volume or image stops the whole uninstall with nothing changed.
        let restores = try manifest.runtimes.map { try restorer.plan(runtime: $0.build) }
        // Each plan checked its own size; together they must fit as well.
        let needed = restores.filter { !$0.alreadyInternal }.compactMap(\.entry.sizeBytes).reduce(0, +)
        if needed > 0, let free = restorer.internalFreeBytes(), free < needed + 2 * 1_073_741_824 {
            throw UninstallError.notEnoughSpace(neededBytes: needed + 2 * 1_073_741_824, freeBytes: free)
        }
        return UninstallPlan(leaveRuntimesOnVolume: false, restores: restores, released: [])
    }

    public func run(_ plan: UninstallPlan, forceUnmount: Bool) throws -> UninstallSummary {
        var summary = UninstallSummary()
        let agentFiles = [paths.agentPropertyList, paths.installedExecutable].filter(files.fileExists(atPath:))

        if plan.leaveRuntimesOnVolume {
            // The agent goes first, so that nothing re-attaches what is
            // released below.
            try agent.uninstall()
            report(.removedAgent)
            let lock = try StateLock.acquire(paths: paths)
            defer { lock.release() }
            for runtime in plan.released {
                _ = try releaser.release(build: runtime.build, forceUnmount: forceUnmount)
                report(.stoppedServing(build: runtime.build))
                summary.imagesKept.append(location(of: runtime))
            }
        } else {
            for restore in plan.restores {
                report(.restoring(build: restore.entry.build))
                do {
                    try restorer.run(restore, deleteImage: false, forceUnmount: forceUnmount)
                } catch RestoreError.notListed {
                    // Imported and ready; only the listing lags. Not a reason
                    // to leave the uninstall half done.
                    report(.restoredButNotListed(build: restore.entry.build))
                }
                summary.imagesKept.append(restore.image)
            }
            try agent.uninstall()
            report(.removedAgent)
        }

        summary.removed += agentFiles.filter { !files.fileExists(atPath: $0) }
        removeFile(paths.manifest, &summary)
        removeFile("\(paths.stateDirectory)/sync.flock", &summary)
        removeFile(paths.agentLog, &summary)
        removeEmptyDirectory((paths.installedExecutable as NSString).deletingLastPathComponent, &summary)
        removeEmptyDirectory(paths.logDirectory, &summary)
        removeEmptyDirectory(paths.stateDirectory, &summary)

        for name in fileSystem.contentsOfDirectory(paths.mountRoot) {
            let directory = "\(paths.mountRoot)/\(name)"
            if fileSystem.isMountPoint(directory) {
                summary.left.append("\(directory) (still mounted)")
            } else {
                removeEmptyDirectory(directory, &summary)
            }
        }
        removeEmptyDirectory(paths.mountRoot, &summary)

        if fileSystem.fileExists(paths.sharedLinkDirectory) {
            if fileSystem.contentsOfDirectory(paths.sharedLinkDirectory).isEmpty {
                summary.sharedLinkDirectory = paths.sharedLinkDirectory
            } else {
                summary.left.append("\(paths.sharedLinkDirectory) (not empty)")
            }
        }
        return summary
    }

    private func location(of runtime: OffloadedRuntime) -> String {
        if let root = volumeLookup(runtime.volumeUUID)?.mountPoint { return "\(root)/\(runtime.imagePath)" }
        return "\(runtime.imagePath) on the volume \(runtime.volumeUUID)"
    }

    private func removeFile(_ path: String, _ summary: inout UninstallSummary) {
        guard files.fileExists(atPath: path) else { return }
        do {
            try files.removeItem(atPath: path)
            summary.removed.append(path)
        } catch {
            summary.left.append("\(path) (\(error.localizedDescription))")
        }
    }

    /// rmdir(2), which removes a directory only when it is empty. Whatever
    /// keeps it from being empty is not ours, and is named.
    private func removeEmptyDirectory(_ path: String, _ summary: inout UninstallSummary) {
        var isDirectory: ObjCBool = false
        guard files.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
        if rmdir(path) == 0 {
            summary.removed.append(path)
        } else {
            let contents = fileSystem.contentsOfDirectory(path).sorted().joined(separator: ", ")
            summary.left.append("\(path) (contains \(contents))")
        }
    }
}
