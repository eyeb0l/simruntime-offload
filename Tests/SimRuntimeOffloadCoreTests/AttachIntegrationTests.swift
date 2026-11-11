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
        let sync = Sync(paths: paths, volumeLookup: { _ in volume })
        let mountPoint = paths.mountPoint(forBuild: "TEST")
        let link = "\(sharedLinks)/offload-TEST.simruntime"

        XCTAssertEqual(try sync.run(manifest: manifest, registeredRuntimes: { [] }).map(\.result), [.attached])

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

        // A second sync finds it attached and linked, and waits for CoreSimulator
        // (which will never list a fake runtime) rather than attaching again.
        guard case .needsAttention? = try sync.run(manifest: manifest, registeredRuntimes: { [] }).first?.result else {
            return XCTFail("expected needsAttention on the second run")
        }

        try Attacher().eject(mountPoint: mountPoint)
        XCTAssertFalse(fileSystem.isMountPoint(mountPoint))
        XCTAssertTrue(Registry(paths: paths).hasDanglingLink(forBuild: "TEST"))
    }
}
