import XCTest
@testable import SimRuntimeOffloadCore

/// Stands in for the disk-image stack: "attaching" creates a directory that
/// looks like a mounted runtime image.
final class FakeAttacher: ImageAttaching, FileSystemProbing {
    private(set) var attached: [String: String] = [:]   // mount point -> image
    private(set) var ejected: [String] = []
    var attachError: Error?
    var imageHasBundle = true
    private let files = FileManager.default

    func attach(image: String, at mountPoint: String) throws {
        if let attachError { throw attachError }
        attached[mountPoint] = image
        if imageHasBundle {
            try files.createDirectory(
                atPath: "\(mountPoint)/\(Paths.bundleSubpath)/iOS 27.0.simruntime",
                withIntermediateDirectories: true)
        }
    }

    /// How many eject attempts fail as busy before one succeeds.
    var busyEjects = 0
    private(set) var forced: [String] = []

    func eject(mountPoint: String) throws {
        if busyEjects > 0 {
            busyEjects -= 1
            throw AttachError.busy(mountPoint: mountPoint, message: "at least one volume could not be unmounted")
        }
        attached[mountPoint] = nil
        ejected.append(mountPoint)
        try? files.removeItem(atPath: "\(mountPoint)/Library")
    }

    func forceEject(mountPoint: String) throws {
        attached[mountPoint] = nil
        forced.append(mountPoint)
        try? files.removeItem(atPath: "\(mountPoint)/Library")
    }

    func contentsOfDirectory(_ path: String) -> [String] {
        (try? files.contentsOfDirectory(atPath: path)) ?? []
    }

    // The file system as the fake sees it: real files, fake mounts.
    func fileExists(_ path: String) -> Bool { files.fileExists(atPath: path) }
    func isMountPoint(_ path: String) -> Bool { attached[path] != nil }
    func symbolicLinkDestination(_ path: String) -> String? {
        try? files.destinationOfSymbolicLink(atPath: path)
    }
}

final class SyncTests: ScratchTestCase {
    private let uuid = "11111111-2222-3333-4444-555555555555"
    private var attacher: FakeAttacher!
    private var volumeConnected = true

    private var volumeRoot: String { "\(root!)/volume" }
    private var entry: OffloadedRuntime {
        OffloadedRuntime(build: "24A434", volumeUUID: uuid, imagePath: "SimRuntimes/24A434/x.dmg")
    }
    private var mountPoint: String { paths.mountPoint(forBuild: "24A434") }
    private var link: String { "\(sharedLinks)/offload-24A434.simruntime" }
    private var registered: Runtime {
        Runtime(identifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0", name: "iOS 27.0", version: "27.0",
                build: "24A434", bundlePath: "\(mountPoint)/\(Paths.bundleSubpath)/iOS 27.0.simruntime", isAvailable: true)
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        attacher = FakeAttacher()
        try files.createDirectory(atPath: sharedLinks, withIntermediateDirectories: true)
        try files.createDirectory(atPath: "\(volumeRoot)/SimRuntimes/24A434", withIntermediateDirectories: true)
        files.createFile(atPath: "\(volumeRoot)/SimRuntimes/24A434/x.dmg", contents: Data())
    }

    private func sync(runtimes: [Runtime] = []) throws -> [SyncOutcome] {
        let volume = Volume(uuid: uuid, name: "External", mountPoint: volumeRoot, isInternal: false, freeBytes: nil)
        return try Sync(
            paths: paths, attacher: attacher, fileSystem: attacher,
            volumeLookup: { [volumeConnected] _ in volumeConnected ? volume : nil }
        ).run(manifest: Manifest(runtimes: [entry]), registeredRuntimes: { runtimes })
    }

    func testAnEmptyManifestDoesNothing() throws {
        let outcomes = try Sync(paths: paths, attacher: attacher, fileSystem: attacher, volumeLookup: { _ in nil })
            .run(manifest: Manifest(), registeredRuntimes: { [] })
        XCTAssertEqual(outcomes, [])
        XCTAssertFalse(files.fileExists(atPath: paths.stateDirectory), "nothing should be created")
    }

    func testAttachesAndLinksWhenTheVolumeIsPresent() throws {
        XCTAssertEqual(try sync(), [SyncOutcome(build: "24A434", result: .attached)])
        XCTAssertEqual(attacher.attached[mountPoint], "\(volumeRoot)/SimRuntimes/24A434/x.dmg")
        XCTAssertEqual(try files.destinationOfSymbolicLink(atPath: link), registered.bundlePath)
    }

