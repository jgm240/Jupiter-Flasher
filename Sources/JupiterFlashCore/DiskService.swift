// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public struct Disk: Identifiable, Hashable, Sendable {
    /// BSD name of the whole disk, e.g. "disk4".
    public let id: String
    public let name: String
    public let size: Int64
    public let busProtocol: String
    public let isRemovable: Bool
    public let volumeNames: [String]

    public var device: String { "/dev/\(id)" }

    public var displayName: String {
        let vols = volumeNames.isEmpty ? "" : " [\(volumeNames.joined(separator: ", "))]"
        return "\(name)\(vols) (\(id), \(ByteFormat.string(size)))"
    }
}

public enum ByteFormat {
    public static func string(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}

public enum DiskService {
    static let diskutil = "/usr/sbin/diskutil"

    /// True when disk-image-backed "external" disks should be listed too (used for testing only).
    static var allowVirtual: Bool { ProcessInfo.processInfo.environment["JUPITERFLASH_ALLOW_VIRTUAL"] == "1" }

    static func plist(_ args: [String]) async throws -> [String: Any] {
        let data = try await Shell.runData(diskutil, args)
        guard let obj = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw FlashError.message("Unexpected output from diskutil.")
        }
        return obj
    }

    /// Lists candidate target disks. Internal disks and the disk macOS is running from are never returned.
    /// - Parameter includeFixed: also list external disks that don't identify as removable (external HDD/SSD).
    public static func listDisks(includeFixed: Bool) async throws -> [Disk] {
        let listArgs = allowVirtual ? ["list", "-plist", "external"] : ["list", "-plist", "external", "physical"]
        let list = try await plist(listArgs)
        let entries = list["AllDisksAndPartitions"] as? [[String: Any]] ?? []

        let bootDisk = (try? await plist(["info", "-plist", "/"]))?["ParentWholeDisk"] as? String

        var result: [Disk] = []
        for entry in entries {
            guard let id = entry["DeviceIdentifier"] as? String, id != bootDisk else { continue }
            guard let info = try? await plist(["info", "-plist", "/dev/\(id)"]) else { continue }
            if info["Internal"] as? Bool == true { continue }
            if info["WholeDisk"] as? Bool == false { continue }
            if !allowVirtual, (info["VirtualOrPhysical"] as? String) == "Virtual" { continue }

            let removable = info["RemovableMedia"] as? Bool ?? false
            if !removable && !includeFixed { continue }

            let parts = entry["Partitions"] as? [[String: Any]] ?? []
            let vols = parts.compactMap { $0["VolumeName"] as? String }.filter { !$0.isEmpty }
            let name = (info["MediaName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled drive"
            let size = (entry["Size"] as? Int64) ?? (entry["Size"] as? Int).map(Int64.init) ?? 0
            result.append(Disk(
                id: id, name: name, size: size,
                busProtocol: info["BusProtocol"] as? String ?? "Unknown",
                isRemovable: removable, volumeNames: vols))
        }
        return result
    }

    /// Re-checks a disk right before it's erased. Throws if it is not a safe target.
    public static func verifySafeTarget(_ disk: Disk) async throws {
        let info = try await plist(["info", "-plist", disk.device])
        if info["Internal"] as? Bool == true { throw FlashError.message("\(disk.id) is an internal disk. Refusing to erase it.") }
        if info["WholeDisk"] as? Bool == false { throw FlashError.message("\(disk.id) is a partition, not a whole disk.") }
        if let boot = (try? await plist(["info", "-plist", "/"]))?["ParentWholeDisk"] as? String, boot == disk.id {
            throw FlashError.message("\(disk.id) holds the running macOS system. Refusing to erase it.")
        }
    }

    /// Safety checks for a raw (DD) write, run by the privileged helper. Never trust the caller's choice.
    public static func verifyRawTarget(id: String, imageSize: Int64) async throws {
        guard id.range(of: "^disk[0-9]+$", options: .regularExpression) != nil else {
            throw FlashError.message("“\(id)” is not a valid whole-disk name.")
        }
        let info = try await plist(["info", "-plist", "/dev/\(id)"])
        if info["Internal"] as? Bool == true { throw FlashError.message("\(id) is an internal disk. Refusing to write to it.") }
        if info["WholeDisk"] as? Bool != true { throw FlashError.message("\(id) is not a whole disk.") }
        if info["VirtualOrPhysical"] as? String == "Virtual", !allowVirtual {
            throw FlashError.message("\(id) is a virtual disk. Refusing to write to it.")
        }
        if let boot = (try? await plist(["info", "-plist", "/"]))?["ParentWholeDisk"] as? String, boot == id {
            throw FlashError.message("\(id) holds the running macOS system. Refusing to write to it.")
        }
        let size = (info["TotalSize"] as? Int64) ?? (info["Size"] as? Int64) ?? 0
        if size > 0 && imageSize > size {
            throw FlashError.message("The image (\(ByteFormat.string(imageSize))) is larger than the drive (\(ByteFormat.string(size))).")
        }
    }

    /// Unmounts every volume on the disk so it can be written raw.
    public static func unmountDisk(id: String) async throws {
        _ = try await Shell.run(diskutil, ["unmountDisk", "force", "/dev/\(id)"])
    }

    /// Unmounts and re-mounts the partition named `label` (so later reads come from the device, not the cache).
    static func remount(label: String, on disk: Disk) async throws -> URL {
        let list = try await plist(["list", "-plist", disk.device])
        let parts = (list["AllDisksAndPartitions"] as? [[String: Any]])?.first?["Partitions"] as? [[String: Any]] ?? []
        guard let id = parts.first(where: { ($0["VolumeName"] as? String) == label })?["DeviceIdentifier"] as? String else {
            throw FlashError.message("Couldn't find the volume “\(label)” to verify.")
        }
        _ = try await Shell.run(diskutil, ["unmount", "/dev/\(id)"])
        _ = try await Shell.run(diskutil, ["mount", "/dev/\(id)"])
        return try await mountPoint(of: label, on: disk)
    }

    /// Finds the mount point of the partition named `label` on `disk` after formatting.
    static func mountPoint(of label: String, on disk: Disk) async throws -> URL {
        let list = try await plist(["list", "-plist", disk.device])
        let parts = (list["AllDisksAndPartitions"] as? [[String: Any]])?.first?["Partitions"] as? [[String: Any]] ?? []
        for p in parts where (p["VolumeName"] as? String) == label {
            if let mp = p["MountPoint"] as? String, !mp.isEmpty { return URL(fileURLWithPath: mp) }
        }
        throw FlashError.message("The freshly formatted volume “\(label)” did not mount.")
    }
}
