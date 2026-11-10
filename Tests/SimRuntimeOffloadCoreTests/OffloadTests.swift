import XCTest
@testable import SimRuntimeOffloadCore

final class FakeSimulators: SimulatorControlling {
    var imageList: [RuntimeImage] = []
    var runtimeList: [Runtime] = []
    var deviceList: [Device] = []
    private(set) var deleted: [String] = []
    private(set) var scans = 0
    /// What a delete does to the world; by default it removes the registration.
    var onDelete: (FakeSimulators, String) -> Void = { simulators, identifier in
        simulators.imageList.removeAll { $0.identifier == identifier }
    }
    var onScan: (FakeSimulators) -> Void = { _ in }

    func images() throws -> [RuntimeImage] { imageList }
    func runtimes() throws -> [Runtime] { runtimeList }
    func devices() throws -> [Device] { deviceList }
    func deleteImage(identifier: String) throws {
        deleted.append(identifier)
        onDelete(self, identifier)
    }
    func scanAndMount() throws {
        scans += 1
        onScan(self)
    }

    private(set) var added: [String] = []
    var addError: Error?
    /// What an import does to the world; by default nothing is registered.
    var onAdd: (FakeSimulators, String) -> Void = { _, _ in }
    func addImage(path: String) throws {
        added.append(path)
        if let addError { throw addError }
        onAdd(self, path)
    }
}

final class FakeServices: ServiceControlling {
    private(set) var launchHostRestarts = 0
    private(set) var serviceRestarts = 0
    func restartLaunchHost() { launchHostRestarts += 1 }
    func restartCoreSimulatorService() { serviceRestarts += 1 }
}

/// Copies for real (the files are tiny) but takes the checksum from a table,
/// so a test can make a copy "differ" without corrupting anything.
final class FakeImageStore: ImageStoring {
    var checksums: [String: String] = [:]
    var copyError: Error?
    private(set) var copies: [(String, String)] = []

    func copyVerified(from source: String, to destination: String, progress: (Int64, Int64) -> Void) throws -> String {
        if let copyError { throw copyError }
        try FileManager.default.createDirectory(
            atPath: (destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: source, toPath: destination)
        copies.append((source, destination))
        progress(10, 10)
        return checksums[source] ?? "same"
    }

    func sha256(ofFile path: String) throws -> String { checksums[path] ?? "same" }

    private(set) var removed: [String] = []
    func removeImage(at path: String) throws {
        removed.append(path)
        try FileManager.default.removeItem(atPath: path)
    }
}

/// Real files, with chosen directories replaced by fixed listings.
struct OverlayFileSystem: FileSystemProbing {
    let base: FakeAttacher
    var listings: () -> [String: [String]]

    func fileExists(_ path: String) -> Bool { base.fileExists(path) }
    func isMountPoint(_ path: String) -> Bool { base.isMountPoint(path) }
    func symbolicLinkDestination(_ path: String) -> String? { base.symbolicLinkDestination(path) }
    func contentsOfDirectory(_ path: String) -> [String] {
        listings()[path] ?? base.contentsOfDirectory(path)
    }
}

final class OffloadTests: ScratchTestCase {
    private let uuid = "11111111-2222-3333-4444-555555555555"
    private var simulators: FakeSimulators!
    private var services: FakeServices!
    private var imageStore: FakeImageStore!
    private var attacher: FakeAttacher!
    private var inbox: [String] = []
    private var events: [OffloadEvent] = []
    private var syncs = 0
    private var volume: Volume!

    private var assetData: String { "\(root!)/internal/abc.asset/AssetData" }
    private var source: String { "\(assetData)/Restore/img.dmg" }
    private var volumeRoot: String { "\(root!)/volume" }
    private var destination: String { "\(volumeRoot)/SimRuntimes/24A434/img.dmg" }
    private var image: RuntimeImage {
        RuntimeImage(
            identifier: "AAAA-1111", build: "24A434", version: "27.0",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
            kind: "Patchable Cryptex Disk Image", state: "Ready", path: assetData,
            mountPath: nil, sizeBytes: 1000, deletable: true)
    }
    private var served: Runtime {
        Runtime(identifier: image.runtimeIdentifier, name: "iOS 27.0", version: "27.0", build: "24A434",
                bundlePath: "\(paths.mountPoint(forBuild: "24A434"))/Library/x.simruntime", isAvailable: true)
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        simulators = FakeSimulators()
        services = FakeServices()
        imageStore = FakeImageStore()
        attacher = FakeAttacher()
        inbox = []
        events = []
        syncs = 0
        syncCollisions = 0
        volume = Volume(uuid: uuid, name: "External", mountPoint: volumeRoot, isInternal: false, freeBytes: 500_000_000_000)

        try files.createDirectory(atPath: "\(assetData)/Restore", withIntermediateDirectories: true)
        files.createFile(atPath: source, contents: Data("image".utf8))
        try files.createDirectory(atPath: volumeRoot, withIntermediateDirectories: true)

        simulators.imageList = [image]
        // By default a delete works as it should: registration and files go.
        simulators.onDelete = { [unowned self] simulators, identifier in
            simulators.imageList.removeAll { $0.identifier == identifier }
            try? self.files.removeItem(atPath: "\(self.root!)/internal/abc.asset")
        }
    }

