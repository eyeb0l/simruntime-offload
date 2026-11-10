import XCTest
@testable import SimRuntimeOffloadCore

/// A file system described by values.
struct FakeFileSystem: FileSystemProbing {
    var files: Set<String> = []
    var mountPoints: Set<String> = []
    var links: [String: String] = [:]

    func fileExists(_ path: String) -> Bool { files.contains(path) }
    func isMountPoint(_ path: String) -> Bool { mountPoints.contains(path) }
    func symbolicLinkDestination(_ path: String) -> String? { links[path] }
    var directories: [String: [String]] = [:]
    func contentsOfDirectory(_ path: String) -> [String] { directories[path] ?? [] }
}

final class InventoryTests: XCTestCase {
    private let paths = Paths(home: "/Users/tester", userID: 501)
    private let uuid = "11111111-2222-3333-4444-555555555555"
    private var entry: OffloadedRuntime {
        OffloadedRuntime(build: "24B8117", volumeUUID: uuid, imagePath: "SimRuntimes/24B8117/x.dmg")
    }
    private let mount = "/private/tmp/simruntime-offload-501/24B8117"
    private var bundle: String { "\(mount)/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 27.2.simruntime" }
    private var volume: Volume {
        Volume(uuid: uuid, name: "External", mountPoint: "/Volumes/External", isInternal: false, freeBytes: nil)
    }
    private var registered: Runtime {
        Runtime(identifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-2", name: "iOS 27.2",
                version: "27.2", build: "24B8117", bundlePath: bundle, isAvailable: true)
    }

    /// A file system in which the runtime is fully attached and linked.
    private var healthy: FakeFileSystem {
        FakeFileSystem(
            files: ["/Volumes/External/SimRuntimes/24B8117/x.dmg"],
            mountPoints: [mount],
            links: ["\("/Library/Developer/DeviceKit/Runtimes")/offload-24B8117.simruntime": bundle])
    }

    private func state(
        fileSystem: FakeFileSystem, volume: Volume?, runtimes: [Runtime]
    ) -> OffloadedRuntimeStatus {
        InventoryBuilder(paths: paths, fileSystem: fileSystem, volumeLookup: { _ in volume })
            .status(of: entry, runtimes: runtimes)
    }

    func testFullyServedRuntimeIsActiveAndTakesCoreSimulatorsName() {
        let status = state(fileSystem: healthy, volume: volume, runtimes: [registered])
        XCTAssertEqual(status.state, .active)
        XCTAssertEqual(status.displayName, "iOS 27.2")
    }

    func testEachMissingPieceIsReportedAsTheFirstThingWrong() {
        XCTAssertEqual(state(fileSystem: healthy, volume: nil, runtimes: [registered]).state, .volumeAbsent)

        let unmounted = Volume(uuid: uuid, name: "External", mountPoint: nil, isInternal: false, freeBytes: nil)
        XCTAssertEqual(state(fileSystem: healthy, volume: unmounted, runtimes: []).state, .volumeAbsent)

        var noImage = healthy
        noImage.files = []
        XCTAssertEqual(state(fileSystem: noImage, volume: volume, runtimes: []).state, .imageMissing)

        var notAttached = healthy
        notAttached.mountPoints = []
        XCTAssertEqual(state(fileSystem: notAttached, volume: volume, runtimes: []).state, .notAttached)

        var notLinked = healthy
        notLinked.links = [:]
        XCTAssertEqual(state(fileSystem: notLinked, volume: volume, runtimes: [registered]).state, .notLinked)

        XCTAssertEqual(state(fileSystem: healthy, volume: volume, runtimes: []).state, .notRegistered)
    }

    func testALinkInThePerUserDirectoryCounts() {
        var perUser = healthy
        perUser.links = ["\(paths.perUserLinkDirectory)/offload-24B8117.simruntime": bundle]
        XCTAssertEqual(state(fileSystem: perUser, volume: volume, runtimes: [registered]).state, .active)
    }

    func testALinkPointingSomewhereElseDoesNotCount() {
        var stale = healthy
        stale.links = ["\("/Library/Developer/DeviceKit/Runtimes")/offload-24B8117.simruntime":
            "/private/tmp/simruntime-offload-501/24B81170/Library/x.simruntime"]
        XCTAssertEqual(state(fileSystem: stale, volume: volume, runtimes: [registered]).state, .notLinked)
    }

    func testARuntimeRegisteredFromElsewhereIsNotMistakenForOurs() {
        let internalCopy = Runtime(
            identifier: registered.identifier, name: "iOS 27.2", version: "27.2", build: "24B8117",
            bundlePath: "/Library/Developer/CoreSimulator/Volumes/iOS_24B8117/Library/x.simruntime", isAvailable: true)
        let status = state(fileSystem: healthy, volume: volume, runtimes: [internalCopy])
        XCTAssertEqual(status.state, .notRegistered)
        XCTAssertEqual(status.displayName, "build 24B8117")
    }

    func testBuildsTheWholeInventory() throws {
        let images = try Simulators.parseImages(fixture("simctl-runtime-list.json"))
        let inventory = InventoryBuilder(paths: paths, fileSystem: healthy, volumeLookup: { _ in self.volume })
            .build(manifest: Manifest(runtimes: [entry]), source: .harness, images: images, runtimes: [registered])
        XCTAssertEqual(inventory.internalImages.count, 2)
        XCTAssertEqual(inventory.offloaded.map(\.state), [.active])
        XCTAssertEqual(inventory.manifestSource, .harness)
    }
}
