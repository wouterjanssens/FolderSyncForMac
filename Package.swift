// swift-tools-version:6.0
import PackageDescription

// Tools version 6.0 is required so `swift test` can use the built-in
// swift-testing framework. The app target keeps the Swift 5 language mode to
// avoid opting the existing code into strict concurrency checking.
let package = Package(
    name: "FolderSync",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "FolderSync",
            path: "Sources/FolderSync",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "FolderSyncTests",
            dependencies: ["FolderSync"],
            path: "Tests/FolderSyncTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
