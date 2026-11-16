import CalmFrameKit
import XCTest

@testable import CalmFrame

/// C4：FrameViewModel——mood 换画、3 秒 crossfade 状态、铭牌文案、caption 开关。
@MainActor
final class FrameViewModelTests: XCTestCase {

    func testInitialPaintingIsCalm() {
        let viewModel = FrameViewModel()
        XCTAssertEqual(viewModel.currentMood, .calm)
        XCTAssertEqual(viewModel.currentPainting.mood, .calm)
        XCTAssertEqual(viewModel.currentPainting.title, "干草车")
        XCTAssertNil(viewModel.previousPainting)
        XCTAssertEqual(viewModel.nameplateText, "房间：平静 · 正在展示：干草车")
        XCTAssertEqual(viewModel.captionText, "田野安静下来，时间也慢了下来。")
    }

    func testMoodChangeKeepsPreviousForCrossfade() {
        let viewModel = FrameViewModel(transitionDuration: 0.05)
        viewModel.setMood(.noisy)
        XCTAssertEqual(viewModel.currentMood, .noisy)
        XCTAssertEqual(viewModel.currentPainting.mood, .noisy)
        XCTAssertEqual(viewModel.previousPainting?.mood, .calm)
        XCTAssertEqual(viewModel.transitionOpacity, 1)
        XCTAssertEqual(viewModel.nameplateText, "房间：嘈杂 · 正在展示：暴风雪：汉尼拔越过阿尔卑斯山")
    }

    func testPreviousClearedAfterTransition() async {
        let viewModel = FrameViewModel(transitionDuration: 0.05)
        viewModel.setMood(.hectic)
        XCTAssertNotNil(viewModel.previousPainting)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(viewModel.previousPainting)
    }

    func testSameMoodOrNilDoesNothing() {
        let viewModel = FrameViewModel(transitionDuration: 0.05)
        viewModel.setMood(.calm)
        XCTAssertNil(viewModel.previousPainting)
        viewModel.setMood(nil)
        XCTAssertNil(viewModel.previousPainting)
        XCTAssertEqual(viewModel.currentMood, .calm)
    }

    func testCaptionToggle() {
        let viewModel = FrameViewModel()
        XCTAssertNotNil(viewModel.captionText)
        viewModel.captionEnabled = false
        XCTAssertNil(viewModel.captionText)
        viewModel.captionEnabled = true
        XCTAssertNotNil(viewModel.captionText)
    }

    func testCrossfadeDurationIsThreeSeconds() {
        XCTAssertEqual(FrameViewModel.crossfadeDuration, 3.0)
    }
}
