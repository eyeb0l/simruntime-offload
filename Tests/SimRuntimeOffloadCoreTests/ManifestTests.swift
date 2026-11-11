import XCTest
@testable import SimRuntimeOffloadCore

final class ManifestTests: XCTestCase {
    private var home: String!
    private var paths: Paths!

    override func setUpWithError() throws {
        home = NSTemporaryDirectory() + "sro-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        paths = Paths(home: home, userID: 501)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: home)
    }

    private let sample = OffloadedRuntime(
        build: "24B8117", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-2", name: "iOS 27.2",
        volumeUUID: "11111111-2222-3333-4444-555555555555", imagePath: "SimRuntimes/24B8117/x.dmg",
        sha256: String(repeating: "a", count: 64), sizeBytes: 8_315_434_484,
        offloadedAt: Date(timeIntervalSince1970: 1_794_000_000))

    func testAMissingManifestIsEmpty() throws {
        XCTAssertEqual(try ManifestStore(paths: paths).load(), Manifest())
    }

    func testRoundTrips() throws {
        let store = ManifestStore(paths: paths)
        try store.save(Manifest(runtimes: [sample]))
        XCTAssertEqual(try store.load(), Manifest(runtimes: [sample]))
    }

    func testSavingCreatesTheStateDirectoryAndIsReadableText() throws {
        try ManifestStore(paths: paths).save(Manifest(runtimes: [sample]))
        let text = try String(contentsOfFile: paths.manifest, encoding: .utf8)
        XCTAssertTrue(text.contains("\"build\" : \"24B8117\""))
        XCTAssertTrue(text.contains("SimRuntimes/24B8117/x.dmg"), "slashes should not be escaped")
    }

    func testACorruptManifestIsAnErrorNotAnEmptyOne() throws {
        try FileManager.default.createDirectory(atPath: paths.stateDirectory, withIntermediateDirectories: true)
        try "{ not json".write(toFile: paths.manifest, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ManifestStore(paths: paths).load()) { error in
            XCTAssertEqual(error as? ManifestError, .unreadable(path: self.paths.manifest))
        }
    }

    func testAManifestFromANewerVersionIsRefused() throws {
        try FileManager.default.createDirectory(atPath: paths.stateDirectory, withIntermediateDirectories: true)
        try #"{"version": 99, "runtimes": []}"#.write(toFile: paths.manifest, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ManifestStore(paths: paths).load()) { error in
            XCTAssertEqual(error as? ManifestError, .newerVersion(found: 99))
        }
    }

    func testReadsLegacyStateButWritesTheCurrentFormat() throws {
        try FileManager.default.createDirectory(atPath: paths.stateDirectory, withIntermediateDirectories: true)
        try #"{"version":1,"runtimes":[]}"#.write(toFile: paths.manifest, atomically: true, encoding: .utf8)
        let store = ManifestStore(paths: paths)
        let old = try store.load()
        XCTAssertEqual(old.version, 1)
        try store.save(old)
        XCTAssertEqual(try store.load().version, Manifest.currentVersion)
    }

}
