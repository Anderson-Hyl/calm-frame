import XCTVapor
import FluentSQLiteDriver
@testable import App

/// Builds a test `Application` backed by an in-memory SQLite database and the
/// notifications route with a fake App Store verifier — no real Postgres or network required.
private func makeNotifyApp(verifier: any AppStoreVerifier) async throws -> Application {
    let app = try await Application.make(.testing)

    // Use in-memory SQLite so tests are self-contained.
    app.databases.use(.sqlite(.memory), as: .psql, isDefault: true)

    // Run migrations.
    app.migrations.add(CreateUsers())
    app.migrations.add(CreateLedgerEntries())
    app.migrations.add(CreateAppStoreNotifications())
    try await app.autoMigrate()

    // Register notifications route with the fake verifier.
    try app.register(collection: AppStoreNotificationsController(appStoreVerifier: verifier))
    return app
}

/// Seeds a user and returns its ID.
private func seedNotifyUser(on app: Application, appleSub: String) async throws -> UUID {
    let userID = UUID()
    try await User(id: userID, appleSub: appleSub).save(on: app.db)
    return userID
}

/// Reads a user's balance from the ledger.
private func notifyBalance(for userID: UUID, on app: Application) async throws -> Int {
    try await LedgerService().balance(for: userID, on: app.db)
}

/// Counts ledger rows of one reason for a user.
private func notifyRowCount(for userID: UUID, reason: LedgerReason, on app: Application) async throws -> Int {
    let entries = try await LedgerEntry.query(on: app.db)
        .filter(\.$userID == userID)
        .all()
    return entries.filter { $0.reason == reason }.count
}

/// Finds an inbox row by notification UUID.
private func inboxRow(uuid: String, on app: Application) async throws -> AppStoreNotification? {
    try await AppStoreNotification.query(on: app.db)
        .filter(\.$notificationUUID == uuid)
        .first()
}

// MARK: - Tests

final class NotificationTests: XCTestCase {

    // MARK: REFUND — deducts the credited points

    func testRefundDeductsBalance() async throws {
        // User bought credits.10 (balance 5 starter + 10 purchase = 15).
        let verifier = FakeAppStoreVerifier(
            transactionResults: ["inner.jws.token": .success(cannedPurchase(transactionId: "txn-001"))],
            notificationResults: ["refund.payload.jws": .success(cannedNotification(type: "REFUND", uuid: "notif-001", signedTransactionInfo: "inner.jws.token"))]
        )
        let app = try await makeNotifyApp(verifier: verifier)
        defer { Task { try await app.asyncShutdown() } }

        let userID = try await seedNotifyUser(on: app, appleSub: "apple-sub-n01")
        try await LedgerService().grantStarter(to: userID, appleSub: "apple-sub-n01", on: app.db)
        try await LedgerService().grantPurchase(to: userID, transactionID: "txn-001", credits: 10, on: app.db)
        var balance = try await notifyBalance(for: userID, on: app)
        XCTAssertEqual(balance, 15)

        try await app.testable().test(.POST, "v1/appstore/notifications", beforeRequest: { req async throws in
            try req.content.encode(["signedPayload": "refund.payload.jws"])
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let body = try res.content.decode(TestNotificationResponse.self)
            XCTAssertTrue(body.received)
        })

        balance = try await notifyBalance(for: userID, on: app)
        XCTAssertEqual(balance, 5, "refund must deduct 10")
        let refundCount = try await notifyRowCount(for: userID, reason: .appleRefund, on: app)
        XCTAssertEqual(refundCount, 1)
        let inbox = try await inboxRow(uuid: "notif-001", on: app)
        XCTAssertEqual(inbox?.status, "processed")
    }

    // MARK: Duplicate delivery — same notificationUUID twice deducts once

    func testDuplicateNotificationIgnored() async throws {
        let verifier = FakeAppStoreVerifier(
            transactionResults: ["inner.jws.token": .success(cannedPurchase(transactionId: "txn-001"))],
            notificationResults: ["refund.payload.jws": .success(cannedNotification(type: "REFUND", uuid: "notif-001", signedTransactionInfo: "inner.jws.token"))]
        )
        let app = try await makeNotifyApp(verifier: verifier)
        defer { Task { try await app.asyncShutdown() } }

        let userID = try await seedNotifyUser(on: app, appleSub: "apple-sub-n02")
        try await LedgerService().grantStarter(to: userID, appleSub: "apple-sub-n02", on: app.db)
        try await LedgerService().grantPurchase(to: userID, transactionID: "txn-001", credits: 10, on: app.db)
        let tester = try app.testable()

        for _ in 0..<2 {
            try await tester.test(.POST, "v1/appstore/notifications", beforeRequest: { req async throws in
                try req.content.encode(["signedPayload": "refund.payload.jws"])
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok, "duplicate delivery must still answer 200")
            })
        }

