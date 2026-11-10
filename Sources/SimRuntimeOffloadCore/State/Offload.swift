import Foundation

public enum OffloadError: Error, Equatable, CustomStringConvertible {
    case runtimeNotFound(String)
    case ambiguous(String, matches: [String])
    case alreadyOffloaded(build: String)
    case simulatorsBooted([String])
    case noVolumeChosen
    case volumeNotMounted(uuid: String)
    case internalVolume(name: String)
    case imageNotFound(path: String)
    case notEnoughSpace(neededBytes: Int64, freeBytes: Int64)
    case destinationDiffers(path: String)
    case notReclaimed(build: String)
    case notServed(build: String)

    public var description: String {
        switch self {
        case .runtimeNotFound(let name):
            return "no runtime on the internal disk matches \"\(name)\"; `simruntime-offload list` shows what is there"
        case .ambiguous(let name, let matches):
            return "\"\(name)\" matches several runtimes: \(matches.joined(separator: ", ")); use the build number or identifier"
        case .alreadyOffloaded(let build):
            return "build \(build) is already served from an external volume"
        case .simulatorsBooted(let names):
            return "these simulators are booted: \(names.joined(separator: ", ")). Shut them down first; nothing was changed"
        case .noVolumeChosen:
            return "choose the volume with --volume <UUID> (`diskutil info /Volumes/<name>` shows a volume's UUID)"
        case .volumeNotMounted(let uuid):
            return "no mounted volume has the UUID \(uuid)"
        case .internalVolume(let name):
            return "\"\(name)\" is an internal volume; offloading to it would save nothing"
        case .imageNotFound(let path):
            return "expected exactly one disk image at \(path)"
        case .notEnoughSpace(let needed, let free):
            return "the volume has \(free / 1_000_000_000) GB free; \(needed / 1_000_000_000) GB is needed"
        case .destinationDiffers(let path):
            return "\(path) already exists and is not a copy of this runtime; it has been left alone. Move or delete it, then run the command again"
        case .notReclaimed(let build):
            return "the copy on the volume is verified, but macOS did not release the internal copy of \(build). It is still installed and usable. Run `simruntime-offload offload \(build)` again later to finish"
        case .notServed(let build):
            return "the internal copy of \(build) was removed and its image is safe on the volume, but CoreSimulator does not list it yet. It should appear after your next login; `simruntime-offload doctor` will show"
        }
    }
}

/// Everything `offload` has worked out before it changes anything.
public struct OffloadPlan: Equatable, Sendable {
    public let image: RuntimeImage
    /// The disk image file on the internal disk.
    public let source: String
    public let volume: Volume
    /// Where the copy goes, as an absolute path and relative to the volume.
    public let destination: String
    public let relativeDestination: String
}

public enum OffloadEvent: Equatable, Sendable {
    case copying(from: String, to: String)
    case copyProgress(done: Int64, total: Int64)
    case reusingVerifiedCopy(path: String)
    case verified(sha256: String)
    case removingInternalCopy
    case retryingRemoval
    case reclaimed
    case restartingCoreSimulator
    case attaching
    case done(name: String)
}

/// Moves an installed runtime to an external volume.
///
/// The order is the point. The internal copy is deleted only after the copy on
/// the volume has passed both checksums, and space is reported as reclaimed
/// only after checking that the internal files are actually gone.
public struct Offloader {
    private let paths: Paths
    private let simulators: SimulatorControlling
    private let volumeLookup: (String) -> Volume?
    private let imageStore: ImageStoring
    private let services: ServiceControlling
    private let fileSystem: FileSystemProbing
    private let store: ManifestStore
    private let sync: (Manifest) throws -> [SyncOutcome]
    private let pause: (TimeInterval) -> Void
    private let report: (OffloadEvent) -> Void

    public init(
        paths: Paths,
        simulators: SimulatorControlling,
        volumeLookup: @escaping (String) -> Volume?,
        imageStore: ImageStoring,
        services: ServiceControlling,
        fileSystem: FileSystemProbing = FileSystem(),
        sync: @escaping (Manifest) throws -> [SyncOutcome],
        pause: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        report: @escaping (OffloadEvent) -> Void = { _ in }
    ) {
        self.paths = paths
        self.simulators = simulators
        self.volumeLookup = volumeLookup
        self.imageStore = imageStore
        self.services = services
        self.fileSystem = fileSystem
        self.store = ManifestStore(paths: paths)
        self.sync = sync
        self.pause = pause
        self.report = report
    }

