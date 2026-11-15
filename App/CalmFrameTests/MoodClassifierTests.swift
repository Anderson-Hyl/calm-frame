import XCTest
@testable import CalmFrame

/// C3 分类器测试（验收标准 C3，design.md §3.1）。
/// 覆盖：任意输入恰好一个 Mood + 置信度 ∈ [0,1]、音量单调性、匹配顺序、
/// 阈值边界（严格大于/小于）、drowsy 只在 13:00–16:00、置信度随裕度增长。
final class MoodClassifierTests: XCTestCase {

    // MARK: - 任意输入恰好一个 Mood

    func testAnyInputYieldsOneMoodAndValidConfidence() {
        // 边界穷举：阈值上下、极值、quietDrop × 时间。
        let typings: [Double] = [0, 0.05, 0.1, 0.2, 0.4, 0.41, 0.6, 1.0]
        let speeches: [Double] = [0, 0.05, 0.1, 0.2, 0.21, 0.5, 0.51, 1.0]
        let dbs: [Double] = [-100, -80, -60, -46, -45, -44, -26, -25, -24, -10, 0]
        for typing in typings {
            for speech in speeches {
                for db in dbs {
                    for quietDrop in [false, true] {
                        for hour in [10, 14] {
                            let f = AmbienceFeatures(
                                typingDensity: typing, speechRatio: speech,
                                meanDBFS: db, quietDrop: quietDrop
                            )
                            let r1 = MoodClassifier.classify(f, at: dateAt(hour: hour))
                            let r2 = MoodClassifier.classify(f, at: dateAt(hour: hour))
                            XCTAssertEqual(r1.mood, r2.mood, "同一输入应确定性地返回同一 mood：\(f)")
                            XCTAssertEqual(r1.confidence, r2.confidence, accuracy: 0)
                            XCTAssertTrue((0...1).contains(r1.confidence), "置信度必须在 0…1：\(r1)")
                        }
                    }
                }
            }
        }
    }

    func testRandomInputsNeverCrashAndStayInRange() {
        // 固定种子随机属性测试：可复现。越界值也测（分类器内部钳制）。
        var rng = SeededRNG(seed: 0xCA1F_F1A9)
        for _ in 0..<2000 {
            let f = AmbienceFeatures(
                typingDensity: rng.next(in: -0.5...1.5),
                speechRatio: rng.next(in: -0.5...1.5),
                meanDBFS: rng.next(in: -120...20),
                quietDrop: rng.nextBool()
            )
            let result = MoodClassifier.classify(f, at: dateAt(hour: rng.nextInt(in: 0...23)))
            XCTAssertTrue((0...1).contains(result.confidence), "置信度必须在 0…1：\(f) -> \(result)")
        }
    }

    // MARK: - 音量单调性

    func testVolumeMonotonicity() {
        // 固定其他特征，只调大音量：一旦变 noisy 就不再翻回 calm。
        var seenNoisy = false
        var seenTenseQuietAfterNoisy = false
        var db = -90.0
        while db <= 0 {
            let f = AmbienceFeatures(typingDensity: 0.05, speechRatio: 0.05, meanDBFS: db, quietDrop: false)
            let mood = MoodClassifier.classify(f, at: dateAt(hour: 10)).mood
            if mood == .noisy { seenNoisy = true }
            if seenNoisy && mood != .noisy {
                XCTFail("音量只增不减，变 noisy 后不应再翻回 \(mood)（db=\(db)）")
            }
            if seenNoisy && mood == .tenseQuiet { seenTenseQuietAfterNoisy = true }
            db += 1
        }
        XCTAssertTrue(seenNoisy, "音量扫到 0 dBFS 应当出现 noisy")
        XCTAssertFalse(seenTenseQuietAfterNoisy)
    }

    func testTenseQuietDisappearsWhenVolumeRises() {
        // quietDrop 且音量低于 -45 时是 tenseQuiet；音量升过 -45 就不再是。
        let low = AmbienceFeatures(typingDensity: 0.05, speechRatio: 0.05, meanDBFS: -60, quietDrop: true)
        XCTAssertEqual(MoodClassifier.classify(low, at: dateAt(hour: 10)).mood, .tenseQuiet)
        let high = AmbienceFeatures(typingDensity: 0.05, speechRatio: 0.05, meanDBFS: -30, quietDrop: true)
        XCTAssertNotEqual(MoodClassifier.classify(high, at: dateAt(hour: 10)).mood, .tenseQuiet)
    }

    // MARK: - 匹配顺序

    func testMatchOrder() {
        // 同时满足 noisy 与 hectic → noisy。
        let noisyAndHectic = AmbienceFeatures(typingDensity: 0.8, speechRatio: 0.9, meanDBFS: -10, quietDrop: false)
        XCTAssertEqual(MoodClassifier.classify(noisyAndHectic, at: dateAt(hour: 10)).mood, .noisy)
        // 同时满足 hectic 与 tenseQuiet → hectic。
        let hecticAndTense = AmbienceFeatures(typingDensity: 0.8, speechRatio: 0.3, meanDBFS: -60, quietDrop: true)
        XCTAssertEqual(MoodClassifier.classify(hecticAndTense, at: dateAt(hour: 10)).mood, .hectic)
        // 同时满足 noisy 与 tenseQuiet → noisy。
        let noisyAndTense = AmbienceFeatures(typingDensity: 0.05, speechRatio: 0.9, meanDBFS: -60, quietDrop: true)
        XCTAssertEqual(MoodClassifier.classify(noisyAndTense, at: dateAt(hour: 10)).mood, .noisy)
    }

