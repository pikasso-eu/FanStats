// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FanStats",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "SMCCore"),
        .executableTarget(name: "fanprobe", dependencies: ["SMCCore"]),
        .executableTarget(name: "fanlog", dependencies: ["SMCCore"]),
        .executableTarget(name: "fananalyze"),
        .executableTarget(name: "FanStats", dependencies: ["SMCCore"]),
    ]
)
