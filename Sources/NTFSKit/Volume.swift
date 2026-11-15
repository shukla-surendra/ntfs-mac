import Foundation

public struct NTFSVolume: Equatable, Identifiable {
    /// BSD identifier, e.g. "disk4s1".
    public let id: String
    public let label: String
    public let sizeBytes: Int64
    /// Where the volume is mounted read-write by us (FUSE-T), if it is.
    public let rwMountPoint: String?
    /// Where macOS's built-in (read-only) driver has it mounted, if it is.
    public let roMountPoint: String?

    public var device: String { "/dev/\(id)" }
    public var isMountedRW: Bool { rwMountPoint != nil }
    public var displayName: String { label.isEmpty ? id : label }
}
