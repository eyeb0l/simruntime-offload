import XCTest
@testable import SimRuntimeOffloadCore

final class SystemProbeParsingTests: XCTestCase {
    func testParsesXcodebuildVersionOutput() {
        XCTAssertEqual(SystemProbe.parseXcodeVersion("Xcode 27.2\nBuild version 27B52\n"), Version("27.2"))
        XCTAssertNil(SystemProbe.parseXcodeVersion("xcode-select: error: tool 'xcodebuild' requires Xcode\n"))
    }

    func testParsesIntegrityProtectionStatus() {
        XCTAssertEqual(
            SystemProbe.parseIntegrityProtectionStatus("System Integrity Protection status: enabled.\n"), true)
        XCTAssertEqual(
            SystemProbe.parseIntegrityProtectionStatus("System Integrity Protection status: disabled.\n"), false)
        XCTAssertNil(SystemProbe.parseIntegrityProtectionStatus("something unexpected"))
    }
}

/// A process runner that replays canned results, keyed by executable path.
struct StubRunner: ProcessRunning {
    var results: [String: ProcessResult] = [:]

    func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        guard let result = results[executable] else {
            throw CocoaError(.fileNoSuchFile)
        }
        return result
    }
}

final class SystemProbeRunnerTests: XCTestCase {
    func testDetectsTheModernImageAttachFromItsUsageText() {
        let usage = "OVERVIEW: Attach a disk image\nUSAGE: diskutil image attach [--verbose] <image-url>\n"
        let present = SystemProbe(runner: StubRunner(results: [
            "/usr/sbin/diskutil": ProcessResult(status: 64, standardError: Data(usage.utf8))
        ]))
        XCTAssertTrue(present.modernImageAttachAvailable())

        let absent = SystemProbe(runner: StubRunner(results: [
            "/usr/sbin/diskutil": ProcessResult(status: 1, standardOutput: Data("Usage:  diskutil [quiet] <verb>".utf8))
        ]))
        XCTAssertFalse(absent.modernImageAttachAvailable())

        XCTAssertFalse(SystemProbe(runner: StubRunner()).modernImageAttachAvailable())
    }

    func testAgentIsLoadedOnlyWhenLaunchctlSucceeds() {
        let loaded = SystemProbe(runner: StubRunner(results: ["/bin/launchctl": ProcessResult(status: 0)]))
        XCTAssertTrue(loaded.agentLoaded(label: "x", userID: 501))
        let missing = SystemProbe(runner: StubRunner(results: ["/bin/launchctl": ProcessResult(status: 113)]))
        XCTAssertFalse(missing.agentLoaded(label: "x", userID: 501))
    }

    func testUnrunnableToolsGiveUnknownNotFalse() {
        let probe = SystemProbe(runner: StubRunner())
        XCTAssertNil(probe.xcodeVersion())
        XCTAssertNil(probe.systemIntegrityProtectionEnabled())
    }
}
