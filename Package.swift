// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PlexPeek",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "PlexPeek", path: "Sources/PlexPeek")
    ]
)
