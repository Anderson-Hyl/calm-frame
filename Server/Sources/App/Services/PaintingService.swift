import CalmFrameKit
import Fluent
import FluentPostgresDriver
import FluentSQL
import Logging
import Vapor

// MARK: - Errors

/// Business errors from `PaintingService`, mapped by `PaintingsController`
/// to Kit `APIError` bodies (plan §4.2). Anything else (e.g. a database
/// failure) propagates as a plain `Abort` — it is not a business error.
enum PaintingServiceError: Error, Sendable {
    /// The JWT names a user with no row (stale token; cannot happen after
    /// sign-in, guarded anyway).
    case userNotFound
    /// Balance < 1: no generation, no ledger row (plan §4.4).
    case insufficientBalance
    /// Another generation for this user is still running (plan §3.3).
    case inFlight
    /// The daily per-user generation cap is reached (plan §7 Q3, approved).
    case dailyLimitReached
    /// Any generation step failed after charging; the credit was refunded.
    case generationFailed
    /// `GET /latest` for a user with no painting yet.
    case notFound

    var status: HTTPResponseStatus {
        switch self {
        case .userNotFound: .unauthorized
        case .insufficientBalance: .paymentRequired
        case .inFlight: .conflict
        case .dailyLimitReached: .tooManyRequests
        case .generationFailed: .serviceUnavailable
        case .notFound: .notFound
        }
    }

    var apiError: APIError {
        switch self {
        case .userNotFound:
            APIError(error: "user not found", retryable: false)
        case .insufficientBalance:
            APIError(error: "insufficient balance", retryable: false)
        case .inFlight:
            APIError(error: "generation already in progress", retryable: true)
        case .dailyLimitReached:
            APIError(error: "daily generation limit reached", retryable: false)
        case .generationFailed:
            APIError(error: "generation failed", retryable: true)
        case .notFound:
            APIError(error: "no painting yet", retryable: false)
        }
    }
}

// MARK: - Daily limit

/// In-memory per-user daily generation counter (design.md §4.7 token
/// bucket, keyed by userID). Single-instance only — the plan notes a
/// multi-instance deployment needs Postgres/Redis instead.
/// Counts charges (cache misses that pass the balance check), not requests:
/// cache hits, 402s and 409s never consume the daily budget.
actor DailyLimitTracker: Sendable {
    private var counts: [UUID: (day: String, count: Int)] = [:]

    /// Checks the daily limit for `userID` and consumes one unit when
    /// allowed. Returns `false` once the user has hit `limit` today (UTC).
    func allow(userID: UUID, limit: Int, on date: Date = Date()) -> Bool {
        let day = Self.dayString(for: date)
        if counts[userID]?.day != day {
            counts[userID] = (day, 0)
        }
        guard counts[userID]!.count < limit else {
            return false
        }
        counts[userID]!.count += 1
        return true
    }

    /// Test support: forget all counts.
    func reset() {
        counts = [:]
    }

    private static func dayString(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year!)-\(parts.month!)-\(parts.day!)"
    }
}

// MARK: - Service

/// Orchestrates one painting request: cache lookup, charge, generate,
/// refund-on-failure, and the widget's latest-painting read.
/// The controller only decodes/authenticates/returns; all decisions live
/// here (plan §4.1).
struct PaintingService: Sendable {
    /// Approved daily cap (plan §7 Q3): 10 generations per user per day,
    /// plus the separate 1-in-flight guard.
    static let dailyLimitPerDay = 10
    /// Generation size (selection doc): 1920×1280, still in Seedream's
    /// ¥0.13 tier (≤ 2.61M px).
    static let generationImageSize = ImageSize(width: 1920, height: 1280)

    let ledger: LedgerService
    let promptWriter: any PromptWriter
    let imageProvider: any ImageProvider
    let storage: any StorageService
    let dailyLimit: DailyLimitTracker
    /// Style anchor images, one per style (public domain, same source as
    /// the client's bundled paintings). Fake ignores them; the Seedream
    /// slice passes the matching one as a reference image.
    let referenceImages: [PaintingStyle: Data]
    let logger: Logger