    func testCreatesAPrivateMountRoot() throws {
        _ = try sync()
        let mode = try files.attributesOfItem(atPath: mountRoot)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)
    }

    func testDoesNotConsultCoreSimulatorWhenNothingIsAttachedYet() throws {
        let volume = Volume(uuid: uuid, name: "External", mountPoint: volumeRoot, isInternal: false, freeBytes: nil)
        var asked = 0
        let outcomes = try Sync(paths: paths, attacher: attacher, fileSystem: attacher, volumeLookup: { _ in volume })
            .run(manifest: Manifest(runtimes: [entry]), registeredRuntimes: { asked += 1; return [] })
        XCTAssertEqual(outcomes.map(\.result), [.attached])
        XCTAssertEqual(asked, 0, "at login the agent should attach without waiting for simctl")
    }

    func testAFailureToAskCoreSimulatorIsReportedForThatRuntime() throws {
        _ = try sync()
        let volume = Volume(uuid: uuid, name: "External", mountPoint: volumeRoot, isInternal: false, freeBytes: nil)
        let outcomes = try Sync(paths: paths, attacher: attacher, fileSystem: attacher, volumeLookup: { _ in volume })
            .run(manifest: Manifest(runtimes: [entry]), registeredRuntimes: {
                throw SimulatorsError.unreadableOutput(command: "xcrun simctl list runtimes -j")
            })
        guard case .failed(let message)? = outcomes.first?.result else { return XCTFail("expected failed") }
        XCTAssertTrue(message.contains("simctl"))
    }

    func testIsIdempotentOnceCoreSimulatorListsTheRuntime() throws {
        _ = try sync()
        XCTAssertEqual(try sync(runtimes: [registered]), [SyncOutcome(build: "24A434", result: .alreadyActive)])
        XCTAssertEqual(attacher.attached.count, 1)
    }

    func testReplacesALinkLeftDanglingByARestart() throws {
        try files.createSymbolicLink(atPath: link, withDestinationPath: "/private/tmp/gone/iOS 27.0.simruntime")
        XCTAssertEqual(try sync().map(\.result), [.attached])
        XCTAssertEqual(try files.destinationOfSymbolicLink(atPath: link), registered.bundlePath)
    }

    func testRemovesADanglingLinkWhenTheVolumeIsAbsent() throws {
        try files.createSymbolicLink(atPath: link, withDestinationPath: "/private/tmp/gone/iOS 27.0.simruntime")
        volumeConnected = false
        XCTAssertEqual(try sync().map(\.result), [.removedDanglingLink])
        XCTAssertNil(try? files.destinationOfSymbolicLink(atPath: link))
        XCTAssertTrue(attacher.attached.isEmpty)
    }

    func testWaitsQuietlyWhenTheVolumeIsAbsentAndNothingIsStale() throws {
        volumeConnected = false
        XCTAssertEqual(try sync().map(\.result), [.waitingForVolume])
    }

    func testReportsAnImageMissingFromAConnectedVolume() throws {
        try files.removeItem(atPath: "\(volumeRoot)/SimRuntimes/24A434/x.dmg")
        guard case .needsAttention(let reason)? = try sync().first?.result else {
            return XCTFail("expected needsAttention")
        }
        XCTAssertTrue(reason.contains("SimRuntimes/24A434/x.dmg"))
    }

    func testLinksAnImageThatIsAttachedButUnlinked() throws {
        _ = try sync()
        try files.removeItem(atPath: link)
        XCTAssertEqual(try sync().map(\.result), [.linked])
        XCTAssertEqual(try files.destinationOfSymbolicLink(atPath: link), registered.bundlePath)
    }

    func testLeavesAnUnregisteredRuntimeAloneAndSaysWhy() throws {
        _ = try sync()
        guard case .needsAttention(let reason)? = try sync(runtimes: []).first?.result else {
            return XCTFail("expected needsAttention")
        }
        XCTAssertTrue(reason.contains("CoreSimulator"))
        XCTAssertTrue(attacher.ejected.isEmpty, "sync never detaches")
    }

    func testAFailedAttachLeavesNoLink() throws {
        attacher.attachError = AttachError.notPermitted(image: "x")
        guard case .failed(let message)? = try sync().first?.result else {
            return XCTFail("expected failed")
        }
        XCTAssertTrue(message.contains("not permitted"))
        XCTAssertNil(try? files.destinationOfSymbolicLink(atPath: link))
    }

    func testAnImageWithoutARuntimeIsEjectedAgain() throws {
        attacher.imageHasBundle = false
        guard case .failed? = try sync().first?.result else {
            return XCTFail("expected failed")
        }
        XCTAssertEqual(attacher.ejected, [mountPoint])
        XCTAssertNil(try? files.destinationOfSymbolicLink(atPath: link))
    }

    func testRefusesAMountRootThatIsNotADirectory() throws {
        files.createFile(atPath: mountRoot, contents: Data())
        guard case .failed(let message)? = try sync().first?.result else {
            return XCTFail("expected failed")
        }
        XCTAssertTrue(message.contains("refusing to mount"))
        XCTAssertTrue(attacher.attached.isEmpty)
    }

    func testGivesWayToASyncThatIsAlreadyRunning() throws {
        try files.createDirectory(atPath: paths.stateDirectory, withIntermediateDirectories: true)
        let held = open("\(paths.stateDirectory)/sync.flock", O_CREAT | O_RDWR, 0o600)
        XCTAssertEqual(flock(held, LOCK_EX | LOCK_NB), 0)
        defer { close(held) }
        XCTAssertThrowsError(try sync()) { error in
            XCTAssertEqual(error as? SyncError, .alreadyRunning)
        }
    }

    func testOneRuntimeFailingDoesNotStopTheOthers() throws {
        let missing = OffloadedRuntime(build: "24B8117", volumeUUID: "unknown", imagePath: "nope.dmg")
        let volume = Volume(uuid: uuid, name: "External", mountPoint: volumeRoot, isInternal: false, freeBytes: nil)
        let outcomes = try Sync(
            paths: paths, attacher: attacher, fileSystem: attacher,
            volumeLookup: { $0 == self.uuid ? volume : nil }
        ).run(manifest: Manifest(runtimes: [missing, entry]), registeredRuntimes: { [] })
        XCTAssertEqual(outcomes.map(\.result), [.waitingForVolume, .attached])
    }
}
