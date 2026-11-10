/// Every path the tool reads or writes, in one place.
///
/// Nothing outside these locations (and the store on the external volume) is
/// ever written. Tests construct this with a temporary home directory.
public struct Paths: Sendable {
    public let home: String
    public let userID: UInt32
    private let mountRootOverride: String?
    private let sharedLinkDirectoryOverride: String?

    /// The overrides exist for tests, which must not touch the real locations.
    public init(
        home: String, userID: UInt32,
        mountRoot: String? = nil, sharedLinkDirectory: String? = nil
    ) {
        self.home = home
        self.userID = userID
        self.mountRootOverride = mountRoot
        self.sharedLinkDirectoryOverride = sharedLinkDirectory
    }

    public static let agentLabel = "dev.simruntime-offload.agent"

    // MARK: State on the internal disk

    public var stateDirectory: String { "\(home)/Library/Application Support/simruntime-offload" }
    public var manifest: String { "\(stateDirectory)/manifest.json" }
    public var logDirectory: String { "\(home)/Library/Logs/simruntime-offload" }
    public var agentLog: String { "\(logDirectory)/agent.log" }

    /// Where `setup` installs a copy of the tool for the login agent to run,
    /// so that the agent does not depend on a build directory, and so that its
    /// identity, which the consent to read removable volumes is tied to,
    /// changes only when the tool is deliberately updated.
    public var installedExecutable: String { "\(stateDirectory)/bin/simruntime-offload" }
    public var agentPropertyList: String { "\(home)/Library/LaunchAgents/\(Paths.agentLabel).plist" }

    // MARK: Mount points

    /// Images are mounted here because the App-Sandboxed CoreDeviceService,
    /// which drives Xcode's live device view, must be able to read the runtime,
    /// and `/private/tmp` is the one unprivileged location it is entitled to.
    public var mountRoot: String { mountRootOverride ?? "/private/tmp/simruntime-offload-\(userID)" }

    public func mountPoint(forBuild build: String) -> String { "\(mountRoot)/\(build)" }

    // MARK: Runtime links

    public static let deviceKitDirectory = "/Library/Developer/DeviceKit"

    /// A profile directory CoreSimulator watches that is neither inside the
    /// protected CoreSimulator tree nor tied to any process's home directory.
    /// Registering runtimes here is what lets Device Hub show their simulators
    /// as available. Creating it is the tool's one privileged step.
    public var sharedLinkDirectory: String {
        sharedLinkDirectoryOverride ?? "\(Paths.deviceKitDirectory)/Runtimes"
    }

    /// The name of the link that registers an offloaded build.
    public static func linkName(forBuild build: String) -> String { "offload-\(build).simruntime" }

    /// Where a runtime bundle sits inside a mounted runtime image.
    public static let bundleSubpath = "Library/Developer/CoreSimulator/Profiles/Runtimes"

    /// The fallback when the shared directory is not set up. Runtimes linked
    /// here build and run, but Device Hub labels their simulators unavailable.
    public var perUserLinkDirectory: String {
        "\(home)/Library/Developer/CoreSimulator/Profiles/Runtimes"
    }

    // MARK: System locations that are only read

    /// Where the disk-image daemon stages images. An import leaves a clone
    /// here that keeps its space allocated after the runtime is deleted, until
    /// a scan clears it; so "reclaimed" includes these being empty.
    public static let daemonInboxes = [
        "/Library/Developer/CoreSimulator/Images/Inbox",
        "/Library/Developer/CoreSimulator/Cryptex/Images/Inbox",
    ]

    public static let coreSimulatorInfoPropertyList =
        "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/Info.plist"
}