    init(
        ledger: LedgerService = LedgerService(),
        promptWriter: any PromptWriter,
        imageProvider: any ImageProvider,
        storage: any StorageService,
        dailyLimit: DailyLimitTracker = DailyLimitTracker(),
        referenceImages: [PaintingStyle: Data] = [:],
        logger: Logger = Logger(label: "painting-service")
    ) {
        self.ledger = ledger
        self.promptWriter = promptWriter
        self.imageProvider = imageProvider
        self.storage = storage
        self.dailyLimit = dailyLimit
        self.referenceImages = referenceImages
        self.logger = logger
    }

    // MARK: - Create

    /// `POST /v1/paintings`: serve from cache when possible, otherwise
    /// charge 1 credit and generate. Any generation failure refunds the
    /// credit and throws `.generationFailed` (→ 503, retryable).
    func create(mood: Mood, style: PaintingStyle, locale: String, userID: UUID, on db: any Database) async throws -> PaintingResponse {
        let attemptID = UUID()
        let effectiveLocale = locale.isEmpty ? "en" : locale
        switch try await decide(mood: mood, style: style, userID: userID, attemptID: attemptID, on: db) {
        case .cached(let painting, let balance):
            return response(for: painting, fromCache: true, balance: balance)
        case .generate:
            return try await generate(
                mood: mood, style: style, locale: effectiveLocale,
                userID: userID, attemptID: attemptID, on: db
            )
        }
    }

    /// `GET /v1/paintings/latest`: the user's most recently served painting
    /// (their `last_painting_id`), for the widget. Pure read — no charge,
    /// no state change. Throws `.notFound` when the user has no painting.
    func latest(userID: UUID, on db: any Database) async throws -> PaintingResponse {
        guard let user = try await User.find(userID, on: db),
              let paintingID = user.lastPaintingID,
              let painting = try await Painting.find(paintingID, on: db)
        else {
            throw PaintingServiceError.notFound
        }
        let balance = try await ledger.balance(for: userID, on: db)
        return response(for: painting, fromCache: true, balance: balance)
    }

    // MARK: - Decision (one transaction)

    private enum Decision: Sendable {
        case cached(Painting, Int)
        case generate
    }

    /// Decides cache-hit vs charge inside one transaction, with the user
    /// row locked on Postgres so two concurrent requests for the same user
    /// cannot both pass the balance check and double-charge.
    private func decide(mood: Mood, style: PaintingStyle, userID: UUID, attemptID: UUID, on db: any Database) async throws -> Decision {
        try await db.transaction { tx in
            // Row lock (Postgres only). SQLite rejects `FOR UPDATE` syntax,
            // but SQLite transactions already serialize writers on the whole
            // database, so the lock is skipped there — S1 only ever runs on
            // SQLite, and the live server only ever runs on Postgres.
            if tx is any PostgresDatabase, let sql = tx as? any SQLDatabase {
                _ = try await sql.raw("SELECT id FROM users WHERE id = \(bind: userID) FOR UPDATE").all()
            }
            guard let user = try await User.find(userID, on: tx) else {
                throw PaintingServiceError.userNotFound
            }
            let balance = try await ledger.balance(for: userID, on: tx)
            // Cache lookup: fetch every variant for the combo and pick the
            // least recently served in Swift. Postgres sorts NULLS LAST and
            // SQLite sorts NULLS FIRST for ASC, so the database must not
            // decide the order (a variant never served has nil
            // `last_served_at` and must win).
            let variants = try await Painting.query(on: tx)
                .filter(\.$mood == mood.rawValue)
                .filter(\.$style == style.rawValue)
                .all()
            if let hit = Self.pickLeastRecentlyServed(variants) {
                hit.lastServedAt = Date()
                try await hit.update(on: tx)
                user.lastPaintingID = hit.id
                try await user.update(on: tx)
                return .cached(hit, balance)
            }
            guard balance >= 1 else {
                throw PaintingServiceError.insufficientBalance
            }
            guard !user.generationInProgress else {
                throw PaintingServiceError.inFlight
            }
            guard await dailyLimit.allow(userID: userID, limit: Self.dailyLimitPerDay) else {
                throw PaintingServiceError.dailyLimitReached
            }
            try await ledger.chargeGeneration(to: userID, attemptID: attemptID, on: tx)
            user.generationInProgress = true
            try await user.update(on: tx)
            return .generate
        }
    }

