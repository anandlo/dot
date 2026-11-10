// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "dot",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Dot", targets: ["Dot"]),
        .library(name: "DotCore", targets: ["DotCore"]),
    ],
    targets: [
        .target(
            name: "DotCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Dot",
            dependencies: ["DotCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DotCoreTests",
            dependencies: ["DotCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DotTests",
            dependencies: ["Dot", "DotCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
