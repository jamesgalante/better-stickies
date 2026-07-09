// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Stickies",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Stickies", path: "Sources/Stickies")
    ]
)
