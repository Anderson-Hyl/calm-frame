import Fluent
import FluentSQL
import Vapor

/// Handles credit ledger reads and writes.
///
/// All mutations are idempotent: the `(reason, ref_id)` unique index in the
/// database ensures that duplicate inserts (e.g. retried starter grants) are
/// silently rejected rather than double-credited.
struct LedgerService {

    // MARK: - Balance

    /// Returns the current credit balance for a user by summing all ledger deltas.
    func balance(for userID: UUID, on db: any Database) async throws -> Int {
        let entries = try await LedgerEntry.query(on: db)
            .filter(\.$userID == userID)
            .all()
        return entries.reduce(0) { $0 + $1.delta }
    }

    // MARK: - Starter Credits

    /// Grants the one-time 5-credit starter bonus to a new user.
    ///
    /// Uses the user's `appleSub` as `ref_id` so the `(reason, ref_id)` unique
    /// constraint makes this call idempotent — a second call for the same user
    /// is silently ignored (the constraint violation is swallowed, not thrown).
    ///
    /// - Parameters:
    ///   - userID: The UUID of the user receiving the credits.
    ///   - appleSub: The Apple `sub` claim, used as the idempotency key.
    ///   - db: The database connection (may be a transaction-scoped database).
    func grantStarter(to userID: UUID, appleSub: String, on db: any Database) async throws {
        _ = try await insertIgnoringConstraint(
            LedgerEntry(userID: userID, delta: 5, reason: .starter, refID: appleSub),
            on: db
        )
    }

    // MARK: - Purchases

    /// Outcome of recording a StoreKit purchase.
    enum PurchaseGrant {
        /// A new ledger row was inserted.
        case granted
        /// The transaction was already credited to this user (idempotent replay).
        case alreadyGranted
        /// The transaction was already credited to a different user (attack signal).
        case grantedToOtherUser
    }

    /// Records a StoreKit purchase as a ledger row.
    ///
    /// Idempotency is enforced by the `(reason, ref_id)` unique constraint —
    /// never by a SELECT-then-INSERT (which double-credits under concurrency).
    /// On a constraint hit, the existing row is read back to tell a same-user
    /// replay (200) from a cross-user replay (409).
    func grantPurchase(to userID: UUID, transactionID: String, credits: Int, on db: any Database) async throws -> PurchaseGrant {
        let entry = LedgerEntry(
            userID: userID,
            delta: credits,
            reason: .purchase,
            refID: transactionID
        )
        guard try await insertIgnoringConstraint(entry, on: db) else {
            guard let existing = try await LedgerEntry.query(on: db)
                .filter(\.$reason == .purchase)
                .filter(\.$refID == transactionID)
                .first() else {
                // Constraint fired but the row is not visible — treat as already
                // granted rather than risk a double credit.
                return .alreadyGranted
            }
            return existing.userID == userID ? .alreadyGranted : .grantedToOtherUser
        }
        return .granted
    }

    // MARK: - Refunds

    /// Records an Apple refund as a negative ledger row.
    /// Returns `false` when the row already exists (duplicate delivery).
    func deductRefund(to userID: UUID, notificationUUID: String, credits: Int, on db: any Database) async throws -> Bool {
        try await insertIgnoringConstraint(
            LedgerEntry(userID: userID, delta: -credits, reason: .appleRefund, refID: notificationUUID),
            on: db
        )
    }

    /// Records a refund reversal as a positive ledger row (credits restored).
    /// Returns `false` when the row already exists (duplicate delivery).
    func restoreRefund(to userID: UUID, notificationUUID: String, credits: Int, on db: any Database) async throws -> Bool {
        try await insertIgnoringConstraint(
            LedgerEntry(userID: userID, delta: credits, reason: .appleRefundReversed, refID: notificationUUID),
            on: db
        )
    }

    /// Finds the user a purchase was credited to, by transaction ID.
    /// Used for refund attribution (the most trustworthy path: it proves the
    /// money was recorded by us).
    func purchaseUserID(forTransactionID transactionID: String, on db: any Database) async throws -> UUID? {
        try await LedgerEntry.query(on: db)
            .filter(\.$reason == .purchase)
            .filter(\.$refID == transactionID)
            .first()?.userID
    }

    // MARK: - Generation

    /// Charges 1 credit for a painting generation.
    ///
    /// `ref_id` is a fresh attempt UUID per request — never the cache key —
    /// so two users generating the same mood + style each get their own
    /// charge row, and the loser's refund is attributable to the exact
    /// attempt that paid (plan §3.3).
    func chargeGeneration(to userID: UUID, attemptID: UUID, on db: any Database) async throws {
        _ = try await insertIgnoringConstraint(
            LedgerEntry(userID: userID, delta: -1, reason: .generate, refID: attemptID.uuidString),
            on: db
        )
    }

    /// Refunds a generation charge (generation failed, or this attempt lost
    /// the cross-user cache-key race). Idempotent on the same attempt UUID:
    /// a second call for the same attempt is silently ignored, so a
    /// double-refund is impossible.
    func refundGeneration(to userID: UUID, attemptID: UUID, on db: any Database) async throws {
        _ = try await insertIgnoringConstraint(
            LedgerEntry(userID: userID, delta: 1, reason: .refundFailure, refID: attemptID.uuidString),
            on: db
        )
    }

    // MARK: - Helpers

    /// Inserts a ledger row, ignoring unique-constraint conflicts.
    /// Returns `true` when the row was inserted, `false` when it already existed.
    ///
    /// Implemented as `INSERT ... ON CONFLICT (reason, ref_id) DO NOTHING
    /// RETURNING id`, not as `save` + catching the constraint error: a failed
    /// statement inside an explicit transaction aborts the whole transaction
    /// on Postgres (sqlState 25P02), so any later statement in that
    /// transaction fails too — idempotent replays then came back HTTP 500
    /// (live redeem check 20261119-060008). `ON CONFLICT DO NOTHING` never
    /// errors, so the transaction stays usable; the unique index is still
    /// the idempotency backstop, never a SELECT-then-INSERT. The same
    /// statement works on the in-memory SQLite used by the test suite.
    private func insertIgnoringConstraint(_ entry: LedgerEntry, on db: any Database) async throws -> Bool {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Ledger requires an SQL database")
        }
        let id = entry.id ?? UUID()
        let row = try await sql.insert(into: LedgerEntry.schema)
            .columns("id", "user_id", "delta", "reason", "ref_id", "created_at")
            .values(id, entry.userID, entry.delta, entry.reason.rawValue, entry.refID, Date())
            .ignoringConflicts(with: ["reason", "ref_id"])
            .returning("id")
            .first()
        return row != nil
    }
}
