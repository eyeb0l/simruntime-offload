import XCTest
@testable import SimRuntimeOffloadCore

final class VersionTests: XCTestCase {
    func testParsesDottedNumbers() {
        XCTAssertEqual(Version("27.2.1")?.components, [27, 2, 1])
        XCTAssertEqual(Version("1174.21")?.components, [1174, 21])
        XCTAssertEqual(Version("27")?.components, [27])
    }

    func testStopsAtTheFirstNonNumericPart() {
        XCTAssertEqual(Version("27.2 beta 3")?.components, [27, 2])
        XCTAssertEqual(Version("27.2-rc")?.components, [27, 2])
    }

    func testRejectsTextThatDoesNotStartWithANumber() {
        XCTAssertNil(Version(""))
        XCTAssertNil(Version("Xcode 27.2"))
        XCTAssertNil(Version(".5"))
    }

    func testMissingComponentsCompareAsZero() {
        XCTAssertEqual(Version("27.2"), Version("27.2.0"))
        XCTAssertLessThan(Version("27.2")!, Version("27.2.1")!)
    }

    func testOrdersNumericallyNotLexically() {
        XCTAssertLessThan(Version("27.9")!, Version("27.10")!)
        XCTAssertLessThan(Version("26.5")!, Version("27.0")!)
        XCTAssertGreaterThan(Version("1174.21")!, Version("1174.3")!)
    }

    func testExposesMajorAndMinor() {
        let version = Version("27.2.1")!
        XCTAssertEqual(version.major, 27)
        XCTAssertEqual(version.minor, 2)
        XCTAssertEqual(Version("27")!.minor, 0)
        XCTAssertEqual(version.description, "27.2.1")
    }
}