    private var syncCollisions = 0

    private func offloader(servesAfterSync: Bool = true) -> Offloader {
        Offloader(
            paths: paths,
            simulators: simulators,
            volumeLookup: { [unowned self] in $0 == self.uuid ? self.volume : nil },
            imageStore: imageStore,
            services: services,
            fileSystem: OverlayFileSystem(base: attacher, listings: { [unowned self] in
                Dictionary(uniqueKeysWithValues: Paths.daemonInboxes.map { ($0, self.inbox) })
            }),
            sync: { [unowned self] _ in
                self.syncs += 1
                if self.syncCollisions > 0 {
                    self.syncCollisions -= 1
                    throw SyncError.alreadyRunning
                }
                if servesAfterSync { self.simulators.runtimeList = [self.served] }
                return []
            },
            pause: { _ in },
            report: { [unowned self] in self.events.append($0) })
    }

    private func savedEntry() throws -> OffloadedRuntime? {
        try ManifestStore(paths: paths).load().runtimes.first { $0.build == "24A434" }
    }

    // MARK: Planning

    func testPlansByBuildOrIdentifierIgnoringCase() throws {
        let plan = try offloader().plan(runtime: "24a434", volumeUUID: uuid)
        XCTAssertEqual(plan.source, source)
        XCTAssertEqual(plan.destination, destination)
        XCTAssertEqual(plan.relativeDestination, "SimRuntimes/24A434/img.dmg")
        XCTAssertEqual(try offloader().plan(runtime: "aaaa-1111", volumeUUID: uuid), plan)
    }

    func testPlanningChangesNothing() throws {
        _ = try offloader().plan(runtime: "24A434", volumeUUID: uuid)
        XCTAssertTrue(simulators.deleted.isEmpty)
        XCTAssertFalse(files.fileExists(atPath: destination))
        XCTAssertFalse(files.fileExists(atPath: paths.manifest))
    }

    func testAnUnknownRuntimeIsRefused() {
        XCTAssertThrowsError(try offloader().plan(runtime: "99Z999", volumeUUID: uuid)) {
            XCTAssertEqual($0 as? OffloadError, .runtimeNotFound("99Z999"))
        }
    }

    func testABootedSimulatorIsRefusedByName() {
        simulators.deviceList = [
            Device(udid: "1", name: "Work iPhone", state: "Booted", runtimeIdentifier: "x", isAvailable: true),
            Device(udid: "2", name: "Idle", state: "Shutdown", runtimeIdentifier: "x", isAvailable: true),
        ]
        XCTAssertThrowsError(try offloader().plan(runtime: "24A434", volumeUUID: uuid)) {
            XCTAssertEqual($0 as? OffloadError, .simulatorsBooted(["Work iPhone"]))
        }
    }

    func testTheVolumeMustBeChosenMountedAndExternal() throws {
        XCTAssertThrowsError(try offloader().plan(runtime: "24A434", volumeUUID: nil)) {
            XCTAssertEqual($0 as? OffloadError, .noVolumeChosen)
        }
        XCTAssertThrowsError(try offloader().plan(runtime: "24A434", volumeUUID: "other")) {
            XCTAssertEqual($0 as? OffloadError, .volumeNotMounted(uuid: "other"))
        }
        volume = Volume(uuid: uuid, name: "Macintosh HD", mountPoint: volumeRoot, isInternal: true, freeBytes: nil)
        XCTAssertThrowsError(try offloader().plan(runtime: "24A434", volumeUUID: uuid)) {
            XCTAssertEqual($0 as? OffloadError, .internalVolume(name: "Macintosh HD"))
        }
    }

    func testDefaultsToTheVolumeAlreadyInUse() throws {
        try ManifestStore(paths: paths).save(Manifest(runtimes: [
            OffloadedRuntime(build: "24B8117", volumeUUID: uuid, imagePath: "SimRuntimes/24B8117/y.dmg")
        ]))
        XCTAssertEqual(try offloader().plan(runtime: "24A434", volumeUUID: nil).volume.uuid, uuid)
    }

    func testRefusesWhenTheVolumeIsTooFull() {
        volume = Volume(uuid: uuid, name: "External", mountPoint: volumeRoot, isInternal: false, freeBytes: 1_000_000)
        XCTAssertThrowsError(try offloader().plan(runtime: "24A434", volumeUUID: uuid)) { error in
            guard case .notEnoughSpace? = error as? OffloadError else { return XCTFail("\(error)") }
        }
    }