    // MARK: - Generation (outside the decision transaction)

    private func generate(mood: Mood, style: PaintingStyle, locale: String, userID: UUID, attemptID: UUID, on db: any Database) async throws -> PaintingResponse {
        let cacheKey = Self.cacheKey(mood: mood, style: style, variant: 0)
        do {
            let prompt = try await promptWriter.write(mood: mood, style: style, locale: locale)
            let image = try await imageProvider.generate(
                prompt: prompt.imagePrompt,
                size: Self.generationImageSize,
                referenceImages: referenceImages[style].map { [$0] } ?? []
            )
            // Record the spend immediately, on its own statement: the money
            // is spent even if a later step fails (plan §3.5).
            let cost = AiCost(
                attemptID: attemptID,
                provider: imageProvider.name,
                model: imageProvider.model,
                costAmountMinor: image.cost.amountMinor,
                costCurrency: image.cost.currency,
                paintingID: nil
            )
            try await cost.save(on: db)
            let imageKey = cacheKey + ".png"
            _ = try await storage.store(data: image.data, key: imageKey, mimeType: "image/png")
            // Commit: insert the painting row (ON CONFLICT DO NOTHING) and
            // clear the in-flight flag, atomically. The painting and the
            // fromCache flag are computed inside the try; the balance is
            // read after it, so a transient read failure after a committed
            // generation never triggers a spurious refund.
            let (painting, fromCache): (Painting, Bool)
            switch try await commitPainting(
                mood: mood, style: style, title: prompt.title, caption: prompt.caption,
                cacheKey: cacheKey, imageKey: imageKey, attemptID: attemptID, userID: userID, on: db
            ) {
            case .inserted(let inserted):
                // Link the spend record to the painting (best effort — the
                // painting itself is already committed).
                cost.paintingID = inserted.id
                do {
                    try await cost.update(on: db)
                } catch {
                    logger.warning("painting: could not link ai_costs row to painting", metadata: [
                        "attemptID": .string(attemptID.uuidString),
                    ])
                }
                (painting, fromCache) = (inserted, false)
            case .conflict(let winner):
                // Lost the cross-user race (§3.4): the winner's row stands,
                // this attempt's charge is refunded, and the winner is
                // served for free.
                cost.paintingID = winner.id
                do {
                    try await cost.update(on: db)
                } catch {
                    logger.warning("painting: could not link ai_costs row to painting", metadata: [
                        "attemptID": .string(attemptID.uuidString),
                    ])
                }
                try await db.transaction { tx in
                    try await ledger.refundGeneration(to: userID, attemptID: attemptID, on: tx)
                }
                (painting, fromCache) = (winner, true)
            }
            let balance = try await ledger.balance(for: userID, on: db)
            return response(for: painting, fromCache: fromCache, balance: balance)
        } catch {
            // Any generation step failed: refund the charge and clear the
            // in-flight flag, best effort. A refund failure is logged with
            // the attempt UUID for manual reconciliation — never swallowed
            // silently — and the client still gets 503.
            do {
                try await db.transaction { tx in
                    try await ledger.refundGeneration(to: userID, attemptID: attemptID, on: tx)
                    if let user = try await User.find(userID, on: tx) {
                        user.generationInProgress = false
                        try await user.update(on: tx)
                    }
                }
            } catch {
                logger.error("painting: refund after generation failure failed", metadata: [
                    "userID": .string(userID.uuidString),
                    "attemptID": .string(attemptID.uuidString),
                ])
            }
            throw PaintingServiceError.generationFailed
        }
    }

