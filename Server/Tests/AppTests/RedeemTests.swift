import XCTVapor
import JWTKit
import FluentSQLiteDriver
@testable import App

/// Builds a test `Application` backed by an in-memory SQLite database and the
/// credits route with a fake App Store verifier — no real Postgres or network required.
private func makeRedeemApp(verifier: any AppStoreVerifier) async throws -> Application {
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
    app.migrations.add(CreateAppStoreNotifications())
    app.migrations.add(CreatePaintings())
    app.migrations.add(CreateAiCosts())
    app.migrations.add(AddPaintingStateToUsers())
    try await app.autoMigrate()

    // Register credits route with the fake verifier.
    try app.register(collection: CreditsController(appStoreVerifier: verifier))
    return app
}

/// Signs a server JWT for `userID` with the test signer.
private func signRedeemToken(for userID: UUID, on app: Application) throws -> String {
    let payload = ServerJWTPayload(
        subject: SubjectClaim(value: userID.uuidString),
        expiration: ExpirationClaim(value: Date().addingTimeInterval(3600))
    )
    return try app.jwtSigners.sign(payload)
}

/// Seeds a user with the 5-credit starter bonus and returns its ID.
/// Pass an explicit `userID` when the test needs to know it before seeding
/// (e.g. to build a verifier that expects that UUID as appAccountToken).
private func seedUserWithStarter(on app: Application, userID: UUID = UUID(), appleSub: String) async throws -> UUID {
    try await User(id: userID, appleSub: appleSub).save(on: app.db)
    try await LedgerService().grantStarter(to: userID, appleSub: appleSub, on: app.db)
    return userID
}

/// Counts purchase ledger rows for a user.
private func purchaseRowCount(for userID: UUID, on app: Application) async throws -> Int {
    let entries = try await LedgerEntry.query(on: app.db)
        .filter(\.$userID == userID)
        .all()
    return entries.filter { $0.reason == .purchase }.count
}

// MARK: - Tests

final class RedeemTests: XCTestCase {

    // MARK: Happy path — verified purchase credits the account

    func testRedeemHappyPath() async throws {
        let verifier = FakeAppStoreVerifier(transactionResults: [
            "valid.jws.token": .success(cannedPurchase(transactionId: "txn-001")),
        ])
        let app = try await makeRedeemApp(verifier: verifier)
        defer { Task { try await app.asyncShutdown() } }

        let userID = try await seedUserWithStarter(on: app, appleSub: "apple-sub-001")
        let token = try signRedeemToken(for: userID, on: app)

        try await app.testable().test(.POST, "v1/credits/redeem", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
            try req.content.encode(["signedTransaction": "valid.jws.token"])
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let body = try res.content.decode(TestBalanceResponse.self)
            XCTAssertEqual(body.balance, 15, "5 starter + 10 purchased must be 15")
        })

