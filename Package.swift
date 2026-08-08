// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Loupe",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "Loupe", targets: ["Loupe"]),
        .executable(name: "loupe", targets: ["LoupeCLI"]),
    ],
    targets: [
        .target(name: "Loupe"),
        .executableTarget(name: "LoupeCLI", dependencies: ["Loupe"]),
        .testTarget(name: "LoupeTests", dependencies: ["Loupe"]),
    ]
)
