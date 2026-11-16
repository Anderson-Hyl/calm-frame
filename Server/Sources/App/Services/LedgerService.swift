import Fluent
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

    // MARK: - Helpers

    /// Inserts a ledger row, swallowing unique-constraint violations.
    /// Returns `true` when the row was inserted, `false` when it already existed.
    private func insertIgnoringConstraint(_ entry: LedgerEntry, on db: any Database) async throws -> Bool {
        do {
            try await entry.save(on: db)
            return true
        } catch {
            if let dbError = error as? any DatabaseError, dbError.isConstraintFailure {
                return false
            }
            throw error
        }
    }
}
