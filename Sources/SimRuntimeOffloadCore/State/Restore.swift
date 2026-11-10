import Foundation

public enum RestoreError: Error, Equatable, CustomStringConvertible {
    case notOffloaded(String)
    case simulatorsBooted([String])
    case volumeNotConnected(name: String?, uuid: String)
    case imageMissing(path: String)
    case imageChanged(path: String)
    case notEnoughSpace(neededBytes: Int64, freeBytes: Int64)
    case stillInUse(build: String, message: String)
    case importFailed(build: String, message: String)
    case notRegistered(build: String)
    case notListed(build: String)

    public var description: String {
        switch self {
        case .notOffloaded(let name):
            return "no offloaded runtime matches \"\(name)\"; `simruntime-offload list` shows what is offloaded"
        case .simulatorsBooted(let names):
            return "these simulators are booted: \(names.joined(separator: ", ")). Shut them down first; nothing was changed"
        case .volumeNotConnected(let name, let uuid):
            return "the volume \(name.map { "\"\($0)\"" } ?? uuid) holding this runtime is not connected; nothing was changed"
        case .imageMissing(let path):
            return "the image is not at \(path); nothing was changed"
        case .imageChanged(let path):
            return "\(path) no longer matches the checksum recorded when it was offloaded, so it has not been imported. Nothing was changed"
        case .notEnoughSpace(let needed, let free):
            return "the internal disk has \(free / 1_000_000_000) GB free; \(needed / 1_000_000_000) GB is needed. Nothing was changed"
        case .stillInUse(let build, let message):
            return "the image of \(build) is still in use (\(message)), so it was not ejected. It is being served from the volume again. Try again shortly, or use --force-unmount"
        case .importFailed(let build, let message):
            return "CoreSimulator would not import \(build): \(message). It is being served from the volume again"
        case .notRegistered(let build):
            return "the import of \(build) was started but CoreSimulator does not list it as ready. The image on the volume is untouched. Run `simruntime-offload restore \(build)` again to finish"
        case .notListed(let build):
            return "\(build) is imported and its image is ready, but CoreSimulator does not list the runtime yet. It should appear after your next login"
        }
    }
}

/// Everything `restore` has worked out before it changes anything.
public struct RestorePlan: Equatable, Sendable {
    public let entry: OffloadedRuntime
    public let volume: Volume
    /// The image on the volume.
    public let image: String
    /// The build is already registered from the internal disk, so there is
    /// nothing to import: the runtime only has to stop being served from the
    /// volume. Happens after an interrupted offload or restore.
    public let alreadyInternal: Bool
}

public enum RestoreEvent: Equatable, Sendable {
    case verifyingImage
    case alreadyInternal
    case releasing
    case importing(from: String)
    case imported
    case restartingCoreSimulator
    case removedImage(path: String)
    case keptImage(path: String)
    case done(name: String?)
}

/// Puts an offloaded runtime back on the internal disk.
///
/// The image on the volume is imported, never moved, and is deleted only on
/// request and only after CoreSimulator reports the import ready. Until the
/// import is confirmed, every failure returns the runtime to being served from
/// the volume.
public struct Restorer {
    private let paths: Paths
    private let simulators: SimulatorControlling
    private let volumeLookup: (String) -> Volume?
    private let imageStore: ImageStoring
    private let services: ServiceControlling
    private let fileSystem: FileSystemProbing
    private let store: ManifestStore
    private let releaser: Releaser
    private let sync: (Manifest) throws -> [SyncOutcome]
    private let pause: (TimeInterval) -> Void
    private let report: (RestoreEvent) -> Void
    /// Free space on the internal disk, or `nil` when it cannot be read.
    public let internalFreeBytes: () -> Int64?

    public init(
        paths: Paths,
        simulators: SimulatorControlling,
        volumeLookup: @escaping (String) -> Volume?,
        imageStore: ImageStoring,
        attacher: ImageAttaching,
        services: ServiceControlling,
        fileSystem: FileSystemProbing = FileSystem(),
        internalFreeBytes: @escaping () -> Int64? = Restorer.systemInternalFreeBytes,
        sync: @escaping (Manifest) throws -> [SyncOutcome],
        pause: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        report: @escaping (RestoreEvent) -> Void = { _ in }
    ) {
        self.paths = paths
        self.simulators = simulators
        self.volumeLookup = volumeLookup
        self.imageStore = imageStore
        self.services = services
        self.fileSystem = fileSystem
        self.store = ManifestStore(paths: paths)
        self.releaser = Releaser(
            paths: paths, attacher: attacher, services: services, fileSystem: fileSystem, pause: pause)
        self.internalFreeBytes = internalFreeBytes
        self.sync = sync
        self.pause = pause
        self.report = report
    }

