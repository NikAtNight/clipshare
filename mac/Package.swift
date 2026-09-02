// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ClipShare",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .target(
            name: "ClipShareCore",
            path: "Sources/ClipShareCore",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "ClipShare",
            dependencies: ["ClipShareCore"],
            path: "Sources/ClipShare",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "ClipShareCoreTests",
            dependencies: ["ClipShareCore"],
            path: "Tests/ClipShareCoreTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
