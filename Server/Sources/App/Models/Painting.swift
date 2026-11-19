import Fluent
import Vapor

/// One painting in the global shared gallery (design.md §4.4).
/// Rows are keyed by `cacheKey` ("mood-style-vVariant", unique) and shared
/// across users: the second request for the same mood + style is a cache
/// hit, never a second generation (plan §7 Q5, approved).
/// Variants 1–5 are reserved for the seed-gallery follow-up step (Q2);
/// this slice only ever writes variant 0.
final class Painting: Model, @unchecked Sendable {
    static let schema = "paintings"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "cache_key")
    var cacheKey: String

    @Field(key: "mood")
    var mood: String

    @Field(key: "style")
    var style: String

    @Field(key: "variant")
    var variant: Int

    @Field(key: "title")
    var title: String

    @Field(key: "caption")
    var caption: String

    /// Storage key under `paintings/` (e.g. `hectic-oilPainting1800s-v0.png`).
    @Field(key: "image_key")
    var imageKey: String

    /// The generation attempt that produced this row (for cost tracing).
    @Field(key: "attempt_id")
    var attemptID: UUID

    /// Last time this variant was served; nil = never served. Rotation
    /// picks the least recently served variant, nil first (plan §3.2).
    @Timestamp(key: "last_served_at", on: .none)
    var lastServedAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        cacheKey: String,
        mood: String,
        style: String,
        variant: Int,
        title: String,
        caption: String,
        imageKey: String,
        attemptID: UUID,
        lastServedAt: Date? = nil
    ) {
        self.id = id
        self.cacheKey = cacheKey
        self.mood = mood
        self.style = style
        self.variant = variant
        self.title = title
        self.caption = caption
        self.imageKey = imageKey
        self.attemptID = attemptID
        self.lastServedAt = lastServedAt
    }
}
