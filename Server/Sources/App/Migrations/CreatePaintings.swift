import Fluent

/// Creates the `paintings` table (plan §3.1): the global shared gallery.
/// `cache_key` is unique — it is the cross-user race guard (§3.4): two
/// concurrent generations for the same mood + style race on this constraint,
/// and the loser refunds and serves the winner's row.
struct CreatePaintings: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Painting.schema)
            .id()
            .field("cache_key", .string, .required)
            .field("mood", .string, .required)
            .field("style", .string, .required)
            .field("variant", .int, .required)
            .field("title", .string, .required)
            .field("caption", .string, .required)
            .field("image_key", .string, .required)
            .field("attempt_id", .uuid, .required)
            .field("last_served_at", .datetime)
            .field("created_at", .datetime)
            .unique(on: "cache_key")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Painting.schema).delete()
    }
}
