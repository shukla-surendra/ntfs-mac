import Foundation

/// The optional background service that mounts NTFS drives read-write as soon as they are plugged in,
/// plus a sudoers rule so the app can mount/unmount without asking for a password every time.
///
/// Security: the daemon runs as root, so it runs a root-owned copy of the app bundle (not the
/// user-writable one in /Applications), and the sudoers rule only allows that copy's
/// `ntfsmac mount|unmount`, for the one user who installed it.
public enum Helper {
    public static let label = "dev.local.ntfsmac.automount"
    public static let installDir = "/Library/Application Support/NTFSMac"
    public static let appPath = installDir + "/NTFS Mac.app"
    public static let cliPath = appPath + "/Contents/MacOS/ntfsmac"
    public static let plistPath = "/Library/LaunchDaemons/\(label).plist"
    public static let sudoersPath = "/etc/sudoers.d/ntfsmac"
    public static let logPath = "/var/log/ntfsmac.log"

    public static var isInstalled: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: plistPath) && fm.isExecutableFile(atPath: cliPath)
    }

    // MARK: Install / uninstall (root)

    /// Copies the app bundle containing the running CLI to a root-owned location, installs the
    /// LaunchDaemon and the sudoers rule for `user`.
    public static func install(user: String) throws {
        guard user.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil, user != "root" else {
            throw MountError("Refusing to install for user '\(user)'.")
        }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let bundle = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard bundle.pathExtension == "app",
              FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/Resources/ntfs-3g/bin/ntfs-3g").path) else {
            throw MountError("install-helper must be run from the packaged app (NTFS Mac.app/Contents/MacOS/ntfsmac).")
        }

        _ = Shell.run("/bin/launchctl", ["bootout", "system/\(label)"]) // stop an older copy, if any
        try check(Shell.run("/bin/mkdir", ["-p", installDir]))
        try check(Shell.run("/bin/rm", ["-rf", appPath]))
        try check(Shell.run("/usr/bin/ditto", [bundle.path, appPath]))
        try check(Shell.run("/usr/sbin/chown", ["-R", "root:wheel", installDir]))
        try check(Shell.run("/bin/chmod", ["-R", "go-w", installDir]))

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [cliPath, "watch"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: plistPath))
        try check(Shell.run("/usr/sbin/chown", ["root:wheel", plistPath]))
        try check(Shell.run("/bin/chmod", ["644", plistPath]))

        // sudoers: spaces in the path must be backslash-escaped.
        let cmd = cliPath.replacingOccurrences(of: " ", with: "\\ ")
        let rule = "# Installed by NTFS Mac: lets \(user) mount/unmount NTFS drives without a password.\n"
            + "\(user) ALL=(root) NOPASSWD: \(cmd) mount *, \(cmd) unmount *\n"
        let tmp = "/private/tmp/ntfsmac.sudoers.\(getpid())"
        try Data(rule.utf8).write(to: URL(fileURLWithPath: tmp))
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try check(Shell.run("/usr/sbin/visudo", ["-cf", tmp]))
        try check(Shell.run("/usr/sbin/chown", ["root:wheel", tmp]))
        try check(Shell.run("/bin/chmod", ["440", tmp]))
        try check(Shell.run("/bin/mv", ["-f", tmp, sudoersPath]))

        try check(Shell.run("/bin/launchctl", ["bootstrap", "system", plistPath]))
    }

    public static func uninstall() throws {
        _ = Shell.run("/bin/launchctl", ["bootout", "system/\(label)"])
        for p in [plistPath, sudoersPath] { try? FileManager.default.removeItem(atPath: p) }
        try check(Shell.run("/bin/rm", ["-rf", installDir]))
    }

    private static func check(_ r: ShellResult) throws {
        if r.status != 0 { throw MountError(r.stderr.isEmpty ? "command failed (\(r.status))" : r.stderr) }
    }

    // MARK: Daemon

    /// Runs forever (as root): mounts each newly connected NTFS volume read-write once, for the
    /// user logged in at the console, and opens it in Finder. A volume the user unmounts stays
    /// unmounted until it is unplugged and plugged in again.
    public static func watch(interval: TimeInterval = 3) -> Never {
        var firstSeen: [String: Date] = [:] // volume key -> when it appeared
        var handled = Set<String>()
        log("watching for NTFS drives")
        while true {
            let vols = Discovery.ntfsVolumes()
            let keys = Set(vols.map(key))
            handled.formIntersection(keys)
            firstSeen = firstSeen.filter { keys.contains($0.key) }

            for v in vols where !handled.contains(key(v)) {
                let k = key(v)
                let seen = firstSeen[k] ?? Date(); firstSeen[k] = seen
                if v.rwMountPoint != nil { handled.insert(k); continue }
                // Let macOS finish its own (read-only) mount first, so we don't race it for the device.
                guard v.roMountPoint != nil || Date().timeIntervalSince(seen) > 10 else { continue }
                guard let user = consoleUser() else { continue } // nobody logged in yet
                handled.insert(k)
                do {
                    let mp = try Mounter.mount(id: v.id, options: MountOptions(uid: user.uid, gid: user.gid))
                    log("mounted \(v.id) (\(v.displayName)) at \(mp)")
                    asUser(user, "/usr/bin/open", [mp])
                } catch {
                    log("could not mount \(v.id): \(error)")
                    notify(user, title: "Couldn't make “\(v.displayName)” writable",
                           text: "\(error)".components(separatedBy: "\n").first ?? "")
                }
            }
            Thread.sleep(forTimeInterval: interval)
        }
    }

    private static func key(_ v: NTFSVolume) -> String { v.id + "|" + v.label + "|\(v.sizeBytes)" }

    struct ConsoleUser { let uid: UInt32; let gid: UInt32; let name: String }

    static func consoleUser() -> ConsoleUser? {
        var st = stat()
        guard stat("/dev/console", &st) == 0, st.st_uid != 0, let pw = getpwuid(st.st_uid) else { return nil }
        return ConsoleUser(uid: st.st_uid, gid: pw.pointee.pw_gid, name: String(cString: pw.pointee.pw_name))
    }

    /// Runs a command in the logged-in user's GUI session, as that user.
    private static func asUser(_ u: ConsoleUser, _ path: String, _ args: [String]) {
        _ = Shell.run("/bin/launchctl", ["asuser", "\(u.uid)", "/usr/bin/sudo", "-u", u.name, path] + args)
    }

    private static func notify(_ u: ConsoleUser, title: String, text: String) {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        asUser(u, "/usr/bin/osascript", ["-e", "display notification \(q(text)) with title \(q(title))"])
    }

    private static func log(_ s: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("\(ts) \(s)\n".utf8))
    }
}
