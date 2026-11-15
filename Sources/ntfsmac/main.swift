import Foundation
import NTFSKit

func fail(_ msg: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("ntfsmac: \(msg)\n".utf8))
    exit(code)
}

let usage = """
usage: ntfsmac <command> [args]

  list [--json]                 list external NTFS volumes
  mount <disk> [--force]        mount read-write   (needs root: sudo ntfsmac mount disk4s1)
  unmount <disk> [--eject]      unmount            (needs root)
  fix <disk>                    clear dirty flag   (needs root)
  doctor                        check the installation

<disk> is a BSD identifier from `ntfsmac list`, e.g. disk4s1.
"""

func human(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

func requireRoot() {
    if geteuid() != 0 { fail("this command needs root. Re-run with sudo.", code: 77) }
}

func invokingUser() -> (UInt32, UInt32) {
    let env = ProcessInfo.processInfo.environment
    if let u = env["SUDO_UID"].flatMap(UInt32.init), let g = env["SUDO_GID"].flatMap(UInt32.init) { return (u, g) }
    if let u = env["NTFSMAC_UID"].flatMap(UInt32.init), let g = env["NTFSMAC_GID"].flatMap(UInt32.init) { return (u, g) }
    return (getuid(), getgid())
}

var args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { print(usage); exit(64) }
args.removeFirst()
let flags = Set(args.filter { $0.hasPrefix("--") })
let positional = args.filter { !$0.hasPrefix("--") }

switch cmd {
case "list":
    let vols = Discovery.ntfsVolumes()
    if flags.contains("--json") {
        let arr = vols.map { v -> [String: Any] in
            ["id": v.id, "label": v.label, "size": v.sizeBytes,
             "rwMount": v.rwMountPoint ?? NSNull(), "roMount": v.roMountPoint ?? NSNull()]
        }
        let data = try JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    } else if vols.isEmpty {
        print("No external NTFS volumes found.")
    } else {
        for v in vols {
            let state = v.rwMountPoint.map { "read-write at \($0)" }
                ?? v.roMountPoint.map { "read-only at \($0)" } ?? "not mounted"
            print("\(v.id)\t\(v.displayName)\t\(human(v.sizeBytes))\t\(state)")
        }
    }
case "mount":
    guard let id = positional.first else { fail("mount: missing <disk>", code: 64) }
    do { try Mounter.validate(id: id) } catch { fail("\(error)", code: 64) }
    requireRoot()
    let (u, g) = invokingUser()
    var o = MountOptions(uid: u, gid: g)
    o.removeHiberfile = flags.contains("--force")
    do { print("Mounted read-write at \(try Mounter.mount(id: id, options: o))") }
    catch { fail("\(error)") }
case "unmount", "umount":
    guard let id = positional.first else { fail("unmount: missing <disk>", code: 64) }
    do { try Mounter.validate(id: id) } catch { fail("\(error)", code: 64) }
    requireRoot()
    do { try Mounter.unmount(id: id, eject: flags.contains("--eject")); print("Unmounted \(id)") }
    catch { fail("\(error)") }
case "fix":
    guard let id = positional.first else { fail("fix: missing <disk>", code: 64) }
    do { try Mounter.validate(id: id) } catch { fail("\(error)", code: 64) }
    requireRoot()
    do { print(try Mounter.fix(id: id)) } catch { fail("\(error)") }
case "doctor":
    print("FUSE-T:    \(Mounter.fuseTInstalled() ? "installed" : "MISSING (brew install --cask macos-fuse-t/cask/fuse-t)")")
    print("ntfs-3g:   \(Mounter.driverPath() ?? "MISSING (run scripts/build-driver.sh)")")
    print("root:      \(geteuid() == 0 ? "yes" : "no (mount/unmount need sudo)")")
default:
    print(usage); exit(64)
}
