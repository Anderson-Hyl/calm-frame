import CalmFrameKit
import XCTest

@testable import CalmFrame

/// APIClient 的 auth 部分：请求组装（方法、路径、鉴权头、body）与无 token 行为。
/// 真网络调用不在这里测，A5 用真服务端联调。
final class APIClientAuthTests: XCTestCase {

    private let baseURL = URL(string: "https://example.invalid")!

    func testSignInRequestBuilder() throws {
        let client = APIClient(baseURL: baseURL)
        let request = try XCTUnwrap(client.makeSignInRequest(identityToken: "id-token-xyz"))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v1/auth/apple")
        // 换 token 这一步不带 Bearer——这时候还没有任何凭证。
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(request.httpBody)
        let decoded = try JSONDecoder().decode(AuthRequest.self, from: body)
        XCTAssertEqual(decoded.identityToken, "id-token-xyz")
    }

    func testCreditsRequestBuilder() throws {
        let client = APIClient(baseURL: baseURL)
        let request = try XCTUnwrap(client.makeCreditsRequest(token: "tok-123"))
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/v1/credits")
        // 只断言带了 Authorization 头，不比值：Foundation 读回这只头时会遮蔽，
        // 读回值在不同构建里并不稳定（旧测试 testRequestBuilder 已覆盖
        // "Bearer <redacted>" 的读回形态）；真 token 能不能用由 A5 真机联调验。
        XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testFetchCreditsWithoutTokenThrowsUnauthorized() async {
        let client = APIClient(baseURL: baseURL, token: nil)
        do {
            _ = try await client.fetchCredits()
            XCTFail("should throw unauthorized")
        } catch let error as APIClientError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
