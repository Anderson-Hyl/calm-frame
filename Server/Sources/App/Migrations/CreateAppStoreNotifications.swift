import Fluent

struct CreateAppStoreNotifications: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("app_store_notifications")
            .id()
            .field("notification_uuid", .string, .required)
            .field("notification_type", .string, .required)
            .field("transaction_id", .string)
            .field("signed_payload", .string, .required)
            .field("status", .string, .required)
            .field("received_at", .datetime)
            .field("processed_at", .datetime)
            // De-duplication: Apple retries a notification with the same UUID.
            .unique(on: "notification_uuid")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("app_store_notifications").delete()
    }
}
