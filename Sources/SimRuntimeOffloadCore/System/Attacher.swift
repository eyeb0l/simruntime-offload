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

    private static func message(from result: ProcessResult) -> String {
        let text = result.errorText.isEmpty ? result.outputText : result.errorText
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
