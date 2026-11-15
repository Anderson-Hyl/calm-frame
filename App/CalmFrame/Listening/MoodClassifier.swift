import CalmFrameKit
import Foundation

/// 氛围 → Mood 的纯函数分类器（C3，design.md §3.1）。
///
/// 纯函数：无状态、无 IO、不读时钟（时间由调用方以 `date` 注入，否则 drowsy 的
/// 时间条件无法测试）。任意输入（包括越界值）都恰好返回一个 Mood，不会崩、不会返回 nil。
///
/// 匹配顺序固定，顺序错了结果就错：
/// noisy → hectic → tenseQuiet → drowsy → 其余 calm。
///
/// 置信度 = 归一化的“离决策边界有多远”，落在 0…1：
/// - 触发某条规则时，是触发维度的超阈裕度（越远离阈值越接近 1）；
/// - 判为 calm 时，是离最近一条规则触发边界的距离（越远离越接近 1）。
/// 具体归一化尺度见各分支注释。
public enum MoodClassifier {

    public static func classify(
        _ features: AmbienceFeatures,
        at date: Date,
        thresholds: MoodThresholds = .default
    ) -> (mood: Mood, confidence: Double) {
        // 越界输入先钳制：分类器对任意输入都有定义。
        let typing = features.typingDensity.clamped(to: 0...1)
        let speech = features.speechRatio.clamped(to: 0...1)
        let db = features.meanDBFS.clamped(to: -100...0)
        let quietDrop = features.quietDrop
        let hour = Calendar.current.component(.hour, from: date)
        let inDrowsyHours = hour >= thresholds.drowsyStartHour && hour < thresholds.drowsyEndHour

        // 1. noisy：响度高于 -25，或人声占比高于 0.5（OR 规则）。
        if db > thresholds.noisyDBFS || speech > thresholds.noisySpeechRatio {
            var margins: [Double] = []
            if db > thresholds.noisyDBFS {
                // 0 dBFS 时为 1；阈值处为 0。
                margins.append((db - thresholds.noisyDBFS) / -thresholds.noisyDBFS)
            }
            if speech > thresholds.noisySpeechRatio {
                margins.append((speech - thresholds.noisySpeechRatio) / (1 - thresholds.noisySpeechRatio))
            }
            return (.noisy, clamp01(margins.max() ?? 0))
        }

        // 2. hectic：打字密且有人声（AND 规则），裕度取较弱的一维。
        if typing > thresholds.hecticTypingDensity && speech > thresholds.hecticSpeechRatio {
            let m1 = (typing - thresholds.hecticTypingDensity) / (1 - thresholds.hecticTypingDensity)
            let m2 = (speech - thresholds.hecticSpeechRatio) / (1 - thresholds.hecticSpeechRatio)
            return (.hectic, clamp01(min(m1, m2)))
        }

        // 3. tenseQuiet：突然安静且响度低于 -45。-60 dBFS 时裕度为 1。
        if quietDrop && db < thresholds.tenseQuietDBFS {
            return (.tenseQuiet, clamp01((thresholds.tenseQuietDBFS - db) / 15))
        }

        // 4. drowsy：午后 13:00–16:00，且又不打字又没人声（AND 规则 + 时间窗）。
        if inDrowsyHours
            && typing < thresholds.drowsyTypingDensity
            && speech < thresholds.drowsySpeechRatio
        {
            let m1 = (thresholds.drowsyTypingDensity - typing) / thresholds.drowsyTypingDensity
            let m2 = (thresholds.drowsySpeechRatio - speech) / thresholds.drowsySpeechRatio
            return (.drowsy, clamp01(min(m1, m2)))
        }

        // 5. 其余 calm。置信度 = 离最近一条规则触发边界的距离。
        let toNoisy = min(
            (thresholds.noisyDBFS - db) / -thresholds.noisyDBFS,
            (thresholds.noisySpeechRatio - speech) / thresholds.noisySpeechRatio
        )
        // AND 规则离触发的距离由较远的一维决定（两维都要越过才触发）。
        let toHectic = max(
            (thresholds.hecticTypingDensity - typing) / thresholds.hecticTypingDensity,
            (thresholds.hecticSpeechRatio - speech) / thresholds.hecticSpeechRatio
        )
        let toTenseQuiet: Double = quietDrop
            ? (db - thresholds.tenseQuietDBFS) / 15
            : 1
        let toDrowsy: Double
        if inDrowsyHours {
            toDrowsy = max(
                (typing - thresholds.drowsyTypingDensity) / thresholds.drowsyTypingDensity,
                (speech - thresholds.drowsySpeechRatio) / thresholds.drowsySpeechRatio
            )
        } else {
            toDrowsy = 1
        }
        let calmConfidence = min(toNoisy, toHectic, toTenseQuiet, toDrowsy)
        return (.calm, clamp01(calmConfidence))
    }

    private static func clamp01(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
