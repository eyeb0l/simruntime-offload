import XCTest
@testable import SimRuntimeOffloadCore

/// Records the commands it is asked to run and answers with one canned result.
final class RecordingRunner: ProcessRunning, @unchecked Sendable {
    private(set) var invocations: [[String]] = []
    var result = ProcessResult(status: 0)

    func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        invocations.append([executable] + arguments)
        return result
    }
}

final class AttacherTests: XCTestCase {
    func testAttachesReadOnlyHiddenWithTheModernStack() throws {
        let runner = RecordingRunner()
        try Attacher(runner: runner).attach(image: "/Volumes/X/a b.dmg", at: "/private/tmp/m/24A434")
        XCTAssertEqual(runner.invocations, [[
            "/usr/sbin/diskutil", "image", "attach", "--readOnly", "--nobrowse",
            "--mountPoint", "/private/tmp/m/24A434", "/Volumes/X/a b.dmg",
        ]])
    }

    func testARefusalIsReportedAsAPermissionProblem() {
        let runner = RecordingRunner()
        runner.result = ProcessResult(
            status: 1, standardError: Data("Error: The operation couldn’t be completed. Operation not permitted\n".utf8))
        XCTAssertThrowsError(try Attacher(runner: runner).attach(image: "/i.dmg", at: "/m")) { error in
            XCTAssertEqual(error as? AttachError, .notPermitted(image: "/i.dmg"))
        }
    }

    func testOtherAttachFailuresCarryTheToolsMessage() {
        let runner = RecordingRunner()
        runner.result = ProcessResult(status: 1, standardError: Data("Error: no mountable file systems\n".utf8))
        XCTAssertThrowsError(try Attacher(runner: runner).attach(image: "/i.dmg", at: "/m")) { error in
            XCTAssertEqual(error as? AttachError, .attachFailed(image: "/i.dmg", message: "Error: no mountable file systems"))
        }
    }

    func testEjectNeverForcesAndReportsABusyVolume() {
        let runner = RecordingRunner()
        runner.result = ProcessResult(
            status: 1, standardOutput: Data("Unmount of disk13 failed: at least one volume could not be unmounted\n".utf8))
        XCTAssertThrowsError(try Attacher(runner: runner).eject(mountPoint: "/m")) { error in
            guard case .busy(let mountPoint, let message)? = error as? AttachError else {
                return XCTFail("expected busy, got \(error)")
            }
            XCTAssertEqual(mountPoint, "/m")
            XCTAssertTrue(message.contains("could not be unmounted"))
        }
        XCTAssertEqual(runner.invocations, [["/usr/sbin/diskutil", "eject", "/m"]])
    }
}
