import Foundation

public enum AttachError: Error, Equatable, CustomStringConvertible {
    /// The system refused access to the image. For the login agent this means
    /// it has not been allowed access to removable volumes.
    case notPermitted(image: String)
    case attachFailed(image: String, message: String)
    /// Something still has the volume open.
    case busy(mountPoint: String, message: String)

    public var description: String {
        switch self {
        case .notPermitted(let image):
            return "not permitted to open \(image). If this is the login agent, allow simruntime-offload access to removable volumes in System Settings ▸ Privacy & Security ▸ Files and Folders."
        case .attachFailed(let image, let message):
            return "could not attach \(image): \(message)"
        case .busy(let mountPoint, let message):
            return "\(mountPoint) is still in use: \(message)"
        }
    }
}

/// Attaches and ejects runtime images. A protocol so the reconcile logic can
/// be tested without disks.
public protocol ImageAttaching {
    /// Mounts `image` read-only at `mountPoint`, which must exist and be empty.
    func attach(image: String, at mountPoint: String) throws
    /// Ejects whatever is mounted at `mountPoint`. Never forces.
    func eject(mountPoint: String) throws
    /// Unmounts `mountPoint` even though something has it open, then ejects the
    /// image. Only ever called because the user asked for exactly this.
    func forceEject(mountPoint: String) throws
}

/// Uses `diskutil image attach`, the kernel-backed disk-image stack.
///
/// The older `hdiutil attach` is deliberately not used. It routes every read
/// through one user-space helper and collapses under the concurrent I/O of a
/// simulator boot: 881 against 6,704 reads per second on the same disk, and a
/// first boot of 219 seconds against 41. See docs/technical-assessment.md.
public struct Attacher: ImageAttaching {
    private let runner: ProcessRunning

    public init(runner: ProcessRunning = SystemProcessRunner()) {
        self.runner = runner
    }

    public func attach(image: String, at mountPoint: String) throws {
        let result = try runner.run("/usr/sbin/diskutil", [
            "image", "attach", "--readOnly", "--nobrowse", "--mountPoint", mountPoint, image,
        ])
        guard result.succeeded else {
            let message = Attacher.message(from: result)
            if message.localizedCaseInsensitiveContains("not permitted") {
                throw AttachError.notPermitted(image: image)
            }
            throw AttachError.attachFailed(image: image, message: message)
        }
    }

    public func eject(mountPoint: String) throws {
        let result = try runner.run("/usr/sbin/diskutil", ["eject", mountPoint])
        guard result.succeeded else {
            throw AttachError.busy(mountPoint: mountPoint, message: Attacher.message(from: result))
        }
    }

    public func forceEject(mountPoint: String) throws {
        // Find the image's device before the mount, and with it the route to
        // the device, disappears.
        let device = wholeDisk(forMountPoint: mountPoint)
        let result = try runner.run("/usr/sbin/diskutil", ["unmount", "force", mountPoint])
        guard result.succeeded else {
            throw AttachError.busy(mountPoint: mountPoint, message: Attacher.message(from: result))
        }
        if let device {
            _ = try? runner.run("/usr/sbin/diskutil", ["eject", device])
        }
    }

    /// The disk-image device behind an APFS volume mounted at `mountPoint`,
    /// for example `disk10` for a volume on `disk11s1`.
    func wholeDisk(forMountPoint mountPoint: String) -> String? {
        guard let result = try? runner.run("/usr/sbin/diskutil", ["info", "-plist", mountPoint]),
              result.succeeded
        else { return nil }
        return Attacher.parseWholeDisk(result.standardOutput)
    }

    static func parseWholeDisk(_ data: Data) -> String? {
        guard
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let dictionary = plist as? [String: Any],
            let stores = dictionary["APFSPhysicalStores"] as? [[String: Any]],
            let store = stores.first?["APFSPhysicalStore"] as? String,
            let slice = store.range(of: #"s\d+$"#, options: .regularExpression)
        else { return nil }
        return String(store[..<slice.lowerBound])
    }

    private static func message(from result: ProcessResult) -> String {
        let text = result.errorText.isEmpty ? result.outputText : result.errorText
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