    /// Space the system would make available to an important write on the
    /// volume CoreSimulator stores images on.
    public static func systemInternalFreeBytes() -> Int64? {
        let url = URL(fileURLWithPath: "/Library/Developer")
        return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    // MARK: Planning (read-only)

    public func plan(runtime name: String) throws -> RestorePlan {
        let manifest = try store.load()
        let matches = manifest.runtimes.filter {
            $0.build.caseInsensitiveCompare(name) == .orderedSame
                || $0.runtimeIdentifier?.caseInsensitiveCompare(name) == .orderedSame
        }
        // Builds are unique in the manifest; a runtime identifier is shared
        // by every build of one version, so it may match more than one.
        guard matches.count == 1, let entry = matches.first else { throw RestoreError.notOffloaded(name) }

        // Ejecting an image restarts a helper every simulator depends on.
        let booted = try simulators.devices().filter(\.isBooted).map(\.name)
        guard booted.isEmpty else { throw RestoreError.simulatorsBooted(booted) }

        let internalCopy = try simulators.images().contains { $0.build == entry.build }
        guard let volume = volumeLookup(entry.volumeUUID), let volumeRoot = volume.mountPoint else {
            throw RestoreError.volumeNotConnected(
                name: volumeLookup(entry.volumeUUID)?.name, uuid: entry.volumeUUID)
        }
        let image = "\(volumeRoot)/\(entry.imagePath)"
        if !internalCopy {
            guard fileSystem.fileExists(image) else { throw RestoreError.imageMissing(path: image) }
            if let size = entry.sizeBytes, let free = internalFreeBytes() {
                let needed = size + 2 * 1_073_741_824
                guard free >= needed else {
                    throw RestoreError.notEnoughSpace(neededBytes: needed, freeBytes: free)
                }
            }
        }
        return RestorePlan(entry: entry, volume: volume, image: image, alreadyInternal: internalCopy)
    }

    // MARK: Execution

    public func run(_ plan: RestorePlan, deleteImage: Bool, forceUnmount: Bool) throws {
        var entry = plan.entry
        let build = entry.build
        let wasStaged = entry.staged

        // Checked before anything is touched: a damaged image must leave the
        // runtime exactly as it was, still served from the volume.
        if !plan.alreadyInternal, let expected = entry.sha256 {
            report(.verifyingImage)
            guard try imageStore.sha256(ofFile: plan.image) == expected else {
                throw RestoreError.imageChanged(path: plan.image)
            }
        }

        // Held to the end, so that the agent cannot re-attach the image while
        // the same build is being imported.
        let lock = try acquireLock()
        defer { lock.release() }

        // Staged from here on: if this process dies, the agent leaves the
        // build alone and a second `restore` picks up where this one stopped.
        entry.staged = true
        try save(entry)

        /// Back to being served from the volume.
        func rollBack() {
            entry.staged = wasStaged
            try? save(entry)
            lock.release()
            _ = try? sync((try? store.load()) ?? Manifest())
        }

        report(plan.alreadyInternal ? .alreadyInternal : .releasing)
        do {
            _ = try releaser.release(build: build, forceUnmount: forceUnmount)
        } catch let EjectError.stillInUse(_, message) {
            rollBack()
            throw RestoreError.stillInUse(build: build, message: message)
        }

        if !plan.alreadyInternal {
            report(.importing(from: plan.image))
            do {
                try simulators.addImage(path: plan.image)
            } catch {
                // The command's status does not settle it. If the build is
                // not registered, nothing was imported and it is safe to go
                // back; if it is, carry on to the checks below.
                try? simulators.scanAndMount()
                if !isRegistered(build) {
                    rollBack()
                    throw RestoreError.importFailed(build: build, message: "\(error)")
                }
            }
            // The import leaves a clone in the daemon's inbox, which would
            // keep the space if the runtime were deleted later.
            try? simulators.scanAndMount()
        }

        guard waitUntil({ isRegistered(build) }, attempts: 30, interval: 2) else {
            throw RestoreError.notRegistered(build: build)
        }
        report(.imported)

        // Confirmed internal: forget the offload.
        var manifest = try store.load()
        manifest.runtimes.removeAll { $0.build == build }
        try store.save(manifest)

        if deleteImage {
            try imageStore.removeImage(at: plan.image)
            report(.removedImage(path: plan.image))
        } else {
            report(.keptImage(path: plan.image))
        }

        // The service may still describe the runtime at its old location.
        if !waitUntil({ listedInternally(build) != nil }, attempts: 10, interval: 1) {
            report(.restartingCoreSimulator)
            services.restartCoreSimulatorService()
            guard waitUntil({ listedInternally(build) != nil }, attempts: 15, interval: 1) else {
                throw RestoreError.notListed(build: build)
            }
        }
        report(.done(name: listedInternally(build)?.name ?? entry.name))
    }

    private func isRegistered(_ build: String) -> Bool {
        ((try? simulators.images()) ?? []).contains { $0.build == build && $0.state == "Ready" }
    }

    /// The runtime as CoreSimulator lists it, when that is no longer from the
    /// offload mount.
    private func listedInternally(_ build: String) -> Runtime? {
        ((try? simulators.runtimes()) ?? []).first {
            $0.build == build && $0.isAvailable && !$0.bundlePath.hasPrefix(paths.mountRoot + "/")
        }
    }

    private func waitUntil(_ condition: () -> Bool, attempts: Int, interval: TimeInterval) -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            pause(interval)
        }
        return condition()
    }

    private func save(_ entry: OffloadedRuntime) throws {
        var manifest = try store.load()
        guard let index = manifest.runtimes.firstIndex(where: { $0.build == entry.build }) else { return }
        manifest.runtimes[index] = entry
        try store.save(manifest)
    }

    /// A sync that is already running finishes within seconds; wait for it.
    private func acquireLock() throws -> StateLock {
        for _ in 1..<5 {
            if let lock = try? StateLock.acquire(paths: paths) { return lock }
            pause(1)
        }
        return try StateLock.acquire(paths: paths)
    }
}