        let purchaseCount = try await purchaseRowCount(for: userID, on: app)
        XCTAssertEqual(purchaseCount, 1, "exactly one purchase row")
    }

    // MARK: Idempotent replay — same JWS twice credits once

    func testRedeemIdempotentReplay() async throws {
        let verifier = FakeAppStoreVerifier(transactionResults: [
            "valid.jws.token": .success(cannedPurchase(transactionId: "txn-001")),
        ])
        let app = try await makeRedeemApp(verifier: verifier)
        defer { Task { try await app.asyncShutdown() } }

        let userID = try await seedUserWithStarter(on: app, appleSub: "apple-sub-002")
        let token = try signRedeemToken(for: userID, on: app)
        let tester = try app.testable()

        for _ in 0..<2 {
            try await tester.test(.POST, "v1/credits/redeem", beforeRequest: { req async throws in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["signedTransaction": "valid.jws.token"])
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok, "replay must return 200 so the app can finish() the transaction")
                let body = try res.content.decode(TestBalanceResponse.self)
                XCTAssertEqual(body.balance, 15, "balance must stay 15 after replay, not 25")
            })
        }

        let purchaseCount = try await purchaseRowCount(for: userID, on: app)
        XCTAssertEqual(purchaseCount, 1, "replay must not insert a second purchase row")
    }

    // MARK: Cross-user replay — same transaction, different user → 409

    func testRedeemCrossUserReplayReturns409() async throws {
        let verifier = FakeAppStoreVerifier(transactionResults: [
            "valid.jws.token": .success(cannedPurchase(transactionId: "txn-001")),
        ])
        let app = try await makeRedeemApp(verifier: verifier)
        defer { Task { try await app.asyncShutdown() } }

        let userA = try await seedUserWithStarter(on: app, appleSub: "apple-sub-003a")
        let userB = try await seedUserWithStarter(on: app, appleSub: "apple-sub-003b")
        let tokenA = try signRedeemToken(for: userA, on: app)
        let tokenB = try signRedeemToken(for: userB, on: app)
        let tester = try app.testable()

        // First user redeems successfully.
        try await tester.test(.POST, "v1/credits/redeem", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = BearerAuthorization(token: tokenA)
            try req.content.encode(["signedTransaction": "valid.jws.token"])
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
        })

        // Second user replays the same transaction → 409, no credit.
        try await tester.test(.POST, "v1/credits/redeem", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = BearerAuthorization(token: tokenB)
            try req.content.encode(["signedTransaction": "valid.jws.token"])
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .conflict)
        })

        let purchaseCountA = try await purchaseRowCount(for: userA, on: app)
        let purchaseCountB = try await purchaseRowCount(for: userB, on: app)
        XCTAssertEqual(purchaseCountA, 1)
        XCTAssertEqual(purchaseCountB, 0, "second user must not be credited")
    }

    // MARK: Unknown product → 422, no credit

    func testRedeemUnknownProductReturns422() async throws {
        let verifier = FakeAppStoreVerifier(transactionResults: [
            "valid.jws.token": .success(cannedPurchase(transactionId: "txn-001", productId: "credits.999")),
        ])
        let app = try await makeRedeemApp(verifier: verifier)
        defer { Task { try await app.asyncShutdown() } }

        let userID = try await seedUserWithStarter(on: app, appleSub: "apple-sub-004")
        let token = try signRedeemToken(for: userID, on: app)

        try await app.testable().test(.POST, "v1/credits/redeem", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
            try req.content.encode(["signedTransaction": "valid.jws.token"])
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .unprocessableEntity)
        })

        let purchaseCount = try await purchaseRowCount(for: userID, on: app)
        XCTAssertEqual(purchaseCount, 0)
    }

    // MARK: Revoked transaction → 409, no credit

    func testRedeemRevokedTransactionReturns409() async throws {
        let verifier = FakeAppStoreVerifier(transactionResults: [
            "valid.jws.token": .success(cannedPurchase(transactionId: "txn-001", revocationDate: Date())),
        ])
        let app = try await makeRedeemApp(verifier: verifier)
        defer { Task { try await app.asyncShutdown() } }

        let userID = try await seedUserWithStarter(on: app, appleSub: "apple-sub-005")
        let token = try signRedeemToken(for: userID, on: app)

        try await app.testable().test(.POST, "v1/credits/redeem", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
            try req.content.encode(["signedTransaction": "valid.jws.token"])
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .conflict)
        })

        let purchaseCount = try await purchaseRowCount(for: userID, on: app)
        XCTAssertEqual(purchaseCount, 0)
    }

    // MARK: appAccountToken mismatch → 409; match → 200

    func testRedeemAppAccountTokenMismatchReturns409() async throws {
        let otherUser = UUID()
        let verifier = FakeAppStoreVerifier(transactionResults: [
            "valid.jws.token": .success(cannedPurchase(transactionId: "txn-001", appAccountToken: otherUser)),
        ])
        let app = try await makeRedeemApp(verifier: verifier)
        defer { Task { try await app.asyncShutdown() } }

        let userID = try await seedUserWithStarter(on: app, appleSub: "apple-sub-006")
        let token = try signRedeemToken(for: userID, on: app)

        try await app.testable().test(.POST, "v1/credits/redeem", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
            try req.content.encode(["signedTransaction": "valid.jws.token"])
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .conflict)
        })

        let purchaseCount = try await purchaseRowCount(for: userID, on: app)
        XCTAssertEqual(purchaseCount, 0)
    }

    func testRedeemAppAccountTokenMatchSucceeds() async throws {
        // The user ID must be known before the app is built so the verifier's
        // canned payload can carry it as appAccountToken.
        let userID = UUID()
        let verifier = FakeAppStoreVerifier(transactionResults: [
            "valid.jws.token": .success(cannedPurchase(transactionId: "txn-001", appAccountToken: userID)),
        ])
        let app = try await makeRedeemApp(verifier: verifier)
        defer { Task { try await app.asyncShutdown() } }

        try await seedUserWithStarter(on: app, userID: userID, appleSub: "apple-sub-007")
        let token = try signRedeemToken(for: userID, on: app)

        try await app.testable().test(.POST, "v1/credits/redeem", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
            try req.content.encode(["signedTransaction": "valid.jws.token"])
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let body = try res.content.decode(TestBalanceResponse.self)
            XCTAssertEqual(body.balance, 15)
        })
    }

    // MARK: Non-consumable → 422

    func testRedeemNonConsumableReturns422() async throws {
        let verifier = FakeAppStoreVerifier(transactionResults: [
            "valid.jws.token": .success(cannedPurchase(transactionId: "txn-001", type: "Non-Consumable")),
        ])
        let app = try await makeRedeemApp(verifier: verifier)
        defer { Task { try await app.asyncShutdown() } }

        let userID = try await seedUserWithStarter(on: app, appleSub: "apple-sub-008")
        let token = try signRedeemToken(for: userID, on: app)

        try await app.testable().test(.POST, "v1/credits/redeem", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
            try req.content.encode(["signedTransaction": "valid.jws.token"])
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .unprocessableEntity)
        })

        let purchaseCount = try await purchaseRowCount(for: userID, on: app)
        XCTAssertEqual(purchaseCount, 0)
    }

    // MARK: Verification failure → 401; malformed JWS → 400; no JWT → 401

    func testRedeemInvalidJWSTokenReturns401() async throws {
        let verifier = FakeAppStoreVerifier() // rejects every JWS
        let app = try await makeRedeemApp(verifier: verifier)
        defer { Task { try await app.asyncShutdown() } }

        let userID = try await seedUserWithStarter(on: app, appleSub: "apple-sub-009")
        let token = try signRedeemToken(for: userID, on: app)

        try await app.testable().test(.POST, "v1/credits/redeem", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
            try req.content.encode(["signedTransaction": "bad.jws.token"])
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .unauthorized)
        })
    }

    func testRedeemMalformedJWSReturns400() async throws {
        let verifier = FakeAppStoreVerifier()
        let app = try await makeRedeemApp(verifier: verifier)
        defer { Task { try await app.asyncShutdown() } }

        let userID = try await seedUserWithStarter(on: app, appleSub: "apple-sub-010")
        let token = try signRedeemToken(for: userID, on: app)
        let tester = try app.testable()

        for malformed in ["not-a-jws", ""] {
            try await tester.test(.POST, "v1/credits/redeem", beforeRequest: { req async throws in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["signedTransaction": malformed])
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .badRequest, "malformed JWS '\(malformed)' must be 400")
            })
        }
    }

    func testRedeemWithoutTokenReturns401() async throws {
        let verifier = FakeAppStoreVerifier()
        let app = try await makeRedeemApp(verifier: verifier)
        defer { Task { try await app.asyncShutdown() } }

        try await app.testable().test(.POST, "v1/credits/redeem", beforeRequest: { req async throws in
            try req.content.encode(["signedTransaction": "valid.jws.token"])
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .unauthorized)
        })
    }
}

// MARK: - Local decode helper

private struct TestBalanceResponse: Decodable {
    var balance: Int
}
