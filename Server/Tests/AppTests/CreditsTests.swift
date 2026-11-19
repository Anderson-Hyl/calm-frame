import XCTVapor
import JWTKit
import FluentSQLiteDriver
@testable import App

/// Builds a test `Application` backed by an in-memory SQLite database and the
/// credits route — no real Postgres or network required.
private func makeCreditsApp() async throws -> Application {
    let app = try await Application.make(.testing)

    // Use in-memory SQLite so tests are self-contained.
    app.databases.use(.sqlite(.memory), as: .psql, isDefault: true)

    // Register JWT signer.
    let signers = JWTSigners()
    signers.use(.hs256(key: "test-secret"))
    app.jwtSigners = signers

    // Run migrations.
    app.migrations.add(CreateUsers())
    app.migrations.add(CreateLedgerEntries())
    app.migrations.add(CreatePaintings())
    app.migrations.add(CreateAiCosts())
    app.migrations.add(AddPaintingStateToUsers())
    try await app.autoMigrate()

    // Register credits route.
    try app.register(collection: CreditsController(appStoreVerifier: FakeAppStoreVerifier()))
    return app
}

/// Signs a server JWT for `userID` with the test signer.
private func signToken(for userID: UUID, on app: Application) throws -> String {
    let payload = ServerJWTPayload(
        subject: SubjectClaim(value: userID.uuidString),
        expiration: ExpirationClaim(value: Date().addingTimeInterval(3600))
    )
    return try app.jwtSigners.sign(payload)
}

// MARK: - Tests

final class CreditsTests: XCTestCase {

    // MARK: Balance sums ledger deltas

    func testCreditsReturnsBalance() async throws {
        let app = try await makeCreditsApp()
        defer { Task { try await app.asyncShutdown() } }

        // Seed a user with a 5-credit starter entry.
        let userID = UUID()
        try await User(id: userID, appleSub: "apple-sub-001").save(on: app.db)
        try await LedgerService().grantStarter(to: userID, appleSub: "apple-sub-001", on: app.db)

        let token = try signToken(for: userID, on: app)

        try await app.testable().test(.GET, "v1/credits", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let body = try res.content.decode(TestCreditsResponse.self)
            XCTAssertEqual(body.balance, 5, "balance must be the sum of ledger deltas")
        })
    }

    // MARK: No ledger entries -> 0

    func testCreditsReturnsZeroWithoutEntries() async throws {
        let app = try await makeCreditsApp()
        defer { Task { try await app.asyncShutdown() } }

        let userID = UUID()
        try await User(id: userID, appleSub: "apple-sub-002").save(on: app.db)
        let token = try signToken(for: userID, on: app)

        try await app.testable().test(.GET, "v1/credits", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let body = try res.content.decode(TestCreditsResponse.self)
            XCTAssertEqual(body.balance, 0, "balance must be 0 with no ledger entries")
        })
    }

    // MARK: Missing token returns 401

    func testCreditsWithoutTokenReturns401() async throws {
        let app = try await makeCreditsApp()
        defer { Task { try await app.asyncShutdown() } }

        try await app.testable().test(.GET, "v1/credits") { res async throws in
            XCTAssertEqual(res.status, .unauthorized)
        }
    }

    // MARK: Garbage token returns 401

    func testCreditsWithBadTokenReturns401() async throws {
        let app = try await makeCreditsApp()
        defer { Task { try await app.asyncShutdown() } }

        try await app.testable().test(.GET, "v1/credits", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = BearerAuthorization(token: "garbage-token")
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .unauthorized)
        })
    }
}

// MARK: - Local decode helper

private struct TestCreditsResponse: Decodable {
    var balance: Int
}
