import Foundation

public enum RegistryError: Error, Equatable, CustomStringConvertible {
    case noBundle(mountPoint: String)
    case occupied(path: String)

    public var description: String {
        switch self {
        case .noBundle(let mountPoint):
            return "no .simruntime bundle found in the image mounted at \(mountPoint)"
        case .occupied(let path):
            return "\(path) exists and is not a link this tool made; it has been left alone"
        }
    }
}

/// The symbolic links that make CoreSimulator see an offloaded runtime.
///
/// CoreSimulator watches a few profile directories, follows symbolic links
/// in them, and accepts a link whose resolved path ends in `.simruntime`.
/// A link is created only once its target exists and removed when it does
/// not: a dangling link makes every `simctl` invocation print a warning.
public struct Registry {
    private let paths: Paths
    private let files = FileManager.default

    public init(paths: Paths) {
        self.paths = paths
    }

    /// The shared directory when it is usable, otherwise the per-user one.
    public var linkDirectory: String {
        var isDirectory: ObjCBool = false
        let shared = paths.sharedLinkDirectory
        if files.fileExists(atPath: shared, isDirectory: &isDirectory), isDirectory.boolValue,
           access(shared, W_OK) == 0 {
            return shared
        }
        return paths.perUserLinkDirectory
    }

    /// Every place a link of ours for `build` might be.
    func candidateLinks(forBuild build: String) -> [String] {
        let name = Paths.linkName(forBuild: build)
        return ["\(paths.sharedLinkDirectory)/\(name)", "\(paths.perUserLinkDirectory)/\(name)"]
    }

    /// The runtime bundle inside a mounted runtime image.
    public func bundle(inImageMountedAt mountPoint: String) throws -> String {
        let directory = "\(mountPoint)/\(Paths.bundleSubpath)"
        let names = (try? files.contentsOfDirectory(atPath: directory)) ?? []
        guard let name = names.sorted().first(where: { $0.hasSuffix(".simruntime") }) else {
            throw RegistryError.noBundle(mountPoint: mountPoint)
        }
        return "\(directory)/\(name)"
    }

    /// Points the link for `build` at `bundle`, replacing a link of ours.
    @discardableResult
    public func link(build: String, to bundle: String) throws -> String {
        try unlink(build: build)
        let directory = linkDirectory
        // Only the per-user directory is ours to create; the shared one is
        // made once, by `setup`.
        if directory == paths.perUserLinkDirectory {
            try files.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        let path = "\(directory)/\(Paths.linkName(forBuild: build))"
        try files.createSymbolicLink(atPath: path, withDestinationPath: bundle)
        return path
    }

    /// Removes our link for `build` from wherever it is. Anything at that name
    /// which is not a symbolic link is left alone and reported.
    public func unlink(build: String) throws {
        for path in candidateLinks(forBuild: build) {
            if (try? files.destinationOfSymbolicLink(atPath: path)) != nil {
                try files.removeItem(atPath: path)
            } else if files.fileExists(atPath: path) {
                throw RegistryError.occupied(path: path)
            }
        }
    }

    /// Whether a link of ours for `build` exists but its target does not.
    public func hasDanglingLink(forBuild build: String) -> Bool {
        candidateLinks(forBuild: build).contains { path in
            guard (try? files.destinationOfSymbolicLink(atPath: path)) != nil else { return false }
            // fileExists follows the link, so false means the target is gone.
            return !files.fileExists(atPath: path)
        }
    }
}
