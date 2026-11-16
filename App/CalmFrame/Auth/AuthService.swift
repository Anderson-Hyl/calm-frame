import AuthenticationServices
import Foundation
import UIKit

/// Sign in with Apple 的结果：只带客户端需要的东西。
/// identityToken 只发一次换服务端 JWT，不存；`userID` 就是 Apple 的 sub，
/// 是服务端认用户的键，也是 Keychain 里存的那一份。
public struct AppleSignInResult: Sendable {
    public var identityToken: String
    public var userID: String
    /// 首次授权才给的姓名（已拼成一句）；App 不展示姓名，这里只透传，不持久化。
    public var fullName: String?
    /// 首次授权才给的邮箱；同上，不持久化。
    public var email: String?

    public init(identityToken: String, userID: String, fullName: String? = nil, email: String? = nil) {
        self.identityToken = identityToken
        self.userID = userID
        self.fullName = fullName
        self.email = email
    }
}

public enum AuthServiceError: Error, Sendable, Equatable {
    case cancelled
    case noIdentityToken
    case failed(String)
}

/// Sign in with Apple 的授权口。真实现走系统授权页；测试用 MockAuthService。
/// 不要求 Sendable：调用方（AuthViewModel）本身就是 @MainActor。
public protocol AuthService {
    func signIn() async throws -> AppleSignInResult
    func credentialState(for userID: String) async -> ASAuthorizationAppleIDProvider.CredentialState
}

/// 真实现：ASAuthorizationAppleIDProvider + ASAuthorizationController。
/// 注意：授权页是系统弹的，App 只发请求、不画登录界面；
/// identityToken 的验签在服务端做，客户端不“验证”它（客户端验等于没验）。
public final class LiveAuthService: NSObject, AuthService, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {

    private var continuation: CheckedContinuation<AppleSignInResult, Error>?
    private var currentController: ASAuthorizationController?

    public override init() {
        super.init()
    }

    public func signIn() async throws -> AppleSignInResult {
        try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                self.beginSignIn(continuation: continuation)
            }
        }
    }

    @MainActor
    private func beginSignIn(continuation: CheckedContinuation<AppleSignInResult, Error>) {
        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.fullName, .email]
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        self.continuation = continuation
        self.currentController = controller
        controller.performRequests()
    }

    public func credentialState(for userID: String) async -> ASAuthorizationAppleIDProvider.CredentialState {
        await withCheckedContinuation { continuation in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: userID) { state, _ in
                continuation.resume(returning: state)
            }
        }
    }

    // MARK: - ASAuthorizationControllerDelegate

    public func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            finish(with: .failure(AuthServiceError.noIdentityToken))
            return
        }
        guard let tokenData = credential.identityToken,
              let identityToken = String(data: tokenData, encoding: .utf8),
              !identityToken.isEmpty
        else {
            finish(with: .failure(AuthServiceError.noIdentityToken))
            return
        }
        // 姓名/邮箱只在首次授权给；取到了也只透传，不由客户端持久化。
        let fullName = credential.fullName.map { PersonNameComponentsFormatter().string(from: $0) }
        let result = AppleSignInResult(
            identityToken: identityToken,
            userID: credential.user,
            fullName: fullName.flatMap { $0.isEmpty ? nil : $0 },
            email: credential.email
        )
        finish(with: .success(result))
    }

    public func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        if let authError = error as? ASAuthorizationError, authError.code == .canceled {
            finish(with: .failure(AuthServiceError.cancelled))
        } else {
            finish(with: .failure(AuthServiceError.failed(error.localizedDescription)))
        }
    }

    // MARK: - ASAuthorizationControllerPresentationContextProviding

    public func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let keyWindow = scenes.flatMap { $0.windows }.first { $0.isKeyWindow }
        return keyWindow ?? ASPresentationAnchor()
    }

    // MARK: - Private

    private func finish(with result: Result<AppleSignInResult, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        self.currentController = nil
        continuation.resume(with: result)
    }
}

/// 测试替身：成功 / 用户取消 / 无 token 三种，由测试定。
public final class MockAuthService: AuthService {
    public enum Mode: Sendable {
        case success(AppleSignInResult)
        case cancelled
        case noToken
    }

    public var mode: Mode
    public var stubbedCredentialState: ASAuthorizationAppleIDProvider.CredentialState

    public init(
        mode: Mode = .success(AppleSignInResult(identityToken: "mock-identity-token", userID: "mock-apple-sub")),
        stubbedCredentialState: ASAuthorizationAppleIDProvider.CredentialState = .authorized
    ) {
        self.mode = mode
        self.stubbedCredentialState = stubbedCredentialState
    }

    public func signIn() async throws -> AppleSignInResult {
        switch mode {
        case .success(let result):
            return result
        case .cancelled:
            throw AuthServiceError.cancelled
        case .noToken:
            throw AuthServiceError.noIdentityToken
        }
    }

    public func credentialState(for userID: String) async -> ASAuthorizationAppleIDProvider.CredentialState {
        stubbedCredentialState
    }
}
