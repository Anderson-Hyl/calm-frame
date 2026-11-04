import Fluent

struct CreateLedgerEntries: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("ledger_entries")
            .id()
            .field("user_id", .uuid, .required,
                   .references("users", "id", onDelete: .cascade))
            .field("delta", .int, .required)
            .field("reason", .string, .required)
            .field("ref_id", .string)
            .field("created_at", .datetime)
            // Idempotency: prevent the same (reason, ref_id) pair from being inserted twice.
            .unique(on: "reason", "ref_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("ledger_entries").delete()
    }
}
