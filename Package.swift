// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Sayso",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Sayso", path: "Sources/Sayso")
    ]
)
