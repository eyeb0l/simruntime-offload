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

    func testEjectsTheWholePhysicalDiskNotJustTheVolume() throws {
        let runner = RecordingRunner()
        runner.result = ProcessResult(status: 0, standardOutput: fixture("diskutil-info-volume.plist"))
        XCTAssertNil(Volumes(runner: runner).eject(uuid: "11111111-2222-3333-4444-555555555555"))
        // The volume is disk7s1 in container disk7, whose store is disk6s2.
        XCTAssertEqual(Volumes.physicalDisk(fixture("diskutil-info-volume.plist")), "disk6")
        XCTAssertEqual(runner.invocations.last, ["/usr/sbin/diskutil", "eject", "disk6"])
    }

    func testNeverEjectsAnInternalDisk() throws {
        var plist = try PropertyListSerialization.propertyList(
            from: fixture("diskutil-info-volume.plist"), format: nil) as! [String: Any]
        plist["Internal"] = true
        let runner = RecordingRunner()
        runner.result = ProcessResult(
            status: 0,
            standardOutput: try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0))
        XCTAssertNotNil(Volumes(runner: runner).eject(uuid: "11111111-2222-3333-4444-555555555555"))
        XCTAssertFalse(runner.invocations.contains { $0.contains("eject") })
    }

    func testFallsBackToTheParentDiskForANonAPFSVolume() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["ParentWholeDisk": "disk9", "DeviceIdentifier": "disk9s1"], format: .xml, options: 0)
        XCTAssertEqual(Volumes.physicalDisk(data), "disk9")
    }

    func testAnUnknownVolumeIsNilNotAnError() {
        let missing = Volumes(runner: StubRunner(results: [
            "/usr/sbin/diskutil": ProcessResult(status: 1, standardError: Data("Could not find disk".utf8))
        ]))
        XCTAssertNil(missing.volume(uuid: "00000000-0000-0000-0000-000000000000"))
        XCTAssertNil(Volumes.parse(Data("not a plist".utf8)))
    }

    func testRejectsNamesPathsAndDeviceNodesBeforeInvokingDiskutil() {
        let runner = RecordingRunner()
        let volumes = Volumes(runner: runner)
        for input in ["External", "/Volumes/External", "disk7s1", ""] {
            XCTAssertNil(volumes.volume(uuid: input))
            XCTAssertNotNil(volumes.eject(uuid: input))
        }
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testRejectsAMismatchedReturnedUUIDForLookupAndEjection() {
        let runner = RecordingRunner()
        runner.result = ProcessResult(status: 0, standardOutput: fixture("diskutil-info-volume.plist"))
        let volumes = Volumes(runner: runner)
        XCTAssertNil(volumes.volume(uuid: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        XCTAssertNotNil(volumes.eject(uuid: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        XCTAssertFalse(runner.invocations.contains { $0.contains("eject") })
    }

    func testMissingOrInvalidInternalClassificationFailsClosed() throws {
        var plist = try PropertyListSerialization.propertyList(from: fixture("diskutil-info-volume.plist"), format: nil) as! [String: Any]
        for value in [nil, "unknown"] as [String?] {
            plist["Internal"] = value
            let runner = RecordingRunner()
            runner.result = ProcessResult(status: 0, standardOutput: try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0))
            let volumes = Volumes(runner: runner)
            let uuid = "11111111-2222-3333-4444-555555555555"
            XCTAssertNil(volumes.volume(uuid: uuid))
            XCTAssertNotNil(volumes.eject(uuid: uuid))
            XCTAssertFalse(runner.invocations.contains { $0.contains("eject") })
        }
    }


    private struct LookupRunner: ProcessRunning {
        let info: ProcessResult
        let listing: ProcessResult
        var infoError: ProcessRunError?
        func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
            if arguments.first == "info" {
                if let infoError { throw infoError }
                return info
            }
            return listing
        }
    }

    private func diskListing(_ disks: [[String: Any]]) throws -> ProcessResult {
        ProcessResult(status: 0, standardOutput: try PropertyListSerialization.data(
            fromPropertyList: ["AllDisks": [String](), "AllDisksAndPartitions": disks], format: .xml, options: 0))
    }

    func testConfirmedAbsenceRequiresASuccessfulDiskListing() throws {
        let uuid = "11111111-2222-3333-4444-555555555555"
        let runner = LookupRunner(info: ProcessResult(status: 1), listing: try diskListing([]))
        XCTAssertNil(try Volumes(runner: runner).confirmedVolume(uuid: uuid))
        let failed = LookupRunner(info: ProcessResult(status: 1), listing: ProcessResult(status: 1))
        XCTAssertThrowsError(try Volumes(runner: failed).confirmedVolume(uuid: uuid))
        let malformed = LookupRunner(info: ProcessResult(status: 1), listing: ProcessResult(status: 0, standardOutput: Data("bad plist".utf8)))
        XCTAssertThrowsError(try Volumes(runner: malformed).confirmedVolume(uuid: uuid))
    }

    func testInfoFailureForAVolumeStillInTheDiskListingIsNotAbsence() throws {
        let uuid = "11111111-2222-3333-4444-555555555555"
        let listing = try diskListing([["APFSVolumes": [["VolumeUUID": uuid, "VolumeName": "External"]]]])
        let runner = LookupRunner(info: ProcessResult(status: 1), listing: listing)
        XCTAssertThrowsError(try Volumes(runner: runner).confirmedVolume(uuid: uuid)) {
            XCTAssertEqual($0 as? VolumeLookupError, .unconfirmed(uuid: uuid))
        }
        let incomplete = try diskListing([["Partitions": [["VolumeName": "External"]]]])
        XCTAssertThrowsError(try Volumes(runner: LookupRunner(info: ProcessResult(status: 1), listing: incomplete)).confirmedVolume(uuid: uuid))
    }

    func testATimedOutLookupDoesNotCertifyAbsence() throws {
        let uuid = "11111111-2222-3333-4444-555555555555"
        let timeout = ProcessRunError.timedOut(executable: "/usr/sbin/diskutil", seconds: 60)
        let runner = LookupRunner(info: ProcessResult(status: 0), listing: try diskListing([]), infoError: timeout)
        XCTAssertThrowsError(try Volumes(runner: runner).confirmedVolume(uuid: uuid)) {
            XCTAssertEqual($0 as? ProcessRunError, timeout)
        }
    }

    func testInvalidIdentityCannotCertifyAbsenceEvenWhenInfoSucceeded() throws {
        let uuid = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let runner = LookupRunner(info: ProcessResult(status: 0, standardOutput: fixture("diskutil-info-volume.plist")),
                                  listing: try diskListing([]))
        XCTAssertThrowsError(try Volumes(runner: runner).confirmedVolume(uuid: uuid))
    }

    func testAPFSWithoutOneConfirmedPhysicalStoreCannotReportSuccessfulEjection() throws {
        var info = try PropertyListSerialization.propertyList(from: fixture("diskutil-info-volume.plist"), format: nil) as! [String: Any]
        info.removeValue(forKey: "APFSPhysicalStores")
        let runner = RecordingRunner()
        runner.result = ProcessResult(status: 0, standardOutput: try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0))
        XCTAssertNotNil(Volumes(runner: runner).eject(uuid: "11111111-2222-3333-4444-555555555555"))
        XCTAssertFalse(runner.invocations.contains { $0.contains("eject") }, "the APFS container parent is not a confirmed physical disk")
    }

}
