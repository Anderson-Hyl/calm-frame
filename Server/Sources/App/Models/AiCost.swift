import Fluent
import Vapor

/// One recorded AI spend: what a generation attempt actually cost, in the
/// provider's own currency (plan §3.5). Written immediately after a
/// successful provider call, on its own statement, so the money is tracked
/// even if a later step fails. `paintingID` is linked afterwards (best
/// effort) once the painting row is committed; it stays nil when the
/// generation failed after the provider call.
final class AiCost: Model, @unchecked Sendable {
    static let schema = "ai_costs"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "attempt_id")
    var attemptID: UUID

    @Field(key: "provider")
    var provider: String

    @Field(key: "model")
    var model: String

    /// Cost in the provider's minor currency unit (e.g. fen for RMB).
    @Field(key: "cost_amount_minor")
    var costAmountMinor: Int

    @Field(key: "cost_currency")
    var costCurrency: String

    @OptionalField(key: "painting_id")
    var paintingID: UUID?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        attemptID: UUID,
        provider: String,
        model: String,
        costAmountMinor: Int,
        costCurrency: String,
        paintingID: UUID? = nil
    ) {
        self.id = id
        self.attemptID = attemptID
        self.provider = provider
        self.model = model
        self.costAmountMinor = costAmountMinor
        self.costCurrency = costCurrency
        self.paintingID = paintingID
    }
}
