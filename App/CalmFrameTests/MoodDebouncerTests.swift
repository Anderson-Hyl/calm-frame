import XCTest
@testable import CalmFrame

/// C3 防抖状态机测试（验收标准 C3，design.md §3.1）：
/// 同一 mood 连续 2 个窗口才放行，单个窗口翻转不算数，中途变 mood 计数清零。
final class MoodDebouncerTests: XCTestCase {

    func testRequiresTwoConsecutiveWindows() {
        var debouncer = MoodDebouncer()
        XCTAssertNil(debouncer.observe(.calm), "第 1 个窗口不应放行")
        XCTAssertEqual(debouncer.observe(.calm), .calm, "连续第 2 个窗口应放行")
        XCTAssertEqual(debouncer.stableMood, .calm)
    }

    func testSingleWindowFlipDoesNotTrigger() {
        var debouncer = MoodDebouncer()
        XCTAssertNil(debouncer.observe(.calm))
        XCTAssertNil(debouncer.observe(.noisy), "中途变 mood 应清零，不放行")
        XCTAssertEqual(debouncer.observe(.noisy), .noisy)
    }

    func testNoDuplicateTriggerWhileStable() {
        var debouncer = MoodDebouncer()
        XCTAssertNil(debouncer.observe(.calm))
        XCTAssertEqual(debouncer.observe(.calm), .calm)
        XCTAssertNil(debouncer.observe(.calm), "已放行的 mood 不应重复放行")
        XCTAssertNil(debouncer.observe(.calm))
        XCTAssertEqual(debouncer.stableMood, .calm)
    }

    func testStableMoodSwitchesAfterTwoWindows() {
        var debouncer = MoodDebouncer()
        XCTAssertNil(debouncer.observe(.calm))
        XCTAssertEqual(debouncer.observe(.calm), .calm)
        XCTAssertNil(debouncer.observe(.drowsy))
        XCTAssertEqual(debouncer.observe(.drowsy), .drowsy)
        XCTAssertEqual(debouncer.stableMood, .drowsy)
    }

    func testReset() {
        var debouncer = MoodDebouncer()
        XCTAssertNil(debouncer.observe(.calm))
        XCTAssertEqual(debouncer.observe(.calm), .calm)
        debouncer.reset()
        XCTAssertNil(debouncer.stableMood)
        XCTAssertNil(debouncer.observe(.calm), "reset 后应重新数 2 个窗口")
        XCTAssertEqual(debouncer.observe(.calm), .calm)
    }
}
