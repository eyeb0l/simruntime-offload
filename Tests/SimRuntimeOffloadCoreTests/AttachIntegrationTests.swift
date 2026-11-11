import XCTest
@testable import SimRuntimeOffloadCore

/// Exercises the real disk-image stack with a small synthetic image.
///
/// Needs no runtime and no external disk, and touches only a scratch
/// directory. Set `SRO_SKIP_INTEGRATION=1` to skip (for example in a sandbox
/// that cannot mount).
final class AttachIntegrationTests: ScratchTestCase {
    private var image: String { "\(root!)/volume/SimRuntimes/TEST/test.dmg" }

    override func setUpWithError() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["SRO_SKIP_INTEGRATION"] != nil)
        try super.setUpWithError()

        // Build a tiny image containing an empty bundle where a runtime's would be.
        let source = "\(root!)/source"
        try files.createDirectory(
            atPath: "\(source)/\(Paths.bundleSubpath)/Test 1.0.simruntime", withIntermediateDirectories: true)
        try files.createDirectory(atPath: "\(root!)/volume/SimRuntimes/TEST", withIntermediateDirectories: true)
        if let failure = try makeTestImage(of: source, at: image, volumeName: "sro-test") {
            throw XCTSkip("could not create a test image: \(failure)")
        }
        try files.createDirectory(atPath: sharedLinks, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let paths {
            // Never leave a test image attached.
            try? Attacher().eject(mountPoint: paths.mountPoint(forBuild: "TEST"))
        }
        try super.tearDownWithError()
    }

    func testSyncAttachesLinksAndTheImageEjectsCleanly() throws {
        let volume = Volume(uuid: "U", name: "scratch", mountPoint: "\(root!)/volume", isInternal: false, freeBytes: nil)
        let manifest = Manifest(runtimes: [
            OffloadedRuntime(build: "TEST", volumeUUID: "U", imagePath: "SimRuntimes/TEST/test.dmg")
        ])
        try ManifestStore(paths: paths).save(manifest)
        let sync = Sync(paths: paths, volumeLookup: { _ in volume })
        let mountPoint = paths.mountPoint(forBuild: "TEST")
        let link = "\(sharedLinks)/offload-TEST.simruntime"

        XCTAssertEqual(try sync.run(registeredRuntimes: { [] }).map(\.result), [.attached])

        let fileSystem = FileSystem()
        XCTAssertTrue(fileSystem.isMountPoint(mountPoint))
        // The same mount, reached through the /var symlink, is still a mount point.
        XCTAssertTrue(fileSystem.isMountPoint(mountPoint.replacingOccurrences(of: "/private/var/", with: "/var/")))
        XCTAssertFalse(fileSystem.isMountPoint(mountRoot), "only the exact mount point counts")
        let destination = try XCTUnwrap(fileSystem.symbolicLinkDestination(link))
        XCTAssertEqual(destination, "\(mountPoint)/\(Paths.bundleSubpath)/Test 1.0.simruntime")
        XCTAssertTrue(files.fileExists(atPath: link), "the link should resolve")

        // The mount is read-only.
        XCTAssertFalse(files.createFile(atPath: "\(mountPoint)/probe", contents: Data()))

        let info = try SystemProcessRunner().run("/usr/sbin/diskutil", ["info", "-plist", mountPoint])
        let attachedVolume = try XCTUnwrap(Volumes.parse(info.standardOutput))
        XCTAssertEqual(try Volumes().confirmedVolume(uuid: attachedVolume.uuid)?.mountPoint, mountPoint)

        // A second sync finds it attached and linked, and waits for CoreSimulator
        // (which will never list a fake runtime) rather than attaching again.
        guard case .needsAttention? = try sync.run(registeredRuntimes: { [] }).first?.result else {
            return XCTFail("expected needsAttention on the second run")
        }

        try Attacher().eject(mountPoint: mountPoint)
        XCTAssertFalse(fileSystem.isMountPoint(mountPoint))
        XCTAssertTrue(Registry(paths: paths).hasDanglingLink(forBuild: "TEST"))
        XCTAssertNil(try Volumes().confirmedVolume(uuid: attachedVolume.uuid), "the real disk listing confirms the ejected image volume is absent")
    }
    func testOffloadAndRestoreRoundTripUsesRealImageVerificationMountsAndLinks() throws {
        let volumeRoot = "\(root!)/volume"
        let uuid = "11111111-2222-3333-4444-555555555555"
        let source = "\(root!)/internal.dmg"
        let imported = "\(root!)/imported.dmg"
        try files.moveItem(atPath: image, toPath: source)
        let expectedHash = try ImageStore().sha256(ofFile: source)
        let sim = FakeSimulators()
        let services = FakeServices()
        let runtimeID = "com.apple.CoreSimulator.SimRuntime.Test"
        func registration(at path: String) -> RuntimeImage {
            RuntimeImage(identifier: "SYNTHETIC", build: "TEST", version: "1", runtimeIdentifier: runtimeID,
                         kind: "Disk Image", state: "Ready", path: path, mountPath: nil, sizeBytes: 1_000_000,
                         deletable: true)
        }
        sim.imageList = [registration(at: source)]
        sim.onDelete = { sim, _ in
            try! self.files.removeItem(atPath: source)
            sim.imageList = []
        }
        sim.onAdd = { sim, path in
            try! self.files.copyItem(atPath: path, toPath: imported)
            sim.imageList = [registration(at: imported)]
        }
        let link = "\(sharedLinks)/offload-TEST.simruntime"
        sim.runtimeProvider = {
            let bundle: String
            if let target = try? self.files.destinationOfSymbolicLink(atPath: link), self.files.fileExists(atPath: target) {
                bundle = target
            } else if !sim.imageList.isEmpty {
                bundle = "\(self.root!)/internal-runtime.simruntime"
            } else { return [] }
            return [Runtime(identifier: runtimeID, name: "Synthetic runtime", version: "1", build: "TEST",
                            bundlePath: bundle, isAvailable: true)]
        }
        defer { sim.runtimeProvider = nil }
        let volume = Volume(uuid: uuid, name: "Scratch", mountPoint: volumeRoot, isInternal: false, freeBytes: 10_000_000_000)
        let fs = SyntheticFileSystem()
        let sync = Sync(paths: paths, fileSystem: fs, volumeLookup: { _ in volume })
        let offloader = Offloader(
            paths: paths, simulators: sim, volumeLookup: { _ in volume }, imageStore: ImageStore(),
            services: services, fileSystem: fs,
            sync: { try sync.run(holding: $0, registeredRuntimes: sim.runtimes) })
        let plan = try offloader.plan(runtime: "TEST", volumeUUID: uuid)
        try offloader.run(plan)
        XCTAssertFalse(files.fileExists(atPath: source))
        XCTAssertTrue(FileSystem().isMountPoint(paths.mountPoint(forBuild: "TEST")))
        XCTAssertTrue(files.fileExists(atPath: link))
        XCTAssertEqual(try ImageStore().sha256(ofFile: plan.destination), expectedHash)
        let restorer = Restorer(
            paths: paths, simulators: sim, volumeLookup: { _ in volume }, imageStore: ImageStore(),
            attacher: Attacher(), services: services, fileSystem: fs,
            internalFreeBytes: { 10_000_000_000 },
            sync: { try sync.run(holding: $0, registeredRuntimes: sim.runtimes) })
        try restorer.run(try restorer.plan(runtime: "TEST"), deleteImage: true, forceUnmount: false)
        XCTAssertFalse(FileSystem().isMountPoint(paths.mountPoint(forBuild: "TEST")))
        XCTAssertNil(try? files.destinationOfSymbolicLink(atPath: link))
        XCTAssertFalse(files.fileExists(atPath: plan.destination))
        XCTAssertEqual(try ImageStore().sha256(ofFile: imported), expectedHash)
        XCTAssertTrue(try ManifestStore(paths: paths).load().runtimes.isEmpty)
    }

}


/// Everything except Apple's global inboxes is real. Tests must neither
/// depend on nor change images installed elsewhere on the host.
private struct SyntheticFileSystem: FileSystemProbing {
    private let base = FileSystem()
    func fileExists(_ path: String) -> Bool { base.fileExists(path) }
    func isMountPoint(_ path: String) -> Bool { base.isMountPoint(path) }
    func symbolicLinkDestination(_ path: String) -> String? { base.symbolicLinkDestination(path) }
    func contentsOfDirectory(_ path: String) -> [String] {
        Paths.daemonInboxes.contains(path) ? [] : base.contentsOfDirectory(path)
    }
}
