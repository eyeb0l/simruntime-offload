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

    func testParsesTheHarnessFormatAndSkipsMalformedLines() {
        let text = """
            24B8117\t11111111-2222-3333-4444-555555555555\tSimRuntimes/24B8117/a.dmg
            24A434\t11111111-2222-3333-4444-555555555555\tSimRuntimes/24A434/b.dmg
            broken line
            X\t\tmissing-uuid.dmg

            """
        let runtimes = ManifestStore.parseHarness(text)
        XCTAssertEqual(runtimes.map(\.build), ["24B8117", "24A434"])
        XCTAssertEqual(runtimes[1].imagePath, "SimRuntimes/24A434/b.dmg")
        XCTAssertNil(runtimes[0].sha256)
    }

    func testFallsBackToTheHarnessOnlyWhenThereIsNoManifest() throws {
        let store = ManifestStore(paths: paths)
        XCTAssertEqual(try store.loadIncludingHarness().source, .none)

        try FileManager.default.createDirectory(atPath: paths.stateDirectory, withIntermediateDirectories: true)
        try "24A434\tU\tp.dmg\n".write(toFile: paths.harnessManifest, atomically: true, encoding: .utf8)
        let fromHarness = try store.loadIncludingHarness()
        XCTAssertEqual(fromHarness.source, .harness)
        XCTAssertEqual(fromHarness.manifest.runtimes.map(\.build), ["24A434"])

        try store.save(Manifest(runtimes: [sample]))
        let fromManifest = try store.loadIncludingHarness()
        XCTAssertEqual(fromManifest.source, .manifest)
        XCTAssertEqual(fromManifest.manifest.runtimes.map(\.build), ["24B8117"])
    }
}
