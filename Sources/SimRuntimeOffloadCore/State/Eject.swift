import Foundation

public enum EjectError: Error, Equatable, CustomStringConvertible {
    case simulatorsBooted([String])
    case stillInUse(build: String, message: String)
    case volumeBusy(name: String, message: String)

    public var description: String {
        switch self {
        case .simulatorsBooted(let names):
            return "these simulators are running or changing state: \(names.joined(separator: ", ")). Shut them down before retrying; no further runtime changes were made"
        case .stillInUse(let build, let message):
            return "every runtime is unregistered, but the image of \(build) is still in use (\(message)). This is usually the system's sampling daemon holding simulator binaries. Do not unplug the disk. Try `simruntime-offload eject` again shortly, or with --force-unmount; or run `simruntime-offload sync` to go back to serving the runtimes"
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

public enum EjectOutcome: Equatable, Sendable {
    /// A refreshed manifest was empty; no disk identity was checked.
    case nothingToEject
    /// Every requested volume was ejected or confirmed absent.
    case safeToUnplug
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
    /// Nil must mean confirmed absence; failures to establish identity throw.
    private let volumeLookup: (String) throws -> Volume?
    private let ejectVolume: (String) -> String?
    private let pause: (TimeInterval) -> Void
    private let report: (EjectEvent) -> Void

    public init(
        paths: Paths,
        simulators: SimulatorControlling,
        attacher: ImageAttaching,
        services: ServiceControlling,
        fileSystem: FileSystemProbing = FileSystem(),
        volumeLookup: @escaping (String) throws -> Volume?,
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

    @discardableResult
    public func run(forceUnmount: Bool) throws -> EjectOutcome {
        let booted = try simulators.devices().filter(\.requiresRuntime).map(\.name)
        guard booted.isEmpty else { throw EjectError.simulatorsBooted(booted) }

        // Held until the volume is gone, so that an agent run started by some
        // unrelated mount cannot re-attach what is being released.
        let lock = try acquireLock()
        defer { lock.release() }
        let manifest = try ManifestStore(paths: paths).load()
        guard !manifest.runtimes.isEmpty else { return .nothingToEject }
        try requireIdle()

        let releaser = Releaser(
            paths: paths, attacher: attacher, services: services, fileSystem: fileSystem, pause: pause,
            requireIdle: requireIdle)
        let builds = manifest.runtimes.map(\.build)
        for build in builds { report(.unregistering(build: build)) }
        try releaser.releaseAll(
            builds: builds, forceUnmount: forceUnmount,
            willForce: { report(.forcing(build: $0)) },
            released: { build, outcome in
                if case .ejected(let attempts) = outcome { report(.ejected(build: build, attempts: attempts)) }
            })

        var seen = Set<String>()
        for uuid in manifest.runtimes.map(\.volumeUUID) where seen.insert(uuid).inserted {
            // Attached is enough: a disk whose volume is already unmounted
            // still has to be released before the cable is pulled.
            guard let volume = try volumeLookup(uuid) else { continue }
            try requireIdle()
            if let message = ejectVolume(uuid) {
                throw EjectError.volumeBusy(name: volume.name, message: message)
            }
            report(.ejectedVolume(name: volume.name))
        }
        return .safeToUnplug
    }

    private func requireIdle() throws {
        let running = try simulators.devices().filter(\.requiresRuntime).map(\.name)
        guard running.isEmpty else { throw EjectError.simulatorsBooted(running) }
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
    let requireIdle: () throws -> Void

    /// Stops serving one runtime.
    func release(build: String, forceUnmount: Bool, willForce: () -> Void = {}) throws -> Outcome {
        var outcome = Outcome.notAttached
        try releaseAll(
            builds: [build], forceUnmount: forceUnmount,
            willForce: { _ in willForce() }, released: { _, result in outcome = result })
        return outcome
    }

    /// Stops serving several runtimes, restarting the launch helper once for
    /// all of them. One restart is quick, but restarting a helper that has
    /// only just been restarted takes about ten seconds, so a restart per
    /// runtime made every runtime after the first cost that much.
    ///
    /// Throws `EjectError.stillInUse` for the first image that stays busy when
    /// `forceUnmount` is false. Every link is already gone by then, and the
    /// images before it are ejected; `sync` puts all of it back.
    func releaseAll(
        builds: [String], forceUnmount: Bool,
        willForce: (String) -> Void = { _ in },
        released: (String, Outcome) -> Void = { _, _ in }
    ) throws {
        // Unregister everything first. CoreSimulator unloads a runtime when
        // its link goes, and with every link gone the restarted helper has no
        // offloaded runtime left to load a library from.
        let registry = Registry(paths: paths)
        try requireIdle()
        for build in builds { try registry.unlink(build: build) }

        let attached = builds.filter { fileSystem.isMountPoint(paths.mountPoint(forBuild: $0)) }
        for build in builds where !attached.contains(build) { released(build, .notAttached) }
        guard !attached.isEmpty else { return }

        pause(1)
        // The launch helper keeps a library from the runtime mapped.
        try requireIdle()
        services.restartLaunchHost()

        for build in attached {
            let mountPoint = paths.mountPoint(forBuild: build)
            released(build, try eject(mountPoint, build: build, forceUnmount: forceUnmount, willForce: willForce))
        }
    }

    private func eject(
        _ mountPoint: String, build: String, forceUnmount: Bool, willForce: (String) -> Void
    ) throws -> Outcome {
        // A shut-down simulator's processes can take a few seconds to exit,
        // longer under a debugger; retrying tells that apart from a real hold.
        var lastMessage = ""
        for attempt in 1...6 {
            do {
                try requireIdle()
                try attacher.eject(mountPoint: mountPoint)
                return .ejected(attempts: attempt)
            } catch let AttachError.busy(_, message) {
                lastMessage = message
                pause(2)
            }
        }
        guard forceUnmount else { throw EjectError.stillInUse(build: build, message: lastMessage) }
        willForce(build)
        try requireIdle()
        try attacher.forceEject(mountPoint: mountPoint)
        return .forced
    }
}
