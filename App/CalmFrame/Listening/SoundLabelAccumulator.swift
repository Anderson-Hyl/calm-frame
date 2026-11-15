import Foundation

/// SoundAnalysis 内置分类器（`SNClassifySoundRequest(classifierIdentifier: .version1)`）
/// 的标签 → 特征维度的映射。纯函数，可测试。
///
/// design.md §3.1 关心的标签：typing、speech、conversation、laughter、silence 等。
/// 映射约定（写死在这里，改动属于语义改动，走 Plannotator 关卡）：
/// - `typing` → 打字声；
/// - `speech` / `conversation` / `laughter` → 人声（都是人发出的声音）；
/// - 其他标签（含 `silence`）→ 既不算打字也不算人声。
/// 只有置信度 ≥ 0.5 的观测才计入；低于此值的分类结果视为不可靠，丢弃。
public enum SoundLabel: Sendable, Equatable {
    case typing
    case speech
    case other

    public static let minimumConfidence = 0.5

    public static func from(identifier: String, confidence: Double) -> SoundLabel? {
        guard confidence >= minimumConfidence else { return nil }
        switch identifier {
        case "typing":
            return .typing
        case "speech", "conversation", "laughter":
            return .speech
        default:
            return .other
        }
    }
}

/// 一个聆听窗口内按标签累积的时长（秒）。纯值类型，可测试。
public struct SoundLabelAccumulator: Sendable {
    public private(set) var typingSeconds: Double = 0
    public private(set) var speechSeconds: Double = 0
    public private(set) var otherSeconds: Double = 0

    public init() {}

    /// 累积一次分类观测。`durationSeconds` 取观测的 timeRange 长度。
    public mutating func ingest(identifier: String, confidence: Double, durationSeconds: Double) {
        guard durationSeconds > 0 else { return }
        switch SoundLabel.from(identifier: identifier, confidence: confidence) {
        case .typing:
            typingSeconds += durationSeconds
        case .speech:
            speechSeconds += durationSeconds
        case .other, nil:
            otherSeconds += durationSeconds
        }
    }

    /// 窗口内的打字密度与人声比例。分类窗口可能重叠，累积时长钳制在窗口内。
    public func densities(windowSeconds: Double) -> (typingDensity: Double, speechRatio: Double) {
        guard windowSeconds > 0 else { return (0, 0) }
        let typing = min(typingSeconds / windowSeconds, 1)
        let speech = min(speechSeconds / windowSeconds, 1)
        return (typing, speech)
    }
}
