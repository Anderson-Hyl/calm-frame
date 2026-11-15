import CalmFrameKit
import Foundation

/// 麦克风权限状态。
public enum ListeningPermission: Sendable, Equatable {
    case unknown
    case granted
    case denied
    /// 设备没有可用输入（例如模拟器无麦克风）。此时只能用手动 mood 模式。
    case unavailable
}

/// 聆听运行状态（供调试页展示）。
public enum ListeningState: Sendable, Equatable {
    case idle
    case listening
    case denied
    case unavailable
    case error(String)
}

/// 一个采样窗口结束时发布的结果。每个窗口都有一条（供调试页展示）；
/// `stableMood` 只在防抖放行（同一 mood 连续 2 窗口）时有值，C4 的请求触发只看它。
public struct ListeningUpdate: Sendable, Equatable {
    public var features: AmbienceFeatures
    public var mood: Mood
    public var confidence: Double
    public var stableMood: Mood?
    public var windowEndsAt: Date
}

/// 聆听引擎协议：`AmbienceListener` 的真实实现与测试替身共用。
/// ViewModel 只依赖这个协议，不直接碰 AVAudioEngine。
public protocol ListeningEngine: AnyObject, Sendable {
    var permission: ListeningPermission { get async }
    func requestPermission() async -> Bool
    func start(intervalMinutes: Int) async
    func stop() async
    var updates: AsyncStream<ListeningUpdate> { get }
    /// 状态变化流（listening / idle / unavailable / error）。ViewModel 订阅它来刷新调试页。
    var stateUpdates: AsyncStream<ListeningState> { get }
}
