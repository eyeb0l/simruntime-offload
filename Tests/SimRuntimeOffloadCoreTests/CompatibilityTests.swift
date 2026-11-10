import XCTest
@testable import SimRuntimeOffloadCore

final class CompatibilityTests: XCTestCase {
    private func versions(macOS: String, xcode: String?, coreSimulator: String?) -> SystemVersions {
        SystemVersions(
            macOS: Version(macOS)!,
            xcode: xcode.flatMap(Version.init),
            coreSimulator: coreSimulator.flatMap(Version.init)
        )
    }

    func testTheCombinationTheInvestigationRanOnIsValidated() {
        let verdict = Compatibility.evaluate(versions(macOS: "27.2.1", xcode: "27.2", coreSimulator: "1174.21"))
        guard case .validated = verdict else {
            return XCTFail("expected validated, got \(verdict)")
        }
    }

    func testAPatchUpdateOfMacOSIsStillValidated() {
        let verdict = Compatibility.evaluate(versions(macOS: "27.2.3", xcode: "27.2.1", coreSimulator: "1174.30"))
        guard case .validated = verdict else {
            return XCTFail("expected validated, got \(verdict)")
        }
    }

    func testANewerXcodeIsNotValidated() {
        let verdict = Compatibility.evaluate(versions(macOS: "27.2.1", xcode: "27.3", coreSimulator: "1174.40"))
        XCTAssertEqual(verdict, .unvalidated(["Xcode 27.3 (validated: 27.2.x)"]))
    }

    func testAnOlderSystemListsEveryMismatch() {
        let verdict = Compatibility.evaluate(versions(macOS: "26.7.1", xcode: "26.5", coreSimulator: "1051.9"))
        guard case .unvalidated(let problems) = verdict else {
            return XCTFail("expected unvalidated")
        }
        XCTAssertEqual(problems.count, 3)
        XCTAssertTrue(problems[0].contains("macOS 26.7.1"))
    }

    func testMissingXcodeIsNotValidated() {
        let verdict = Compatibility.evaluate(versions(macOS: "27.2.1", xcode: nil, coreSimulator: nil))
        guard case .unvalidated(let problems) = verdict else {
            return XCTFail("expected unvalidated")
        }
        XCTAssertTrue(problems.contains { $0.hasPrefix("Xcode not found") })
        XCTAssertTrue(problems.contains { $0.hasPrefix("CoreSimulator not found") })
    }

    func testAnEmptyTableValidatesNothing() {
        let verdict = Compatibility.evaluate(
            versions(macOS: "27.2.1", xcode: "27.2", coreSimulator: "1174.21"),
            against: []
        )
        guard case .unvalidated = verdict else {
            return XCTFail("expected unvalidated")
        }
    }
}