    func testARuntimeAlreadyOffloadedIsRefused() throws {
        try ManifestStore(paths: paths).save(Manifest(runtimes: [
            OffloadedRuntime(build: "24A434", volumeUUID: uuid, imagePath: "SimRuntimes/24A434/img.dmg")
        ]))
        XCTAssertThrowsError(try offloader().plan(runtime: "24A434", volumeUUID: uuid)) {
            XCTAssertEqual($0 as? OffloadError, .alreadyOffloaded(build: "24A434"))
        }
    }

    func testOffloadingTwiceSaysItIsAlreadyDone() throws {
        let offloader = offloader()
        try offloader.run(try offloader.plan(runtime: "24A434", volumeUUID: uuid))
        // The image is no longer on the internal disk at all.
        XCTAssertThrowsError(try offloader.plan(runtime: "24a434", volumeUUID: uuid)) {
            XCTAssertEqual($0 as? OffloadError, .alreadyOffloaded(build: "24A434"))
        }
    }

    // MARK: Execution

    func testOffloadsInTheSafeOrder() throws {
        let offloader = offloader()
        try offloader.run(try offloader.plan(runtime: "24A434", volumeUUID: uuid))

        XCTAssertEqual(events.filter { if case .copyProgress = $0 { return false } else { return true } }, [
            .copying(from: source, to: destination),
            .verified(sha256: "same"),
            .removingInternalCopy,
            .reclaimed,
            .restartingCoreSimulator,
            .attaching,
            .done(name: "iOS 27.0"),
        ])
        XCTAssertEqual(simulators.deleted, ["AAAA-1111"])
        XCTAssertEqual(simulators.scans, 1, "a scan always follows a delete")
        XCTAssertEqual(services.serviceRestarts, 1)
        XCTAssertEqual(syncs, 1)

        let entry = try XCTUnwrap(try savedEntry())
        XCTAssertFalse(entry.isStaged)
        XCTAssertEqual(entry.sha256, "same")
        XCTAssertEqual(entry.imagePath, "SimRuntimes/24A434/img.dmg")
        XCTAssertEqual(entry.volumeUUID, uuid)
        XCTAssertNotNil(entry.offloadedAt)
    }

    func testAFailedCopyDeletesNothing() throws {
        imageStore.copyError = ImageStoreError.checksumMismatch(source: "a", copy: "b")
        let offloader = offloader()
        XCTAssertThrowsError(try offloader.run(try offloader.plan(runtime: "24A434", volumeUUID: uuid)))
        XCTAssertTrue(simulators.deleted.isEmpty)
        XCTAssertNil(try savedEntry())
        XCTAssertTrue(files.fileExists(atPath: source), "the internal image must be untouched")
        XCTAssertEqual(services.serviceRestarts, 0)
    }

    func testADeleteThatLeavesTheImageIsRetriedAfterARescan() throws {
        // The first delete drops the registration but leaves the files, as
        // happened with a superseded release candidate; the scan re-registers
        // them under a new identifier; deleting that one works.
        simulators.onDelete = { [unowned self] simulators, identifier in
            simulators.imageList.removeAll { $0.identifier == identifier }
            if identifier == "BBBB-2222" { try? self.files.removeItem(atPath: "\(self.root!)/internal/abc.asset") }
        }
        simulators.onScan = { [unowned self] simulators in
            guard self.files.fileExists(atPath: self.assetData), simulators.imageList.isEmpty else { return }
            let again = self.image
            simulators.imageList = [RuntimeImage(
                identifier: "BBBB-2222", build: again.build, version: again.version,
                runtimeIdentifier: again.runtimeIdentifier, kind: "Disk Image", state: "Ready",
                path: again.path, mountPath: nil, sizeBytes: again.sizeBytes, deletable: true)]
        }
        let offloader = offloader()
        try offloader.run(try offloader.plan(runtime: "24A434", volumeUUID: uuid))

        XCTAssertEqual(simulators.deleted, ["AAAA-1111", "BBBB-2222"])
        XCTAssertTrue(events.contains(.retryingRemoval))
        XCTAssertTrue(events.contains(.reclaimed))
        XCTAssertFalse(try XCTUnwrap(try savedEntry()).isStaged)
    }

    func testALeftoverInTheDaemonsInboxCountsAsNotReclaimedUntilAScanClearsIt() throws {
        inbox = ["91C6C250.dmg"]
        var scansSeen = 0
        simulators.onScan = { [unowned self] _ in
            scansSeen += 1
            if scansSeen == 2 { self.inbox = [] }
        }
        let offloader = offloader()
        try offloader.run(try offloader.plan(runtime: "24A434", volumeUUID: uuid))
        XCTAssertTrue(events.contains(.retryingRemoval))
        XCTAssertTrue(events.contains(.reclaimed))
    }

