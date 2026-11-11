import XCTest
@testable import SimRuntimeOffloadCore

final class AgentLogTests: ScratchTestCase {
    func testRotationKeepsOnlyCurrentAndOnePreviousBoundedLog() throws {
        let log = AgentLog(paths: paths, maximumBytes: 16)
        try log.append("first message")
        try log.append("second message")
        XCTAssertEqual(try String(contentsOfFile: paths.agentLog), "second message\n")
        XCTAssertEqual(try String(contentsOfFile: paths.agentLog + ".1"), "first message\n")
        try log.append("third message")
        XCTAssertEqual(try String(contentsOfFile: paths.agentLog), "third message\n")
        XCTAssertEqual(try String(contentsOfFile: paths.agentLog + ".1"), "second message\n")
        XCTAssertEqual(Set(try files.contentsOfDirectory(atPath: paths.logDirectory)), ["agent.log", "agent.log.1"])
    }

    func testBoundsOversizedMessagesAndHistoricLogs() throws {
        try files.createDirectory(atPath: paths.logDirectory, withIntermediateDirectories: true)
        try Data(repeating: 65, count: 10_000).write(to: URL(fileURLWithPath: paths.agentLog))
        try AgentLog(paths: paths, maximumBytes: 32).append(String(repeating: "x", count: 100))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: paths.agentLog)).count, 32)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: paths.agentLog + ".1")).count, 32)
    }
}
