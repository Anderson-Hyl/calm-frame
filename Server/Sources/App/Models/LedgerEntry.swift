import Fluent
import Vapor

/// A single credit ledger entry for a user.
///
/// Balance = SUM(delta) for a given user — no separate mutable balance column,
/// which prevents "credits added but not recorded" inconsistencies.
final class LedgerEntry: Model, @unchecked Sendable {
    static let schema = "ledger_entries"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userID: UUID

    /// Positive for credits in (starter, purchase); negative for credits out (generate, refund).
    @Field(key: "delta")
    var delta: Int

    /// The business reason for this entry.
    @Field(key: "reason")
    var reason: LedgerReason

    /// Idempotency key scoped to the reason (e.g. transactionId for purchases).
    /// Enforced unique per (reason, ref_id) pair by a database index.
    @OptionalField(key: "ref_id")
    var refID: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userID: UUID,
        delta: Int,
        reason: LedgerReason,
        refID: String? = nil
    ) {
        self.id = id
        self.userID = userID
        self.delta = delta
        self.reason = reason
        self.refID = refID
    }
}

/// The business reason behind a ledger delta.
enum LedgerReason: String, Codable, Sendable {
    /// 5 free credits granted on first sign-in.
    case starter
    /// Credits purchased via StoreKit 2.
    case purchase
    /// 1 credit consumed to generate a painting.
    case generate
    /// Refund issued when AI generation fails after deducting a credit.
    case refundFailure = "refund_failure"
    /// Credits clawed back after an Apple App Store refund.
    case appleRefund = "apple_refund"
    /// Credits restored after an Apple refund reversal.
    case appleRefundReversed = "apple_refund_reversed"
}
