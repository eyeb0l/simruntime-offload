import XCTest
@testable import SimRuntimeOffloadCore

final class EjectTests: ScratchTestCase {
    private let uuid = "11111111-2222-3333-4444-555555555555"
    private var simulators: FakeSimulators!
    private var services: FakeServices!
    private var attacher: FakeAttacher!
    private var events: [EjectEvent] = []
    private var ejectedVolumes: [String] = []
    private var volumeEjectMessage: String?
    private var volumeMounted = true
    private var volumeAttached = true

    private var manifest: Manifest {
        Manifest(runtimes: [
            OffloadedRuntime(build: "24A434", volumeUUID: uuid, imagePath: "SimRuntimes/24A434/a.dmg"),
            OffloadedRuntime(build: "24B8117", volumeUUID: uuid, imagePath: "SimRuntimes/24B8117/b.dmg"),
        ])
    }
    private func link(_ build: String) -> String { "\(sharedLinks)/offload-\(build).simruntime" }

    override func setUpWithError() throws {
        try super.setUpWithError()
        simulators = FakeSimulators()
        services = FakeServices()
        attacher = FakeAttacher()
        events = []
        ejectedVolumes = []
        volumeEjectMessage = nil
        volumeMounted = true
        volumeAttached = true
        try files.createDirectory(atPath: sharedLinks, withIntermediateDirectories: true)
        // Both runtimes attached and linked.
        for build in ["24A434", "24B8117"] {
            let mountPoint = paths.mountPoint(forBuild: build)
            try files.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)
            try attacher.attach(image: "/volume/\(build).dmg", at: mountPoint)
            try Registry(paths: paths).link(
                build: build, to: "\(mountPoint)/\(Paths.bundleSubpath)/iOS 27.0.simruntime")
        }
    }

    private func eject(force: Bool = false) throws {
        try Ejector(
            paths: paths, simulators: simulators, attacher: attacher, services: services, fileSystem: attacher,
            volumeLookup: { [unowned self] uuid in
                guard self.volumeAttached else { return nil }
                return Volume(uuid: uuid, name: "External", mountPoint: self.volumeMounted ? "/Volumes/External" : nil,
                              isInternal: false, freeBytes: nil)
            },
            ejectVolume: { [unowned self] uuid in
                if self.volumeEjectMessage == nil { self.ejectedVolumes.append(uuid) }
                return self.volumeEjectMessage
            },
            pause: { _ in },
            report: { [unowned self] in self.events.append($0) }
        ).run(manifest: manifest, forceUnmount: force)
    }

    func testRefusesWhileASimulatorIsBootedAndTouchesNothing() {
        simulators.deviceList = [Device(udid: "1", name: "Work iPhone", state: "Booted", runtimeIdentifier: "x", isAvailable: true)]
        XCTAssertThrowsError(try eject()) {
            XCTAssertEqual($0 as? EjectError, .simulatorsBooted(["Work iPhone"]))
        }
        XCTAssertEqual(attacher.attached.count, 2)
        XCTAssertNotNil(try? files.destinationOfSymbolicLink(atPath: link("24A434")))
        XCTAssertEqual(services.launchHostRestarts, 0)
        XCTAssertTrue(ejectedVolumes.isEmpty)
    }

    func testReleasesEveryRuntimeThenTheVolumeOnce() throws {
        try eject()
        XCTAssertEqual(events, [
            .unregistering(build: "24A434"), .ejected(build: "24A434", attempts: 1),
            .unregistering(build: "24B8117"), .ejected(build: "24B8117", attempts: 1),
            .ejectedVolume(name: "External"),
        ])
        XCTAssertTrue(attacher.attached.isEmpty)
        XCTAssertNil(try? files.destinationOfSymbolicLink(atPath: link("24A434")))
        XCTAssertNil(try? files.destinationOfSymbolicLink(atPath: link("24B8117")))
        XCTAssertEqual(services.launchHostRestarts, 2, "the helper is restarted before each eject")
        XCTAssertEqual(ejectedVolumes, [uuid], "two runtimes on one volume eject it once")
        XCTAssertTrue(attacher.forced.isEmpty)
    }

    func testRetriesAVolumeThatIsBrieflyBusy() throws {
        attacher.busyEjects = 2
        try eject()
        XCTAssertTrue(events.contains(.ejected(build: "24A434", attempts: 3)))
        XCTAssertTrue(attacher.forced.isEmpty)
    }

    func testAPersistentHoldStopsWithoutForcingAndWithoutEjectingTheVolume() {
        attacher.busyEjects = 100
        XCTAssertThrowsError(try eject()) { error in
            guard case .stillInUse(let build, _)? = error as? EjectError else { return XCTFail("\(error)") }
            XCTAssertEqual(build, "24A434")
        }
        XCTAssertTrue(attacher.forced.isEmpty, "never forced unless asked")
        XCTAssertTrue(ejectedVolumes.isEmpty, "the disk must not be reported safe")
        XCTAssertFalse(events.contains { if case .ejectedVolume = $0 { return true } else { return false } })
    }

    func testForcesOnlyWhenAskedAndOnlyAfterRetrying() throws {
        attacher.busyEjects = 6   // exactly the retries for the first runtime
        try eject(force: true)
        XCTAssertEqual(attacher.forced, [paths.mountPoint(forBuild: "24A434")])
        XCTAssertTrue(events.contains(.forcing(build: "24A434")))
        XCTAssertTrue(events.contains(.ejected(build: "24B8117", attempts: 1)), "the second runtime ejects normally")
        XCTAssertEqual(ejectedVolumes, [uuid])
    }

    func testARuntimeThatIsNotAttachedIsJustUnlinked() throws {
        try attacher.eject(mountPoint: paths.mountPoint(forBuild: "24A434"))
        let restartsBefore = services.launchHostRestarts
        try eject()
        XCTAssertNil(try? files.destinationOfSymbolicLink(atPath: link("24A434")))
        XCTAssertEqual(services.launchHostRestarts - restartsBefore, 1, "only the attached runtime needs the helper restarted")
    }

    func testAVolumeThatWillNotEjectIsReportedAsNotSafe() {
        volumeEjectMessage = "Volume failed to eject: in use"
        XCTAssertThrowsError(try eject()) {
            XCTAssertEqual($0 as? EjectError, .volumeBusy(name: "External", message: "Volume failed to eject: in use"))
        }
        XCTAssertTrue(attacher.attached.isEmpty, "the runtimes were still released")
    }

    func testHoldsTheSyncLockSoTheAgentCannotReattachMidway() throws {
        var syncRefusedDuringEject = false
        try Ejector(
            paths: paths, simulators: simulators, attacher: attacher, services: services, fileSystem: attacher,
            volumeLookup: { Volume(uuid: $0, name: "External", mountPoint: "/Volumes/External", isInternal: false, freeBytes: nil) },
            ejectVolume: { [unowned self] _ in
                // What the agent would do if a mount woke it at this moment.
                do {
                    _ = try Sync(paths: self.paths, attacher: self.attacher, fileSystem: self.attacher, volumeLookup: { _ in nil })
                        .run(manifest: self.manifest, registeredRuntimes: { [] })
                } catch SyncError.alreadyRunning {
                    syncRefusedDuringEject = true
                } catch {}
                return nil
            },
            pause: { _ in }
        ).run(manifest: manifest, forceUnmount: false)
        XCTAssertTrue(syncRefusedDuringEject)
        XCTAssertTrue(attacher.attached.isEmpty)
        // And the lock is released afterwards.
        XCTAssertNoThrow(try StateLock.acquire(paths: paths).release())
    }

    func testWaitsOutASyncThatIsAlreadyRunningAndFailsIfItNeverEnds() throws {
        let held = try StateLock.acquire(paths: paths)
        XCTAssertThrowsError(try eject()) { XCTAssertEqual($0 as? SyncError, .alreadyRunning) }
        XCTAssertEqual(attacher.attached.count, 2, "nothing is released without the lock")
        held.release()
        try eject()
        XCTAssertTrue(attacher.attached.isEmpty)
    }

    func testAnAbsentVolumeIsNotEjected() throws {
        volumeAttached = false
        try eject()
        XCTAssertTrue(ejectedVolumes.isEmpty)
    }

    func testADiskWhoseVolumeIsOnlyUnmountedIsStillReleased() throws {
        volumeMounted = false
        try eject()
        XCTAssertEqual(ejectedVolumes, [uuid])
    }
}

final class AttacherForceTests: XCTestCase {
    func testFindsTheImageDeviceBehindAVolume() throws {
        let plist: [String: Any] = [
            "DeviceIdentifier": "disk11s1",
            "APFSPhysicalStores": [["APFSPhysicalStore": "disk10s1"]],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        XCTAssertEqual(Attacher.parseWholeDisk(data), "disk10")
        XCTAssertNil(Attacher.parseWholeDisk(Data("nonsense".utf8)))
    }

    func testForceEjectUnmountsByForceAndNothingElseDoes() throws {
        let runner = RecordingRunner()
        try Attacher(runner: runner).forceEject(mountPoint: "/m")
        XCTAssertTrue(runner.invocations.contains(["/usr/sbin/diskutil", "unmount", "force", "/m"]))

        let plain = RecordingRunner()
        try Attacher(runner: plain).eject(mountPoint: "/m")
        XCTAssertFalse(plain.invocations.joined().contains("force"))
    }
}
