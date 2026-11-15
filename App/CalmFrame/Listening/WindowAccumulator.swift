import AVFAudio
import Foundation

/// 一个聆听窗口的累积器：收 tap 的音频能量 + 分类观测，窗口结束时算出 `AmbienceFeatures`。
///
/// 线程安全：tap 回调（实时音频线程）与分类观测回调（SoundAnalysis 内部队列）
/// 都会调它，内部用 NSLock 保护，临界区只有几次加法。
/// 音频本身只在内存里过：这里只累积能量平方和与分类时长，不保存任何采样，
/// 更不写文件（全仓无 `AVAudioFile`）。
public final class WindowAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var sumOfSquares: Double = 0
    private var sampleCount: Int = 0
    private var labels = SoundLabelAccumulator()
    private var previousWindowMeanDBFS: Double?

    public init() {}

    /// 从一个 tap buffer 累积能量。只取第 0 声道。
    public func ingestAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        var sum: Double = 0
        for i in 0..<count {
            let sample = Double(channel[i])
            sum += sample * sample
        }
        lock.lock()
        defer { lock.unlock() }
        sumOfSquares += sum
        sampleCount += count
    }

    /// 从一次分类观测累积时长。
    public func ingestClassification(identifier: String, confidence: Double, durationSeconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        labels.ingest(identifier: identifier, confidence: confidence, durationSeconds: durationSeconds)
    }

    /// 窗口结束：算出特征并重置累积器（保留本窗口均值供下一窗口算 quietDrop）。
    /// `windowSeconds` 是窗口名义长度（30 秒）。
    public func finishWindow(windowSeconds: Double, thresholds: MoodThresholds) -> AmbienceFeatures {
        lock.lock()
        defer { lock.unlock() }
        let meanDBFS = WindowAccumulator.dbfs(sumOfSquares: sumOfSquares, sampleCount: sampleCount)
        let (typingDensity, speechRatio) = labels.densities(windowSeconds: windowSeconds)
        // quietDrop：相对上一窗口的安静突变（需求 1.2）。首个窗口无上一窗口，为 false。
        let quietDrop: Bool
        if let previous = previousWindowMeanDBFS {
            quietDrop = (previous - meanDBFS) > thresholds.quietDropDB
        } else {
            quietDrop = false
        }
        previousWindowMeanDBFS = meanDBFS
        sumOfSquares = 0
        sampleCount = 0
        labels = SoundLabelAccumulator()
        return AmbienceFeatures(
            typingDensity: typingDensity,
            speechRatio: speechRatio,
            meanDBFS: meanDBFS,
            quietDrop: quietDrop
        )
    }

    /// 全部清零（含上一窗口均值）。停止聆听后重新开始时调用。
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        sumOfSquares = 0
        sampleCount = 0
        labels = SoundLabelAccumulator()
        previousWindowMeanDBFS = nil
    }

    /// 能量平方和 → dBFS。无采样（静默）时为 -100（钳制下限，不用 -inf）。
    public static func dbfs(sumOfSquares: Double, sampleCount: Int) -> Double {
        guard sampleCount > 0, sumOfSquares > 0 else { return -100 }
        let meanSquare = sumOfSquares / Double(sampleCount)
        let rms = meanSquare.squareRoot()
        return max(20 * log10(rms), -100)
    }
}
