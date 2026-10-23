// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OMPKit",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "OMPCore", targets: ["OMPCore"]),
        .library(name: "OMPDesign", targets: ["OMPDesign"]),
    ],
    targets: [
        .target(
            name: "OMPCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "OMPDesign",
            dependencies: ["OMPCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "OMPCoreTests",
            dependencies: ["OMPCore", "OMPDesign"],
            path: "Tests/OMPCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
