import Foundation

public struct MountError: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}

public struct MountOptions {
    public var uid: UInt32
    public var gid: UInt32
    /// Drop the Windows hibernation file when the volume was left hibernated (loses that session).
    public var removeHiberfile = false
    public init(uid: UInt32, gid: UInt32) { self.uid = uid; self.gid = gid }
}

public enum Mounter {
    // MARK: Validation

    /// Only accept plain BSD identifiers; this code runs as root.
    public static func validate(id: String) throws {
        guard id.range(of: #"^disk[0-9]+(s[0-9]+)?$"#, options: .regularExpression) != nil else {
            throw MountError("Invalid disk identifier '\(id)' (expected e.g. disk4s1)")
        }
    }

    static func sanitize(label: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\0")
        let s = label.components(separatedBy: bad).joined(separator: "_")
            .trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "NTFS" : s
    }

    // MARK: Driver lookup

    public static func driverPath() -> String? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["NTFSMAC_NTFS3G"], fm.isExecutableFile(atPath: env) {
            return env
        }
        var candidates: [String] = []
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            .deletingLastPathComponent()
        // App bundle: Contents/MacOS/<exe> -> Contents/Resources/ntfs-3g/bin/ntfs-3g
        candidates.append(exeDir.appendingPathComponent("../Resources/ntfs-3g/bin/ntfs-3g").standardized.path)
        // Dev tree: walk upwards looking for build/prefix/bin/ntfs-3g
        var dir = exeDir
        for _ in 0..<6 {
            candidates.append(dir.appendingPathComponent("build/prefix/bin/ntfs-3g").path)
            dir = dir.deletingLastPathComponent()
        }
        candidates += ["/opt/homebrew/bin/ntfs-3g", "/usr/local/bin/ntfs-3g"]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    public static func fuseTInstalled() -> Bool {
        FileManager.default.fileExists(atPath: "/usr/local/lib/libfuse-t.dylib")
    }

    // MARK: Mount

    /// Mounts read-write. Must run as root for real block devices. Returns the mount point.
    @discardableResult
    public static func mount(id: String, options: MountOptions) throws -> String {
        try validate(id: id)
        guard fuseTInstalled() else {
            throw MountError("FUSE-T is not installed. Install it with: brew install --cask macos-fuse-t/cask/fuse-t")
        }
        guard let driver = driverPath() else {
            throw MountError("ntfs-3g driver not found. Run scripts/build-driver.sh first.")
        }
        guard let vol = Discovery.ntfsVolumes().first(where: { $0.id == id }) else {
            throw MountError("\(id) is not an external NTFS volume.")
        }
        if let mp = vol.rwMountPoint { return mp }

        // The built-in driver mounts NTFS read-only; it must let go of the device first.
        if vol.roMountPoint != nil {
            let r = Shell.run("/usr/sbin/diskutil", ["unmount", id])
            guard r.status == 0 else {
                throw MountError("Could not unmount \(id) from the read-only driver (files in use?): \(r.stderr)")
            }
        }

        let fm = FileManager.default
        var mountPoint = "/Volumes/" + sanitize(label: vol.label)
        if fm.fileExists(atPath: mountPoint),
           (try? fm.contentsOfDirectory(atPath: mountPoint).isEmpty) != true {
            mountPoint += " (\(id))"
        }
        try? fm.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)

        var o = ["rw", "volname=\(sanitize(label: vol.label))", "local", "noatime", "windows_names",
                 "uid=\(options.uid)", "gid=\(options.gid)"]
        if options.removeHiberfile { o.append("remove_hiberfile") }
        let r = Shell.run(driver, [vol.device, mountPoint, "-o", o.joined(separator: ",")])
        guard r.status == 0 else {
            try? fm.removeItem(atPath: mountPoint) // only succeeds if empty
            _ = Shell.run("/usr/sbin/diskutil", ["mount", id]) // give it back to macOS (read-only)
            throw MountError(explain(status: r.status, stderr: r.stderr))
        }
        return mountPoint
    }

    static func explain(status: Int32, stderr: String) -> String {
        let s = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let low = s.lowercased()
        if low.contains("hibernat") || low.contains("fast restart") || low.contains("fast startup") {
            return "Windows left this disk hibernated (Fast Startup). Shut Windows down fully "
                 + "(or run `powercfg /h off`), or mount with --force to discard the hibernation file.\n\(s)"
        }
        if low.contains("unclean") || low.contains("dirty") || low.contains("not cleanly") {
            return "The volume was not cleanly unmounted. Run chkdsk on Windows, or `ntfsmac fix <disk>`.\n\(s)"
        }
        return s.isEmpty ? "ntfs-3g failed with exit code \(status)" : s
    }

    // MARK: Unmount

    /// Unmounts our read-write mount and hands the volume back to macOS (read-only).
    public static func unmount(id: String, eject: Bool = false) throws {
        try validate(id: id)
        guard let vol = Discovery.ntfsVolumes().first(where: { $0.id == id }) else {
            throw MountError("\(id) is not an NTFS volume.")
        }
        if let mp = vol.rwMountPoint {
            var r = Shell.run("/sbin/umount", [mp])
            if r.status != 0 { r = Shell.run("/usr/sbin/diskutil", ["unmount", mp]) }
            guard r.status == 0 else {
                throw MountError("Could not unmount \(mp) (files in use?): \(r.stderr)")
            }
            try? FileManager.default.removeItem(atPath: mp) // removes only if empty
        }
        if eject {
            let whole = id.replacingOccurrences(of: #"s[0-9]+$"#, with: "", options: .regularExpression)
            let r = Shell.run("/usr/sbin/diskutil", ["eject", whole])
            guard r.status == 0 else { throw MountError("Eject failed: \(r.stderr)") }
        } else if vol.rwMountPoint != nil {
            _ = Shell.run("/usr/sbin/diskutil", ["mount", id])
        }
    }

    // MARK: Repair

    /// Clears the dirty flag / replays the log via ntfsfix (no full chkdsk replacement).
    public static func fix(id: String) throws -> String {
        try validate(id: id)
        guard let driver = driverPath() else { throw MountError("ntfs-3g driver not found.") }
        let fixer = URL(fileURLWithPath: driver).deletingLastPathComponent().appendingPathComponent("ntfsfix").path
        let r = Shell.run(fixer, ["-d", "/dev/\(id)"])
        guard r.status == 0 else { throw MountError(r.stderr) }
        return r.stdoutString
    }
}
