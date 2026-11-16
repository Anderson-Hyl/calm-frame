import CalmFrameKit
import Foundation

/// mock 聆听引擎（用户决定 2026-11-15：先不做真声音采集，用 mock 推进）。
/// 只产出合成的窗口结果：特征按 mood 编造得“像真的”（调试页可看），
/// 绝不碰麦克风、不读音频。启动参数 `--mock-mood` / `--mock-cycle` 启用。
/// 与测试替身 FakeListeningEngine 同构（`nonisolated let` 流 + NSLock 状态）。
public final class MockListeningEngine: ListeningEngine {
    public nonisolated let updates: AsyncStream<ListeningUpdate>
    public nonisolated let stateUpdates: AsyncStream<ListeningState>

    private let updatesContinuation: AsyncStream<ListeningUpdate>.Continuation
    private let stateContinuation: AsyncStream<ListeningState>.Continuation
    private let moods: [Mood]
    private let cycleSeconds: TimeInterval
    private let lock = NSLock()
    private var loopTask: Task<Void, Never>?
    private var running = false

    public init(moods: [Mood], cycleSeconds: TimeInterval = 8) {
        self.moods = moods.isEmpty ? Mood.allCases : moods
        self.cycleSeconds = cycleSeconds
        var u: AsyncStream<ListeningUpdate>.Continuation!
        self.updates = AsyncStream { u = $0 }
        self.updatesContinuation = u
        var s: AsyncStream<ListeningState>.Continuation!
        self.stateUpdates = AsyncStream { s = $0 }
        self.stateContinuation = s
    }

    public var permission: ListeningPermission {
        get async { .granted }
    }

    public func requestPermission() async -> Bool { true }

    public func start(intervalMinutes: Int) async {
        let alreadyRunning = lock.withLock {
            let was = running
            running = true
            return was
        }
        guard !alreadyRunning else { return }
        stateContinuation.yield(.listening)
        loopTask = Task { [weak self] in
            guard let self else { return }
            var index = 0
            while !Task.isCancelled {
                let mood = self.moods[index % self.moods.count]
                self.updatesContinuation.yield(ListeningUpdate(
                    features: Self.features(for: mood),
                    mood: mood,
                    confidence: 0.8,
                    stableMood: mood,
                    windowEndsAt: Date()
                ))
                index += 1
                if self.moods.count == 1 {
                    // 单 mood 定住：只发一次，之后等取消。
                    try? await Task.sleep(for: .seconds(3600))
                } else {
                    try? await Task.sleep(for: .seconds(self.cycleSeconds))
                }
            }
        }
    }

    public func stop() async {
        lock.withLock { running = false }
        loopTask?.cancel()
        loopTask = nil
        stateContinuation.yield(.idle)
    }

    /// 按 mood 编造“像真的”特征（只供调试页显示；mock 不走分类器，
    /// 数值与 MoodThresholds 的规则方向一致）。
    static func features(for mood: Mood) -> AmbienceFeatures {
        switch mood {
        case .hectic: return AmbienceFeatures(typingDensity: 0.6, speechRatio: 0.3, meanDBFS: -30, quietDrop: false)
        case .noisy: return AmbienceFeatures(typingDensity: 0.2, speechRatio: 0.7, meanDBFS: -20, quietDrop: false)
        case .tenseQuiet: return AmbienceFeatures(typingDensity: 0.05, speechRatio: 0.05, meanDBFS: -50, quietDrop: true)
        case .drowsy: return AmbienceFeatures(typingDensity: 0.05, speechRatio: 0.05, meanDBFS: -55, quietDrop: false)
        case .calm: return AmbienceFeatures(typingDensity: 0.1, speechRatio: 0.1, meanDBFS: -45, quietDrop: false)
        }
    }
}

/// mock 启动参数解析。
/// `--mock-mood <mood>` 定住一个 mood；`--mock-cycle <秒>` 按
/// calm → hectic → noisy → tenseQuiet → drowsy 循环；
/// 两者都给时从指定 mood 开始循环；都不给返回 nil（走真聆听）。
public struct MockListeningConfiguration: Sendable, Equatable {
    public var moods: [Mood]
    public var cycleSeconds: TimeInterval

    public static let cycleOrder: [Mood] = [.calm, .hectic, .noisy, .tenseQuiet, .drowsy]

    public static func fromArguments(_ arguments: [String] = CommandLine.arguments) -> MockListeningConfiguration? {
        var startMood: Mood?
        if let i = arguments.firstIndex(of: "--mock-mood"), i + 1 < arguments.count {
            startMood = Mood(rawValue: arguments[i + 1])
        }
        var cycle: TimeInterval?
        if let i = arguments.firstIndex(of: "--mock-cycle"), i + 1 < arguments.count {
            cycle = TimeInterval(arguments[i + 1])
        }
        guard startMood != nil || cycle != nil else { return nil }
        if let cycle {
            var order = cycleOrder
            if let startMood, let idx = order.firstIndex(of: startMood) {
                order = Array(order[idx...] + order[..<idx])
            }
            return MockListeningConfiguration(moods: order, cycleSeconds: max(cycle, 1))
        }
        return MockListeningConfiguration(moods: [startMood ?? .calm], cycleSeconds: 3600)
    }
}