    // MARK: - Commit

    private enum CommitOutcome: Sendable {
        case inserted(Painting)
        /// Another request inserted this cache key first; the winner's row.
        case conflict(Painting)
    }

    private func commitPainting(
        mood: Mood, style: PaintingStyle, title: String, caption: String,
        cacheKey: String, imageKey: String, attemptID: UUID, userID: UUID, on db: any Database
    ) async throws -> CommitOutcome {
        try await db.transaction { tx in
            let painting = Painting(
                cacheKey: cacheKey, mood: mood.rawValue, style: style.rawValue, variant: 0,
                title: title, caption: caption, imageKey: imageKey, attemptID: attemptID,
                lastServedAt: Date()
            )
            if let insertedID = try await insertPaintingIgnoringConflict(painting, on: tx) {
                guard let user = try await User.find(userID, on: tx) else {
                    throw PaintingServiceError.userNotFound
                }
                user.lastPaintingID = insertedID
                user.generationInProgress = false
                try await user.update(on: tx)
                guard let inserted = try await Painting.find(insertedID, on: tx) else {
                    throw PaintingServiceError.generationFailed
                }
                return .inserted(inserted)
            }
            // Lost the race: read back the winner.
            guard let winner = try await Painting.query(on: tx)
                .filter(\.$cacheKey == cacheKey)
                .first()
            else {
                throw PaintingServiceError.generationFailed
            }
            if let user = try await User.find(userID, on: tx) {
                user.lastPaintingID = winner.id
                user.generationInProgress = false
                try await user.update(on: tx)
            }
            return .conflict(winner)
        }
    }

    /// Inserts a painting row, ignoring a `cache_key` conflict. Returns the
    /// new row's id, or `nil` when another request already inserted that
    /// cache key (the §3.4 race). Same `ON CONFLICT DO NOTHING` shape as
    /// the ledger — a failed statement inside a transaction aborts it on
    /// Postgres (25P02), so the conflict must never raise.
    /// Exposed (internal) so S1 can prove the conflict branch without
    /// depending on racy timing; the live race itself is proven by the
    /// driver `paintings-race` check.
    func insertPaintingIgnoringConflict(_ painting: Painting, on db: any Database) async throws -> UUID? {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Paintings require an SQL database")
        }
        let id = painting.id ?? UUID()
        let row = try await sql.insert(into: Painting.schema)
            .columns("id", "cache_key", "mood", "style", "variant", "title", "caption", "image_key", "attempt_id", "last_served_at", "created_at")
            .values(id, painting.cacheKey, painting.mood, painting.style, painting.variant, painting.title, painting.caption, painting.imageKey, painting.attemptID, painting.lastServedAt ?? Date(), painting.createdAt ?? Date())
            .ignoringConflicts(with: ["cache_key"])
            .returning("id")
            .first()
        return try row?.decode(column: "id", as: UUID.self)
    }

    // MARK: - Helpers

    /// Cache key for a variant (design.md §4.4, verbatim).
    static func cacheKey(mood: Mood, style: PaintingStyle, variant: Int) -> String {
        "\(mood.rawValue)-\(style.rawValue)-v\(variant)"
    }

    /// Least recently served variant; never-served (`lastServedAt == nil`)
    /// wins over any served one.
    private static func pickLeastRecentlyServed(_ variants: [Painting]) -> Painting? {
        variants.min { a, b in
            switch (a.lastServedAt, b.lastServedAt) {
            case (nil, nil): return false
            case (nil, _): return true
            case (_, nil): return false
            case (let x?, let y?): return x < y
            }
        }
    }

    private func response(for painting: Painting, fromCache: Bool, balance: Int) -> PaintingResponse {
        PaintingResponse(
            id: painting.id ?? UUID(),
            imageURL: storage.url(for: painting.imageKey),
            title: painting.title,
            caption: painting.caption,
            fromCache: fromCache,
            balance: balance
        )
    }
}
