import Fluent
import Vapor

/// One received App Store Server Notification, kept for de-duplication and
/// replay debugging. The `signedPayload` is stored verbatim (it carries
/// Apple's JWS, not user credentials — no tokens are ever stored here).
final class AppStoreNotification: Model, @unchecked Sendable {
    static let schema = "app_store_notifications"

    @ID(key: .id)
    var id: UUID?

    /// Apple's `notificationUUID` — the de-duplication key (stable across retries).
    @Field(key: "notification_uuid")
    var notificationUUID: String

    /// Raw `notificationType` string (e.g. "REFUND"); kept as a string so
    /// unknown future types don't break decoding.
    @Field(key: "notification_type")
    var notificationType: String

    /// Transaction the notification concerns, if any (from the inner transaction).
    @OptionalField(key: "transaction_id")
    var transactionID: String?

    /// The raw `signedPayload` JWS, verbatim, for replay/debugging.
    @Field(key: "signed_payload")
    var signedPayload: String

    /// `processed` or `parked` (parked = verified but could not be applied yet).
    @Field(key: "status")
    var status: String

    @Timestamp(key: "received_at", on: .create)
    var receivedAt: Date?

    /// Set explicitly when the notification reaches its final state.
    @OptionalField(key: "processed_at")
    var processedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        notificationUUID: String,
        notificationType: String,
        transactionID: String?,
        signedPayload: String,
        status: String
    ) {
        self.id = id
        self.notificationUUID = notificationUUID
        self.notificationType = notificationType
        self.transactionID = transactionID
        self.signedPayload = signedPayload
        self.status = status
    }
}
