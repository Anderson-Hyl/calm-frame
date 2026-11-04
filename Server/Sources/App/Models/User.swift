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

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, appleSub: String) {
        self.id = id
        self.appleSub = appleSub
    }
}
