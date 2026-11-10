/// Restarts the two per-user CoreSimulator processes that hold on to state
/// about a runtime after it has gone. Neither is a system daemon; both are
/// relaunched on demand. Callers must first make sure no simulator is booted.
public protocol ServiceControlling {
    /// `SimLaunchHost` keeps a library mapped from every runtime it has loaded,
    /// which blocks unmounting. Apple's own delete path unmounts anyway and
    /// crashes it; restarting it first avoids that.
    func restartLaunchHost()
    /// After a runtime is deleted the service keeps it registered at its dead
    /// path and rejects the same build from elsewhere as a duplicate.
    func restartCoreSimulatorService()
}

public struct Services: ServiceControlling {
    private let userID: UInt32
    private let runner: ProcessRunning

    public init(userID: UInt32, runner: ProcessRunning = SystemProcessRunner()) {
        self.userID = userID
        self.runner = runner
    }

    public func restartLaunchHost() {
        kickstart("com.apple.CoreSimulator.SimLaunchHost-arm64")
    }

    public func restartCoreSimulatorService() {
        kickstart("com.apple.CoreSimulator.CoreSimulatorService")
    }

    /// A service that is not running cannot be restarted and does not need to
    /// be, so a failure here is not an error.
    private func kickstart(_ label: String) {
        _ = try? runner.run("/bin/launchctl", ["kickstart", "-k", "user/\(userID)/\(label)"])
    }
}
