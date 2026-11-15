import Foundation

public enum Discovery {
    /// Lists NTFS volumes on external/removable disks (never the boot disk).
    public static func ntfsVolumes() -> [NTFSVolume] {
        let fuseMounts = currentFuseMounts()
        var result: [NTFSVolume] = []
        for id in externalPartitionIDs() {
            guard let info = plist(["info", "-plist", id]),
                  (info["FilesystemType"] as? String)?.lowercased() == "ntfs" else { continue }
            let label = info["VolumeName"] as? String ?? ""
            let size = (info["TotalSize"] as? NSNumber)?.int64Value
                ?? (info["Size"] as? NSNumber)?.int64Value ?? 0
            let appleMount = (info["MountPoint"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let rw = fuseMounts.first { $0.name == label && !label.isEmpty }?.path
            result.append(NTFSVolume(id: id, label: label, sizeBytes: size,
                                     rwMountPoint: rw,
                                     roMountPoint: rw == nil ? appleMount : nil))
        }
        return result
    }

    static func externalPartitionIDs() -> [String] {
        guard let list = plist(["list", "-plist", "external"]),
              let disks = list["AllDisksAndPartitions"] as? [[String: Any]] else { return [] }
        var ids: [String] = []
        for d in disks {
            // Whole-disk volumes (no partition map) and partitions are both candidates.
            if let id = d["DeviceIdentifier"] as? String { ids.append(id) }
            for p in d["Partitions"] as? [[String: Any]] ?? [] {
                if let id = p["DeviceIdentifier"] as? String { ids.append(id) }
            }
        }
        return ids
    }

    struct FuseMount { let name: String; let path: String }

    /// Parses `mount` output for FUSE-T mounts: "fuse-t:/NAME on /path (nfs, ...)".
    static func currentFuseMounts() -> [FuseMount] {
        let out = Shell.run("/sbin/mount", []).stdoutString
        var mounts: [FuseMount] = []
        for line in out.split(separator: "\n") where line.hasPrefix("fuse-t:/") {
            guard let onRange = line.range(of: " on ") else { continue }
            let name = String(line[line.index(line.startIndex, offsetBy: 8)..<onRange.lowerBound])
            var rest = String(line[onRange.upperBound...])
            if let paren = rest.range(of: " (", options: .backwards) { rest = String(rest[..<paren.lowerBound]) }
            mounts.append(FuseMount(name: name, path: rest))
        }
        return mounts
    }

    static func plist(_ args: [String]) -> [String: Any]? {
        let r = Shell.run("/usr/sbin/diskutil", args)
        guard r.status == 0,
              let obj = try? PropertyListSerialization.propertyList(from: r.stdout, format: nil),
              let dict = obj as? [String: Any] else { return nil }
        return dict
    }
}
