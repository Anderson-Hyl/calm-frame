import CalmFrameKit
import XCTest

@testable import CalmFrame

/// C5：内置画目录——每 mood 恰好 1 张，元数据完整，图确实在 bundle 里。
final class BundledPaintingsTests: XCTestCase {

    func testAllMoodsCoveredExactlyOnce() {
        XCTAssertEqual(BundledPaintings.all.count, Mood.allCases.count)
        XCTAssertEqual(Set(BundledPaintings.all.map(\.mood)), Set(Mood.allCases))
    }

    func testPaintingForEveryMood() {
        for mood in Mood.allCases {
            XCTAssertEqual(BundledPaintings.painting(for: mood).mood, mood)
        }
    }

    func testMetadataNonEmptyAndImageNamesUnique() {
        let names = BundledPaintings.all.map(\.imageName)
        XCTAssertEqual(Set(names).count, names.count)
        for painting in BundledPaintings.all {
            XCTAssertFalse(painting.title.isEmpty, "\(painting.mood)")
            XCTAssertFalse(painting.artist.isEmpty, "\(painting.mood)")
            XCTAssertFalse(painting.caption.isEmpty, "\(painting.mood)")
        }
    }

    /// 图必须真在 app bundle 里（不是只有目录条目）：这一步抓资源漏打。
    func testImagesLoadFromBundle() {
        for painting in BundledPaintings.all {
            XCTAssertNotNil(
                BundledPaintings.image(for: painting),
                "内置画 \(painting.mood)（\(painting.imageName).jpg）没打进 bundle"
            )
        }
    }
}
