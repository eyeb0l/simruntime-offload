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
    private let registry: Registry
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
        self.registry = Registry(paths: paths)
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

        for runtime in manifest.runtimes {
            let mountPoint = paths.mountPoint(forBuild: runtime.build)
            // Unregister first; CoreSimulator unloads the runtime when the
            // link goes and again when asked to approve the unmount.
            report(.unregistering(build: runtime.build))
            try registry.unlink(build: runtime.build)
            guard fileSystem.isMountPoint(mountPoint) else { continue }
            pause(1)
            services.restartLaunchHost()
            try release(mountPoint, build: runtime.build, forceUnmount: forceUnmount)
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

    private func release(_ mountPoint: String, build: String, forceUnmount: Bool) throws {
        // A shut-down simulator's processes can take a few seconds to exit,
        // longer under a debugger; retrying tells that apart from a real hold.
        var lastMessage = ""
        for attempt in 1...6 {
            do {
                try attacher.eject(mountPoint: mountPoint)
                report(.ejected(build: build, attempts: attempt))
                return
            } catch let AttachError.busy(_, message) {
                lastMessage = message
                pause(2)
            }
        }
        guard forceUnmount else { throw EjectError.stillInUse(build: build, message: lastMessage) }
        report(.forcing(build: build))
        try attacher.forceEject(mountPoint: mountPoint)
    }
}
