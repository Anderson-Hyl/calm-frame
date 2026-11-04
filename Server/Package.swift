// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "calm-frame-server",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // Web framework — latest stable Vapor 4
        .package(url: "https://github.com/vapor/vapor.git", from: "4.122.3"),
        // ORM
        .package(url: "https://github.com/vapor/fluent.git", from: "4.13.0"),
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.14.0"),
        // JWT signing/verification (Vapor-4-compatible series)
        .package(url: "https://github.com/vapor/jwt-kit.git", from: "4.13.5"),
        // SQLite driver for in-memory test databases
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.8.0"),
        // Shared models — local package
        .package(name: "CalmFrameKit", path: "../Packages/CalmFrameKit"),
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "JWTKit", package: "jwt-kit"),
                .product(name: "CalmFrameKit", package: "CalmFrameKit"),
            ],
            path: "Sources/App",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "AppTests",
            dependencies: [
                .target(name: "App"),
                .product(name: "XCTVapor", package: "vapor"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
            ],
            path: "Tests/AppTests",
            swiftSettings: swiftSettings
        ),
    ]
)

var swiftSettings: [SwiftSetting] {
    [
        .enableUpcomingFeature("DisableOutwardActorInference"),
        .enableUpcomingFeature("ExistentialAny"),
    ]
}
