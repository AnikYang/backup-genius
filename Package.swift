// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BackupGenius",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "BackupCore", targets: ["BackupCore"]),
        .executable(name: "BackupGenius", targets: ["BackupGenius"]),
        .executable(name: "BackupBench", targets: ["BackupBench"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "CBackup"),
        .target(name: "BackupCore", dependencies: ["CSQLite", "CBackup"]),
        .executableTarget(name: "BackupGenius", dependencies: ["BackupCore"]),
        .executableTarget(name: "BackupBench", dependencies: ["BackupCore"]),
        .testTarget(name: "BackupCoreTests", dependencies: ["BackupCore"]),
    ]
)
