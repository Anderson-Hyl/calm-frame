import CalmFrameKit
import XCTest
@testable import CalmFrame

/// C2 调试页状态机测试：手动模式、拒权/无麦克风强制手动、说明页流程、
/// 窗口结果流入、间隔切换。引擎用替身，不碰 AVAudioEngine / 麦克风。
@MainActor
final class ListeningViewModelTests: XCTestCase {

    // MARK: - 替身引擎

    private final class FakeListeningEngine: ListeningEngine, @unchecked Sendable {
        var permissionToReturn: ListeningPermission = .granted
        var requestPermissionResult = true
        private let lock = NSLock()
        private var _startCalls: [Int] = []
        private var _stopCalls = 0

        var startCalls: [Int] { lock.withLock { _startCalls } }
        var stopCalls: Int { lock.withLock { _stopCalls } }

        let updates: AsyncStream<ListeningUpdate>
        let updateContinuation: AsyncStream<ListeningUpdate>.Continuation
        let stateUpdates: AsyncStream<ListeningState>
        let stateContinuation: AsyncStream<ListeningState>.Continuation

        init() {
            let (updates, updateContinuation) = AsyncStream.makeStream(of: ListeningUpdate.self)
            self.updates = updates
            self.updateContinuation = updateContinuation
            let (stateUpdates, stateContinuation) = AsyncStream.makeStream(of: ListeningState.self)
            self.stateUpdates = stateUpdates
            self.stateContinuation = stateContinuation
        }

        var permission: ListeningPermission {
            get async { lock.withLock { permissionToReturn } }
        }

        func requestPermission() async -> Bool {
            let granted = requestPermissionResult
            if granted {
                lock.withLock { permissionToReturn = .granted }
            }
            return granted
        }

        func start(intervalMinutes: Int) async {
            lock.withLock { _startCalls.append(intervalMinutes) }
        }

        func stop() async {
            lock.withLock { _stopCalls += 1 }
        }

        func emit(_ update: ListeningUpdate) {
            updateContinuation.yield(update)
        }
    }

    // MARK: - 工具

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func sampleUpdate(mood: Mood = .hectic, stableMood: Mood? = nil) -> ListeningUpdate {
        ListeningUpdate(
            features: AmbienceFeatures(typingDensity: 0.8, speechRatio: 0.3, meanDBFS: -20, quietDrop: false),
            mood: mood,
            confidence: 0.7,
            stableMood: stableMood,
            windowEndsAt: Date()
        )
    }

    // MARK: - 测试

    func testManualMoodSelectionSwitchesToManual() {
        let viewModel = ListeningViewModel(engine: FakeListeningEngine())
        XCTAssertNil(viewModel.currentMood)
        viewModel.selectManualMood(.drowsy)
        XCTAssertEqual(viewModel.mode, .manual)
        XCTAssertEqual(viewModel.manualMood, .drowsy)
        XCTAssertEqual(viewModel.currentMood, .drowsy)
    }

    func testExplainerShownBeforeFirstStart() async {
        let engine = FakeListeningEngine()
        let viewModel = ListeningViewModel(engine: engine)
        viewModel.hasShownExplainer = false
        viewModel.startListening()
        XCTAssertTrue(viewModel.isExplainerPresented, "首次开启应先弹说明页，不直接弹系统权限")
        XCTAssertTrue(engine.startCalls.isEmpty)
        viewModel.explainerConfirmed()
        XCTAssertTrue(viewModel.hasShownExplainer)
        XCTAssertFalse(viewModel.isExplainerPresented)
        await waitUntil { engine.startCalls.count == 1 }
        XCTAssertEqual(engine.startCalls, [5], "确认后走权限流程并以默认间隔 5 分钟启动")
    }

    func testDeniedPermissionForcesManualMode() async {
        let engine = FakeListeningEngine()
        engine.permissionToReturn = .denied
        let viewModel = ListeningViewModel(engine: engine)
        viewModel.hasShownExplainer = true
        viewModel.startListening()
        await waitUntil { viewModel.state == .denied }
        XCTAssertEqual(viewModel.state, .denied)
        XCTAssertEqual(viewModel.mode, .manual, "拒权后强制手动模式")
        XCTAssertTrue(engine.startCalls.isEmpty, "拒权时不应启动引擎")
    }

    func testUnavailableInputForcesManualMode() async {
        let engine = FakeListeningEngine()
        engine.permissionToReturn = .unavailable
        let viewModel = ListeningViewModel(engine: engine)
        viewModel.hasShownExplainer = true
        viewModel.startListening()
        await waitUntil { viewModel.state == .unavailable }
        XCTAssertEqual(viewModel.state, .unavailable)
        XCTAssertEqual(viewModel.mode, .manual, "无麦克风（模拟器）时强制手动模式")
    }

    func testRequestPermissionFlowWhenUndetermined() async {
        let engine = FakeListeningEngine()
        engine.permissionToReturn = .unknown
        engine.requestPermissionResult = true
        let viewModel = ListeningViewModel(engine: engine)
        viewModel.hasShownExplainer = true
        viewModel.startListening()
        await waitUntil { engine.startCalls.count == 1 }
        XCTAssertEqual(viewModel.state, .listening)
        XCTAssertEqual(viewModel.permission, .granted)
    }

    func testUpdatesFlowIntoPublishedState() async {
        let engine = FakeListeningEngine()
        let viewModel = ListeningViewModel(engine: engine)
        viewModel.hasShownExplainer = true
        viewModel.startListening()
        await waitUntil { engine.startCalls.count == 1 }
        engine.emit(sampleUpdate(mood: .hectic, stableMood: nil))
        await waitUntil { viewModel.lastMood == .hectic }
        XCTAssertEqual(viewModel.lastMood, .hectic)
        XCTAssertEqual(viewModel.lastConfidence ?? -1, 0.7, accuracy: 0.001)
        XCTAssertEqual(viewModel.lastFeatures?.typingDensity ?? -1, 0.8, accuracy: 0.001)
        XCTAssertEqual(viewModel.recentWindows.count, 1)
        XCTAssertNil(viewModel.stableMood, "未放行时 stableMood 仍为空")
        engine.emit(sampleUpdate(mood: .hectic, stableMood: .hectic))
        await waitUntil { viewModel.stableMood == .hectic }
        XCTAssertEqual(viewModel.currentMood, .hectic, "自动模式下 currentMood 用防抖后的稳定值")
        XCTAssertEqual(viewModel.recentWindows.count, 2)
    }

    func testIntervalChangeRestartsEngineWhileListening() async {
        let engine = FakeListeningEngine()
        let viewModel = ListeningViewModel(engine: engine)
        viewModel.hasShownExplainer = true
        viewModel.startListening()
        await waitUntil { engine.startCalls.count == 1 }
        viewModel.setInterval(3)
        await waitUntil { engine.startCalls.count == 2 }
        XCTAssertEqual(viewModel.intervalMinutes, 3)
        XCTAssertEqual(engine.startCalls, [5, 3])
        XCTAssertEqual(engine.stopCalls, 1, "切换间隔时先停再起")
    }

    func testStopListening() async {
        let engine = FakeListeningEngine()
        let viewModel = ListeningViewModel(engine: engine)
        viewModel.hasShownExplainer = true
        viewModel.startListening()
        await waitUntil { engine.startCalls.count == 1 }
        viewModel.stopListening()
        await waitUntil { viewModel.state == .idle }
        XCTAssertEqual(viewModel.state, .idle)
        XCTAssertEqual(engine.stopCalls, 1)
    }
}
