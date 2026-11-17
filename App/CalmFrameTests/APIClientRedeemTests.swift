import CalmFrameKit
import XCTest

@testable import CalmFrame

/// APIClient 的 redeem 部分：请求组装（方法、路径、鉴权头、body）与无 token 行为。
/// 真网络调用不在这里测，B-store-6 用模拟器（.storekit）与真机沙盒验。
final class APIClientRedeemTests: XCTestCase {

    private let baseURL = URL(string: "https://example.invalid")!

    func testRedeemRequestBuilder() throws {
        let client = APIClient(baseURL: baseURL)
        let request = try XCTUnwrap(client.makeRedeemRequest(signedTransaction: "jws-abc", token: "tok-123"))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v1/credits/redeem")
        // 只断言带了 Authorization 头，不比值（读回遮蔽，见 APIClientAuthTests）。
        XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(request.httpBody)
        let decoded = try JSONDecoder().decode(RedeemRequest.self, from: body)
        // JWS 原样发出，不解析、不改写。
        XCTAssertEqual(decoded.signedTransaction, "jws-abc")
    }

    func testRedeemWithoutTokenThrowsUnauthorized() async {
        let client = APIClient(baseURL: baseURL, token: nil)
        do {
            _ = try await client.redeem(signedTransaction: "jws-abc")
            XCTFail("should throw unauthorized")
        } catch let error as APIClientError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
