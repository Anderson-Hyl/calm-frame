/// App 与 Server 共用的 HTTP 路由路径常量。
///
/// 用法示例：
/// ```swift
/// let url = baseURL.appendingPathComponent(APIRoutes.auth)
/// ```
public enum APIRoutes {
    // MARK: - Auth
    /// `POST /v1/auth/apple` — Sign in with Apple，建号并领取 starter credits。
    public static let auth = "/v1/auth/apple"

    // MARK: - Credits
    /// `GET /v1/credits` — 查询点数余额。
    public static let creditsBalance = "/v1/credits"
    /// `POST /v1/credits/redeem` — 兑换 StoreKit 2 交易。
    public static let creditsRedeem = "/v1/credits/redeem"

    // MARK: - Paintings
    /// `POST /v1/paintings` — 生成或取缓存画作（消耗 1 点，缓存命中免费）。
    public static let paintingsCreate = "/v1/paintings"
    /// `GET /v1/paintings/latest` — 小组件拉取最新画作。
    public static let paintingsLatest = "/v1/paintings/latest"

    // MARK: - App Store Server Notifications
    /// `POST /v1/appstore/notifications` — Apple ASSN V2 回调。
    public static let appStoreNotifications = "/v1/appstore/notifications"

    // MARK: - Health
    /// `GET /health` — 部署健康检查，无需认证。
    public static let health = "/health"
}
