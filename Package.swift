// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NTFSMac",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "NTFSKit", targets: ["NTFSKit"]),
        .executable(name: "ntfsmac", targets: ["ntfsmac"]),
        .executable(name: "NTFSMacApp", targets: ["NTFSMacApp"]),
    ],
    targets: [
        .target(name: "NTFSKit"),
        .executableTarget(name: "ntfsmac", dependencies: ["NTFSKit"]),
        .executableTarget(name: "NTFSMacApp", dependencies: ["NTFSKit"]),
    ]
)
