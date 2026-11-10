/// Where an offloaded runtime stands, from most to least broken.
public enum OffloadState: String, Equatable, Codable, Sendable {
    /// Attached, linked and known to CoreSimulator.
    case active
    /// The external volume is not connected (or not mounted).
    case volumeAbsent
    /// The volume is there but the image is not where the manifest says.
    case imageMissing
    /// The image is there but not attached.
    case notAttached
    /// Attached, but no link of ours points at it.
    case notLinked
    /// Attached and linked, but CoreSimulator does not list the runtime.
    case notRegistered
    /// Copied to the volume, but the internal copy has not been removed yet.
    case staged
}

public struct OffloadedRuntimeStatus: Equatable, Sendable {
    public let runtime: OffloadedRuntime
    public let volume: Volume?
    public let state: OffloadState
    /// The name CoreSimulator gives the runtime, when it is registered.
    public let registeredName: String?

    public var displayName: String {
        registeredName ?? runtime.name ?? "build \(runtime.build)"
    }
}

/// What `list` shows: the runtimes on the internal disk and the runtimes
/// served from an external volume.
public struct Inventory: Equatable, Sendable {
    public let internalImages: [RuntimeImage]
    public let offloaded: [OffloadedRuntimeStatus]
}

/// Works out the state of every offloaded runtime. Reads only.
public struct InventoryBuilder {
    private let paths: Paths
    private let fileSystem: FileSystemProbing
    private let volumeLookup: (String) -> Volume?

    public init(
        paths: Paths,
        fileSystem: FileSystemProbing = FileSystem(),
        volumeLookup: @escaping (String) -> Volume?
    ) {
        self.paths = paths
        self.fileSystem = fileSystem
        self.volumeLookup = volumeLookup
    }

    public func build(
        manifest: Manifest,
        images: [RuntimeImage],
        runtimes: [Runtime]
    ) -> Inventory {
        Inventory(
            internalImages: images,
            offloaded: manifest.runtimes.map { status(of: $0, runtimes: runtimes) }
        )
    }

    func status(of runtime: OffloadedRuntime, runtimes: [Runtime]) -> OffloadedRuntimeStatus {
        let volume = volumeLookup(runtime.volumeUUID)
        let mountPoint = paths.mountPoint(forBuild: runtime.build)
        // A runtime served from our mount is one whose bundle lies inside it.
        let registered = runtimes.first { $0.bundlePath.hasPrefix(mountPoint + "/") }

        func result(_ state: OffloadState) -> OffloadedRuntimeStatus {
            OffloadedRuntimeStatus(
                runtime: runtime, volume: volume, state: state, registeredName: registered?.name)
        }

        if runtime.isStaged { return result(.staged) }
        guard let volumeRoot = volume?.mountPoint else { return result(.volumeAbsent) }
        guard fileSystem.fileExists("\(volumeRoot)/\(runtime.imagePath)") else { return result(.imageMissing) }
        guard fileSystem.isMountPoint(mountPoint) else { return result(.notAttached) }
        guard isLinked(build: runtime.build, into: mountPoint) else { return result(.notLinked) }
        guard registered != nil else { return result(.notRegistered) }
        return result(.active)
    }

    /// Whether one of our links, in either link directory, points into `mountPoint`.
    private func isLinked(build: String, into mountPoint: String) -> Bool {
        let name = Paths.linkName(forBuild: build)
        return [paths.sharedLinkDirectory, paths.perUserLinkDirectory].contains { directory in
            fileSystem.symbolicLinkDestination("\(directory)/\(name)")?.hasPrefix(mountPoint + "/") ?? false
        }
    }
}
