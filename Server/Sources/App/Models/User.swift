import Fluent
import Vapor

/// A registered user, identified by their Apple subject (`sub`) claim.
final class User: Model, @unchecked Sendable {
    static let schema = "users"

    @ID(key: .id)
    var id: UUID?

    /// The `sub` claim from the Apple identity token. Unique per user.
    @Field(key: "apple_sub")
    var appleSub: String

    /// The user's most recently served painting (for `GET /latest`).
    /// Null until the first painting is served.
    @OptionalField(key: "last_painting_id")
    var lastPaintingID: UUID?

    /// True while a generation for this user is in flight (plan §3.3).
    /// A second request while true gets 409; cleared on success, failure,
    /// or refund — never left set by a failed generation.
    @Field(key: "generation_in_progress")
    var generationInProgress: Bool

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, appleSub: String) {
        self.id = id
        self.appleSub = appleSub
        self.generationInProgress = false
    }
}
