import CalmFrameKit
import Foundation

/// Mood 防抖状态机（C3，design.md §3.1）：与分类器分离，纯状态、无 IO。
///
/// 规则：同一 mood 连续出现 2 个窗口才放行（返回该 mood，调用方据此触发请求）；
/// 单个窗口的翻转不放行；中途变 mood 则计数清零；已放行的 mood 不会重复放行，
/// 直到换成另一个 mood 并再次连续 2 窗口。
public struct MoodDebouncer: Sendable {
    /// 最近一次放行的 mood；未放行过为 nil。
    public private(set) var stableMood: Mood?

    private var pendingMood: Mood?
    private var consecutiveCount: Int = 0

    public init() {}

    /// 每个窗口调用一次。放行时返回该 mood，否则返回 nil。
    public mutating func observe(_ mood: Mood) -> Mood? {
        if mood == pendingMood {
            consecutiveCount += 1
        } else {
            pendingMood = mood
            consecutiveCount = 1
        }
        if consecutiveCount >= 2 && stableMood != mood {
            stableMood = mood
            return mood
        }
        return nil
    }

    public mutating func reset() {
        stableMood = nil
        pendingMood = nil
        consecutiveCount = 0
    }
}