        let balance = try await notifyBalance(for: userID, on: app)
        XCTAssertEqual(balance, 5, "second delivery must not deduct again")
        let refundCount = try await notifyRowCount(for: userID, reason: .appleRefund, on: app)
        XCTAssertEqual(refundCount, 1)
        let inboxCount = try await AppStoreNotification.query(on: app.db)
            .filter(\.$notificationUUID == "notif-001")
            .all().count
        XCTAssertEqual(inboxCount, 1, "exactly one inbox row per notificationUUID")
    }

    // MARK: REFUND_REVERSED — restores points after a recorded refund

    func testRefundReversedRestores() async throws {
        let verifier = FakeAppStoreVerifier(
            transactionResults: ["inner.jws.token": .success(cannedPurchase(transactionId: "txn-001"))],
            notificationResults: [
                "refund.payload.jws": .success(cannedNotification(type: "REFUND", uuid: "notif-001", signedTransactionInfo: "inner.jws.token")),
                "reversal.payload.jws": .success(cannedNotification(type: "REFUND_REVERSED", uuid: "notif-002", signedTransactionInfo: "inner.jws.token")),
            ]
        )
        let app = try await makeNotifyApp(verifier: verifier)
        defer { Task { try await app.asyncShutdown() } }

        let userID = try await seedNotifyUser(on: app, appleSub: "apple-sub-n03")
        try await LedgerService().grantStarter(to: userID, appleSub: "apple-sub-n03", on: app.db)
        try await LedgerService().grantPurchase(to: userID, transactionID: "txn-001", credits: 10, on: app.db)
        let tester = try app.testable()

        try await tester.test(.POST, "v1/appstore/notifications", beforeRequest: { req async throws in
            try req.content.encode(["signedPayload": "refund.payload.jws"])
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
        })
        var balance = try await notifyBalance(for: userID, on: app)
        XCTAssertEqual(balance, 5)

        try await tester.test(.POST, "v1/appstore/notifications", beforeRequest: { req async throws in
            try req.content.encode(["signedPayload": "reversal.payload.jws"])
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
        })

        balance = try await notifyBalance(for: userID, on: app)
        XCTAssertEqual(balance, 15, "reversal must restore the 10 points")
        let reversalCount = try await notifyRowCount(for: userID, reason: .appleRefundReversed, on: app)
        XCTAssertEqual(reversalCount, 1)
    }

    // MARK: Out-of-order reversal — parked, never credited blindly

    func testOutOfOrderReversalParked() async throws {
        let verifier = FakeAppStoreVerifier(
            transactionResults: ["inner.jws.token": .success(cannedPurchase(transactionId: "txn-001"))],
            notificationResults: ["reversal.payload.jws": .success(cannedNotification(type: "REFUND_REVERSED", uuid: "notif-002", signedTransactionInfo: "inner.jws.token"))]
        )
        let app = try await makeNotifyApp(verifier: verifier)
        defer { Task { try await app.asyncShutdown() } }

        let userID = try await seedNotifyUser(on: app, appleSub: "apple-sub-n04")
        try await LedgerService().grantStarter(to: userID, appleSub: "apple-sub-n04", on: app.db)
        try await LedgerService().grantPurchase(to: userID, transactionID: "txn-001", credits: 10, on: app.db)

        try await app.testable().test(.POST, "v1/appstore/notifications", beforeRequest: { req async throws in
            try req.content.encode(["signedPayload": "reversal.payload.jws"])
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok, "parked notifications still answer 200")
        })

        let balance = try await notifyBalance(for: userID, on: app)
        XCTAssertEqual(balance, 15, "balance must not change")
        let reversalCount = try await notifyRowCount(for: userID, reason: .appleRefundReversed, on: app)
        XCTAssertEqual(reversalCount, 0)
        let inbox = try await inboxRow(uuid: "notif-002", on: app)
        XCTAssertEqual(inbox?.status, "parked")
    }

    // MARK: Unknown / TEST / CONSUMPTION_REQUEST — accepted, no ledger change

    func testUnknownTypeIgnored() async throws {
        let verifier = FakeAppStoreVerifier(notificationResults: [
            "unknown.payload.jws": .success(cannedNotification(type: "DID_RENEW", uuid: "notif-010")),
        ])
        let app = try await makeNotifyApp(verifier: verifier)
        defer { Task { try await app.asyncShutdown() } }

        let userID = try await seedNotifyUser(on: app, appleSub: "apple-sub-n05")
        try await LedgerService().grantStarter(to: userID, appleSub: "apple-sub-n05", on: app.db)

        try await app.testable().test(.POST, "v1/appstore/notifications", beforeRequest: { req async throws in
            try req.content.encode(["signedPayload": "unknown.payload.jws"])
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
        })

        let balance = try await notifyBalance(for: userID, on: app)
        XCTAssertEqual(balance, 5)
        let inbox = try await inboxRow(uuid: "notif-010", on: app)
        XCTAssertEqual(inbox?.status, "processed")
    }

    func testTestNotificationIgnored() async throws {
        let verifier = FakeAppStoreVerifier(notificationResults: [
            "test.payload.jws": .success(cannedNotification(type: "TEST", uuid: "notif-011")),
        ])
        let app = try await makeNotifyApp(verifier: verifier)
        defer { Task { try await app.asyncShutdown() } }

        try await app.testable().test(.POST, "v1/appstore/notifications", beforeRequest: { req async throws in
            try req.content.encode(["signedPayload": "test.payload.jws"])
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
        })

        let inbox = try await inboxRow(uuid: "notif-011", on: app)
        XCTAssertNotNil(inbox)
    }

    // MARK: Invalid outer payload → 400; empty payload → 400

    func testInvalidOuterPayloadReturns400() async throws {
        let verifier = FakeAppStoreVerifier() // rejects every JWS
        let app = try await makeNotifyApp(verifier: verifier)
        defer { Task { try await app.asyncShutdown() } }

        try await app.testable().test(.POST, "v1/appstore/notifications", beforeRequest: { req async throws in
            try req.content.encode(["signedPayload": "bad.payload.jws"])
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .badRequest)
        })
    }

    func testEmptyPayloadReturns400() async throws {
        let verifier = FakeAppStoreVerifier()
        let app = try await makeNotifyApp(verifier: verifier)
        defer { Task { try await app.asyncShutdown() } }

        try await app.testable().test(.POST, "v1/appstore/notifications", beforeRequest: { req async throws in
            try req.content.encode(["signedPayload": ""])
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .badRequest)
        })
    }

    // MARK: Refund attribution — appAccountToken fallback, unattributed parks

    func testRefundAttributionViaAppAccountToken() async throws {
        // No purchase ledger row exists; the transaction carries the user's
        // appAccountToken, so the refund still attributes to them (balance goes negative).
        let userID = UUID()
        let verifier = FakeAppStoreVerifier(
            transactionResults: ["inner.jws.token": .success(cannedPurchase(transactionId: "txn-unknown", appAccountToken: userID))],
            notificationResults: ["refund.payload.jws": .success(cannedNotification(type: "REFUND", uuid: "notif-020", signedTransactionInfo: "inner.jws.token"))]
        )
        let app = try await makeNotifyApp(verifier: verifier)
        defer { Task { try await app.asyncShutdown() } }

        try await User(id: userID, appleSub: "apple-sub-n06").save(on: app.db)
        var balance = try await notifyBalance(for: userID, on: app)
        XCTAssertEqual(balance, 0)

        try await app.testable().test(.POST, "v1/appstore/notifications", beforeRequest: { req async throws in
            try req.content.encode(["signedPayload": "refund.payload.jws"])
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
        })

        balance = try await notifyBalance(for: userID, on: app)
        XCTAssertEqual(balance, -10, "balance may go negative on refund (plan §4.7)")
        let refundCount = try await notifyRowCount(for: userID, reason: .appleRefund, on: app)
        XCTAssertEqual(refundCount, 1)
    }

    func testRefundUnattributedParked() async throws {
        // No purchase row and no appAccountToken — nobody to deduct from.
        let verifier = FakeAppStoreVerifier(
            transactionResults: ["inner.jws.token": .success(cannedPurchase(transactionId: "txn-unknown"))],
            notificationResults: ["refund.payload.jws": .success(cannedNotification(type: "REFUND", uuid: "notif-021", signedTransactionInfo: "inner.jws.token"))]
        )
        let app = try await makeNotifyApp(verifier: verifier)
        defer { Task { try await app.asyncShutdown() } }

        try await app.testable().test(.POST, "v1/appstore/notifications", beforeRequest: { req async throws in
            try req.content.encode(["signedPayload": "refund.payload.jws"])
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok, "parked notifications still answer 200")
        })

        let inbox = try await inboxRow(uuid: "notif-021", on: app)
        XCTAssertEqual(inbox?.status, "parked")
        let refundRows = try await LedgerEntry.query(on: app.db).all().filter { $0.reason == .appleRefund }
        XCTAssertEqual(refundRows.count, 0, "no ledger row when the refund cannot be attributed")
    }

    // MARK: Unknown product refund — parked, no ledger change

    func testRefundUnknownProductParked() async throws {
        let verifier = FakeAppStoreVerifier(
            transactionResults: ["inner.jws.token": .success(cannedPurchase(transactionId: "txn-001", productId: "credits.999"))],
            notificationResults: ["refund.payload.jws": .success(cannedNotification(type: "REFUND", uuid: "notif-022", signedTransactionInfo: "inner.jws.token"))]
        )
        let app = try await makeNotifyApp(verifier: verifier)
        defer { Task { try await app.asyncShutdown() } }

        let userID = try await seedNotifyUser(on: app, appleSub: "apple-sub-n07")
        try await LedgerService().grantStarter(to: userID, appleSub: "apple-sub-n07", on: app.db)

        try await app.testable().test(.POST, "v1/appstore/notifications", beforeRequest: { req async throws in
            try req.content.encode(["signedPayload": "refund.payload.jws"])
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
        })

        let balance = try await notifyBalance(for: userID, on: app)
        XCTAssertEqual(balance, 5)
        let inbox = try await inboxRow(uuid: "notif-022", on: app)
        XCTAssertEqual(inbox?.status, "parked")
    }
}

// MARK: - Local decode helper

private struct TestNotificationResponse: Decodable {
    var received: Bool
}
