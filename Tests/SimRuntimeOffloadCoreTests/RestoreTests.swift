import XCTest
@testable import SimRuntimeOffloadCore

/// A machine with one runtime offloaded, attached and linked, as `restore`
/// and `uninstall` find it.
class OffloadedMachineTestCase: ScratchTestCase {
    let uuid = "11111111-2222-3333-4444-555555555555"
    var simulators: FakeSimulators!
    var services: FakeServices!
    var imageStore: FakeImageStore!
    var attacher: FakeAttacher!
    var restoreEvents: [RestoreEvent] = []
    var syncs = 0
    var freeBytes: Int64? = 500_000_000_000
    var volumeConnected = true
    var onPause: (TimeInterval) -> Void = { _ in }

    var volumeRoot: String { "\(root!)/volume" }
    func imagePath(_ build: String) -> String { "\(volumeRoot)/SimRuntimes/\(build)/img.dmg" }
    func link(_ build: String) -> String { "\(sharedLinks)/offload-\(build).simruntime" }

    func entry(_ build: String) -> OffloadedRuntime {
        OffloadedRuntime(
            build: build, runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0", name: "iOS 27.0",
            volumeUUID: uuid, imagePath: "SimRuntimes/\(build)/img.dmg", sha256: "same", sizeBytes: 8_000_000_000)
    }

    func internalImage(_ build: String, state: String = "Ready") -> RuntimeImage {
        RuntimeImage(
            identifier: "IMPORTED-\(build)", build: build, version: "27.0",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0", kind: "Disk Image", state: state,
            path: "/Library/Developer/CoreSimulator/Images/x.dmg", mountPath: nil, sizeBytes: 8_000_000_000,
            deletable: true)
    }

    func internalRuntime(_ build: String) -> Runtime {
        Runtime(identifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0", name: "iOS 27.0", version: "27.0",
                build: build, bundlePath: "/Library/Developer/CoreSimulator/Volumes/iOS_\(build)/x.simruntime",
                isAvailable: true)
    }

