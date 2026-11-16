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
        // Apple App Store Server Library — verifies StoreKit JWS signatures
        // (x5c chain) for redeem + App Store Server Notifications.
        //
        // Version note (2026-11-16, verified against the library source):
        // v3.0.0+ of this library requires jwt-kit 5, which conflicts with
        // Vapor 4's jwt-kit 4 — SPM cannot resolve v6 in this graph.
        // v2.3.0 is the newest release that resolves with Vapor 4 / jwt-kit 4.
        // Its EventLoop deadlock (apple/app-store-server-library-swift#113,
        // fixed in v5) lives in the OCSP request path only, so online checks
        // stay OFF (see AppStoreVerifier.swift); offline chain verification
        // still proves the signature is Apple's. Production online checks
        // need a library/Vapor upgrade — see verify-calm-frame/SKILL.md.
        .package(url: "https://github.com/apple/app-store-server-library-swift.git", .upToNextMinor(from: "2.3.0")),
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
                .product(name: "AppStoreServerLibrary", package: "app-store-server-library-swift"),
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
