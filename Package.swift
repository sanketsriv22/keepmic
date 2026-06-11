// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "keepmic",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(name: "keepmic", path: "Sources/keepmic")
    ]
)
