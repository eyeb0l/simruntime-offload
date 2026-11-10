import Foundation

/// A storage volume, identified by its APFS volume UUID.
///
/// The UUID is the only identity this tool trusts. A device node such as
/// `/dev/disk7s1` changes between connections, and a volume name can be shared
/// by two disks.
public struct Volume: Equatable, Sendable {
    public let uuid: String
    public let name: String
    /// `nil` when the volume is attached but not mounted.
    public let mountPoint: String?
    public let isInternal: Bool
    public let freeBytes: Int64?
}

/// Looks up volumes through `diskutil info -plist`.
public struct Volumes {
    private let runner: ProcessRunning

    public init(runner: ProcessRunning = SystemProcessRunner()) {
        self.runner = runner
    }

    /// The volume with this UUID, or `nil` when no such volume is attached.
    public func volume(uuid: String) -> Volume? {
        guard
            let result = try? runner.run("/usr/sbin/diskutil", ["info", "-plist", uuid]),
            result.succeeded
        else { return nil }
        return Volumes.parse(result.standardOutput)
    }

    static func parse(_ data: Data) -> Volume? {
        guard
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let dictionary = plist as? [String: Any],
            let uuid = dictionary["VolumeUUID"] as? String
        else { return nil }
        let mountPoint = dictionary["MountPoint"] as? String
        // APFS reports free space for the container, which all its volumes share.
        let free = (dictionary["APFSContainerFree"] as? NSNumber) ?? (dictionary["FreeSpace"] as? NSNumber)
        return Volume(
            uuid: uuid,
            name: dictionary["VolumeName"] as? String ?? "",
            mountPoint: (mountPoint?.isEmpty ?? true) ? nil : mountPoint,
            isInternal: dictionary["Internal"] as? Bool ?? false,
            freeBytes: free?.int64Value
        )
    }
}
