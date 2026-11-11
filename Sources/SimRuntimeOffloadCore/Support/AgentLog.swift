import Foundation

/// One bounded current log and one bounded previous log. Each write opens the
/// current path, so rotation never leaves launchd writing through a stale fd.
public struct AgentLog {
    private let paths: Paths
    private let maximumBytes: Int

    public init(paths: Paths, maximumBytes: Int = 1_048_576) {
        precondition(maximumBytes > 0)
        self.paths = paths
        self.maximumBytes = maximumBytes
    }

    public func append(_ message: String) throws {
        let files = FileManager.default
        try files.createDirectory(atPath: paths.logDirectory, withIntermediateDirectories: true)
        let data = Data((message + "\n").utf8).suffix(maximumBytes)
        let size = (try? files.attributesOfItem(atPath: paths.agentLog)[.size] as? NSNumber)?.intValue ?? 0
        if size + data.count > maximumBytes, size > 0 {
            // Bound archives from older releases too, without reading a large
            // historic log into memory.
            let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: paths.agentLog))
            defer { try? input.close() }
            try input.seek(toOffset: UInt64(max(0, size - maximumBytes)))
            let tail = try input.read(upToCount: maximumBytes) ?? Data()
            try tail.write(to: URL(fileURLWithPath: paths.agentLog + ".1"), options: .atomic)
            try Data().write(to: URL(fileURLWithPath: paths.agentLog), options: .atomic)
        }
        if !files.fileExists(atPath: paths.agentLog) {
            guard files.createFile(atPath: paths.agentLog, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let output = try FileHandle(forWritingTo: URL(fileURLWithPath: paths.agentLog))
        defer { try? output.close() }
        try output.seekToEnd()
        try output.write(contentsOf: data)
    }
}
