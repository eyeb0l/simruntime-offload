import XCTest
@testable import SimRuntimeOffloadCore

final class ImageStoreTests: ScratchTestCase {
    func testHashesAFile() throws {
        let path = "\(root!)/abc"
        files.createFile(atPath: path, contents: Data("abc".utf8))
        let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        XCTAssertEqual(try ImageStore().sha256(ofFile: path), expected)
        XCTAssertEqual(try ImageStore().sha256(ofFile: path, uncached: true), expected)
    }

    func testHashesAFileLargerThanOneChunk() throws {
        let path = "\(root!)/big"
        let data = Data((0..<(9 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        files.createFile(atPath: path, contents: data)
        // Compare with the system's own tool.
        let reference = try SystemProcessRunner().run("/usr/bin/shasum", ["-a", "256", path])
        XCTAssertEqual(try ImageStore().sha256(ofFile: path), String(reference.outputText.prefix(64)))
    }

    func testAMissingFileIsAnError() {
        XCTAssertThrowsError(try ImageStore().sha256(ofFile: "\(root!)/absent")) {
            XCTAssertEqual($0 as? ImageStoreError, .cannotRead(path: "\(self.root!)/absent"))
        }
    }

    func testCopiesARealImageAndRecordsItsChecksum() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["SRO_SKIP_INTEGRATION"] != nil)
        let folder = "\(root!)/content"
        try files.createDirectory(atPath: folder, withIntermediateDirectories: true)
        files.createFile(atPath: "\(folder)/file", contents: Data("hello".utf8))
        let source = "\(root!)/source.dmg"
        if let failure = try makeTestImage(of: folder, at: source) {
            throw XCTSkip("could not create a test image: \(failure)")
        }
        // An extended attribute on the original must not follow the copy.
        _ = try SystemProcessRunner().run("/usr/bin/xattr", ["-w", "com.apple.quarantine", "0081;test", source])

        let destination = "\(root!)/volume/SimRuntimes/TEST/source.dmg"
        var lastProgress: (Int64, Int64) = (0, 0)
        let checksum = try ImageStore().copyVerified(from: source, to: destination) { lastProgress = ($0, $1) }

        XCTAssertEqual(checksum, try ImageStore().sha256(ofFile: source))
        XCTAssertEqual(files.contents(atPath: destination), files.contents(atPath: source))
        XCTAssertFalse(files.fileExists(atPath: destination + ".partial"))
        XCTAssertEqual(lastProgress.0, lastProgress.1)
        XCTAssertGreaterThan(lastProgress.1, 0)

        let sums = try String(contentsOfFile: "\(root!)/volume/SimRuntimes/TEST/SHA256SUMS", encoding: .utf8)
        XCTAssertEqual(sums, "\(checksum)  source.dmg\n")

        let attributes = try SystemProcessRunner().run("/usr/bin/xattr", [destination])
        XCTAssertFalse(attributes.outputText.contains("quarantine"))
    }

    func testAFileThatIsNotADiskImageIsRejectedAndRemoved() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["SRO_SKIP_INTEGRATION"] != nil)
        let source = "\(root!)/not-an-image.dmg"
        files.createFile(atPath: source, contents: Data(repeating: 7, count: 4096))
        let destination = "\(root!)/volume/x.dmg"
        XCTAssertThrowsError(try ImageStore().copyVerified(from: source, to: destination) { _, _ in }) { error in
            guard case .notADiskImage? = error as? ImageStoreError else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(files.fileExists(atPath: destination))
        XCTAssertFalse(files.fileExists(atPath: destination + ".partial"))
    }

    func testNeverWritesThroughAnExistingPartialFile() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["SRO_SKIP_INTEGRATION"] != nil)
        let source = "\(root!)/s.dmg"
        files.createFile(atPath: source, contents: Data(repeating: 1, count: 100))
        let destination = "\(root!)/volume/d.dmg"
        try files.createDirectory(atPath: "\(root!)/volume", withIntermediateDirectories: true)
        files.createFile(atPath: destination + ".partial", contents: Data("stale".utf8))
        // The stale partial is replaced, not appended to or trusted.
        XCTAssertThrowsError(try ImageStore().copyVerified(from: source, to: destination) { _, _ in })
        XCTAssertFalse(files.fileExists(atPath: destination + ".partial"))
    }

    func testFailedOrInterruptedVerificationNeverPublishesAFinalImage() throws {
        struct ThrowingRunner: ProcessRunning {
            func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
                throw ProcessRunError.timedOut(executable: executable, seconds: 300)
            }
        }
        let source = "\(root!)/source.dmg"
        let destination = "\(root!)/volume/dest.dmg"
        try Data("arbitrary bytes".utf8).write(to: URL(fileURLWithPath: source))
        XCTAssertThrowsError(try ImageStore(runner: ThrowingRunner()).copyVerified(from: source, to: destination) { _, _ in })
        XCTAssertFalse(files.fileExists(atPath: destination))
        XCTAssertFalse(files.fileExists(atPath: destination + ".partial"))
        XCTAssertTrue(files.fileExists(atPath: source))
    }

    func testVerifyingAnExistingInvalidImageLeavesItUntouched() throws {
        let path = "\(root!)/existing.dmg"
        let data = Data("not an image".utf8)
        try data.write(to: URL(fileURLWithPath: path))
        let runner = RecordingRunner()
        runner.result = ProcessResult(status: 1, standardError: Data("invalid".utf8))
        XCTAssertThrowsError(try ImageStore(runner: runner).verifyImage(at: path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), data)
        XCTAssertEqual(runner.invocations, [["/usr/bin/hdiutil", "verify", "-quiet", path]])
    }

}
