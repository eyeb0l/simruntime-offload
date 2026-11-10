import XCTest
@testable import SimRuntimeOffloadCore

final class AgentTests: ScratchTestCase {
    func testTheJobRunsSyncAtLoginAndOnMountAtNormalPriority() {
        let plist = Agent(paths: paths, runner: RecordingRunner()).propertyList(program: "/x/simruntime-offload")
        XCTAssertEqual(plist["Label"] as? String, "dev.simruntime-offload.agent")
        XCTAssertEqual(plist["ProgramArguments"] as? [String], ["/x/simruntime-offload", "sync"])
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["StartOnMount"] as? Bool, true)
        // Background priority delayed the agent by over a minute at login.
        XCTAssertEqual(plist["ProcessType"] as? String, "Interactive")
        XCTAssertEqual(plist["StandardOutPath"] as? String, paths.agentLog)
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
        XCTAssertEqual(written["ProgramArguments"] as? [String], [paths.installedExecutable, "sync"])

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

final class AdoptionTests: ScratchTestCase {
    private let uuid = "11111111-2222-3333-4444-555555555555"
    private var volumeRoot: String { "\(root!)/volume" }
    private var harness: [OffloadedRuntime] {
        [OffloadedRuntime(build: "24A434", volumeUUID: uuid, imagePath: "SimRuntimes/24A434/x.dmg")]
    }
    private let checksum = String(repeating: "ab", count: 32)

    private func adopt(existing: Manifest = Manifest(), runtimes: [Runtime] = [], connected: Bool = true) -> Manifest {
        let volume = Volume(uuid: uuid, name: "External", mountPoint: volumeRoot, isInternal: false, freeBytes: nil)
        return Adoption(paths: paths, volumeLookup: { _ in connected ? volume : nil })
            .manifest(adopting: harness, existing: existing, runtimes: runtimes)
    }

    func testReadsAShasumStyleFile() {
        let text = "\(checksum)  x.dmg\n\(String(repeating: "cd", count: 32)) *other.dmg\nnot a checksum  y.dmg\n"
        XCTAssertEqual(Adoption.checksum(for: "x.dmg", in: text), checksum)
        XCTAssertEqual(Adoption.checksum(for: "other.dmg", in: text), String(repeating: "cd", count: 32))
        XCTAssertNil(Adoption.checksum(for: "y.dmg", in: text))
        XCTAssertNil(Adoption.checksum(for: "absent.dmg", in: text))
    }

    func testCompletesAnEntryFromTheVolumeAndCoreSimulator() throws {
        try files.createDirectory(atPath: "\(volumeRoot)/SimRuntimes/24A434", withIntermediateDirectories: true)
        files.createFile(atPath: "\(volumeRoot)/SimRuntimes/24A434/x.dmg", contents: Data(count: 1234))
        try "\(checksum)  x.dmg\n".write(
            toFile: "\(volumeRoot)/SimRuntimes/24A434/SHA256SUMS", atomically: true, encoding: .utf8)
        let registered = Runtime(
            identifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0", name: "iOS 27.0", version: "27.0",
            build: "24A434", bundlePath: "\(paths.mountPoint(forBuild: "24A434"))/Library/x.simruntime", isAvailable: true)

        let entry = try XCTUnwrap(adopt(runtimes: [registered]).runtimes.first)
        XCTAssertEqual(entry.sha256, checksum)
        XCTAssertEqual(entry.sizeBytes, 1234)
        XCTAssertEqual(entry.name, "iOS 27.0")
        XCTAssertEqual(entry.runtimeIdentifier, "com.apple.CoreSimulator.SimRuntime.iOS-27-0")
    }

    func testAdoptsTheBareEntryWhenTheVolumeIsAbsent() {
        XCTAssertEqual(adopt(connected: false).runtimes, harness)
    }

    func testKeepsDetailsAlreadyRecordedWhenTheyCannotBeRefreshed() {
        var known = harness[0]
        known.sha256 = checksum
        known.name = "iOS 27.0"
        let adopted = adopt(existing: Manifest(runtimes: [known]), connected: false)
        XCTAssertEqual(adopted.runtimes, [known])
    }

    func testFollowsTheHarnessWhenARuntimeWasRemovedThere() {
        let stale = OffloadedRuntime(build: "24B114", volumeUUID: uuid, imagePath: "SimRuntimes/24B114/y.dmg")
        let adopted = adopt(existing: Manifest(runtimes: [stale]), connected: false)
        XCTAssertEqual(adopted.runtimes.map(\.build), ["24A434"])
    }
}
