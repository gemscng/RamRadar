// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RamRadar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "RamRadar", targets: ["RamRadar"]),
    ],
    targets: [
        .target(name: "RamRadarCore"),
        .executableTarget(name: "RamRadar", dependencies: ["RamRadarCore"]),
        .testTarget(name: "RamRadarCoreTests", dependencies: ["RamRadarCore"]),
    ]
)
