import XCTest
@testable import SimRuntimeOffloadCore

/// A scratch directory tree standing in for a home directory, a mount root
/// and the shared link directory.
class ScratchTestCase: XCTestCase {
    var root: String!
    var paths: Paths!
    let files = FileManager.default

    var sharedLinks: String { "\(root!)/shared" }
    var mountRoot: String { "\(root!)/mnt" }

    override func setUpWithError() throws {
        // Canonicalise: the temporary directory is under /var, a link to
        // /private/var, and link targets are compared as written.
        let base = try XCTUnwrap(FileSystem.canonicalPath(NSTemporaryDirectory()))
        root = "\(base)/sro-tests-\(UUID().uuidString)"
        try files.createDirectory(atPath: "\(root!)/home", withIntermediateDirectories: true)
        paths = Paths(home: "\(root!)/home", userID: getuid(), mountRoot: mountRoot, sharedLinkDirectory: sharedLinks)
    }

    override func tearDownWithError() throws {
        try? files.removeItem(atPath: root)
    }

    /// Creates a directory that looks like a mounted runtime image and returns
    /// the path of the bundle inside it.
    @discardableResult
    func makeFakeRuntime(at mountPoint: String, named name: String = "iOS 27.0.simruntime") throws -> String {
        let bundle = "\(mountPoint)/\(Paths.bundleSubpath)/\(name)"
        try files.createDirectory(atPath: bundle, withIntermediateDirectories: true)
        return bundle
    }
}

final class RegistryTests: ScratchTestCase {
    func testUsesTheSharedDirectoryOnlyWhenItExists() throws {
        XCTAssertEqual(Registry(paths: paths).linkDirectory, paths.perUserLinkDirectory)
        try files.createDirectory(atPath: sharedLinks, withIntermediateDirectories: true)
        XCTAssertEqual(Registry(paths: paths).linkDirectory, sharedLinks)
    }

    func testFindsTheBundleInAMountedImage() throws {
        let bundle = try makeFakeRuntime(at: "\(mountRoot)/24A434")
        XCTAssertEqual(try Registry(paths: paths).bundle(inImageMountedAt: "\(mountRoot)/24A434"), bundle)
    }

    func testAnImageWithoutABundleIsAnError() throws {
        try files.createDirectory(atPath: "\(mountRoot)/empty", withIntermediateDirectories: true)
        XCTAssertThrowsError(try Registry(paths: paths).bundle(inImageMountedAt: "\(mountRoot)/empty")) { error in
            XCTAssertEqual(error as? RegistryError, .noBundle(mountPoint: "\(self.mountRoot)/empty"))
        }
    }

    func testLinksIntoThePerUserDirectoryCreatingIt() throws {
        let bundle = try makeFakeRuntime(at: "\(mountRoot)/24A434")
        let link = try Registry(paths: paths).link(build: "24A434", to: bundle)
        XCTAssertEqual(link, "\(paths.perUserLinkDirectory)/offload-24A434.simruntime")
        XCTAssertEqual(try files.destinationOfSymbolicLink(atPath: link), bundle)
    }

    func testRelinkingReplacesOurOwnLinkWhereverItWas() throws {
        let registry = Registry(paths: paths)
        let first = try makeFakeRuntime(at: "\(mountRoot)/a")
        let perUser = try registry.link(build: "24A434", to: first)

        try files.createDirectory(atPath: sharedLinks, withIntermediateDirectories: true)
        let second = try makeFakeRuntime(at: "\(mountRoot)/b")
        let shared = try registry.link(build: "24A434", to: second)

        XCTAssertEqual(shared, "\(sharedLinks)/offload-24A434.simruntime")
        XCTAssertEqual(try files.destinationOfSymbolicLink(atPath: shared), second)
        XCTAssertFalse(files.fileExists(atPath: perUser), "the old per-user link should be gone")
    }

    func testDetectsAndRemovesADanglingLink() throws {
        let registry = Registry(paths: paths)
        let bundle = try makeFakeRuntime(at: "\(mountRoot)/24A434")
        try registry.link(build: "24A434", to: bundle)
        XCTAssertFalse(registry.hasDanglingLink(forBuild: "24A434"))

        try files.removeItem(atPath: "\(mountRoot)/24A434")
        XCTAssertTrue(registry.hasDanglingLink(forBuild: "24A434"))

        try registry.unlink(build: "24A434")
        XCTAssertFalse(registry.hasDanglingLink(forBuild: "24A434"))
        XCTAssertNil(try? files.destinationOfSymbolicLink(atPath: "\(paths.perUserLinkDirectory)/offload-24A434.simruntime"))
    }

    func testUnlinkingWhenThereIsNoLinkIsNotAnError() throws {
        XCTAssertNoThrow(try Registry(paths: paths).unlink(build: "24A434"))
    }

    func testARealDirectoryAtTheLinkNameIsLeftAlone() throws {
        let squatter = "\(paths.perUserLinkDirectory)/offload-24A434.simruntime"
        try files.createDirectory(atPath: squatter, withIntermediateDirectories: true)
        XCTAssertThrowsError(try Registry(paths: paths).unlink(build: "24A434")) { error in
            XCTAssertEqual(error as? RegistryError, .occupied(path: squatter))
        }
        XCTAssertTrue(files.fileExists(atPath: squatter))
    }
}
