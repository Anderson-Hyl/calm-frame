import XCTest
@testable import CalmFrame

/// C1 占位测试：只验证测试 target 能编译、能跑，且能 @testable import App 模块
///（C3 的分类器测试依赖这一点）。真正的属性测试在 C3 落地。
final class PlaceholderTests: XCTestCase {
    func testPlaceholder() {
        XCTAssertTrue(true)
    }
}
