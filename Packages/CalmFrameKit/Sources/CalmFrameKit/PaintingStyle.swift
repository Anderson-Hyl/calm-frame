/// The visual style applied to a generated painting.
///
/// - oilPainting1800s: 19th-century landscape oil painting.
/// - oldPostcard: Hand-painted vintage postcard illustration.
/// - gothicNight: Gothic night scene; used after end-of-day hour (Halloween easter egg).
public enum PaintingStyle: String, Codable, Sendable, CaseIterable, Hashable {
    case oilPainting1800s
    case oldPostcard
    case gothicNight
}
