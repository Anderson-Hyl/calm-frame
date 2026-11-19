import CalmFrameKit
import XCTVapor
import JWTKit
import FluentSQLiteDriver
@testable import App

/// S1 acceptance for the paintings slice (plan §5.2): in-memory SQLite,
/// `FakeImageProvider` + `StubPromptWriter`, no network, no real key.
/// The live Postgres + driver checks are the separate `paintings-*` checks
/// in verify-calm-frame.
private func makePaintingsApp(
    failImage: Bool = false,
    promptWriter: (any PromptWriter)? = nil,
    storage: (any StorageService)? = nil
) async throws -> Application {
    let app = try await Application.make(.testing)

    // Use in-memory SQLite so tests are self-contained.
    app.databases.use(.sqlite(.memory), as: .psql, isDefault: true)

    // Register JWT signer.
    let signers = JWTSigners()
    signers.use(.hs256(key: "test-secret"))
    app.jwtSigners = signers

    // Run migrations (paintings tables + user painting state).
    app.migrations.add(CreateUsers())
    app.migrations.add(CreateLedgerEntries())
    app.migrations.add(CreatePaintings())
    app.migrations.add(CreateAiCosts())
    app.migrations.add(AddPaintingStateToUsers())
    try await app.autoMigrate()

    // Wire the paintings service with the fake provider and a per-test
    // temp directory for local storage.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("calm-frame-paintings-tests-\(UUID().uuidString)", isDirectory: true)
    let service = PaintingService(
        promptWriter: promptWriter ?? StubPromptWriter(),
        imageProvider: FakeImageProvider(shouldFail: failImage),
        storage: storage ?? LocalStorageService(
            directory: directory,
            baseURL: URL(string: "http://127.0.0.1:8080")!
        )
    )
    app.configurePaintings(service: service, staticDirectory: directory)

    // Register paintings route.
    try app.register(collection: PaintingsController())
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

/// Creates a user whose ledger sums to `balance` (starter 5, topped up
/// with fake purchases, or drawn down with generation charges).
private func makeUser(appleSub: String, balance: Int, on app: Application) async throws -> UUID {
    let userID = UUID()
    try await User(id: userID, appleSub: appleSub).save(on: app.db)
    guard balance != 0 else { return userID }
    let ledger = LedgerService()
    try await ledger.grantStarter(to: userID, appleSub: appleSub, on: app.db)
    var current = 5
    var i = 0
    while current < balance {
        let chunk = min(balance - current, 50)
        _ = try await ledger.grantPurchase(
            to: userID, transactionID: "test-tx-\(appleSub)-\(i)", credits: chunk, on: app.db
        )
        current += chunk
        i += 1
    }
    while current > balance {
        try await ledger.chargeGeneration(to: userID, attemptID: UUID(), on: app.db)
        current -= 1
    }
    return userID
}

private struct PostResult {
    var status: HTTPResponseStatus
    var painting: PaintingResponse?
    var apiError: APIError?
}

private func postPainting(
    _ app: Application, token: String,
    mood: Mood = .hectic, style: PaintingStyle = .oilPainting1800s, locale: String = "en"
) async throws -> PostResult {
    var result = PostResult(status: .ok, painting: nil, apiError: nil)
    try await app.testable().test(.POST, "v1/paintings", beforeRequest: { req async throws in
        req.headers.bearerAuthorization = BearerAuthorization(token: token)
        try req.content.encode(PaintingRequest(mood: mood, style: style, locale: locale))
    }, afterResponse: { res async throws in
        result.status = res.status
        if res.status == .ok {
            result.painting = try res.content.decode(PaintingResponse.self)
        } else {
            result.apiError = try? res.content.decode(APIError.self)
        }
    })
    return result
}

private func ledgerEntries(for userID: UUID, on app: Application) async throws -> [LedgerEntry] {
    try await LedgerEntry.query(on: app.db).filter(\.$userID == userID).all()
}

// MARK: - Tests

final class PaintingsTests: XCTestCase {

    // MARK: Charge then generate

    func testChargeThenGenerate() async throws {
        let app = try await makePaintingsApp()
        defer { Task { try await app.asyncShutdown() } }
        let userID = try await makeUser(appleSub: "paintings-charge", balance: 5, on: app)
        let token = try signToken(for: userID, on: app)

        let result = try await postPainting(app, token: token)
        XCTAssertEqual(result.status, .ok)
        let painting = try XCTUnwrap(result.painting)
        XCTAssertFalse(painting.fromCache, "first request must generate, not hit cache")
        XCTAssertEqual(painting.balance, 4, "one credit must be charged")
        XCTAssertEqual(painting.title, "Quiet Lake at Dusk")
        XCTAssertTrue(painting.imageURL.absoluteString.hasPrefix("http://127.0.0.1:8080/static/paintings/"))

        // One generate row, one ai_costs row, one painting row.
        let entries = try await ledgerEntries(for: userID, on: app)
        XCTAssertEqual(entries.filter { $0.reason == .generate }.count, 1)
        let aiCostCount = try await AiCost.query(on: app.db).count()
        XCTAssertEqual(aiCostCount, 1)
        let stored = try await Painting.query(on: app.db).all()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.id, painting.id)

        // The generated file is on disk, byte-identical to the fake PNG.
        let file = app.paintingsStaticDirectory.appendingPathComponent(stored.first!.imageKey)
        XCTAssertEqual(try Data(contentsOf: file), FakeImageProvider.fakePNG)
    }

    // MARK: Cache hit is free

    func testCacheHitSecondRequestFree() async throws {
        let app = try await makePaintingsApp()
        defer { Task { try await app.asyncShutdown() } }
        let userID = try await makeUser(appleSub: "paintings-cache", balance: 5, on: app)
        let token = try signToken(for: userID, on: app)

        let first = try await postPainting(app, token: token)
        let second = try await postPainting(app, token: token)
        XCTAssertEqual(second.status, .ok)
        XCTAssertTrue(second.painting?.fromCache == true, "second request must hit cache")
        XCTAssertEqual(second.painting?.balance, 4, "cache hit must not charge")
        XCTAssertEqual(second.painting?.id, first.painting?.id, "cache hit must return the same painting")

        let entries = try await ledgerEntries(for: userID, on: app)
        XCTAssertEqual(entries.filter { $0.reason == .generate }.count, 1, "only the first request charges")
        let paintingCount = try await Painting.query(on: app.db).count()
        XCTAssertEqual(paintingCount, 1)
    }

    // MARK: Zero balance → 402

    func testZeroBalanceReturns402() async throws {
        let app = try await makePaintingsApp()
        defer { Task { try await app.asyncShutdown() } }
        let userID = try await makeUser(appleSub: "paintings-zero", balance: 0, on: app)
        let token = try signToken(for: userID, on: app)

        let result = try await postPainting(app, token: token)
        XCTAssertEqual(result.status, .paymentRequired)
        XCTAssertEqual(result.apiError?.retryable, false)
        let entryCount = try await ledgerEntries(for: userID, on: app).count
        XCTAssertEqual(entryCount, 0, "402 must not write any ledger row")
        let paintingCount = try await Painting.query(on: app.db).count()
        XCTAssertEqual(paintingCount, 0)
    }

    // MARK: Negative balance → 402

    func testNegativeBalanceReturns402() async throws {
        let app = try await makePaintingsApp()
        defer { Task { try await app.asyncShutdown() } }
        let userID = try await makeUser(appleSub: "paintings-negative", balance: -1, on: app)
        let token = try signToken(for: userID, on: app)

        let result = try await postPainting(app, token: token)
        XCTAssertEqual(result.status, .paymentRequired)
        XCTAssertEqual(result.apiError?.retryable, false)
        let paintingCount = try await Painting.query(on: app.db).count()
        XCTAssertEqual(paintingCount, 0)
    }

    // MARK: Refund on image failure

    func testRefundOnImageFailure() async throws {
        let app = try await makePaintingsApp(failImage: true)
        defer { Task { try await app.asyncShutdown() } }
        let userID = try await makeUser(appleSub: "paintings-refund-image", balance: 5, on: app)
        let token = try signToken(for: userID, on: app)

        let result = try await postPainting(app, token: token)
        XCTAssertEqual(result.status, .serviceUnavailable)
        XCTAssertEqual(result.apiError?.retryable, true)

        let entries = try await ledgerEntries(for: userID, on: app)
        XCTAssertEqual(entries.filter { $0.reason == .generate }.count, 1)
        XCTAssertEqual(entries.filter { $0.reason == .refundFailure }.count, 1)
        let balance = try await LedgerService().balance(for: userID, on: app.db)
        XCTAssertEqual(balance, 5, "failed generation must refund")
        let paintingCount = try await Painting.query(on: app.db).count()
        XCTAssertEqual(paintingCount, 0)
        let user = try await User.find(userID, on: app.db)
        XCTAssertEqual(user?.generationInProgress, false, "in-flight flag must clear on failure")
    }

    // MARK: Refund on caption failure

    func testRefundOnCaptionFailure() async throws {
        struct FailingPromptWriter: PromptWriter {
            func write(mood: Mood, style: PaintingStyle, locale: String) async throws -> PaintingPrompt {
                throw StubError.captionFailed
            }
        }
        enum StubError: Error { case captionFailed }

        let app = try await makePaintingsApp(promptWriter: FailingPromptWriter())
        defer { Task { try await app.asyncShutdown() } }
        let userID = try await makeUser(appleSub: "paintings-refund-caption", balance: 5, on: app)
        let token = try signToken(for: userID, on: app)

        let result = try await postPainting(app, token: token)
        XCTAssertEqual(result.status, .serviceUnavailable)
        XCTAssertEqual(result.apiError?.retryable, true)
        let entries = try await ledgerEntries(for: userID, on: app)
        XCTAssertEqual(entries.filter { $0.reason == .refundFailure }.count, 1)
        let balance = try await LedgerService().balance(for: userID, on: app.db)
        XCTAssertEqual(balance, 5)
        let user = try await User.find(userID, on: app.db)
        XCTAssertEqual(user?.generationInProgress, false)
    }

    // MARK: Refund on storage failure

    func testRefundOnStorageFailure() async throws {
        struct FailingStorageService: StorageService {
            func store(data: Data, key: String, mimeType: String) async throws -> URL {
                throw StubError.storageFailed
            }
            func url(for key: String) -> URL {
                URL(string: "http://127.0.0.1:8080/static/paintings/\(key)")!
            }
            func delete(key: String) async throws {
                throw StubError.storageFailed
            }
        }
        enum StubError: Error { case storageFailed }

        let app = try await makePaintingsApp(storage: FailingStorageService())
        defer { Task { try await app.asyncShutdown() } }
        let userID = try await makeUser(appleSub: "paintings-refund-storage", balance: 5, on: app)
        let token = try signToken(for: userID, on: app)

        let result = try await postPainting(app, token: token)
        XCTAssertEqual(result.status, .serviceUnavailable)
        XCTAssertEqual(result.apiError?.retryable, true)
        let entries = try await ledgerEntries(for: userID, on: app)
        XCTAssertEqual(entries.filter { $0.reason == .refundFailure }.count, 1)
        let balance = try await LedgerService().balance(for: userID, on: app.db)
        XCTAssertEqual(balance, 5)
        // The provider call succeeded before storage failed, so its cost is
        // recorded even though the painting never landed.
        let aiCostCount = try await AiCost.query(on: app.db).count()
        XCTAssertEqual(aiCostCount, 1)
        let paintingCount = try await Painting.query(on: app.db).count()
        XCTAssertEqual(paintingCount, 0)
        let user = try await User.find(userID, on: app.db)
        XCTAssertEqual(user?.generationInProgress, false)
    }

    // MARK: Rotation serves the least recently served variant

    func testRotationServesLeastRecentlyServed() async throws {
        let app = try await makePaintingsApp()
        defer { Task { try await app.asyncShutdown() } }
        let userID = try await makeUser(appleSub: "paintings-rotation", balance: 5, on: app)
        let token = try signToken(for: userID, on: app)

        let old = Painting(
            cacheKey: "hectic-oilPainting1800s-v0", mood: "hectic", style: "oilPainting1800s", variant: 0,
            title: "Old", caption: "old", imageKey: "hectic-oilPainting1800s-v0.png", attemptID: UUID(),
            lastServedAt: Date(timeIntervalSince1970: 1_000_000)
        )
        let fresh = Painting(
            cacheKey: "hectic-oilPainting1800s-v1", mood: "hectic", style: "oilPainting1800s", variant: 1,
            title: "Fresh", caption: "fresh", imageKey: "hectic-oilPainting1800s-v1.png", attemptID: UUID(),
            lastServedAt: Date()
        )
        try await old.save(on: app.db)
        try await fresh.save(on: app.db)

        let first = try await postPainting(app, token: token)
        XCTAssertEqual(first.painting?.id, old.id, "least recently served variant must win")
        XCTAssertTrue(first.painting?.fromCache == true)

        let second = try await postPainting(app, token: token)
        XCTAssertEqual(second.painting?.id, fresh.id, "the next-oldest variant must win next")
        XCTAssertTrue(second.painting?.fromCache == true)
        XCTAssertEqual(second.painting?.balance, 5, "rotation hits must not charge")
    }

    // MARK: Latest — no painting → 404

    func testLatestReturns404WithoutPainting() async throws {
        let app = try await makePaintingsApp()
        defer { Task { try await app.asyncShutdown() } }
        let userID = try await makeUser(appleSub: "paintings-latest-404", balance: 5, on: app)
        let token = try signToken(for: userID, on: app)

        try await app.testable().test(.GET, "v1/paintings/latest", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .notFound)
            XCTAssertEqual(try res.content.decode(APIError.self).retryable, false)
        })
    }

    // MARK: Latest — with painting → 200

    func testLatestReturns200WithPainting() async throws {
        let app = try await makePaintingsApp()
        defer { Task { try await app.asyncShutdown() } }
        let userID = try await makeUser(appleSub: "paintings-latest-200", balance: 5, on: app)
        let token = try signToken(for: userID, on: app)

        let generated = try await postPainting(app, token: token)
        XCTAssertEqual(generated.status, .ok)

        try await app.testable().test(.GET, "v1/paintings/latest", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let latest = try res.content.decode(PaintingResponse.self)
            XCTAssertEqual(latest.id, generated.painting?.id)
            XCTAssertEqual(latest.balance, 4)
        })
    }

    // MARK: In-flight → 409

    func testInFlightReturns409() async throws {
        let app = try await makePaintingsApp()
        defer { Task { try await app.asyncShutdown() } }
        let userID = try await makeUser(appleSub: "paintings-inflight", balance: 5, on: app)
        let token = try signToken(for: userID, on: app)

        // Simulate a generation already running for this user.
        let foundUser = try await User.find(userID, on: app.db)
        let user = try XCTUnwrap(foundUser)
        user.generationInProgress = true
        try await user.update(on: app.db)

        let result = try await postPainting(app, token: token)
        XCTAssertEqual(result.status, .conflict)
        XCTAssertEqual(result.apiError?.retryable, true)
        let balance = try await LedgerService().balance(for: userID, on: app.db)
        XCTAssertEqual(balance, 5, "409 must not charge")
        let entryCount = try await ledgerEntries(for: userID, on: app).count
        XCTAssertEqual(entryCount, 1, "only the starter row")
    }

    // MARK: Cache-key conflict insert

    func testCacheKeyConflictInsert() async throws {
        let app = try await makePaintingsApp()
        defer { Task { try await app.asyncShutdown() } }

        let service = app.paintingsService
        let first = Painting(
            cacheKey: "calm-oldPostcard-v0", mood: "calm", style: "oldPostcard", variant: 0,
            title: "One", caption: "one", imageKey: "calm-oldPostcard-v0.png", attemptID: UUID()
        )
        let second = Painting(
            cacheKey: "calm-oldPostcard-v0", mood: "calm", style: "oldPostcard", variant: 0,
            title: "Two", caption: "two", imageKey: "calm-oldPostcard-v0.png", attemptID: UUID()
        )
        let firstID = try await service.insertPaintingIgnoringConflict(first, on: app.db)
        XCTAssertNotNil(firstID)
        let secondID = try await service.insertPaintingIgnoringConflict(second, on: app.db)
        XCTAssertNil(secondID, "second insert on the same cache key must be ignored, not throw")
        let paintingCount = try await Painting.query(on: app.db).count()
        XCTAssertEqual(paintingCount, 1)
        let winner = try await Painting.find(firstID!, on: app.db)
        XCTAssertEqual(winner?.title, "One")
    }

    // MARK: Daily limit

    func testDailyLimitReached() async throws {
        let app = try await makePaintingsApp()
        defer { Task { try await app.asyncShutdown() } }
        let userID = try await makeUser(appleSub: "paintings-daily-limit", balance: 15, on: app)
        let token = try signToken(for: userID, on: app)

        // 10 generations on 10 distinct combos (the daily cap, plan §7 Q3).
        let combos: [(Mood, PaintingStyle)] = [
            (.hectic, .oilPainting1800s), (.hectic, .oldPostcard), (.hectic, .gothicNight),
            (.noisy, .oilPainting1800s), (.noisy, .oldPostcard), (.noisy, .gothicNight),
            (.tenseQuiet, .oilPainting1800s), (.tenseQuiet, .oldPostcard), (.tenseQuiet, .gothicNight),
            (.drowsy, .oilPainting1800s),
        ]
        for (mood, style) in combos {
            let result = try await postPainting(app, token: token, mood: mood, style: style)
            XCTAssertEqual(result.status, .ok, "generation \(mood)/\(style) must succeed")
        }

        // 11th generation, a fresh combo, must hit the daily cap.
        let capped = try await postPainting(app, token: token, mood: .drowsy, style: .oldPostcard)
        XCTAssertEqual(capped.status, .tooManyRequests)
        XCTAssertEqual(capped.apiError?.retryable, false)
        let balance = try await LedgerService().balance(for: userID, on: app.db)
        XCTAssertEqual(balance, 5, "capped request must not charge")

        // Cache hits still work after the cap — only generations count.
        let hit = try await postPainting(app, token: token, mood: .hectic, style: .oilPainting1800s)
        XCTAssertEqual(hit.status, .ok)
        XCTAssertTrue(hit.painting?.fromCache == true)
    }
}
