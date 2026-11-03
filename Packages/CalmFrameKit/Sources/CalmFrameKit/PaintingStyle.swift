/// 画作风格。
///
/// - oilPainting1800s: 19 世纪风景油画
/// - oldPostcard: 老明信片（手绘彩印风）
/// - gothicNight: 哥特夜景（下班后万圣节彩蛋）
public enum PaintingStyle: String, Codable, Sendable, CaseIterable, Hashable {
    case oilPainting1800s
    case oldPostcard
    case gothicNight
}
