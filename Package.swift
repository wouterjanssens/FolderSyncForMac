// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FolderSync",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "FolderSync",
            path: "Sources/FolderSync"
        )
    ]
)
