import XCTest
@testable import SimRuntimeOffloadCore

final class UninstallTests: OffloadedMachineTestCase {
    private var runner: RecordingRunner!
    private var events: [UninstallEvent] = []
    private var onEvent: (UninstallEvent) -> Void = { _ in }

    override func setUpWithError() throws {
        try super.setUpWithError()
        runner = RecordingRunner()
        events = []
        try offload("24A434")
        try offload("24B8117")
        // What `setup` installs.
        let agent = Agent(paths: paths, runner: runner)
        try files.createDirectory(
            atPath: (paths.installedExecutable as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        files.createFile(atPath: paths.installedExecutable, contents: Data("binary".utf8))
        try files.createDirectory(
            atPath: (paths.agentPropertyList as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try PropertyListSerialization.data(
            fromPropertyList: agent.propertyList(program: paths.installedExecutable), format: .xml, options: 0
        ).write(to: URL(fileURLWithPath: paths.agentPropertyList))
        try files.createDirectory(atPath: paths.logDirectory, withIntermediateDirectories: true)
        files.createFile(atPath: paths.agentLog, contents: Data("log".utf8))
    }

    private func uninstaller() -> Uninstaller {
        Uninstaller(
            paths: paths, simulators: simulators, restorer: restorer(), attacher: attacher, services: services,
            agent: Agent(paths: paths, runner: runner), fileSystem: attacher,
            volumeLookup: { [unowned self] in self.volume($0) },
            pause: { _ in },
            report: { [unowned self] in self.events.append($0); self.onEvent($0) })
    }

    private func uninstall(leave: Bool = false) throws -> UninstallSummary {
        let uninstaller = uninstaller()
        return try uninstaller.run(try uninstaller.plan(leaveRuntimesOnVolume: leave), forceUnmount: false)
    }

    private func assertNothingOfOursRemains(file: StaticString = #filePath, line: UInt = #line) {
        for path in [paths.stateDirectory, paths.logDirectory, paths.agentPropertyList, paths.mountRoot] {
            XCTAssertFalse(files.fileExists(atPath: path), path, file: file, line: line)
        }
        XCTAssertEqual(try? files.contentsOfDirectory(atPath: sharedLinks), [], file: file, line: line)
        XCTAssertTrue(runner.invocations.contains { $0.contains("bootout") }, file: file, line: line)
    }

    func testRestoresEveryRuntimeThenRemovesEverythingButTheImages() throws {
        let summary = try uninstall()
        XCTAssertEqual(simulators.added, [imagePath("24A434"), imagePath("24B8117")])
        XCTAssertEqual(events, [.restoring(build: "24A434"), .restoring(build: "24B8117"), .removedAgent])
        assertNothingOfOursRemains()
        XCTAssertEqual(summary.left, [])
        XCTAssertEqual(summary.imagesKept, [imagePath("24A434"), imagePath("24B8117")])
        XCTAssertTrue(files.fileExists(atPath: imagePath("24A434")))
        XCTAssertTrue(files.fileExists(atPath: imagePath("24B8117")))
        XCTAssertEqual(summary.sharedLinkDirectory, sharedLinks, "left for the user to remove with sudo")
        XCTAssertTrue(files.fileExists(atPath: sharedLinks))
    }

    func testPlanningChangesNothing() throws {
        let plan = try uninstaller().plan(leaveRuntimesOnVolume: false)
        XCTAssertEqual(plan.restores.map(\.entry.build), ["24A434", "24B8117"])
        XCTAssertTrue(simulators.added.isEmpty)
        XCTAssertEqual(attacher.attached.count, 2)
        XCTAssertTrue(files.fileExists(atPath: paths.agentPropertyList))
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testAMissingVolumeStopsEverythingBeforeAnythingChanges() throws {
        volumeConnected = false
        XCTAssertThrowsError(try uninstall()) { error in
            guard case .volumeNotConnected? = error as? RestoreError else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(files.fileExists(atPath: paths.agentPropertyList))
        XCTAssertEqual(try manifestBuilds(), ["24A434", "24B8117"])
        XCTAssertTrue(runner.invocations.isEmpty, "the agent is still loaded")
    }

    func testOneUnrestorableRuntimeStopsEverythingBeforeAnyIsRestored() throws {
        try files.removeItem(atPath: imagePath("24B8117"))
        XCTAssertThrowsError(try uninstall())
        XCTAssertTrue(simulators.added.isEmpty, "the first runtime was not restored either")
        XCTAssertEqual(attacher.attached.count, 2)
    }

    func testTheRuntimesTogetherMustFitOnTheInternalDisk() {
        freeBytes = 12_000_000_000   // enough for either, not for both
        XCTAssertThrowsError(try uninstall()) { error in
            guard case .notEnoughSpace? = error as? UninstallError else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(simulators.added.isEmpty)
    }

    func testABootedSimulatorIsRefused() {
        simulators.deviceList = [Device(udid: "1", name: "Work iPhone", state: "Booted", runtimeIdentifier: "x", isAvailable: true)]
        XCTAssertThrowsError(try uninstall(leave: true)) {
            XCTAssertEqual($0 as? UninstallError, .simulatorsBooted(["Work iPhone"]))
        }
        XCTAssertEqual(attacher.attached.count, 2)
    }

    func testCanLeaveTheRuntimesOnTheVolumeWithoutImportingAnything() throws {
        let summary = try uninstall(leave: true)
        XCTAssertTrue(simulators.added.isEmpty)
        XCTAssertEqual(events, [.removedAgent, .stoppedServing(build: "24A434"), .stoppedServing(build: "24B8117")])
        XCTAssertTrue(attacher.attached.isEmpty)
        assertNothingOfOursRemains()
        XCTAssertEqual(summary.imagesKept, [imagePath("24A434"), imagePath("24B8117")])
        XCTAssertTrue(files.fileExists(atPath: imagePath("24A434")))
    }

    func testLeavingRuntimesWorksWithTheVolumeUnplugged() throws {
        // As after an abrupt disconnection: the mounts are gone, the links dangle.
        for build in ["24A434", "24B8117"] { try attacher.eject(mountPoint: paths.mountPoint(forBuild: build)) }
        volumeConnected = false
        let summary = try uninstall(leave: true)
        assertNothingOfOursRemains()
        XCTAssertEqual(summary.imagesKept.count, 2)
        XCTAssertTrue(summary.imagesKept[0].contains(uuid), "named by volume when the volume is not there")
    }

    func testFilesThatAreNotOursAreLeftAndNamed() throws {
        files.createFile(atPath: "\(paths.stateDirectory)/notes.txt", contents: Data("mine".utf8))
        let summary = try uninstall(leave: true)
        XCTAssertTrue(files.fileExists(atPath: "\(paths.stateDirectory)/notes.txt"))
        XCTAssertEqual(summary.left, ["\(paths.stateDirectory) (contains notes.txt)"])
        XCTAssertFalse(files.fileExists(atPath: paths.manifest))
    }

    func testWithNothingOffloadedItJustRemovesItself() throws {
        _ = try uninstall(leave: true)
        // A second run finds nothing and fails at nothing.
        runner = RecordingRunner()
        let summary = try uninstall()
        XCTAssertEqual(summary.removed, [])
        XCTAssertEqual(summary.left, [])
    }

    func testRemovesImageChecksumAndEmptyDirectoryButNothingElse() throws {
        let directory = "\(root!)/v/SimRuntimes/B1"
        try files.createDirectory(atPath: directory, withIntermediateDirectories: true)
        files.createFile(atPath: "\(directory)/a.dmg", contents: Data("x".utf8))
        files.createFile(atPath: "\(directory)/SHA256SUMS", contents: Data("x".utf8))
        try ImageStore().removeImage(at: "\(directory)/a.dmg")
        XCTAssertFalse(files.fileExists(atPath: directory))

        try files.createDirectory(atPath: "\(directory)/asset-metadata", withIntermediateDirectories: true)
        files.createFile(atPath: "\(directory)/a.dmg", contents: Data("x".utf8))
        try ImageStore().removeImage(at: "\(directory)/a.dmg")
        XCTAssertTrue(files.fileExists(atPath: "\(directory)/asset-metadata"), "anything else keeps the directory")
    }

    func testUninstallHoldsOneStableLockFromAgentRemovalThroughCleanup() throws {
        var checked = false
        onEvent = { [unowned self] event in
            guard event == .removedAgent else { return }
            checked = true
            do {
                let unexpected = try StateLock.acquire(paths: self.paths)
                unexpected.release()
                XCTFail("uninstall must keep the state lock through agent removal")
            } catch { XCTAssertEqual(error as? SyncError, .alreadyRunning) }
        }
        let originalLock = try StateLock.acquire(paths: paths)
        originalLock.release()
        let inode = try files.attributesOfItem(atPath: paths.lockFile)[.systemFileNumber] as? NSNumber
        _ = try uninstall(leave: true)
        XCTAssertTrue(checked)
        XCTAssertTrue(files.fileExists(atPath: paths.lockFile))
        XCTAssertEqual(try files.attributesOfItem(atPath: paths.lockFile)[.systemFileNumber] as? NSNumber, inode)
        XCTAssertNoThrow(try StateLock.acquire(paths: paths).release())
        assertNothingOfOursRemains()
    }

    func testUninstallReplansToIncludeARuntimeAddedAfterItsPreview() throws {
        let uninstaller = uninstaller()
        let preview = try uninstaller.plan(leaveRuntimesOnVolume: false)
        try offload("NEW-BUILD")
        _ = try uninstaller.run(preview, forceUnmount: false)
        XCTAssertEqual(simulators.added.count, 3)
        XCTAssertTrue(simulators.added.contains(imagePath("NEW-BUILD")))
        assertNothingOfOursRemains()
    }

    func testUninstallRemovesBothBoundedLogFiles() throws {
        try Data("previous log".utf8).write(to: URL(fileURLWithPath: paths.agentLog + ".1"))
        _ = try uninstall(leave: true)
        XCTAssertFalse(files.fileExists(atPath: paths.agentLog + ".1"))
        assertNothingOfOursRemains()
    }


    func testUninstallCleansUpTheLegacyLockButRetainsThePermanentOne() throws {
        let legacy = "\(paths.stateDirectory)/sync.flock"
        try Data().write(to: URL(fileURLWithPath: legacy))
        _ = try uninstall(leave: true)
        XCTAssertFalse(files.fileExists(atPath: legacy))
        XCTAssertTrue(files.fileExists(atPath: paths.lockFile))
        assertNothingOfOursRemains()
    }

}
