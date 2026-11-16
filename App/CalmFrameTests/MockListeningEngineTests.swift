import CalmFrameKit
import XCTest

@testable import CalmFrame

/// mock 聆听引擎：循环顺序、单 mood 定住、权限恒为 granted；以及启动参数解析。
@MainActor
final class MockListeningEngineTests: XCTestCase {

    func testPermissionAlwaysGranted() async {
        let engine = MockListeningEngine(moods: [.calm])
        let permission = await engine.permission
        XCTAssertEqual(permission, .granted)
        let granted = await engine.requestPermission()
        XCTAssertTrue(granted)
    }

    func testCyclesMoodsInOrder() async {
        let engine = MockListeningEngine(moods: [.calm, .noisy], cycleSeconds: 0.15)
        let box = LockedBox<[Mood]>([])
        let collect = Task {
            for await update in engine.updates {
                box.withLock { $0.append(update.mood) }
            }
        }
        await engine.start(intervalMinutes: 5)
        try? await Task.sleep(for: .milliseconds(500))
        await engine.stop()
        collect.cancel()
        let received = box.withLock { $0 }
        XCTAssertGreaterThanOrEqual(received.count, 3)
        XCTAssertEqual(Array(received.prefix(3)), [.calm, .noisy, .calm])
    }

    func testSingleMoodYieldsOnceAndHolds() async {
        let engine = MockListeningEngine(moods: [.drowsy], cycleSeconds: 3600)
        let box = LockedBox<[Mood]>([])
        let collect = Task {
            for await update in engine.updates {
                box.withLock { $0.append(update.mood) }
            }
        }
        await engine.start(intervalMinutes: 5)
        try? await Task.sleep(for: .milliseconds(300))
        await engine.stop()
        collect.cancel()
        XCTAssertEqual(box.withLock { $0 }, [.drowsy])
    }

    func testMockFeaturesArePlausiblePerMood() {
        XCTAssertEqual(MockListeningEngine.features(for: .noisy).speechRatio, 0.7, accuracy: 0.001)
        XCTAssertTrue(MockListeningEngine.features(for: .tenseQuiet).quietDrop)
        XCTAssertLessThan(MockListeningEngine.features(for: .calm).meanDBFS, -40)
    }

    // MARK: - 启动参数解析

    func testNoMockArgumentsReturnsNil() {
        XCTAssertNil(MockListeningConfiguration.fromArguments(["CalmFrame"]))
    }

    func testSingleMockMood() {
        let config = MockListeningConfiguration.fromArguments(["CalmFrame", "--mock-mood", "noisy"])
        XCTAssertEqual(config?.moods, [.noisy])
    }

    func testCycleUsesFixedOrder() {
        let config = MockListeningConfiguration.fromArguments(["CalmFrame", "--mock-cycle", "8"])
        XCTAssertEqual(config?.moods, [.calm, .hectic, .noisy, .tenseQuiet, .drowsy])
        XCTAssertEqual(config?.cycleSeconds, 8)
    }

    func testCycleStartsFromGivenMood() {
        let config = MockListeningConfiguration.fromArguments(
            ["CalmFrame", "--mock-mood", "noisy", "--mock-cycle", "5"]
        )
        XCTAssertEqual(config?.moods, [.noisy, .tenseQuiet, .drowsy, .calm, .hectic])
        XCTAssertEqual(config?.cycleSeconds, 5)
    }

    func testInvalidMoodIsIgnored() {
        XCTAssertNil(MockListeningConfiguration.fromArguments(["CalmFrame", "--mock-mood", "bogus"]))
    }
}

/// 供测试任务收集流结果的锁保护盒子（避免跨任务读写数组的数据竞争）。
private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
