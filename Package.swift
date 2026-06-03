// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StorageAI",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "StorageAI", targets: ["StorageAI"])
    ],
    targets: [
        .executableTarget(
            name: "StorageAI",
            path: "StorageAI",
            exclude: ["Info.plist"]
        ),
        .testTarget(
            name: "StorageAITests",
            dependencies: ["StorageAI"],
            path: "Tests/StorageAITests"
        )
    ]
)
