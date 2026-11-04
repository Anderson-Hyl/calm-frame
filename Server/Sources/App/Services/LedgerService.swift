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
        let entry = LedgerEntry(
            userID: userID,
            delta: 5,
            reason: .starter,
            refID: appleSub
        )
        do {
            try await entry.save(on: db)
        } catch {
            // Swallow unique-constraint violations — this means the starter was
            // already granted. Any other error is re-thrown.
            if let dbError = error as? any DatabaseError, dbError.isConstraintFailure {
                return
            }
            throw error
        }
    }
}