    // MARK: Planning (read-only)

    public func plan(runtime name: String, volumeUUID: String?) throws -> OffloadPlan {
        let manifest = try store.load()
        let image: RuntimeImage
        do {
            image = try resolve(name, among: try simulators.images())
        } catch OffloadError.runtimeNotFound {
            // Say so when the reason it is not on the internal disk is that
            // it has been offloaded already.
            if let done = manifest.runtimes.first(where: {
                !$0.isStaged && $0.build.caseInsensitiveCompare(name) == .orderedSame
            }) {
                throw OffloadError.alreadyOffloaded(build: done.build)
            }
            throw OffloadError.runtimeNotFound(name)
        }
        if manifest.runtimes.contains(where: { $0.build == image.build && !$0.isStaged }) {
            throw OffloadError.alreadyOffloaded(build: image.build)
        }

        // Removing a runtime, and restarting the service afterwards, must
        // never happen underneath a running simulator.
        let booted = try simulators.devices().filter(\.isBooted).map(\.name)
        guard booted.isEmpty else { throw OffloadError.simulatorsBooted(booted) }

        let uuid = try volumeUUID ?? defaultVolume(in: manifest)
        guard let volume = volumeLookup(uuid), let volumeRoot = volume.mountPoint else {
            throw OffloadError.volumeNotMounted(uuid: uuid)
        }
        guard !volume.isInternal else { throw OffloadError.internalVolume(name: volume.name) }

        let source = try imageFile(of: image)
        // A runtime restored from this volume and offloaded again has a new
        // file name internally (CoreSimulator names imports by UUID), while
        // its image may still be on the volume under the old one. Aim at that
        // file: `run` reuses it if it is the same image and stops if it is not,
        // rather than putting a second copy beside it.
        let directory = "SimRuntimes/\(image.build)"
        let present = fileSystem.contentsOfDirectory("\(volumeRoot)/\(directory)").filter { $0.hasSuffix(".dmg") }
        let fileName = present.count == 1 ? present[0] : (source as NSString).lastPathComponent
        let relative = "\(directory)/\(fileName)"
        let destination = "\(volumeRoot)/\(relative)"

        if !fileSystem.fileExists(destination), let size = image.sizeBytes, let free = volume.freeBytes {
            let needed = size + 1_073_741_824
            guard free >= needed else {
                throw OffloadError.notEnoughSpace(neededBytes: needed, freeBytes: free)
            }
        }
        return OffloadPlan(
            image: image, source: source, volume: volume,
            destination: destination, relativeDestination: relative)
    }

    private func resolve(_ name: String, among images: [RuntimeImage]) throws -> RuntimeImage {
        let matches = images.filter {
            $0.build.caseInsensitiveCompare(name) == .orderedSame
                || $0.identifier.caseInsensitiveCompare(name) == .orderedSame
        }
        switch matches.count {
        case 0: throw OffloadError.runtimeNotFound(name)
        case 1: return matches[0]
        default: throw OffloadError.ambiguous(name, matches: matches.map(\.identifier))
        }
    }

    /// The volume already in use, when there is exactly one.
    private func defaultVolume(in manifest: Manifest) throws -> String {
        let used = Set(manifest.runtimes.map(\.volumeUUID))
        guard used.count == 1, let uuid = used.first else { throw OffloadError.noVolumeChosen }
        return uuid
    }

    /// A runtime downloaded by Xcode registers its asset directory, with the
    /// image in a `Restore` subdirectory; an imported one registers the image.
    private func imageFile(of image: RuntimeImage) throws -> String {
        if image.path.hasSuffix(".dmg"), fileSystem.fileExists(image.path) { return image.path }
        let directory = "\(image.path)/Restore"
        let images = fileSystem.contentsOfDirectory(directory).filter { $0.hasSuffix(".dmg") }
        guard images.count == 1 else { throw OffloadError.imageNotFound(path: directory) }
        return "\(directory)/\(images[0])"
    }

