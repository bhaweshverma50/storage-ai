// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SpaceLens",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SpaceLens", targets: ["SpaceLens"])
    ],
    targets: [
        .executableTarget(
            name: "SpaceLens",
            path: "SpaceLens",
            exclude: ["Info.plist", "SpaceLens.entitlements"]
        ),
        .testTarget(
            name: "SpaceLensTests",
            dependencies: ["SpaceLens"],
            path: "Tests/SpaceLensTests"
        )
    ]
)
