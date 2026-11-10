import Foundation

/// The few file-system questions the tool asks when working out what state a
/// runtime is in. A protocol so the decision logic can be tested without disks.
public protocol FileSystemProbing {
    func fileExists(_ path: String) -> Bool
    /// Whether a file system is mounted exactly at `path`.
    func isMountPoint(_ path: String) -> Bool
    /// Where the symbolic link at `path` points, or `nil` if it is not a link.
    func symbolicLinkDestination(_ path: String) -> String?
    /// The names in a directory; empty if it cannot be listed.
    func contentsOfDirectory(_ path: String) -> [String]
}

public struct FileSystem: FileSystemProbing {
    public init() {}

    public func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func isMountPoint(_ path: String) -> Bool {
        // The kernel reports mount points by their canonical path, so compare
        // against that: `/var/…` and `/tmp/…` are links into `/private`.
        guard let canonical = FileSystem.canonicalPath(path) else { return false }
        var info = statfs()
        guard statfs(canonical, &info) == 0 else { return false }
        let mountedOn = withUnsafePointer(to: &info.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return mountedOn == canonical
    }

    /// `path` with every symbolic link resolved, or `nil` if it does not exist.
    /// Uses realpath(3) rather than Foundation, which strips `/private`.
    public static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public func symbolicLinkDestination(_ path: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: path)
    }

    public func contentsOfDirectory(_ path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }
}
