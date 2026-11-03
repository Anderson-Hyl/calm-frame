import Foundation

// MARK: - Auth

/// App 发给 `POST /v1/auth/apple` 的请求体。
public struct AuthRequest: Codable, Sendable {
    /// Sign in with Apple 返回的 identity token（Base64 编码的 JWT）。
    public var identityToken: String

    public init(identityToken: String) {
        self.identityToken = identityToken
    }
}

/// `POST /v1/auth/apple` 的响应体。
public struct AuthResponse: Codable, Sendable {
    /// 服务端签发的 JWT，后续请求放在 `Authorization: Bearer` 头里。
    public var token: String
    /// 当前点数余额（新用户为 5）。
    public var balance: Int

    public init(token: String, balance: Int) {
        self.token = token
        self.balance = balance
    }
}

// MARK: - Credits

/// `GET /v1/credits` 的响应体。
public struct BalanceResponse: Codable, Sendable {
    /// 当前点数余额。永远用 `Int`，禁止浮点。
    public var balance: Int

    public init(balance: Int) {
        self.balance = balance
    }
}

/// App 发给 `POST /v1/credits/redeem` 的请求体。
public struct RedeemRequest: Codable, Sendable {
    /// StoreKit 2 `VerificationResult<Transaction>` 的 `jwsRepresentation`。
    public var signedTransaction: String

    public init(signedTransaction: String) {
        self.signedTransaction = signedTransaction
    }
}

// MARK: - Paintings

/// App 发给 `POST /v1/paintings` 的请求体。
///
/// 只携带 mood、style、locale——不含任何音频数据。
public struct PaintingRequest: Codable, Sendable {
    public var mood: Mood
    public var style: PaintingStyle
    /// BCP 47 语言标签，如 `"zh-Hans"`、`"en"`，用于 caption 语言。
    public var locale: String

    public init(mood: Mood, style: PaintingStyle, locale: String) {
        self.mood = mood
        self.style = style
        self.locale = locale
    }
}

/// `POST /v1/paintings` 及 `GET /v1/paintings/latest` 的响应体。
public struct PaintingResponse: Codable, Sendable {
    /// 画作在数据库中的唯一 ID。
    public var id: UUID
    /// R2/S3 预签名或 CDN URL，App 直接加载图片。
    public var imageURL: URL
    /// 画作标题（Claude 生成，1–8 个字）。
    public var title: String
    /// 一句话 caption，可为 nil（calm 等情况）。
    public var caption: String?
    /// `true` 表示命中缓存，未消耗点数。
    public var fromCache: Bool
    /// 本次操作后的最新余额。
    public var balance: Int

    public init(
        id: UUID,
        imageURL: URL,
        title: String,
        caption: String? = nil,
        fromCache: Bool,
        balance: Int
    ) {
        self.id = id
        self.imageURL = imageURL
        self.title = title
        self.caption = caption
        self.fromCache = fromCache
        self.balance = balance
    }
}

// MARK: - Errors

/// 服务端返回的通用错误信息（JSON body：`{ "error": "...", "retryable": true }`）。
public struct APIError: Codable, Sendable, LocalizedError {
    public var error: String
    /// `true` 表示客户端可以做指数退避重试（如 AI 生成失败）。
    public var retryable: Bool

    public init(error: String, retryable: Bool = false) {
        self.error = error
        self.retryable = retryable
    }

    public var errorDescription: String? { error }
}