    // MARK: Execution

    public func run(_ plan: OffloadPlan) throws {
        let build = plan.image.build

        // 1. Copy and verify. Nothing internal has been touched yet.
        let checksum: String
        if fileSystem.fileExists(plan.destination) {
            // A previous attempt got this far. Trust nothing: compare again.
            checksum = try imageStore.sha256(ofFile: plan.source)
            guard try imageStore.sha256(ofFile: plan.destination) == checksum else {
                throw OffloadError.destinationDiffers(path: plan.destination)
            }
            report(.reusingVerifiedCopy(path: plan.destination))
        } else {
            report(.copying(from: plan.source, to: plan.destination))
            checksum = try imageStore.copyVerified(from: plan.source, to: plan.destination) { done, total in
                report(.copyProgress(done: done, total: total))
            }
        }
        report(.verified(sha256: checksum))

        // 2. Record it as staged, so that an interruption from here on leaves
        //    a record of the copy, and so that the agent does not attach a
        //    build that is still registered internally.
        let name = (try? simulators.runtimes())?.first { $0.build == build }?.name
        var entry = OffloadedRuntime(
            build: build, runtimeIdentifier: plan.image.runtimeIdentifier, name: name,
            volumeUUID: plan.volume.uuid, imagePath: plan.relativeDestination,
            sha256: checksum, sizeBytes: plan.image.sizeBytes, staged: true)
        try save(entry)

        // 3. Point of no return: remove the internal copy, and check that it
        //    is really gone rather than trusting the command's exit status.
        report(.removingInternalCopy)
        try? simulators.deleteImage(identifier: plan.image.identifier)
        try? simulators.scanAndMount()
        if !waitUntilReclaimed(plan.image) {
            // A delete can leave the image behind, re-registered by the scan
            // under a new identifier. Deleting that one is the documented fix.
            report(.retryingRemoval)
            for leftover in ((try? simulators.images()) ?? []).filter({ $0.build == build }) {
                try? simulators.deleteImage(identifier: leftover.identifier)
            }
            try? simulators.scanAndMount()
            guard waitUntilReclaimed(plan.image) else { throw OffloadError.notReclaimed(build: build) }
        }
        report(.reclaimed)

        // 4. The running service still holds the deleted runtime and would
        //    reject the same build from the volume as a duplicate.
        report(.restartingCoreSimulator)
        services.restartCoreSimulatorService()

        // 5. Serve it from the volume.
        entry.staged = nil
        entry.offloadedAt = Date()
        try save(entry)
        report(.attaching)
        // The login agent reacts to mounts and may be syncing at this very
        // moment. Wait for it rather than fail; whichever of us attaches the
        // image, the check below is what decides the outcome.
        for attempt in 1...5 {
            do {
                _ = try sync(try store.load())
                break
            } catch SyncError.alreadyRunning where attempt < 5 {
                pause(2)
            } catch SyncError.alreadyRunning {
                break
            }
        }

        let mountPoint = paths.mountPoint(forBuild: build)
        for _ in 0..<10 {
            if let served = (try? simulators.runtimes())?.first(where: { $0.bundlePath.hasPrefix(mountPoint + "/") }) {
                report(.done(name: served.name))
                return
            }
            pause(1)
        }
        throw OffloadError.notServed(build: build)
    }

    private func save(_ entry: OffloadedRuntime) throws {
        var manifest = try store.load()
        manifest.runtimes.removeAll { $0.build == entry.build }
        manifest.runtimes.append(entry)
        try store.save(manifest)
    }

    /// Whether every internal trace of the image is gone: its registration,
    /// its file, and anything left in the daemon's inboxes.
    private func isReclaimed(_ image: RuntimeImage) -> Bool {
        guard let images = try? simulators.images(), !images.contains(where: { $0.build == image.build }) else {
            return false
        }
        if fileSystem.fileExists(image.path) { return false }
        return Paths.daemonInboxes.allSatisfy { fileSystem.contentsOfDirectory($0).isEmpty }
    }

    private func waitUntilReclaimed(_ image: RuntimeImage) -> Bool {
        for _ in 0..<10 {
            if isReclaimed(image) { return true }
            pause(1.5)
        }
        return isReclaimed(image)
    }
}
