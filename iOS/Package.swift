// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EmdashDeps",
    platforms: [.iOS(.v18)],
    products: [],
    dependencies: [
        .package(url: "https://github.com/nicklockwood/SwiftFormat", from: "0.54.0"),
    ],
    targets: []
)
