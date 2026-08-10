// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CopyCo",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "CopyCo", targets: ["CopyCo"]),
        .library(name: "CopyCoCore", targets: ["CopyCoCore"])
    ],
    targets: [
        .target(name: "CopyCoCore"),
        .executableTarget(name: "CopyCo", dependencies: ["CopyCoCore"]),
        .testTarget(name: "CopyCoCoreTests", dependencies: ["CopyCoCore", "CopyCo"])
    ]
)
