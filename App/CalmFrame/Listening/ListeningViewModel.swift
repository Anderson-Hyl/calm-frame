import CalmFrameKit
import Foundation
import SwiftUI

/// 聆听调试页的状态机（@MainActor）。拥有 `ListeningEngine`，把窗口结果翻译成
/// 调试页能显示的状态；不直接碰 AVAudioEngine（测试时用替身引擎注入）。
@MainActor
public final class ListeningViewModel: ObservableObject {

    public enum Mode: String, CaseIterable, Sendable {
        case auto = "自动"
        case manual = "手动"
    }

    /// 最近窗口记录（调试页列表，最多留 5 条）。
    public struct WindowRecord: Identifiable, Sendable {
        public var id = UUID()
        public var endsAt: Date
        public var features: AmbienceFeatures
        public var mood: Mood
        public var confidence: Double
    }

    @Published public private(set) var permission: ListeningPermission = .unknown
    @Published public private(set) var state: ListeningState = .idle
    @Published public var mode: Mode = .auto
    /// 采样间隔（分钟）。可选 3/5/10；1 分钟仅供调试（窗口仍是 30 秒）。
    @Published public var intervalMinutes: Int = 5
    @Published public private(set) var lastFeatures: AmbienceFeatures?
    @Published public private(set) var lastMood: Mood?
    @Published public private(set) var lastConfidence: Double?
    @Published public private(set) var stableMood: Mood?
    @Published public var manualMood: Mood?
    @Published public private(set) var recentWindows: [WindowRecord] = []
    @Published public var isExplainerPresented = false
    @Published public private(set) var errorMessage: String?

    /// 当前生效的 mood：手动模式用手动选择，否则用防抖后的稳定 mood（没有则用最近窗口的）。
    public var currentMood: Mood? {
        if mode == .manual { return manualMood }
        return stableMood ?? lastMood
    }

    public static let intervalOptions = [1, 3, 5, 10]

    private let engine: any ListeningEngine
    private var updatesTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?

    /// `hasShownExplainer` 存 UserDefaults：首次开启聆听先弹说明页，再弹系统权限。
    public var hasShownExplainer: Bool {
        get { UserDefaults.standard.bool(forKey: "listeningExplainerShown") }
        set { UserDefaults.standard.set(newValue, forKey: "listeningExplainerShown") }
    }

    public init(engine: any ListeningEngine = AmbienceListener()) {
        self.engine = engine
    }

    // MARK: - 启停

    /// 点“开始聆听”：没看过说明先弹说明页；看过直接走权限流程。
    public func startListening() {
        if !hasShownExplainer {
            isExplainerPresented = true
            return
        }
        Task { await requestPermissionAndStart() }
    }

    /// 说明页确认：记下已看过，走权限流程。
    public func explainerConfirmed() {
        hasShownExplainer = true
        isExplainerPresented = false
        Task { await requestPermissionAndStart() }
    }

    public func stopListening() {
        updatesTask?.cancel()
        updatesTask = nil
        stateTask?.cancel()
        stateTask = nil
        Task {
            await engine.stop()
            state = .idle
        }
    }

    private func requestPermissionAndStart() async {
        permission = await engine.permission
        switch permission {
        case .unavailable:
            // 模拟器等无麦克风的设备：只能手动模式。
            state = .unavailable
            mode = .manual
            return
        case .denied:
            state = .denied
            mode = .manual
            return
        case .unknown:
            let granted = await engine.requestPermission()
            permission = await engine.permission
            if !granted {
                state = .denied
                mode = .manual
                return
            }
            fallthrough
        case .granted:
            await engine.start(intervalMinutes: intervalMinutes)
            state = .listening
            subscribe()
        }
    }

    private func subscribe() {
        updatesTask?.cancel()
        stateTask?.cancel()
        updatesTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.engine.updates
            for await update in stream {
                self.apply(update)
            }
        }
        stateTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.engine.stateUpdates
            for await newState in stream {
                self.applyState(newState)
            }
        }
    }

    private func apply(_ update: ListeningUpdate) {
        lastFeatures = update.features
        lastMood = update.mood
        lastConfidence = update.confidence
        if let stable = update.stableMood {
            stableMood = stable
        }
        recentWindows.insert(
            WindowRecord(endsAt: update.windowEndsAt, features: update.features, mood: update.mood, confidence: update.confidence),
            at: 0
        )
        if recentWindows.count > 5 {
            recentWindows.removeLast(recentWindows.count - 5)
        }
    }

    private func applyState(_ newState: ListeningState) {
        switch newState {
        case .error(let message):
            errorMessage = message
            state = .error(message)
        case .unavailable:
            state = .unavailable
            mode = .manual
        case .idle:
            state = .idle
        case .listening:
            state = .listening
        case .denied:
            state = .denied
            mode = .manual
        }
    }

    // MARK: - 手动模式与间隔

    /// 手动选 mood：切到手动模式（需求 1.5；拒权或无麦克风时这是唯一 mood 通路）。
    public func selectManualMood(_ mood: Mood) {
        manualMood = mood
        mode = .manual
    }

    public func setInterval(_ minutes: Int) {
        intervalMinutes = minutes
        guard state == .listening else { return }
        Task {
            await engine.stop()
            await engine.start(intervalMinutes: minutes)
        }
    }
}
