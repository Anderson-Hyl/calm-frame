import Fluent
import FluentSQL
import SQLKit

/// Adds painting state to `users` (plan §3.1):
/// - `last_painting_id` — nullable FK to `paintings`, for `GET /latest`.
/// - `generation_in_progress` — the in-flight guard (§3.3), default false.
///
/// The bool default is expressed as a raw SQL column constraint: FluentKit
/// has no built-in `.default` field constraint, and `SQLSchemaConverter`
/// passes `.custom(any)` through as a `SQLExpression`, so
/// `SQLColumnConstraintAlgorithm.default(SQLLiteral.boolean(false))` is the
/// supported path (verified against fluent-kit 1.57.0 / SQLKit sources).
/// The default matters on Postgres, where pre-existing user rows must get
/// `false` when the column is added.
struct AddPaintingStateToUsers: AsyncMigration {
    func prepare(on database: any Database) async throws {
        // Two separate ALTER TABLE statements: SQLite accepts only one
        // ADD COLUMN per statement — a single update with both fields
        // emits `ADD COLUMN ..., ADD COLUMN ...`, which fails on SQLite
        // with `near ",": syntax error` (S1 caught this).
        try await database.schema(User.schema)
            .field("last_painting_id", .uuid, .references(Painting.schema, "id", onDelete: .setNull))
            .update()
        try await database.schema(User.schema)
            .field(
                "generation_in_progress", .bool, .required,
                .custom(SQLColumnConstraintAlgorithm.default(SQLLiteral.boolean(false)))
            )
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(User.schema)
            .deleteField("last_painting_id")
            .deleteField("generation_in_progress")
            .update()
    }
}
