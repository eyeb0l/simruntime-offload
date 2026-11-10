import Foundation

/// One runtime that is served from an external volume.
public struct OffloadedRuntime: Codable, Equatable, Sendable {
    public var build: String
    public var runtimeIdentifier: String?
    public var name: String?
    public var volumeUUID: String
    /// Relative to the root of the volume.
    public var imagePath: String
    public var sha256: String?
    public var sizeBytes: Int64?
    public var offloadedAt: Date?
    /// True while the same build is, or may be, registered from the internal
    /// disk: during an offload, from the verified copy until the internal copy
    /// is confirmed gone, and during a restore, from before the image is
    /// released until the import is confirmed. A staged runtime is never
    /// attached, because the same build must not be registered twice.
    public var staged: Bool?

    public var isStaged: Bool { staged ?? false }

    public init(
        build: String, runtimeIdentifier: String? = nil, name: String? = nil,
        volumeUUID: String, imagePath: String, sha256: String? = nil,
        sizeBytes: Int64? = nil, offloadedAt: Date? = nil, staged: Bool? = nil
    ) {
        self.build = build
        self.runtimeIdentifier = runtimeIdentifier
        self.name = name
        self.volumeUUID = volumeUUID
        self.imagePath = imagePath
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.offloadedAt = offloadedAt
        self.staged = staged
    }
}

/// The record of what is offloaded.
///
/// It is kept on the internal disk, not on the volume, so that the tool knows
/// which links are its own and can remove them while the volume is absent.
public struct Manifest: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var runtimes: [OffloadedRuntime]

    public init(runtimes: [OffloadedRuntime] = []) {
        self.version = Manifest.currentVersion
        self.runtimes = runtimes
    }
}

public enum ManifestError: Error, Equatable, CustomStringConvertible {
    case unreadable(path: String)
    case newerVersion(found: Int)

    public var description: String {
        switch self {
        case .unreadable(let path):
            return "\(path) exists but could not be read as a manifest"
        case .newerVersion(let found):
            return "the manifest was written by a newer simruntime-offload (format \(found)); update the tool"
        }
    }
}

public struct ManifestStore {
    private let paths: Paths

    public init(paths: Paths) {
        self.paths = paths
    }

    /// The saved manifest, or an empty one when none has been written.
    public func load() throws -> Manifest {
        let url = URL(fileURLWithPath: paths.manifest)
        guard FileManager.default.fileExists(atPath: paths.manifest) else { return Manifest() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let manifest = try? decoder.decode(Manifest.self, from: data)
        else { throw ManifestError.unreadable(path: paths.manifest) }
        // Refuse rather than silently drop fields a newer version relies on.
        guard manifest.version <= Manifest.currentVersion else {
            throw ManifestError.newerVersion(found: manifest.version)
        }
        return manifest
    }

    /// Writes the manifest atomically, so an interruption leaves the old one.
    public func save(_ manifest: Manifest) throws {
        try FileManager.default.createDirectory(
            atPath: paths.stateDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: URL(fileURLWithPath: paths.manifest), options: .atomic)
    }
}
