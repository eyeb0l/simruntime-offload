import XCTest
@testable import SimRuntimeOffloadCore

final class SimulatorsTests: XCTestCase {
    func testParsesInstalledImagesOfBothKinds() throws {
        let images = try Simulators.parseImages(fixture("simctl-runtime-list.json"))
        XCTAssertEqual(images.map(\.build), ["24A434", "24B8117"])

        let imported = images[0]
        XCTAssertEqual(imported.kind, "Disk Image")
        XCTAssertEqual(imported.path, "/Library/Developer/CoreSimulator/Images/3FEAF5F7-2FBB-4D87-BA62-772B4D3937D4.dmg")
        XCTAssertEqual(imported.sizeBytes, 8_067_000_161)

        let downloaded = images[1]
        XCTAssertEqual(downloaded.kind, "Patchable Cryptex Disk Image")
        XCTAssertEqual(downloaded.runtimeIdentifier, "com.apple.CoreSimulator.SimRuntime.iOS-27-2")
        XCTAssertEqual(downloaded.state, "Ready")
        XCTAssertEqual(downloaded.deletable, true)
    }

    func testAnEmptyImageListIsNotAnError() throws {
        XCTAssertEqual(try Simulators.parseImages(fixture("simctl-runtime-list-empty.json")), [])
    }

    func testParsesRuntimes() throws {
        let runtimes = try Simulators.parseRuntimes(fixture("simctl-list-runtimes.json"))
        XCTAssertEqual(runtimes.map(\.build), ["24A434", "24B8117"])
        XCTAssertEqual(runtimes[0].name, "iOS 27.0")
        XCTAssertTrue(runtimes[0].bundlePath.hasPrefix("/private/tmp/simruntime-offload-501/24A434/"))
        XCTAssertTrue(runtimes[1].isAvailable)
    }

    func testParsesDevicesWithTheirRuntime() throws {
        let devices = try Simulators.parseDevices(fixture("simctl-list-devices.json"))
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices.map(\.runtimeIdentifier), [
            "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
            "com.apple.CoreSimulator.SimRuntime.iOS-27-2",
        ])
        XCTAssertEqual(devices[0].name, "sro-offload-3")
        XCTAssertFalse(devices[0].isBooted)
    }

    func testUnreadableOutputIsReportedNotGuessed() {
        let garbage = Data("not json".utf8)
        XCTAssertThrowsError(try Simulators.parseImages(garbage))
        XCTAssertThrowsError(try Simulators.parseRuntimes(garbage))
        XCTAssertThrowsError(try Simulators.parseDevices(garbage))
    }

    func testAFailingCommandCarriesItsStatusAndMessage() {
        let simulators = Simulators(runner: StubRunner(results: [
            "/usr/bin/xcrun": ProcessResult(status: 72, standardError: Data("xcrun: error: unable to find utility\n".utf8))
        ]))
        XCTAssertThrowsError(try simulators.images()) { error in
            XCTAssertEqual(error as? SimulatorsError, .commandFailed(
                command: "xcrun simctl runtime list -j", status: 72,
                message: "xcrun: error: unable to find utility"))
        }
    }

    func testRunsSimctlAndParsesItsOutput() throws {
        let simulators = Simulators(runner: StubRunner(results: [
            "/usr/bin/xcrun": ProcessResult(status: 0, standardOutput: fixture("simctl-list-runtimes.json"))
        ]))
        XCTAssertEqual(try simulators.runtimes().count, 2)
    }
}

final class VolumesTests: XCTestCase {
    func testParsesAMountedExternalVolume() {
        let volume = Volumes.parse(fixture("diskutil-info-volume.plist"))
        XCTAssertEqual(volume?.uuid, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(volume?.name, "External")
        XCTAssertEqual(volume?.mountPoint, "/Volumes/External")
        XCTAssertEqual(volume?.isInternal, false)
        XCTAssertEqual(volume?.freeBytes, 239_328_944_128)
    }

    func testAnUnmountedVolumeHasNoMountPoint() throws {
        var plist = try PropertyListSerialization.propertyList(
            from: fixture("diskutil-info-volume.plist"), format: nil) as! [String: Any]
        plist["MountPoint"] = ""
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        XCTAssertNil(Volumes.parse(data)?.mountPoint)
    }

    func testAnUnknownVolumeIsNilNotAnError() {
        let missing = Volumes(runner: StubRunner(results: [
            "/usr/sbin/diskutil": ProcessResult(status: 1, standardError: Data("Could not find disk".utf8))
        ]))
        XCTAssertNil(missing.volume(uuid: "00000000-0000-0000-0000-000000000000"))
        XCTAssertNil(Volumes.parse(Data("not a plist".utf8)))
    }
}
