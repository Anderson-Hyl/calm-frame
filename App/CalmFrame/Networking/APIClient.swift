import CalmFrameKit
import Foundation

/// 客户端请求失败的分类：UI 只需要区分“未登录/要重登”和“别的错”。
public enum APIClientError: Error, Sendable, Equatable {
    /// 没有 token，或服务端返回 401。
    case unauthorized
    case network(String)
    case server(status: Int)
    case decoding
}

/// 远端客户端（C4 打底，auth 切片接线）。
/// 没有真 JWT 就不发请求、不伪造 token；locale 取设备 BCP 47，绝不写死。
public struct APIClient: Sendable {
    public var baseURL: URL
    public var token: String?
    public var session: URLSession

    public init(baseURL: URL, token: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    // MARK: - Auth（A3）

    /// POST /v1/auth/apple：拿 Apple identityToken 换服务端 JWT。不带 Bearer。
    public func signIn(identityToken: String) async throws -> AuthResponse {
        guard let request = makeSignInRequest(identityToken: identityToken) else {
            throw APIClientError.network("cannot build sign-in request")
        }
        let data = try await data(for: request)
        do {
            return try JSONDecoder().decode(AuthResponse.self, from: data)
        } catch {
            throw APIClientError.decoding
        }
    }

    /// GET /v1/credits：查余额。需要 token；401 由调用方决定是否静默重登。
    /// 返回形状 `{"balance": 5}`（与服务端约定；若服务端改裸数字，这里跟着改）。
    public func fetchCredits() async throws -> Int {
        guard let token, let request = makeCreditsRequest(token: token) else {
            throw APIClientError.unauthorized
        }
        let data = try await data(for: request)
        do {
            return try JSONDecoder().decode(CreditsResponse.self, from: data).balance
        } catch {
            throw APIClientError.decoding
        }
    }

    /// 纯函数：组装 POST /v1/auth/apple 请求（可单测）。只发 identityToken，不带 Bearer。
    public func makeSignInRequest(identityToken: String) -> URLRequest? {
        let url = baseURL.appendingPathComponent("v1/auth/apple")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(AuthRequest(identityToken: identityToken))
        return request.httpBody == nil ? nil : request
    }

    /// 纯函数：组装 GET /v1/credits 请求（可单测）。
    public func makeCreditsRequest(token: String) -> URLRequest? {
        let url = baseURL.appendingPathComponent("v1/credits")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: - Paintings（C4，token 改由 SessionStore 经 AuthViewModel 同步）

    /// 有 token 才发请求；无 token 返回 nil，且不产生任何网络流量。
    public func fetchPainting(for mood: Mood) async -> PaintingResponse? {
        guard let token, let request = makeRequest(for: mood, token: token) else { return nil }
        do {
            let (data, _) = try await session.data(for: request)
            return try JSONDecoder().decode(PaintingResponse.self, from: data)
        } catch {
            return nil
        }
    }

    /// 纯函数：组装 POST /v1/paintings 请求（可单测）。
    public func makeRequest(for mood: Mood, token: String) -> URLRequest? {
        let url = baseURL.appendingPathComponent("v1/paintings")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = PaintingRequest(mood: mood, style: .oilPainting1800s, locale: Self.deviceLocaleBCP47)
        request.httpBody = try? JSONEncoder().encode(body)
        return request.httpBody == nil ? nil : request
    }

    /// 设备 locale 的 BCP 47 标识（例如 zh-Hans-CN），绝不写死。
    public static var deviceLocaleBCP47: String {
        Locale.current.identifier(.bcp47)
    }

    // MARK: - Private

    /// 发请求并按状态码分类错误：401 → unauthorized；其他非 2xx → server。
    private func data(for request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIClientError.network(error.localizedDescription)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIClientError.network("non-HTTP response")
        }
        switch httpResponse.statusCode {
        case 200..<300:
            return data
        case 401:
            throw APIClientError.unauthorized
        default:
            throw APIClientError.server(status: httpResponse.statusCode)
        }
    }
}

/// GET /v1/credits 的返回体（服务端约定）。
private struct CreditsResponse: Decodable {
    var balance: Int
}
