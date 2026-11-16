import CalmFrameKit
import Foundation

/// 最小版远端画作客户端（C4，方案节点 4）。
/// 只组装请求；没有真 JWT 就不发请求、不伪造 token——本轮离线画是完整通路。
/// locale 取设备 BCP 47，绝不写死。
public struct APIClient: Sendable {
    public var baseURL: URL
    public var token: String?

    public init(baseURL: URL, token: String? = nil) {
        self.baseURL = baseURL
        self.token = token
    }

    /// 有 token 才发请求；无 token 返回 nil，且不产生任何网络流量。
    public func fetchPainting(for mood: Mood) async -> PaintingResponse? {
        guard let token, let request = makeRequest(for: mood, token: token) else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
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
}