    func testIfTheInternalCopyWillNotGoItStaysUsableAndTheEntryStaysStaged() throws {
        simulators.onDelete = { _, _ in }   // nothing is ever removed
        let offloader = offloader()
        XCTAssertThrowsError(try offloader.run(try offloader.plan(runtime: "24A434", volumeUUID: uuid))) {
            XCTAssertEqual($0 as? OffloadError, .notReclaimed(build: "24A434"))
        }
        XCTAssertTrue(try XCTUnwrap(try savedEntry()).isStaged)
        XCTAssertEqual(services.serviceRestarts, 0, "the service is not restarted for nothing")
        XCTAssertEqual(syncs, 0, "a build still installed internally must not also be attached")
        XCTAssertTrue(files.fileExists(atPath: destination), "the verified copy is kept for the next attempt")
    }

    func testResumesFromAVerifiedCopyWithoutCopyingAgain() throws {
        try files.createDirectory(atPath: (destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        files.createFile(atPath: destination, contents: Data("image".utf8))
        let offloader = offloader()
        try offloader.run(try offloader.plan(runtime: "24A434", volumeUUID: uuid))
        XCTAssertTrue(imageStore.copies.isEmpty)
        XCTAssertTrue(events.contains(.reusingVerifiedCopy(path: destination)))
        XCTAssertEqual(simulators.deleted, ["AAAA-1111"])
    }

    func testReusesAnImageLeftOnTheVolumeUnderAnotherName() throws {
        // As after `restore`, which keeps the image: the internal copy now
        // has a different file name from the one on the volume.
        let kept = "\(volumeRoot)/SimRuntimes/24A434/043-70362-657.dmg"
        try files.createDirectory(atPath: (kept as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        files.createFile(atPath: kept, contents: Data("image".utf8))

        let offloader = offloader()
        let plan = try offloader.plan(runtime: "24A434", volumeUUID: uuid)
        XCTAssertEqual(plan.destination, kept)
        try offloader.run(plan)
        XCTAssertTrue(imageStore.copies.isEmpty, "no second copy beside the first")
        XCTAssertEqual(try savedEntry()?.imagePath, "SimRuntimes/24A434/043-70362-657.dmg")
        XCTAssertEqual(try files.contentsOfDirectory(atPath: (kept as NSString).deletingLastPathComponent), ["043-70362-657.dmg"])
    }

    func testAnExistingFileThatIsNotACopyStopsEverything() throws {
        try files.createDirectory(atPath: (destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        files.createFile(atPath: destination, contents: Data("something else".utf8))
        imageStore.checksums = [source: "original", destination: "different"]
        let offloader = offloader()
        XCTAssertThrowsError(try offloader.run(try offloader.plan(runtime: "24A434", volumeUUID: uuid))) {
            XCTAssertEqual($0 as? OffloadError, .destinationDiffers(path: self.destination))
        }
        XCTAssertTrue(simulators.deleted.isEmpty)
        XCTAssertEqual(files.contents(atPath: destination), Data("something else".utf8))
    }

    func testReportsWhenCoreSimulatorDoesNotListTheRuntimeAfterwards() throws {
        let offloader = offloader(servesAfterSync: false)
        XCTAssertThrowsError(try offloader.run(try offloader.plan(runtime: "24A434", volumeUUID: uuid))) {
            XCTAssertEqual($0 as? OffloadError, .notServed(build: "24A434"))
        }
        // The offload itself is complete: recorded, and no longer staged.
        XCTAssertFalse(try XCTUnwrap(try savedEntry()).isStaged)
    }

    func testWaitsForTheAgentWhenItIsSyncingAtTheSameMoment() throws {
        syncCollisions = 2
        let offloader = offloader()
        try offloader.run(try offloader.plan(runtime: "24A434", volumeUUID: uuid))
        XCTAssertEqual(syncs, 3)
        XCTAssertTrue(events.contains(.done(name: "iOS 27.0")))
    }

    func testAStagedEntryIsNeverAttachedBySync() throws {
        try ManifestStore(paths: paths).save(Manifest(runtimes: [
            OffloadedRuntime(build: "24A434", volumeUUID: uuid, imagePath: "SimRuntimes/24A434/img.dmg", staged: true)
        ]))
        let outcomes = try Sync(paths: paths, attacher: attacher, fileSystem: attacher, volumeLookup: { _ in self.volume })
            .run(manifest: try ManifestStore(paths: paths).load(), registeredRuntimes: { [] })
        guard case .needsAttention? = outcomes.first?.result else { return XCTFail("expected needsAttention") }
        XCTAssertTrue(attacher.attached.isEmpty)
    }
}
