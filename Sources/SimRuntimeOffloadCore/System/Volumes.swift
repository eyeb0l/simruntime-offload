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

public enum VolumeLookupError: Error, Equatable, CustomStringConvertible {
    case unconfirmed(uuid: String)

    public var description: String {
        switch self {
        case .unconfirmed(let uuid):
            return "could not confirm whether volume \(uuid) is attached; do not unplug its disk"
        }
    }
}

/// Looks up volumes through `diskutil info -plist`.
public struct Volumes {
    private let runner: ProcessRunning

    public init(runner: ProcessRunning = SystemProcessRunner()) {
        self.runner = runner
    }

    /// The volume with this UUID, or `nil` when unavailable or lookup fails.
    public func volume(uuid: String) -> Volume? {
        guard UUID(uuidString: uuid) != nil,
              let result = try? runner.run("/usr/sbin/diskutil", ["info", "-plist", uuid]),
              result.succeeded,
              let volume = Volumes.parse(result.standardOutput),
              volume.uuid.caseInsensitiveCompare(uuid) == .orderedSame
        else { return nil }
        return volume
    }

    /// A destructive caller may treat nil as absence only after a successful,
    /// complete disk listing confirms it. Lookup errors must never become an
    /// assurance that a connected disk is safe to unplug.
    public func confirmedVolume(uuid: String) throws -> Volume? {
        guard UUID(uuidString: uuid) != nil else { throw VolumeLookupError.unconfirmed(uuid: uuid) }
        let result = try runner.run("/usr/sbin/diskutil", ["info", "-plist", uuid])
        if result.succeeded {
            guard let volume = Self.parse(result.standardOutput),
                  volume.uuid.caseInsensitiveCompare(uuid) == .orderedSame else {
                throw VolumeLookupError.unconfirmed(uuid: uuid)
            }
            return volume
        }
        let listing = try runner.run("/usr/sbin/diskutil", ["list", "-plist"])
        guard listing.succeeded,
              let plist = try? PropertyListSerialization.propertyList(from: listing.standardOutput, format: nil),
              let dictionary = plist as? [String: Any],
              let disks = dictionary["AllDisksAndPartitions"] as? [[String: Any]],
              dictionary["AllDisks"] is [String] else {
            throw VolumeLookupError.unconfirmed(uuid: uuid)
        }
        func check(_ node: [String: Any]) throws {
            if let found = node["VolumeUUID"] as? String {
                guard UUID(uuidString: found) != nil,
                      found.caseInsensitiveCompare(uuid) != .orderedSame else {
                    throw VolumeLookupError.unconfirmed(uuid: uuid)
                }
            } else if node["VolumeName"] != nil {
                // A volume with no identity cannot establish absence.
                throw VolumeLookupError.unconfirmed(uuid: uuid)
            }
            for key in ["Partitions", "APFSVolumes"] {
                if let children = node[key] {
                    guard let children = children as? [[String: Any]] else {
                        throw VolumeLookupError.unconfirmed(uuid: uuid)
                    }
                    for child in children { try check(child) }
                }
            }
        }
        for disk in disks { try check(disk) }
        return nil
    }

    /// Ejects the physical disk holding the volume, which unmounts every
    /// volume on it. Returns the tool's message on failure.
    ///
    /// The whole device, not the one volume: `diskutil eject <volume>` only
    /// unmounts that volume, and "safe to unplug" has to be true of the cable.
    /// If another volume on the disk is busy the eject fails, and that is the
    /// right answer.
    public func eject(uuid: String) -> String? {
        guard UUID(uuidString: uuid) != nil else { return "a volume UUID is required" }
        guard
            let info = try? runner.run("/usr/sbin/diskutil", ["info", "-plist", uuid]),
            info.succeeded
        else { return "the volume is no longer attached" }
        guard let volume = Volumes.parse(info.standardOutput),
              volume.uuid.caseInsensitiveCompare(uuid) == .orderedSame,
              !volume.isInternal else {
            return "refusing to eject an internal disk"
        }
        guard let target = Volumes.physicalDisk(info.standardOutput) else {
            return "could not identify the physical disk; do not unplug it"
        }
        guard let result = try? runner.run("/usr/sbin/diskutil", ["eject", target]) else {
            return "could not run diskutil"
        }
        if result.succeeded { return nil }
        let text = result.errorText.isEmpty ? result.outputText : result.errorText
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The whole physical disk behind a volume: for APFS, the disk its
    /// container's physical store is a slice of; otherwise the parent disk.
    static func physicalDisk(_ data: Data) -> String? {
        guard
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let dictionary = plist as? [String: Any]
        else { return nil }
        if dictionary["APFSPhysicalStores"] != nil || dictionary["FilesystemType"] as? String == "apfs" {
            guard let stores = dictionary["APFSPhysicalStores"] as? [[String: Any]], stores.count == 1 else { return nil }
            return Attacher.parseWholeDisk(data)
        }
        return dictionary["ParentWholeDisk"] as? String
    }

    static func parse(_ data: Data) -> Volume? {
        guard
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let dictionary = plist as? [String: Any],
            let uuid = dictionary["VolumeUUID"] as? String,
            UUID(uuidString: uuid) != nil,
            let isInternal = dictionary["Internal"] as? Bool
        else { return nil }
        let mountPoint = dictionary["MountPoint"] as? String
        // APFS reports free space for the container, which all its volumes share.
        let free = (dictionary["APFSContainerFree"] as? NSNumber) ?? (dictionary["FreeSpace"] as? NSNumber)
        return Volume(
            uuid: uuid,
            name: dictionary["VolumeName"] as? String ?? "",
            mountPoint: (mountPoint?.isEmpty ?? true) ? nil : mountPoint,
            isInternal: isInternal,
            freeBytes: free?.int64Value
        )
    }
}
