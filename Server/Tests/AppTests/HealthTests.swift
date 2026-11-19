import FluentSQLiteDriver
import XCTVapor
@testable import App

final class HealthTests: XCTestCase {
    func testHealthEndpoint() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try await app.asyncShutdown() } }

        // Use in-memory SQLite so no real Postgres is required.
        app.databases.use(.sqlite(.memory), as: .psql, isDefault: true)
        app.migrations.add(CreateUsers())
        app.migrations.add(CreateLedgerEntries())
        app.migrations.add(CreatePaintings())
        app.migrations.add(CreateAiCosts())
        app.migrations.add(AddPaintingStateToUsers())
        try await app.autoMigrate()
        // routes() needs the App Store verifier configured (as configure() does
        // in production); the health endpoint itself never uses it, so the fake is enough.
        app.appStoreVerifier = FakeAppStoreVerifier()
        try routes(app)

        try await app.testable().test(.GET, "health") { res async throws in
            XCTAssertEqual(res.status, .ok)
            let body = try res.content.decode([String: String].self)
            XCTAssertEqual(body["status"], "ok")
        }
    }
}
