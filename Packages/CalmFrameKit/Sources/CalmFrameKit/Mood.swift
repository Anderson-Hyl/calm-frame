/// 办公室氛围分类。
///
/// - hectic: 忙乱（键盘密集 + 人声交叠）
/// - noisy: 吵闹（高音量）
/// - tenseQuiet: 紧绷的安静（突然安静，之前很响）
/// - drowsy: 犯困（下午安静低活跃）
/// - calm: 平静（不触发新画生成）
public enum Mood: String, Codable, Sendable, CaseIterable, Hashable {
    case hectic
    case noisy
    case tenseQuiet
    case drowsy
    case calm
}
