import Foundation

/// The outcome of running an external command.
public struct ProcessResult: Equatable, Sendable {
    public let status: Int32
    public let standardOutput: Data
    public let standardError: Data

    public init(status: Int32, standardOutput: Data = Data(), standardError: Data = Data()) {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var succeeded: Bool { status == 0 }

    public var outputText: String {
        String(decoding: standardOutput, as: UTF8.self)
    }

    public var errorText: String {
        String(decoding: standardError, as: UTF8.self)
    }
}

/// Runs external commands. A protocol so that tests can substitute recorded
/// output for the three system tools this project depends on.
public protocol ProcessRunning: Sendable {
    /// Runs `executable` with `arguments`. Throws only when the command could
    /// not be started; a non-zero exit is reported in the result.
    func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult
}

/// Runs commands for real.
///
/// Commands are started by absolute path with an argument array. Nothing is
/// ever passed through a shell, so no argument is subject to word splitting,
/// globbing or substitution.
public struct SystemProcessRunner: ProcessRunning {
    public init() {}

    public func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        precondition(executable.hasPrefix("/"), "commands are run by absolute path")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()

        // Drain both pipes concurrently: a child that fills one pipe while we
        // block reading the other would otherwise never exit.
        let group = DispatchGroup()
        let errorBox = DataBox()
        group.enter()
        DispatchQueue.global().async {
            errorBox.data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()

        return ProcessResult(
            status: process.terminationStatus,
            standardOutput: output,
            standardError: errorBox.data
        )
    }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}
