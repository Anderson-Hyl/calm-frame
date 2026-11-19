import CalmFrameKit
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
    app.migrations.add(CreatePaintings())
    app.migrations.add(CreateAiCosts())
    app.migrations.add(AddPaintingStateToUsers())
    try await app.autoMigrate()

    // MARK: - Paintings
    // Wires the painting generation chain (plan §2): image provider,
    // prompt writer and storage, selected from the environment.
    // Throws at startup on a bad configuration (unknown provider, missing
    // API key for a real provider, unsupported storage backend) — a
    // fail-fast, never a silent fallback to fake (plan §2.2/§2.3).
    try app.configurePaintings()

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

    /// Wires the painting generation chain from the environment (plan §2).
    /// Throws at startup on a bad configuration — unknown `IMAGE_PROVIDER`,
    /// missing `IMAGE_API_KEY` for a real provider, or an unsupported
    /// `STORAGE_BACKEND` — instead of silently falling back to fake.
    func configurePaintings() throws {
        let imageProviderName = Environment.get("IMAGE_PROVIDER") ?? "fake"
        let imageAPIKey = Environment.get("IMAGE_API_KEY")
        let textModel = Environment.get("ARK_TEXT_MODEL") ?? DoubaoPromptWriter.defaultModel
        let storageBackend = Environment.get("STORAGE_BACKEND") ?? "local"
        let paintingsDir = Environment.get("PAINTINGS_DIR") ?? "paintings/"

        let imageProvider = try ImageProviderFactory.make(
            provider: imageProviderName,
            failMode: Environment.get("FAKE_IMAGE_FAIL")?.lowercased() == "true"
        )
        let promptWriter = try PromptWriterFactory.make(
            provider: imageProviderName,
            apiKey: imageAPIKey,
            textModel: textModel
        ) { request in
            try await self.client.send(request)
        }

        let paintingsDirectory: URL = paintingsDir.hasPrefix("/")
            ? URL(fileURLWithPath: paintingsDir, isDirectory: true)
            : URL(fileURLWithPath: directory.workingDirectory)
                .appendingPathComponent(paintingsDir, isDirectory: true)
        let baseURL: URL
        if let rawBaseURL = Environment.get("PUBLIC_BASE_URL") {
            guard let parsed = URL(string: rawBaseURL) else {
                throw PaintingsConfigurationError.invalidBaseURL(rawBaseURL)
            }
            baseURL = parsed
        } else {
            baseURL = URL(string: "http://127.0.0.1:8080")!
        }
        let storage = try StorageServiceFactory.make(
            backend: storageBackend, directory: paintingsDirectory, baseURL: baseURL
        )

        // Style anchor images (public domain, same source as the client's
        // bundled paintings). Missing files are skipped with a warning —
        // fake ignores them, and a real provider generates without a
        // reference rather than failing the whole server.
        let referenceDir = URL(fileURLWithPath: directory.resourcesDirectory)
            .appendingPathComponent("ReferencePaintings", isDirectory: true)
        var referenceImages: [PaintingStyle: Data] = [:]
        for (style, file) in PaintingStyle.referenceImageFiles {
            if let data = try? Data(contentsOf: referenceDir.appendingPathComponent(file)) {
                referenceImages[style] = data
            } else {
                logger.warning("paintings: reference image missing, generating without it", metadata: [
                    "style": .string(style.rawValue),
                    "file": .string(file),
                ])
            }
        }

        let service = PaintingService(
            promptWriter: promptWriter,
            imageProvider: imageProvider,
            storage: storage,
            referenceImages: referenceImages,
            logger: logger
        )
        configurePaintings(service: service, staticDirectory: paintingsDirectory)
    }
}
