import Foundation

/// Turns the state the experiment harness recorded into a manifest.
///
/// The harness kept only the build, the volume and the image path. Adoption
/// fills in what can be learned without changing anything: the checksum the
/// harness wrote beside the image, the image's size, and the name
/// CoreSimulator gives the runtime.
public struct Adoption {
    private let paths: Paths
    private let volumeLookup: (String) -> Volume?
    private let files = FileManager.default

    public init(paths: Paths, volumeLookup: @escaping (String) -> Volume?) {
        self.paths = paths
        self.volumeLookup = volumeLookup
    }

    /// The manifest to save: every harness entry, completed where possible.
    /// Details already recorded in `existing` are kept, so adopting twice
    /// never loses anything.
    public func manifest(
        adopting harness: [OffloadedRuntime], existing: Manifest, runtimes: [Runtime]
    ) -> Manifest {
        Manifest(runtimes: harness.map { entry in
            var completed = existing.runtimes.first { $0.build == entry.build } ?? entry
            completed.volumeUUID = entry.volumeUUID
            completed.imagePath = entry.imagePath

            let mountPoint = paths.mountPoint(forBuild: entry.build)
            if let registered = runtimes.first(where: { $0.bundlePath.hasPrefix(mountPoint + "/") }) {
                completed.name = registered.name
                completed.runtimeIdentifier = registered.identifier
            }
            if let volumeRoot = volumeLookup(entry.volumeUUID)?.mountPoint {
                let image = "\(volumeRoot)/\(entry.imagePath)"
                if let size = (try? files.attributesOfItem(atPath: image))?[.size] as? NSNumber {
                    completed.sizeBytes = size.int64Value
                }
                let sums = ((image as NSString).deletingLastPathComponent as NSString)
                    .appendingPathComponent("SHA256SUMS")
                if let text = try? String(contentsOfFile: sums, encoding: .utf8),
                   let checksum = Adoption.checksum(for: (image as NSString).lastPathComponent, in: text) {
                    completed.sha256 = checksum
                }
            }
            return completed
        })
    }

    /// Reads one entry from a `shasum`-style file: `<hex>  <file name>`.
    static func checksum(for fileName: String, in text: String) -> String? {
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let name = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " *"))
            if name == fileName, parts[0].count == 64, parts[0].allSatisfy(\.isHexDigit) {
                return String(parts[0])
            }
        }
        return nil
    }
}
