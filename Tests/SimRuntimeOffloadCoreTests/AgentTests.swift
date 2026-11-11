import XCTest
@testable import SimRuntimeOffloadCore

final class AgentTests: ScratchTestCase {
    func testTheJobRunsSyncAtLoginAndOnMountAtNormalPriority() {
        let plist = Agent(paths: paths, runner: RecordingRunner()).propertyList(program: "/x/simruntime-offload")
        XCTAssertEqual(plist["Label"] as? String, "dev.simruntime-offload.agent")
        XCTAssertEqual(plist["ProgramArguments"] as? [String], ["/x/simruntime-offload", "sync", "--agent"])
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["StartOnMount"] as? Bool, true)
        XCTAssertEqual(plist["StartInterval"] as? Int, 60, "retry mount events missed while the state lock is busy")
        // Background priority delayed the agent by over a minute at login.
        XCTAssertEqual(plist["ProcessType"] as? String, "Interactive")
        XCTAssertNil(plist["StandardOutPath"], "the agent writes its bounded log itself")
        XCTAssertNil(plist["StandardErrorPath"])
    }

    func testTheProgramIsNeverAShell() {
        let plist = Agent(paths: paths, runner: RecordingRunner()).propertyList(program: paths.installedExecutable)
        let program = (plist["ProgramArguments"] as! [String])[0]
        XCTAssertFalse(program.hasSuffix("/bash") || program.hasSuffix("/sh") || program.hasSuffix("/zsh"))
    }

    func testInstallsACopyOfTheExecutableOnce() throws {
        let source = "\(root!)/built"
        files.createFile(atPath: source, contents: Data("program v1".utf8))
        let agent = Agent(paths: paths, runner: RecordingRunner())

        XCTAssertTrue(try agent.installExecutable(from: source))
        XCTAssertEqual(files.contents(atPath: paths.installedExecutable), Data("program v1".utf8))
        let mode = try files.attributesOfItem(atPath: paths.installedExecutable)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o755)

        // An identical copy is left alone, to keep the user's consent.
        let before = try files.attributesOfItem(atPath: paths.installedExecutable)[.systemFileNumber] as? Int
        XCTAssertFalse(try agent.installExecutable(from: source))
        let after = try files.attributesOfItem(atPath: paths.installedExecutable)[.systemFileNumber] as? Int
        XCTAssertEqual(before, after, "the installed file should not have been replaced")

        files.createFile(atPath: source, contents: Data("program v2".utf8))
        XCTAssertTrue(try agent.installExecutable(from: source))
        XCTAssertEqual(files.contents(atPath: paths.installedExecutable), Data("program v2".utf8))
    }

    func testInstallWritesTheJobAndReloadsIt() throws {
        let runner = RecordingRunner()
        try Agent(paths: paths, runner: runner).install()

        let written = try PropertyListSerialization.propertyList(
            from: try XCTUnwrap(files.contents(atPath: paths.agentPropertyList)), format: nil) as! [String: Any]
        XCTAssertEqual(written["ProgramArguments"] as? [String], [paths.installedExecutable, "sync", "--agent"])

        let domain = "gui/\(getuid())"
        XCTAssertEqual(runner.invocations, [
            ["/bin/launchctl", "bootout", "\(domain)/dev.simruntime-offload.agent"],
            ["/bin/launchctl", "bootstrap", domain, paths.agentPropertyList],
        ])
    }

    func testAJobThatWillNotLoadIsAnError() {
        let runner = RecordingRunner()
        runner.result = ProcessResult(status: 5, standardError: Data("Bootstrap failed: 5: Input/output error\n".utf8))
        XCTAssertThrowsError(try Agent(paths: paths, runner: runner).install()) { error in
            XCTAssertEqual(error as? AgentError, .couldNotLoad(message: "Bootstrap failed: 5: Input/output error"))
        }
    }

    func testUninstallRemovesTheJobAndTheInstalledCopy() throws {
        let source = "\(root!)/built"
        files.createFile(atPath: source, contents: Data("program".utf8))
        let runner = RecordingRunner()
        let agent = Agent(paths: paths, runner: runner)
        try agent.installExecutable(from: source)
        try agent.install()

        try agent.uninstall()
        XCTAssertFalse(files.fileExists(atPath: paths.agentPropertyList))
        XCTAssertFalse(files.fileExists(atPath: paths.installedExecutable))
        XCTAssertEqual(runner.invocations.last, ["/bin/launchctl", "bootout", "gui/\(getuid())/dev.simruntime-offload.agent"])
        XCTAssertNoThrow(try agent.uninstall(), "uninstalling twice is not an error")
    }
}
