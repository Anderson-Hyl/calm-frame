import AuthenticationServices
import CalmFrameKit
import Foundation
import Observation
import SwiftUI

/// 登录的协调者（@MainActor）：AuthService 拿 identityToken → APIClient 换服务端 JWT
/// → SessionStore 存 Keychain；401 时静默重登一次，仍失败则回未登录态。
@MainActor
@Observable
public final class AuthViewModel {
    public private(set) var isSignedIn = false
    public private(set) var balance: Int?
    public private(set) var isSigningIn = false
    public private(set) var errorMessage: String?

    private let authService: any AuthService
    private let session: SessionStore
    @ObservationIgnored private var apiClient: APIClient

    /// 本地联调 base URL：Mac 上跑着的 Vapor 服务（模拟器与 Mac 共用网络栈）。
    public static let localBaseURL = URL(string: "http://localhost:8080")!

    public init(
        authService: any AuthService = LiveAuthService(),
        session: SessionStore = SessionStore(),
        baseURL: URL = AuthViewModel.localBaseURL
    ) {
        self.authService = authService
        self.session = session
        self.apiClient = APIClient(baseURL: baseURL, token: session.serverToken)
        self.isSignedIn = session.isSignedIn
        self.balance = session.balance
    }

    /// 启动恢复：有存根先看 Apple 凭证还在不在，再拿 token 验一次余额。
    /// 凭证被撤 / 转让 / 找不着 → 静默登出，不崩、不留坏状态。
    public func restoreSession() async {
        guard let token = session.serverToken else { return }
        if let sub = session.appleSub {
            let state = await authService.credentialState(for: sub)
            switch state {
            case .revoked, .transferred, .notFound:
                signOut()
                return
            case .authorized:
                break
            @unknown default:
                break
            }
        }
        apiClient.token = token
        await refreshBalance()
    }

    /// 点登录：授权页 → 换 JWT → 存 Keychain → 余额。
    /// 用户取消不算错：只停下，不写错误文案、不碰已有状态。
    public func signIn() async {
        guard !isSigningIn else { return }
        isSigningIn = true
        errorMessage = nil
        defer { isSigningIn = false }
        do {
            let result = try await authService.signIn()
            let response = try await apiClient.signIn(identityToken: result.identityToken)
            session.save(token: response.token, appleSub: result.userID, balance: response.balance)
            apiClient.token = response.token
            isSignedIn = true
            balance = response.balance
        } catch AuthServiceError.cancelled {
            return
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    public func signOut() {
        session.clear()
        apiClient.token = nil
        isSignedIn = false
        balance = nil
        errorMessage = nil
    }

    /// 查余额；401 → 静默重登一次再查，仍失败则回未登录态。
    public func refreshBalance() async {
        guard session.serverToken != nil else {
            isSignedIn = false
            return
        }
        do {
            let value = try await apiClient.fetchCredits()
            session.updateBalance(value)
            balance = value
            isSignedIn = true
        } catch APIClientError.unauthorized {
            await silentReLoginThenRetry()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 静默重登：系统凭证还在时，重新授权可以不弹界面直接拿到新 identityToken；
    /// 弹了界面用户又取消、或换 token 失败 → 回未登录态，不崩。
    private func silentReLoginThenRetry() async {
        do {
            let result = try await authService.signIn()
            let response = try await apiClient.signIn(identityToken: result.identityToken)
            session.save(token: response.token, appleSub: result.userID, balance: response.balance)
            apiClient.token = response.token
            isSignedIn = true
            balance = response.balance
        } catch {
            signOut()
        }
    }
}
