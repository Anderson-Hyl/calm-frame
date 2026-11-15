import AVFAudio
import XCTest
@testable import CalmFrame

/// C2 窗口累积器测试：dBFS 换算、特征合成、quietDrop（相对上一窗口）。
/// 用合成 buffer（直流 / 正弦）喂，不依赖麦克风。
final class WindowAccumulatorTests: XCTestCase {

    private func makeBuffer(samples: [Float], sampleRate: Double = 44_100) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = buffer.floatChannelData![0]
        for (i, sample) in samples.enumerated() {
            channel[i] = sample
        }
        return buffer
    }

    // MARK: - dBFS 换算

    func testSilenceIsMinus100() {
        XCTAssertEqual(WindowAccumulator.dbfs(sumOfSquares: 0, sampleCount: 44100), -100, accuracy: 0.001)
        XCTAssertEqual(WindowAccumulator.dbfs(sumOfSquares: 0, sampleCount: 0), -100, accuracy: 0.001)
    }

    func testFullScaleSineIsMinus3dBFS() {
        // 满幅正弦 RMS = 1/√2 → -3.01 dBFS。
        let samples = (0..<4410).map { i in Float(sin(2 * Double.pi * Double(i) / 100)) }
        let buffer = makeBuffer(samples: samples)
        let acc = WindowAccumulator()
        acc.ingestAudioBuffer(buffer)
        let features = acc.finishWindow(windowSeconds: 30, thresholds: .default)
        XCTAssertEqual(features.meanDBFS, -3.01, accuracy: 0.05)
    }

    func testConstantLevelMatchesFormula() {
        // 直流 0.1 → RMS 0.1 → -20 dBFS。
        let buffer = makeBuffer(samples: [Float](repeating: 0.1, count: 4410))
        let acc = WindowAccumulator()
        acc.ingestAudioBuffer(buffer)
        let features = acc.finishWindow(windowSeconds: 30, thresholds: .default)
        XCTAssertEqual(features.meanDBFS, -20, accuracy: 0.01)
    }

    // MARK: - 特征合成

    func testFinishWindowCombinesAudioAndLabels() {
        let acc = WindowAccumulator()
        acc.ingestAudioBuffer(makeBuffer(samples: [Float](repeating: 0.1, count: 4410)))
        acc.ingestClassification(identifier: "typing", confidence: 0.9, durationSeconds: 15)
        acc.ingestClassification(identifier: "speech", confidence: 0.9, durationSeconds: 6)
        let features = acc.finishWindow(windowSeconds: 30, thresholds: .default)
        XCTAssertEqual(features.typingDensity, 0.5, accuracy: 0.001)
        XCTAssertEqual(features.speechRatio, 0.2, accuracy: 0.001)
        XCTAssertEqual(features.meanDBFS, -20, accuracy: 0.01)
        XCTAssertFalse(features.quietDrop, "首个窗口没有上一窗口，quietDrop 为 false")
    }

    // MARK: - quietDrop（相对上一窗口）

    func testQuietDropOnLargeFall() {
        let acc = WindowAccumulator()
        acc.ingestAudioBuffer(makeBuffer(samples: [Float](repeating: 0.1, count: 4410)))
        let first = acc.finishWindow(windowSeconds: 30, thresholds: .default)
        XCTAssertFalse(first.quietDrop)
        // -20 dBFS → -50 dBFS，跌 30 dB > 12 dB 阈值。
        acc.ingestAudioBuffer(makeBuffer(samples: [Float](repeating: 0.00316, count: 4410)))
        let second = acc.finishWindow(windowSeconds: 30, thresholds: .default)
        XCTAssertEqual(second.meanDBFS, -50, accuracy: 0.5)
        XCTAssertTrue(second.quietDrop)
    }

    func testNoQuietDropOnSmallFallOrRise() {
        let acc = WindowAccumulator()
        acc.ingestAudioBuffer(makeBuffer(samples: [Float](repeating: 0.1, count: 4410)))
        _ = acc.finishWindow(windowSeconds: 30, thresholds: .default)
        // -20 → -25 dBFS，跌 5 dB < 12 dB 阈值。
        acc.ingestAudioBuffer(makeBuffer(samples: [Float](repeating: 0.0562, count: 4410)))
        let second = acc.finishWindow(windowSeconds: 30, thresholds: .default)
        XCTAssertFalse(second.quietDrop)
        // 再升回去也不算。
        acc.ingestAudioBuffer(makeBuffer(samples: [Float](repeating: 0.1, count: 4410)))
        let third = acc.finishWindow(windowSeconds: 30, thresholds: .default)
        XCTAssertFalse(third.quietDrop)
    }

    func testResetClearsPreviousWindow() {
        let acc = WindowAccumulator()
        acc.ingestAudioBuffer(makeBuffer(samples: [Float](repeating: 0.1, count: 4410)))
        _ = acc.finishWindow(windowSeconds: 30, thresholds: .default)
        acc.reset()
        acc.ingestAudioBuffer(makeBuffer(samples: [Float](repeating: 0.00316, count: 4410)))
        let features = acc.finishWindow(windowSeconds: 30, thresholds: .default)
        XCTAssertFalse(features.quietDrop, "reset 后没有上一窗口")
    }
}
