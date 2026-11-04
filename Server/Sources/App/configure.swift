import Fluent
import FluentPostgresDriver
import Vapor

/// Configures the Vapor application: database, migrations, and routes.
public func configure(_ app: Application) async throws {
    // MARK: - Database
    // Read the connection URL from the environment.
    // The default matches docker-compose.yml for local development.
    let databaseURL = Environment.get("DATABASE_URL")
        ?? "postgres://calmframe:calmframe@localhost:5432/calmframe"

    try app.databases.use(.postgres(url: databaseURL), as: .psql)

    // MARK: - Migrations
    app.migrations.add(CreateUsers())
    app.migrations.add(CreateLedgerEntries())
    try await app.autoMigrate()

    // MARK: - Routes
    try routes(app)
}
