import Fluent

/// Creates the `ai_costs` table (plan §3.5): one row per provider call
/// that succeeded, recording the real spend in the provider's currency.
/// `painting_id` is a nullable FK — it is linked after the painting row
/// commits, and stays null when generation failed after the provider call.
struct CreateAiCosts: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(AiCost.schema)
            .id()
            .field("attempt_id", .uuid, .required)
            .field("provider", .string, .required)
            .field("model", .string, .required)
            .field("cost_amount_minor", .int, .required)
            .field("cost_currency", .string, .required)
            .field("painting_id", .uuid, .references(Painting.schema, "id", onDelete: .setNull))
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(AiCost.schema).delete()
    }
}
