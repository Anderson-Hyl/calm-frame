import AVFAudio
import CalmFrameKit
import Foundation
import SoundAnalysis

/// 氛围聆听器（actor，design.md §3.1，tasks.md 任务 5）。
///
/// 每周期：启动 `AVAudioEngine` 采 30 秒，tap 的 buffer 直接喂给
/// `SNAudioStreamAnalyzer`（内置分类器 `.version1`），同时在 `WindowAccumulator`
/// 里算能量；窗口结束关掉引擎，特征 → `MoodClassifier` → `MoodDebouncer`，
/// 结果发到 `updates` 流，状态变化发到 `stateUpdates` 流。
///
/// 隐私红线：全程只在内存，不保存采样，不写文件，不发网络。
/// 全仓没有 `AVAudioFile`，不要加。
public actor AmbienceListener: ListeningEngine {

    public static let windowSeconds: TimeInterval = 30

    private let thresholds: MoodThresholds
    private var debouncer = MoodDebouncer()
    private var loopTask: Task<Void, Never>?
    private var isRunning = false

    private let updateContinuation: AsyncStream<ListeningUpdate>.Continuation
    private let stateContinuation: AsyncStream<ListeningState>.Continuation

    /// 流本身是不隔离的 `let`：协议要求同步读取，actor 用 nonisolated 满足；
    /// 写入只发生在 actor 隔离的方法里（经 continuation）。
    public nonisolated let updates: AsyncStream<ListeningUpdate>
    public nonisolated let stateUpdates: AsyncStream<ListeningState>

    public init(thresholds: MoodThresholds = .default) {
        self.thresholds = thresholds
        let (updateStream, updateContinuation) = AsyncStream.makeStream(of: ListeningUpdate.self)
        self.updates = updateStream
        self.updateContinuation = updateContinuation
        let (stateStream, stateContinuation) = AsyncStream.makeStream(of: ListeningState.self)
        self.stateUpdates = stateStream
        self.stateContinuation = stateContinuation
    }

    // MARK: - 权限

    public var permission: ListeningPermission {
        get async {
            if !AVAudioSession.sharedInstance().isInputAvailable {
                return .unavailable
            }
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return .granted
            case .denied: return .denied
            case .undetermined: return .unknown
            @unknown default: return .unknown
            }
        }
    }

    public func requestPermission() async -> Bool {
        guard AVAudioSession.sharedInstance().isInputAvailable else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    // MARK: - 启停

    public func start(intervalMinutes: Int) async {
        guard !isRunning else { return }
        guard await permission == .granted else { return }
        isRunning = true
        stateContinuation.yield(.listening)
        loopTask = Task {
            await runLoop(intervalMinutes: max(intervalMinutes, 1))
        }
    }

    public func stop() async {
        isRunning = false
        loopTask?.cancel()
        loopTask = nil
        stateContinuation.yield(.idle)
    }

    // MARK: - 采样循环

    private func runLoop(intervalMinutes: Int) async {
        let interval = TimeInterval(intervalMinutes * 60)
        while isRunning && !Task.isCancelled {
            let ok = await runOneWindow()
            if !ok {
                // 引擎起不来（例如模拟器）：停循环，等上层切手动模式。
                isRunning = false
                stateContinuation.yield(.unavailable)
                return
            }
            guard isRunning && !Task.isCancelled else { break }
            let gap = interval - Self.windowSeconds
            if gap > 0 {
                try? await Task.sleep(for: .seconds(gap))
            }
        }
        if isRunning {
            isRunning = false
            stateContinuation.yield(.idle)
        }
    }

    /// 采一个 30 秒窗口。返回 false 表示引擎无法启动（无输入或启动失败）。
    private func runOneWindow() async -> Bool {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { return false }

        let windowAccumulator = WindowAccumulator()
        let analyzer = SNAudioStreamAnalyzer(format: inputFormat)
        let stateContinuation = self.stateContinuation
        let observer = ClassificationObserver(
            onResult: { [windowAccumulator] result in
                guard let top = result.classifications.first else { return }
                windowAccumulator.ingestClassification(
                    identifier: top.identifier,
                    confidence: top.confidence,
                    durationSeconds: result.timeRange.duration.seconds
                )
            },
            onError: { _ in
                stateContinuation.yield(.error("SoundAnalysis 分析失败"))
            }
        )

        do {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            try analyzer.add(request, withObserver: observer)
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [windowAccumulator, analyzer] buffer, time in
                windowAccumulator.ingestAudioBuffer(buffer)
                // tap 回调里调 analyze 是文档明确允许的。
                analyzer.analyze(buffer, atAudioFramePosition: time.sampleTime)
            }
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement)
            try AVAudioSession.sharedInstance().setActive(true)
            engine.prepare()
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            return false
        }

        // 采满 30 秒（可取消：停止聆听时直接结束本窗口）。
        try? await Task.sleep(for: .seconds(Self.windowSeconds))
        inputNode.removeTap(onBus: 0)
        engine.stop()
        analyzer.completeAnalysis()
        try? AVAudioSession.sharedInstance().setActive(false)

        let features = windowAccumulator.finishWindow(
            windowSeconds: Self.windowSeconds,
            thresholds: thresholds
        )
        let (mood, confidence) = MoodClassifier.classify(features, at: Date(), thresholds: thresholds)
        let stableMood = debouncer.observe(mood)
        updateContinuation.yield(ListeningUpdate(
            features: features,
            mood: mood,
            confidence: confidence,
            stableMood: stableMood,
            windowEndsAt: Date()
        ))
        return true
    }
}

/// SoundAnalysis 结果观测者：把每次分类结果转给窗口累积器。
/// 只碰累积器（自带锁）和 state continuation，不碰 actor 状态，
/// 所以可以在 SoundAnalysis 的内部队列回调。
private final class ClassificationObserver: NSObject, SNResultsObserving {
    private let onResult: (SNClassificationResult) -> Void
    private let onError: ((Error) -> Void)?

    init(onResult: @escaping (SNClassificationResult) -> Void, onError: ((Error) -> Void)? = nil) {
        self.onResult = onResult
        self.onError = onError
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let classification = result as? SNClassificationResult else { return }
        onResult(classification)
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        onError?(error)
    }

    func requestDidComplete(_ request: SNRequest) {}
}
