import CalmFrameKit
import XCTest

@testable import CalmFrame

/// 最小版 APIClient：无 token 不发请求；请求组装正确（方法、路径、鉴权、body、locale）。
final class APIClientTests: XCTestCase {

    private let baseURL = URL(string: "https://example.invalid")!

    func testNoTokenMakesNoRequest() async {
        let client = APIClient(baseURL: baseURL, token: nil)
        let result = await client.fetchPainting(for: .noisy)
        XCTAssertNil(result)
    }

    func testRequestBuilder() throws {
        let client = APIClient(baseURL: baseURL, token: "tok-123")
        let request = try XCTUnwrap(client.makeRequest(for: .hectic, token: "tok-123"))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v1/paintings")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-123")
        let body = try XCTUnwrap(request.httpBody)
        let decoded = try JSONDecoder().decode(PaintingRequest.self, from: body)
        XCTAssertEqual(decoded.mood, .hectic)
        XCTAssertEqual(decoded.style, .oilPainting1800s)
        XCTAssertEqual(decoded.locale, APIClient.deviceLocaleBCP47)
    }

    func testDeviceLocaleIsBCP47AndNonEmpty() {
        let locale = APIClient.deviceLocaleBCP47
        XCTAssertFalse(locale.isEmpty)
        XCTAssertEqual(locale, Locale.current.identifier(.bcp47))
    }
}
