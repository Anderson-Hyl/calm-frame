import XCTVapor
import JWTKit
import FluentSQLiteDriver
@testable import App

// MARK: - Fake Apple Token Verifier

/// Injected in tests to avoid real network calls to Apple's JWKS endpoint.
private struct FakeAppleTokenVerifier: AppleTokenVerifier {
    /// Maps raw token strings to the `sub` they should resolve to.
    /// Tokens not present in the map cause a thrown `.invalidToken` error.
    let tokenToSub: [String: String]

    func verify(_ identityToken: String, audience: String) async throws -> String {
        guard let sub = tokenToSub[identityToken] else {
            throw AppleTokenVerificationError.invalidToken
        }
        return sub
    }
}

// MARK: - Test Helpers

/// Builds a test `Application` backed by an in-memory SQLite database and the
/// fake Apple verifier — no real Postgres or network required.
private func makeApp(verifier: any AppleTokenVerifier) async throws -> Application {
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

    // Register auth route with the fake verifier.
    try app.register(collection: AuthController(appleVerifier: verifier))
    return app
}

// MARK: - Tests

final class AuthTests: XCTestCase {

    // MARK: New user receives 5 starter credits

    func testNewUserReceivesStarterCredits() async throws {
        let verifier = FakeAppleTokenVerifier(tokenToSub: ["valid-token": "apple-sub-001"])
        let app = try await makeApp(verifier: verifier)
        defer { Task { try await app.asyncShutdown() } }

        try await app.testable().test(.POST, "v1/auth/apple", beforeRequest: { req async throws in
            try req.content.encode(["identityToken": "valid-token"])
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let body = try res.content.decode(TestAuthResponse.self)
            XCTAssertFalse(body.token.isEmpty, "token must be non-empty")
            XCTAssertEqual(body.balance, 5, "new user must get exactly 5 starter credits")
        })
    }

    // MARK: Repeat sign-in does not double-grant starter credits

    func testRepeatSignInDoesNotDuplicateStarterCredits() async throws {
        let verifier = FakeAppleTokenVerifier(tokenToSub: ["valid-token": "apple-sub-002"])
        let app = try await makeApp(verifier: verifier)
        defer { Task { try await app.asyncShutdown() } }

        let tester = try app.testable()

        // First sign-in
        try await tester.test(.POST, "v1/auth/apple", beforeRequest: { req async throws in
            try req.content.encode(["identityToken": "valid-token"])
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
        })

        // Second sign-in with the same identity token (same Apple sub)
        try await tester.test(.POST, "v1/auth/apple", beforeRequest: { req async throws in
            try req.content.encode(["identityToken": "valid-token"])
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let body = try res.content.decode(TestAuthResponse.self)
            XCTAssertEqual(body.balance, 5, "balance must remain 5 after repeat sign-in, not 10")
        })
    }

    // MARK: Invalid token returns 401

    func testInvalidTokenReturns401() async throws {
        let verifier = FakeAppleTokenVerifier(tokenToSub: [:]) // rejects all tokens
        let app = try await makeApp(verifier: verifier)
        defer { Task { try await app.asyncShutdown() } }

        try await app.testable().test(.POST, "v1/auth/apple", beforeRequest: { req async throws in
            try req.content.encode(["identityToken": "garbage-token"])
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .unauthorized)
        })
    }
}

// MARK: - Local decode helper

private struct TestAuthResponse: Decodable {
    var token: String
    var balance: Int
}
