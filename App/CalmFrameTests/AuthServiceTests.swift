import AuthenticationServices
import XCTest

@testable import CalmFrame

/// AuthService 的测试替身：成功 / 用户取消 / 无 token 三种。
final class AuthServiceTests: XCTestCase {

    func testMockSuccessReturnsTokenAndSub() async throws {
        let expected = AppleSignInResult(
            identityToken: "tok-abc",
            userID: "sub-123",
            fullName: "Test User",
            email: "test@example.com"
        )
        let service = MockAuthService(mode: .success(expected))
        let result = try await service.signIn()
        XCTAssertEqual(result.identityToken, "tok-abc")
        XCTAssertEqual(result.userID, "sub-123")
        XCTAssertEqual(result.email, "test@example.com")
    }

    func testMockCancelledThrowsCancelled() async {
        let service = MockAuthService(mode: .cancelled)
        do {
            _ = try await service.signIn()
            XCTFail("should throw cancelled")
        } catch let error as AuthServiceError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testMockNoTokenThrowsNoIdentityToken() async {
        let service = MockAuthService(mode: .noToken)
        do {
            _ = try await service.signIn()
            XCTFail("should throw noIdentityToken")
        } catch let error as AuthServiceError {
            XCTAssertEqual(error, .noIdentityToken)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testMockCredentialState() async {
        let service = MockAuthService(stubbedCredentialState: .revoked)
        let state = await service.credentialState(for: "sub-123")
        XCTAssertEqual(state, .revoked)
    }
}
