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
    /// Runs `executable` with `arguments`. Start, output-read and deadline
    /// failures throw; a non-zero exit is reported in the result.
    func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult
}

public enum ProcessRunError: Error, Equatable, CustomStringConvertible {
    case timedOut(executable: String, seconds: TimeInterval)
    case cannotReadOutput

    public var description: String {
        switch self {
        case .timedOut(let executable, let seconds):
            return "\(executable) exceeded its \(Int(seconds)) second deadline and was stopped; inspect the operation's saved state before retrying"
        case .cannotReadOutput:
            return "could not read a command's output"
        }
    }
}

/// Commands use absolute paths and argument arrays, never a shell. Both pipes
/// are drained without blocking, including after observing command termination.
public struct SystemProcessRunner: ProcessRunning {
    private let timeout: TimeInterval?
    private let beforeExitCheck: (@Sendable () throws -> Void)?

    /// Overrides command-specific deadlines, principally for focused tests.
    public init(timeout: TimeInterval? = nil) {
        precondition(timeout == nil || timeout! > 0)
        self.timeout = timeout
        self.beforeExitCheck = nil
    }

    /// A deterministic seam for the final-write/exit interleaving regression.
    init(timeout: TimeInterval, beforeExitCheck: @escaping @Sendable () throws -> Void) {
        precondition(timeout > 0)
        self.timeout = timeout
        self.beforeExitCheck = beforeExitCheck
    }

    static func deadline(for executable: String, arguments: [String]) -> TimeInterval {
        if executable == "/usr/bin/xcrun", arguments.starts(with: ["simctl", "runtime", "add"]) {
            return 900 // A full image import on a slow external disk.
        }
        if executable == "/usr/bin/hdiutil" { return 300 }
        if executable == "/usr/sbin/diskutil", arguments.starts(with: ["image", "attach"]) {
            return 180 // Includes time to answer removable-volume consent.
        }
        return 60
    }

    public func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        precondition(executable.hasPrefix("/"), "commands are run by absolute path")
        let seconds = timeout ?? Self.deadline(for: executable, arguments: arguments)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        // Parent writers must close too, otherwise EOF is never observable.
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? outputPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForReading.close()
        }

        let descriptors = [outputPipe.fileHandleForReading.fileDescriptor, errorPipe.fileHandleForReading.fileDescriptor]
        for descriptor in descriptors {
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw ProcessRunError.cannotReadOutput
            }
        }
        var captured = [Data(), Data()]
        var ended = [false, false]
        let started = ProcessInfo.processInfo.systemUptime
        var expiredAt: TimeInterval?
        func drain(_ index: Int) throws {
            guard !ended[index] else { return }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            // More than the kernel can buffer for this pipe. Bound the drain
            // even if a descendant continuously writes after its parent exits.
            for _ in 0..<16 {
                let count = read(descriptors[index], &buffer, buffer.count)
                if count > 0 {
                    captured[index].append(contentsOf: buffer.prefix(count))
                } else if count == 0 {
                    ended[index] = true
                    return
                } else if errno == EINTR {
                    continue
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                } else {
                    throw ProcessRunError.cannotReadOutput
                }
            }
        }
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            if expiredAt == nil, process.isRunning, now - started >= seconds {
                expiredAt = now
                process.terminate()
            }
            if let expiredAt, now - expiredAt >= 0.25, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            for index in 0..<2 { try drain(index) }
            try beforeExitCheck?()
            if !process.isRunning {
                // A final write can occur after EAGAIN but before observing
                // exit. Only a drain after that observation captures it.
                for index in 0..<2 { try drain(index) }
                break
            }
            var polling = descriptors.enumerated().map {
                pollfd(fd: ended[$0.offset] ? -1 : $0.element, events: Int16(POLLIN), revents: 0)
            }
            _ = poll(&polling, nfds_t(polling.count), 20)
        }
        process.waitUntilExit()
        if expiredAt != nil { throw ProcessRunError.timedOut(executable: executable, seconds: seconds) }
        return ProcessResult(status: process.terminationStatus, standardOutput: captured[0], standardError: captured[1])
    }
}
