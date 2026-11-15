import Foundation

/// MoodClassifier 的阈值。默认值按 design.md §3.1（方案 v2 批复版）。
/// 集中一处，调试页（C2）以后可调；改默认值属于语义改动，走 Plannotator 关卡，不静默改。
public struct MoodThresholds: Sendable, Equatable {
    /// noisy：响度线（meanDBFS 高于此值即嘈杂）。
    public var noisyDBFS: Double = -25
    /// noisy：人声占比线。
    public var noisySpeechRatio: Double = 0.5
    /// hectic：打字密度线。
    public var hecticTypingDensity: Double = 0.4
    /// hectic：人声占比线。
    public var hecticSpeechRatio: Double = 0.2
    /// tenseQuiet：响度线（meanDBFS 低于此值且出现 quietDrop 即紧绷的安静）。
    public var tenseQuietDBFS: Double = -45
    /// drowsy：打字密度线。
    public var drowsyTypingDensity: Double = 0.1
    /// drowsy：人声占比线。
    public var drowsySpeechRatio: Double = 0.1
    /// drowsy 时间窗起始小时（含），本地时间。
    public var drowsyStartHour: Int = 13
    /// drowsy 时间窗结束小时（不含），本地时间。
    public var drowsyEndHour: Int = 16

    public static let `default` = MoodThresholds()

    public init() {}
}
