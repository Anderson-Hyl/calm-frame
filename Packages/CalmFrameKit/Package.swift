// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CalmFrameKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CalmFrameKit",
            targets: ["CalmFrameKit"]
        ),
    ],
    targets: [
        .target(
            name: "CalmFrameKit",
            path: "Sources/CalmFrameKit"
        ),
        .testTarget(
            name: "CalmFrameKitTests",
            dependencies: ["CalmFrameKit"],
            path: "Tests/CalmFrameKitTests"
        ),
    ]
)
