/// The ambient mood of the office environment, classified on-device.
///
/// - hectic: Dense keyboard activity combined with overlapping voices.
/// - noisy: High overall volume.
/// - tenseQuiet: A sudden drop to silence after a loud period.
/// - drowsy: Low activity and quiet, typically in the early afternoon.
/// - calm: Baseline state; no new painting is requested.
public enum Mood: String, Codable, Sendable, CaseIterable, Hashable {
    case hectic
    case noisy
    case tenseQuiet
    case drowsy
    case calm
}
