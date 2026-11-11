import XCTest
@testable import SimRuntimeOffloadCore

final class ProcessRunnerTests: ScratchTestCase {
    func testDrainsLargeStdoutAndStderrAndPreservesExitStatus() throws {
        let result = try SystemProcessRunner(timeout: 5).run("/bin/sh", ["-c", """
            i=0
            while [ "$i" -lt 12000 ]; do
              printf 'stdout-line\n'
              printf 'stderr-line\n' >&2
              i=$((i+1))
            done
            exit 17
            """])
        XCTAssertEqual(result.status, 17)
        XCTAssertEqual(result.outputText, String(repeating: "stdout-line\n", count: 12000))
        XCTAssertEqual(result.errorText, String(repeating: "stderr-line\n", count: 12000))
    }

    func testDeadlineKillsAChildThatIgnoresTerminationAndReturnsPromptly() throws {
        let pidFile = "\(root!)/pid"
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try SystemProcessRunner(timeout: 0.2).run("/bin/sh", ["-c", """
            echo $$ > '\(pidFile)'
            trap '' TERM
            while :; do :; done
            """])) {
            XCTAssertEqual($0 as? ProcessRunError, .timedOut(executable: "/bin/sh", seconds: 0.2))
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 3)
        let pid = try XCTUnwrap(Int32(try String(contentsOfFile: pidFile).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(pid, 0), -1, "the timed-out child must be reaped, not left running")
        XCTAssertEqual(errno, ESRCH)
    }

    func testADescendantsOpenPipeDoesNotBlockReturnAfterTheCommandExits() throws {
        let pidFile = "\(root!)/descendant"
        defer {
            if let text = try? String(contentsOfFile: pidFile),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) { kill(pid, SIGKILL) }
        }
        let start = ProcessInfo.processInfo.systemUptime
        let result = try SystemProcessRunner(timeout: 1).run("/bin/sh", ["-c", """
            /bin/sleep 10 &
            echo $! > '\(pidFile)'
            printf done
            """])
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.outputText, "done")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
    }

    func testFinalWritesBetweenEmptyReadsAndExitObservationAreCaptured() throws {
        let gate = FinalWriteGate(root: root)
        let runner = SystemProcessRunner(timeout: 5, beforeExitCheck: { try gate.releaseAndAwaitExit() })
        let result = try runner.run("/bin/sh", ["-c", """
            echo $$ > '\(gate.pidFile)'
            while [ ! -f '\(gate.releaseFile)' ]; do :; done
            printf 'final stdout'
            printf 'final stderr' >&2
            """])
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.outputText, "final stdout")
        XCTAssertEqual(result.errorText, "final stderr")
    }

}


/// Only the runner's calling thread accesses this gate. The child waits for
/// the file, so its only pipe writes happen inside the injected interleaving.
private final class FinalWriteGate: @unchecked Sendable {
    let pidFile: String
    let releaseFile: String
    private var released = false
    init(root: String) {
        pidFile = "\(root)/final-write-pid"
        releaseFile = "\(root)/release-final-write"
    }
    func releaseAndAwaitExit() throws {
        guard !released else { return }
        released = true
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var pid: Int32?
        while pid == nil {
            if let text = try? String(contentsOfFile: pidFile) {
                pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CocoaError(.fileReadUnknown) }
            if pid == nil { usleep(1_000) }
        }
        try Data().write(to: URL(fileURLWithPath: releaseFile))
        while kill(pid!, 0) == 0 {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CocoaError(.fileReadUnknown) }
            usleep(1_000)
        }
    }
}