    /// Offloads `build` in the fake world: image on the volume, attached, linked, in the manifest.
    func offload(_ build: String) throws {
        try files.createDirectory(
            atPath: (imagePath(build) as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        files.createFile(atPath: imagePath(build), contents: Data("image".utf8))
        let mountPoint = paths.mountPoint(forBuild: build)
        try files.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)
        try attacher.attach(image: imagePath(build), at: mountPoint)
        try Registry(paths: paths).link(build: build, to: "\(mountPoint)/\(Paths.bundleSubpath)/iOS 27.0.simruntime")
        let store = ManifestStore(paths: paths)
        var manifest = try store.load()
        manifest.runtimes.append(entry(build))
        try store.save(manifest)
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        simulators = FakeSimulators()
        services = FakeServices()
        imageStore = FakeImageStore()
        attacher = FakeAttacher()
        restoreEvents = []
        syncs = 0
        freeBytes = 500_000_000_000
        volumeConnected = true
        try files.createDirectory(atPath: sharedLinks, withIntermediateDirectories: true)
        try files.createDirectory(atPath: volumeRoot, withIntermediateDirectories: true)
        // By default an import works: the build becomes a ready image and an
        // available runtime at an internal path.
        simulators.onAdd = { [unowned self] simulators, path in
            let build = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            simulators.imageList.append(self.internalImage(build))
            simulators.runtimeList.append(self.internalRuntime(build))
        }
    }

    func volume(_ uuid: String) -> Volume? {
        guard volumeConnected, uuid == self.uuid else { return nil }
        return Volume(uuid: uuid, name: "External", mountPoint: volumeRoot, isInternal: false, freeBytes: nil)
    }

    func restorer() -> Restorer {
        Restorer(
            paths: paths, simulators: simulators,
            volumeLookup: { [unowned self] in self.volume($0) },
            imageStore: imageStore, attacher: attacher, services: services, fileSystem: attacher,
            internalFreeBytes: { [unowned self] in self.freeBytes },
            sync: { [unowned self] lock in
                self.syncs += 1
                // The real thing, so that a rollback really re-attaches.
                return try Sync(
                    paths: self.paths, attacher: self.attacher, fileSystem: self.attacher,
                    volumeLookup: { self.volume($0) }
                ).run(holding: lock, registeredRuntimes: { [] })
            },
            pause: { [unowned self] in self.onPause($0) },
            report: { [unowned self] in self.restoreEvents.append($0) })
    }

    func manifestBuilds() throws -> [String] {
        try ManifestStore(paths: paths).load().runtimes.map(\.build)
    }
}

final class RestoreTests: OffloadedMachineTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try offload("24A434")
    }

    private func restore(deleteImage: Bool = false, force: Bool = false) throws {
        let restorer = restorer()
        try restorer.run(try restorer.plan(runtime: "24a434"), deleteImage: deleteImage, forceUnmount: force)
    }

    private func assertStillOffloaded(file: StaticString = #filePath, line: UInt = #line) throws {
        let entry = try XCTUnwrap(try ManifestStore(paths: paths).load().runtimes.first, file: file, line: line)
        XCTAssertFalse(entry.isStaged, file: file, line: line)
        XCTAssertNotNil(attacher.attached[paths.mountPoint(forBuild: "24A434")], file: file, line: line)
        XCTAssertNotNil(try? files.destinationOfSymbolicLink(atPath: link("24A434")), file: file, line: line)
        XCTAssertTrue(files.fileExists(atPath: imagePath("24A434")), file: file, line: line)
    }

    // MARK: Planning

    func testPlanningChangesNothing() throws {
        let plan = try restorer().plan(runtime: "24A434")
        XCTAssertEqual(plan.image, imagePath("24A434"))
        XCTAssertFalse(plan.alreadyInternal)
        XCTAssertTrue(simulators.added.isEmpty)
        try assertStillOffloaded()
    }

    func testAnUnknownRuntimeIsRefused() {
        XCTAssertThrowsError(try restorer().plan(runtime: "99Z999")) {
            XCTAssertEqual($0 as? RestoreError, .notOffloaded("99Z999"))
        }
    }

    func testABootedSimulatorIsRefused() {
        simulators.deviceList = [Device(udid: "1", name: "Work iPhone", state: "Booted", runtimeIdentifier: "x", isAvailable: true)]
        XCTAssertThrowsError(try restorer().plan(runtime: "24A434")) {
            XCTAssertEqual($0 as? RestoreError, .simulatorsBooted(["Work iPhone"]))
        }
    }

    func testNeedsTheVolumeTheImageAndTheSpace() throws {
        freeBytes = 9_000_000_000   // the image plus less than the headroom
        XCTAssertThrowsError(try restorer().plan(runtime: "24A434")) { error in
            guard case .notEnoughSpace? = error as? RestoreError else { return XCTFail("\(error)") }
        }
        freeBytes = 500_000_000_000
        try files.removeItem(atPath: imagePath("24A434"))
        XCTAssertThrowsError(try restorer().plan(runtime: "24A434")) {
            XCTAssertEqual($0 as? RestoreError, .imageMissing(path: self.imagePath("24A434")))
        }
        volumeConnected = false
        XCTAssertThrowsError(try restorer().plan(runtime: "24A434")) {
            XCTAssertEqual($0 as? RestoreError, .volumeNotConnected(name: nil, uuid: self.uuid))
        }
    }

    // MARK: Execution

    func testRestoresInTheSafeOrderAndKeepsTheImage() throws {
        try restore()
        XCTAssertEqual(restoreEvents, [
            .verifyingImage, .releasing, .importing(from: imagePath("24A434")), .imported,
            .keptImage(path: imagePath("24A434")), .done(name: "iOS 27.0"),
        ])
        XCTAssertEqual(simulators.added, [imagePath("24A434")])
        XCTAssertEqual(simulators.scans, 1, "the inbox clone is cleared after an import")
        XCTAssertTrue(attacher.attached.isEmpty)
        XCTAssertNil(try? files.destinationOfSymbolicLink(atPath: link("24A434")))
        XCTAssertEqual(try manifestBuilds(), [])
        XCTAssertTrue(files.fileExists(atPath: imagePath("24A434")))
        XCTAssertTrue(imageStore.removed.isEmpty)
        XCTAssertEqual(services.serviceRestarts, 0, "no restart when the runtime is listed without one")
        XCTAssertEqual(syncs, 0)
    }

    func testDeletesTheImageOnlyWhenAskedAndOnlyAfterTheImportIsReady() throws {
        simulators.onAdd = { [unowned self] simulators, _ in
            XCTAssertTrue(self.files.fileExists(atPath: self.imagePath("24A434")))
            simulators.imageList.append(self.internalImage("24A434"))
            simulators.runtimeList.append(self.internalRuntime("24A434"))
        }
        try restore(deleteImage: true)
        XCTAssertEqual(imageStore.removed, [imagePath("24A434")])
        XCTAssertTrue(restoreEvents.contains(.removedImage(path: imagePath("24A434"))))
    }

    func testAnImageThatNoLongerMatchesItsChecksumIsNotImported() throws {
        imageStore.checksums[imagePath("24A434")] = "different"
        XCTAssertThrowsError(try restore()) {
            XCTAssertEqual($0 as? RestoreError, .imageChanged(path: self.imagePath("24A434")))
        }
        XCTAssertTrue(simulators.added.isEmpty)
        XCTAssertEqual(attacher.ejected, [], "nothing was released")
        try assertStillOffloaded()
    }

    func testAFailedImportGoesBackToBeingServedFromTheVolume() throws {
        simulators.addError = SimulatorsError.commandFailed(command: "xcrun simctl runtime add", status: 1, message: "no")
        XCTAssertThrowsError(try restore(deleteImage: true)) { error in
            guard case .importFailed(let build, _)? = error as? RestoreError else { return XCTFail("\(error)") }
            XCTAssertEqual(build, "24A434")
        }
        XCTAssertEqual(syncs, 1)
        XCTAssertTrue(imageStore.removed.isEmpty, "the image is never deleted after a failure")
        try assertStillOffloaded()
        // And the lock was released, so the agent can run again.
        XCTAssertNoThrow(try StateLock.acquire(paths: paths).release())
    }

    func testAnImportThatReportsFailureButRegisteredIsTreatedAsDone() throws {
        simulators.addError = SimulatorsError.commandFailed(command: "xcrun simctl runtime add", status: 1, message: "odd")
        simulators.onScan = { [unowned self] simulators in
            guard simulators.imageList.isEmpty else { return }
            simulators.imageList = [self.internalImage("24A434")]
            simulators.runtimeList = [self.internalRuntime("24A434")]
        }
        try restore()
        XCTAssertEqual(try manifestBuilds(), [])
        XCTAssertEqual(syncs, 0, "no rollback: a second copy must not be attached")
    }

    func testAnImageThatStaysBusyIsServedAgainUnlessForced() throws {
        attacher.busyEjects = 100
        XCTAssertThrowsError(try restore()) { error in
            guard case .stillInUse? = error as? RestoreError else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(simulators.added.isEmpty)
        XCTAssertTrue(attacher.forced.isEmpty)
        try assertStillOffloaded()

        attacher.busyEjects = 6
        try restore(force: true)
        XCTAssertEqual(attacher.forced, [paths.mountPoint(forBuild: "24A434")])
        XCTAssertEqual(try manifestBuilds(), [])
    }

    func testAnImportThatNeverBecomesReadyLeavesTheEntryStagedAndTheImageAlone() throws {
        simulators.onAdd = { [unowned self] simulators, _ in
            simulators.imageList.append(self.internalImage("24A434", state: "Verifying"))
        }
        XCTAssertThrowsError(try restore(deleteImage: true)) {
            XCTAssertEqual($0 as? RestoreError, .notRegistered(build: "24A434"))
        }
        let entry = try XCTUnwrap(try ManifestStore(paths: paths).load().runtimes.first)
        XCTAssertTrue(entry.isStaged, "so the agent does not attach a build that is half imported")
        XCTAssertTrue(files.fileExists(atPath: imagePath("24A434")))
        XCTAssertTrue(imageStore.removed.isEmpty)
    }

    func testFinishesAnInterruptedRestoreWithoutImportingTwice() throws {
        // As left by the test above, once the import has become ready.
        simulators.onAdd = { [unowned self] simulators, _ in
            simulators.imageList.append(self.internalImage("24A434", state: "Verifying"))
        }
        XCTAssertThrowsError(try restore())
        simulators.imageList = [internalImage("24A434")]
        simulators.runtimeList = [internalRuntime("24A434")]

        try restore()
        XCTAssertEqual(simulators.added.count, 1, "the second run imports nothing")
        XCTAssertTrue(restoreEvents.contains(.alreadyInternal))
        XCTAssertEqual(try manifestBuilds(), [])
    }

    func testRestartsTheServiceWhenTheRuntimeIsStillListedFromTheVolume() throws {
        let stale = Runtime(
            identifier: "x", name: "iOS 27.0", version: "27.0", build: "24A434",
            bundlePath: "\(paths.mountPoint(forBuild: "24A434"))/Library/x.simruntime", isAvailable: true)
        simulators.onAdd = { [unowned self] simulators, _ in
            simulators.imageList.append(self.internalImage("24A434"))
            simulators.runtimeList = [stale]
        }
        XCTAssertThrowsError(try restore()) {
            XCTAssertEqual($0 as? RestoreError, .notListed(build: "24A434"))
        }
        XCTAssertEqual(services.serviceRestarts, 1)
        XCTAssertEqual(try manifestBuilds(), [], "the import itself is complete")
    }

    func testHoldsTheLockSoTheAgentCannotReattachDuringTheImport() throws {
        var agentWasTurnedAway = false
        simulators.onAdd = { [unowned self] simulators, _ in
            do { _ = try StateLock.acquire(paths: self.paths) } catch { agentWasTurnedAway = true }
            simulators.imageList.append(self.internalImage("24A434"))
            simulators.runtimeList.append(self.internalRuntime("24A434"))
        }
        try restore()
        XCTAssertTrue(agentWasTurnedAway)
    }

    func testASimulatorStartedDuringHashingLeavesTheRuntimeServedAndDoesNotImport() throws {
        imageStore.onHash = { [unowned self] _ in
            self.simulators.deviceList = [Device(udid: "other", name: "Late simulator", state: "Booting",
                                                runtimeIdentifier: "other-runtime", isAvailable: true)]
        }
        XCTAssertThrowsError(try restore()) {
            XCTAssertEqual($0 as? RestoreError, .simulatorsBooted(["Late simulator"]))
        }
        XCTAssertTrue(attacher.ejected.isEmpty)
        XCTAssertTrue(simulators.added.isEmpty)
        XCTAssertEqual(services.launchHostRestarts, 0)
        try assertStillOffloaded()
    }

    func testAStaleRestorePlanCannotSkipImportAndDeleteTheExternalImage() throws {
        simulators.imageList = [internalImage("24A434")]
        let restorer = restorer()
        let stale = try restorer.plan(runtime: "24A434")
        XCTAssertTrue(stale.alreadyInternal)
        // An external actor removed the internal registration after planning.
        simulators.imageList = []
        try restorer.run(stale, deleteImage: true, forceUnmount: false)
        XCTAssertEqual(simulators.added, [imagePath("24A434")], "execution must replan under the lock")
        XCTAssertEqual(imageStore.removed.count, 1)
    }

    func testATimedOutImportStaysStagedAndDoesNotReattachAnAmbiguousCopy() throws {
        simulators.addError = ProcessRunError.timedOut(executable: "/usr/bin/xcrun", seconds: 900)
        XCTAssertThrowsError(try restore()) {
            XCTAssertEqual($0 as? RestoreError, .notRegistered(build: "24A434"))
        }
        let entry = try XCTUnwrap(try ManifestStore(paths: paths).load().runtimes.first)
        XCTAssertTrue(entry.isStaged)
        XCTAssertNil(entry.offloadSource)
        XCTAssertEqual(syncs, 0)
        XCTAssertTrue(attacher.attached.isEmpty)
        XCTAssertTrue(files.fileExists(atPath: imagePath("24A434")))
        XCTAssertNoThrow(try StateLock.acquire(paths: paths).release())
    }


    func testASimulatorStartingDuringReleaseWaitPreventsTheHelperRestartAndRollsBack() throws {
        onPause = { [unowned self] _ in
            self.simulators.deviceList = [Device(udid: "late", name: "Late simulator", state: "Booting",
                                                runtimeIdentifier: "other", isAvailable: true)]
        }
        XCTAssertThrowsError(try restore()) {
            XCTAssertEqual($0 as? RestoreError, .simulatorsBooted(["Late simulator"]))
        }
        XCTAssertEqual(services.launchHostRestarts, 0)
        XCTAssertTrue(simulators.added.isEmpty)
        XCTAssertTrue(attacher.ejected.isEmpty)
        try assertStillOffloaded()
    }

    func testAFailedImportWithAVerifyingRegistrationDoesNotAttachADuplicate() throws {
        simulators.addError = SimulatorsError.commandFailed(command: "import", status: 1, message: "unfinished")
        simulators.onScan = { [unowned self] sim in sim.imageList = [self.internalImage("24A434", state: "Verifying")] }
        XCTAssertThrowsError(try restore()) {
            XCTAssertEqual($0 as? RestoreError, .notRegistered(build: "24A434"))
        }
        XCTAssertTrue(try XCTUnwrap(ManifestStore(paths: paths).load().runtimes.first).isStaged)
        XCTAssertEqual(syncs, 0)
        XCTAssertTrue(attacher.attached.isEmpty)
        XCTAssertTrue(files.fileExists(atPath: imagePath("24A434")))
    }

}
