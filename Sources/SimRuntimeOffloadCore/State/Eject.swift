import Foundation

public enum EjectError: Error, Equatable, CustomStringConvertible {
    case simulatorsBooted([String])
    case stillInUse(build: String, message: String)
    case volumeBusy(name: String, message: String)

    public var description: String {
        switch self {
        case .simulatorsBooted(let names):
            return "these simulators are booted: \(names.joined(separator: ", ")). Shut them down first; nothing was changed"
        case .stillInUse(let build, let message):
            return "the runtime \(build) is unregistered but its volume is still in use (\(message)). This is usually the system's sampling daemon holding simulator binaries. Do not unplug the disk. Either try again shortly, or run `simruntime-offload eject --force-unmount`"
        case .volumeBusy(let name, let message):
            return "the runtimes are released but \"\(name)\" could not be ejected (\(message)). Something else is using the disk; do not unplug it"
        }
    }
}

public enum EjectEvent: Equatable, Sendable {
    case unregistering(build: String)
    case ejected(build: String, attempts: Int)
    case forcing(build: String)
    case ejectedVolume(name: String)
}

/// Releases every offloaded runtime and then the volume, so the disk can be
/// unplugged.
///
/// Nothing is unmounted while a simulator is booted, and nothing is forced
/// unless the caller asked for exactly that.
public struct Ejector {
    private let paths: Paths
    private let simulators: SimulatorControlling
    private let attacher: ImageAttaching
    private let services: ServiceControlling
    private let fileSystem: FileSystemProbing
    private let volumeLookup: (String) -> Volume?
    private let ejectVolume: (String) -> String?
    private let pause: (TimeInterval) -> Void
    private let report: (EjectEvent) -> Void

    public init(
        paths: Paths,
        simulators: SimulatorControlling,
        attacher: ImageAttaching,
        services: ServiceControlling,
        fileSystem: FileSystemProbing = FileSystem(),
        volumeLookup: @escaping (String) -> Volume?,
        ejectVolume: @escaping (String) -> String?,
        pause: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        report: @escaping (EjectEvent) -> Void = { _ in }
    ) {
        self.paths = paths
        self.simulators = simulators
        self.attacher = attacher
        self.services = services
        self.fileSystem = fileSystem
        self.volumeLookup = volumeLookup
        self.ejectVolume = ejectVolume
        self.pause = pause
        self.report = report
    }

    public func run(manifest: Manifest, forceUnmount: Bool) throws {
        let booted = try simulators.devices().filter(\.isBooted).map(\.name)
        guard booted.isEmpty else { throw EjectError.simulatorsBooted(booted) }

        // Held until the volume is gone, so that an agent run started by some
        // unrelated mount cannot re-attach what is being released.
        let lock = try acquireLock()
        defer { lock.release() }

        let releaser = Releaser(
            paths: paths, attacher: attacher, services: services, fileSystem: fileSystem, pause: pause)
        for runtime in manifest.runtimes {
            let build = runtime.build
            report(.unregistering(build: build))
            switch try releaser.release(build: build, forceUnmount: forceUnmount, willForce: { report(.forcing(build: build)) }) {
            case .notAttached, .forced: break
            case .ejected(let attempts): report(.ejected(build: build, attempts: attempts))
            }
        }

        var seen = Set<String>()
        for uuid in manifest.runtimes.map(\.volumeUUID) where seen.insert(uuid).inserted {
            // Attached is enough: a disk whose volume is already unmounted
            // still has to be released before the cable is pulled.
            guard let volume = volumeLookup(uuid) else { continue }
            if let message = ejectVolume(uuid) {
                throw EjectError.volumeBusy(name: volume.name, message: message)
            }
            report(.ejectedVolume(name: volume.name))
        }
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

/// Stops serving one runtime: removes its link and ejects its image.
///
/// Shared by `eject`, `restore` and `uninstall`. The caller is responsible
/// for having checked that no simulator is booted, and for holding the state
/// lock so that the agent does not re-attach what is released here.
struct Releaser {
    enum Outcome: Equatable {
        case notAttached
        case ejected(attempts: Int)
        case forced
    }

    let paths: Paths
    let attacher: ImageAttaching
    let services: ServiceControlling
    let fileSystem: FileSystemProbing
    let pause: (TimeInterval) -> Void

    /// Throws `EjectError.stillInUse` when the image stays busy and
    /// `forceUnmount` is false. The link is already gone by then.
    func release(build: String, forceUnmount: Bool, willForce: () -> Void = {}) throws -> Outcome {
        let mountPoint = paths.mountPoint(forBuild: build)
        // Unregister first; CoreSimulator unloads the runtime when the link
        // goes and again when asked to approve the unmount.
        try Registry(paths: paths).unlink(build: build)
        guard fileSystem.isMountPoint(mountPoint) else { return .notAttached }
        pause(1)
        // The launch helper keeps a library from the runtime mapped.
        services.restartLaunchHost()

        // A shut-down simulator's processes can take a few seconds to exit,
        // longer under a debugger; retrying tells that apart from a real hold.
        var lastMessage = ""
        for attempt in 1...6 {
            do {
                try attacher.eject(mountPoint: mountPoint)
                return .ejected(attempts: attempt)
            } catch let AttachError.busy(_, message) {
                lastMessage = message
                pause(2)
            }
        }
        guard forceUnmount else { throw EjectError.stillInUse(build: build, message: lastMessage) }
        willForce()
        try attacher.forceEject(mountPoint: mountPoint)
        return .forced
    }
}