    // MARK: - 阈值边界（严格大于 / 小于）

    func testThresholdBoundariesAreExclusive() {
        let base = AmbienceFeatures(typingDensity: 0.05, speechRatio: 0.05, meanDBFS: -60, quietDrop: false)
        // meanDBFS 恰为 -25 不是 noisy；speechRatio 恰为 0.5 不是 noisy。
        XCTAssertNotEqual(
            MoodClassifier.classify(AmbienceFeatures(typingDensity: 0.05, speechRatio: 0.05, meanDBFS: -25, quietDrop: false), at: dateAt(hour: 10)).mood,
            .noisy
        )
        XCTAssertNotEqual(
            MoodClassifier.classify(AmbienceFeatures(typingDensity: 0.05, speechRatio: 0.5, meanDBFS: -60, quietDrop: false), at: dateAt(hour: 10)).mood,
            .noisy
        )
        // typingDensity 恰为 0.4 不是 hectic（speech 已满足）。
        XCTAssertNotEqual(
            MoodClassifier.classify(AmbienceFeatures(typingDensity: 0.4, speechRatio: 0.3, meanDBFS: -60, quietDrop: false), at: dateAt(hour: 10)).mood,
            .hectic
        )
        // meanDBFS 恰为 -45 不是 tenseQuiet。
        XCTAssertNotEqual(
            MoodClassifier.classify(AmbienceFeatures(typingDensity: 0.05, speechRatio: 0.05, meanDBFS: -45, quietDrop: true), at: dateAt(hour: 10)).mood,
            .tenseQuiet
        )
        // typingDensity 恰为 0.1 不是 drowsy。
        XCTAssertNotEqual(
            MoodClassifier.classify(AmbienceFeatures(typingDensity: 0.1, speechRatio: 0.05, meanDBFS: -60, quietDrop: false), at: dateAt(hour: 14)).mood,
            .drowsy
        )
        _ = base
    }

    // MARK: - drowsy 只在 13:00–16:00

    func testDrowsyOnlyInAfternoon() {
        let sleepy = AmbienceFeatures(typingDensity: 0.05, speechRatio: 0.05, meanDBFS: -60, quietDrop: false)
        XCTAssertEqual(MoodClassifier.classify(sleepy, at: dateAt(hour: 13)).mood, .drowsy)
        XCTAssertEqual(MoodClassifier.classify(sleepy, at: dateAt(hour: 15, minute: 59)).mood, .drowsy)
        XCTAssertEqual(MoodClassifier.classify(sleepy, at: dateAt(hour: 10)).mood, .calm)
        XCTAssertEqual(MoodClassifier.classify(sleepy, at: dateAt(hour: 12, minute: 59)).mood, .calm)
        XCTAssertEqual(MoodClassifier.classify(sleepy, at: dateAt(hour: 16)).mood, .calm)
        XCTAssertEqual(MoodClassifier.classify(sleepy, at: dateAt(hour: 22)).mood, .calm)
    }

    // MARK: - 置信度随裕度增长

    func testConfidenceGrowsWithMargin() {
        // noisy：离阈值越远置信度越高。
        func noisyConfidence(db: Double) -> Double {
            MoodClassifier.classify(
                AmbienceFeatures(typingDensity: 0.05, speechRatio: 0.05, meanDBFS: db, quietDrop: false),
                at: dateAt(hour: 10)
            ).confidence
        }
        XCTAssertLessThan(noisyConfidence(db: -24), noisyConfidence(db: -15))
        XCTAssertLessThan(noisyConfidence(db: -15), noisyConfidence(db: -5))
        // calm：离边界越远置信度越高。
        func calmConfidence(typing: Double, speech: Double) -> Double {
            MoodClassifier.classify(
                AmbienceFeatures(typingDensity: typing, speechRatio: speech, meanDBFS: -60, quietDrop: false),
                at: dateAt(hour: 10)
            ).confidence
        }
        XCTAssertLessThan(calmConfidence(typing: 0.09, speech: 0.09), calmConfidence(typing: 0.05, speech: 0.05))
        XCTAssertLessThan(calmConfidence(typing: 0.05, speech: 0.05), calmConfidence(typing: 0.0, speech: 0.0))
    }

    // MARK: - 工具

    /// 当天指定时刻（本地时区）。drowsy 的时间窗按本地小时判断。
    private func dateAt(hour: Int, minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 11
        components.day = 15
        components.hour = hour
        components.minute = minute
        components.timeZone = TimeZone.current
        return Calendar.current.date(from: components)!
    }
}

/// 固定种子伪随机数（SplitMix64），保证随机属性测试可复现。
private struct SeededRNG {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    private mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        let u = Double(nextUInt64()) / Double(UInt64.max)
        return range.lowerBound + u * (range.upperBound - range.lowerBound)
    }

    mutating func nextInt(in range: ClosedRange<Int>) -> Int {
        let span = range.upperBound - range.lowerBound + 1
        return range.lowerBound + Int(nextUInt64() % UInt64(span))
    }

    mutating func nextBool() -> Bool { nextUInt64() & 1 == 0 }
}
