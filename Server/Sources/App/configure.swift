import Fluent
import FluentPostgresDriver
import JWTKit
import Vapor

/// Configures the Vapor application: database, migrations, and routes.
public func configure(_ app: Application) async throws {
    // MARK: - JWT
    // Register the HMAC-SHA256 signer used to sign and verify server-issued JWTs.
    // JWT_SECRET must be set in production; a fallback is provided for local dev only.
    let jwtSecret = Environment.get("JWT_SECRET") ?? "dev-secret-change-me"
    let signers = JWTSigners()
    signers.use(.hs256(key: jwtSecret))
    app.jwtSigners = signers

    // MARK: - App Store (StoreKit JWS verification)
    // Built from the environment + the bundled Apple Root CA - G3 certificate.
    // Throws at startup if the certificate is missing — a fail-fast for a
    // security-critical configuration error.
    app.appStoreVerifier = try LiveAppStoreVerifier.fromEnvironment(workingDirectory: app.directory.workingDirectory)

    // MARK: - Database
    // Read the connection URL from the environment.
    // The default matches docker-compose.yml for local development.
    let databaseURL = Environment.get("DATABASE_URL")
        ?? "postgres://calmframe:calmframe@localhost:5432/calmframe"

    try app.databases.use(.postgres(url: databaseURL), as: .psql)

    // MARK: - Migrations
    app.migrations.add(CreateUsers())
    app.migrations.add(CreateLedgerEntries())
    app.migrations.add(CreateAppStoreNotifications())
    try await app.autoMigrate()

    // MARK: - Routes
    try routes(app)
}

// MARK: - Application storage key for JWTSigners

/// `JWTSigners` is not `Sendable` in jwt-kit 4, so we wrap it with
/// `@unchecked Sendable` for storage. Access is always from the main actor
/// during app startup and from the event loop during request handling, which
/// is safe in practice.
final class JWTSignersBox: @unchecked Sendable {
    let signers: JWTSigners
    init(_ signers: JWTSigners) { self.signers = signers }
}

/// Stores a `JWTSigners` instance on the Vapor `Application` without requiring `vapor/jwt`.
struct JWTSignersKey: StorageKey {
    typealias Value = JWTSignersBox
}

extension Application {
    /// The shared JWT signers for this application instance.
    var jwtSigners: JWTSigners {
        get {
            storage[JWTSignersKey.self]?.signers ?? JWTSigners()
        }
        set {
            storage[JWTSignersKey.self] = JWTSignersBox(newValue)
        }
    }
}
