/// Shared HTTP path constants used by both the App and the Server.
///
/// Example usage:
/// ```swift
/// let url = baseURL.appendingPathComponent(APIRoutes.auth)
/// ```
public enum APIRoutes {
    // MARK: - Auth

    /// `POST /v1/auth/apple` — Sign in with Apple; creates an account and grants starter credits.
    public static let auth = "/v1/auth/apple"

    // MARK: - Credits

    /// `GET /v1/credits` — Fetch the current credit balance.
    public static let creditsBalance = "/v1/credits"

    /// `POST /v1/credits/redeem` — Redeem a StoreKit 2 signed transaction.
    public static let creditsRedeem = "/v1/credits/redeem"

    // MARK: - Paintings

    /// `POST /v1/paintings` — Generate or retrieve a cached painting (costs 1 credit; free on cache hit).
    public static let paintingsCreate = "/v1/paintings"

    /// `GET /v1/paintings/latest` — Fetch the most recent painting for the widget.
    public static let paintingsLatest = "/v1/paintings/latest"

    // MARK: - App Store Server Notifications

    /// `POST /v1/appstore/notifications` — Apple App Store Server Notifications V2 webhook.
    public static let appStoreNotifications = "/v1/appstore/notifications"

    // MARK: - Health

    /// `GET /health` — Deployment health check; no authentication required.
    public static let health = "/health"
}
