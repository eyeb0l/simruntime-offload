import Foundation

/// What happened to one runtime during a sync.
public struct SyncOutcome: Equatable, Sendable {
    public enum Result: Equatable, Sendable {
        case alreadyActive
        case attached
        case linked
        case removedDanglingLink
        /// The volume is not connected and there was nothing to tidy.
        case waitingForVolume
        /// Left alone, with the reason.
        case needsAttention(String)
        case failed(String)
    }

    public let build: String
    public let result: Result
}

public enum SyncError: Error, Equatable, CustomStringConvertible {
    case alreadyRunning
    case mountRootNotOurs(path: String)

    public var description: String {
        switch self {
        case .alreadyRunning:
            return "another sync is already running"
        case .mountRootNotOurs(let path):
            return "\(path) exists but is not a directory owned by you; refusing to mount into it"
        }
    }
}

/// Brings the machine into line with the manifest: attaches and links every
/// runtime whose volume is present, and removes the links of those whose
/// volume is absent.
///
/// Run by the login agent at login and on every mount, and by the
/// command-line tool after it changes anything. It is idempotent, never
/// detaches anything, and never forces anything.
public struct Sync {
    private let paths: Paths
    private let attacher: ImageAttaching
    private let fileSystem: FileSystemProbing
    private let registry: Registry
    private let inventory: InventoryBuilder
    private let files = FileManager.default

    public init(
        paths: Paths,
        attacher: ImageAttaching = Attacher(),
        fileSystem: FileSystemProbing = FileSystem(),
        volumeLookup: @escaping (String) -> Volume?
    ) {
        self.paths = paths
        self.attacher = attacher
        self.fileSystem = fileSystem
        self.registry = Registry(paths: paths)
        self.inventory = InventoryBuilder(paths: paths, fileSystem: fileSystem, volumeLookup: volumeLookup)
    }

    /// Reconciles every runtime in `manifest`. One runtime failing does not
    /// stop the others. Throws only when no work could be attempted.
    ///
    /// `registeredRuntimes` is called at most once, and only if some runtime is
    /// already attached and linked. At login nothing is, so the agent attaches
    /// without first waiting for CoreSimulator to start.
    public func run(
        manifest: Manifest,
        registeredRuntimes: () throws -> [Runtime]
    ) throws -> [SyncOutcome] {
        guard !manifest.runtimes.isEmpty else { return [] }
        let lock = try StateLock.acquire(paths: paths)
        defer { lock.release() }

        var cached: [Runtime]?
        func runtimes() throws -> [Runtime] {
            if let cached { return cached }
            let fetched = try registeredRuntimes()
            cached = fetched
            return fetched
        }

        return manifest.runtimes.map { runtime in
            do {
                return SyncOutcome(build: runtime.build, result: try reconcile(runtime, runtimes: runtimes))
            } catch {
                return SyncOutcome(build: runtime.build, result: .failed("\(error)"))
            }
        }
    }

    private func reconcile(
        _ runtime: OffloadedRuntime, runtimes: () throws -> [Runtime]
    ) throws -> SyncOutcome.Result {
        // Without the runtime list the furthest a status can get is
        // "not registered"; only then is CoreSimulator consulted.
        var status = inventory.status(of: runtime, runtimes: [])
        if status.state == .notRegistered {
            status = inventory.status(of: runtime, runtimes: try runtimes())
        }
        let mountPoint = paths.mountPoint(forBuild: runtime.build)

        switch status.state {
        case .active:
            return .alreadyActive

        case .volumeAbsent, .imageMissing:
            if registry.hasDanglingLink(forBuild: runtime.build) {
                try registry.unlink(build: runtime.build)
                return .removedDanglingLink
            }
            return status.state == .imageMissing
                ? .needsAttention("the volume is connected but \(runtime.imagePath) is not on it")
                : .waitingForVolume

        case .notAttached:
            guard let volumeRoot = status.volume?.mountPoint else { return .waitingForVolume }
            // A link left from before a restart points at nothing; clear it
            // first so CoreSimulator never sees it resolve half-way.
            try registry.unlink(build: runtime.build)
            try prepareMountPoint(mountPoint)
            try attacher.attach(image: "\(volumeRoot)/\(runtime.imagePath)", at: mountPoint)
            do {
                // The link is made only after the mount exists.
                try registry.link(build: runtime.build, to: registry.bundle(inImageMountedAt: mountPoint))
            } catch {
                // Do not leave an image attached that nothing refers to.
                try? attacher.eject(mountPoint: mountPoint)
                throw error
            }
            return .attached

        case .notLinked:
            try registry.link(build: runtime.build, to: registry.bundle(inImageMountedAt: mountPoint))
            return .linked

        case .staged:
            return .needsAttention(
                "copied to the volume, but its internal copy is still installed; finish with `simruntime-offload offload \(runtime.build)`")

        case .notRegistered:
            return .needsAttention(
                "attached and linked, but CoreSimulator does not list it yet; it may need the CoreSimulator service restarted or a new login")
        }
    }

    /// Creates the per-user mount root and the mount point for one build.
    ///
    /// `/private/tmp` is world-writable, so an existing mount root is used only
    /// if it is a real directory owned by this user.
    private func prepareMountPoint(_ mountPoint: String) throws {
        let root = paths.mountRoot
        var info = stat()
        if lstat(root, &info) == 0 {
            let isDirectory = (info.st_mode & S_IFMT) == S_IFDIR
            guard isDirectory, info.st_uid == paths.userID else {
                throw SyncError.mountRootNotOurs(path: root)
            }
        } else {
            try files.createDirectory(
                atPath: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try files.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)
    }
}
