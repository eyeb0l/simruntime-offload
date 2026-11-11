import CryptoKit
import Foundation

public enum ImageStoreError: Error, Equatable, CustomStringConvertible {
    case cannotRead(path: String)
    case cannotWrite(path: String)
    case checksumMismatch(source: String, copy: String)
    case notADiskImage(path: String, message: String)

    public var description: String {
        switch self {
        case .cannotRead(let path): return "could not read \(path)"
        case .cannotWrite(let path): return "could not write \(path)"
        case .checksumMismatch(let source, let copy):
            return "the copy does not match the original (SHA-256 \(copy) instead of \(source))"
        case .notADiskImage(let path, let message):
            return "\(path) did not pass disk-image verification (\(message))"
        }
    }
}

/// Copies a runtime image to the external volume and proves the copy is good.
public protocol ImageStoring {
    /// Copies `source` to `destination` and returns the SHA-256 both share.
    /// Throws, leaving nothing at `destination`, unless the copy read back from
    /// the device matches the original and passes disk-image verification.
    func copyVerified(
        from source: String, to destination: String, progress: (Int64, Int64) -> Void
    ) throws -> String
    /// Verifies the disk image itself, without deleting an existing file on failure.
    func verifyImage(at path: String) throws
    func sha256(ofFile path: String) throws -> String
    /// Deletes an image this tool stored, with the checksum file beside it,
    /// and the directory they were in if that leaves it empty.
    func removeImage(at path: String) throws
}

public struct ImageStore: ImageStoring {
    private let runner: ProcessRunning
    private let files = FileManager.default
    private static let chunk = 4 * 1024 * 1024

    public init(runner: ProcessRunning = SystemProcessRunner()) {
        self.runner = runner
    }

    public func copyVerified(
        from source: String, to destination: String, progress: (Int64, Int64) -> Void
    ) throws -> String {
        let partial = destination + ".partial"
        try? files.removeItem(atPath: partial)
        try files.createDirectory(
            atPath: (destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true)

        // Data only: no extended attributes, so a quarantine flag can never
        // follow the image onto the volume.
        let sourceChecksum: String
        do {
            sourceChecksum = try copyHashing(from: source, to: partial, progress: progress)
        } catch {
            try? files.removeItem(atPath: partial)
            throw error
        }

        // Read the copy back from the device, bypassing the cache, so that
        // what is verified is what was actually written.
        let copyChecksum = try sha256(ofFile: partial, uncached: true)
        guard copyChecksum == sourceChecksum else {
            try? files.removeItem(atPath: partial)
            throw ImageStoreError.checksumMismatch(source: sourceChecksum, copy: copyChecksum)
        }
        // Keep the partial name until both independent checks have passed.
        do {
            try verifyImage(at: partial)
        } catch {
            try? files.removeItem(atPath: partial)
            throw error
        }
        try files.moveItem(atPath: partial, toPath: destination)

        let name = (destination as NSString).lastPathComponent
        let sums = ((destination as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("SHA256SUMS")
        try "\(sourceChecksum)  \(name)\n".write(toFile: sums, atomically: true, encoding: .utf8)
        return sourceChecksum
    }

    public func verifyImage(at path: String) throws {
        let result = try runner.run("/usr/bin/hdiutil", ["verify", "-quiet", path])
        guard result.succeeded else {
            throw ImageStoreError.notADiskImage(
                path: path, message: result.errorText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    public func sha256(ofFile path: String) throws -> String {
        try sha256(ofFile: path, uncached: true)
    }

    /// Removes exactly two named files and then, without recursion, the
    /// directory. Anything else in the directory keeps it in place.
    public func removeImage(at path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try files.removeItem(atPath: path)
        let sums = (directory as NSString).appendingPathComponent("SHA256SUMS")
        if files.fileExists(atPath: sums) { try files.removeItem(atPath: sums) }
        rmdir(directory)
    }

    func sha256(ofFile path: String, uncached: Bool) throws -> String {
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { throw ImageStoreError.cannotRead(path: path) }
        defer { close(descriptor) }
        if uncached { _ = fcntl(descriptor, F_NOCACHE, 1) }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: ImageStore.chunk)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            guard count >= 0 else { throw ImageStoreError.cannotRead(path: path) }
            if count == 0 { break }
            hasher.update(data: buffer[0..<count])
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func copyHashing(
        from source: String, to destination: String, progress: (Int64, Int64) -> Void
    ) throws -> String {
        let input = open(source, O_RDONLY)
        guard input >= 0 else { throw ImageStoreError.cannotRead(path: source) }
        defer { close(input) }
        // O_EXCL: never write through something that appeared at this name.
        let output = open(destination, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard output >= 0 else { throw ImageStoreError.cannotWrite(path: destination) }
        defer { close(output) }

        var info = stat()
        fstat(input, &info)
        let total = Int64(info.st_size)

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: ImageStore.chunk)
        var done: Int64 = 0
        while true {
            let count = read(input, &buffer, buffer.count)
            guard count >= 0 else { throw ImageStoreError.cannotRead(path: source) }
            if count == 0 { break }
            hasher.update(data: buffer[0..<count])
            var written = 0
            while written < count {
                let result = buffer.withUnsafeBytes {
                    write(output, $0.baseAddress! + written, count - written)
                }
                guard result > 0 else { throw ImageStoreError.cannotWrite(path: destination) }
                written += result
            }
            done += Int64(count)
            progress(done, total)
        }
        // Make sure the data has reached the device before it is read back.
        guard fcntl(output, F_FULLFSYNC) == 0 || fsync(output) == 0 else {
            throw ImageStoreError.cannotWrite(path: destination)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
