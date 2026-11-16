import Vapor

/// Registers all top-level routes.
/// Feature routes are registered inside their respective controllers.
func routes(_ app: Application) throws {
    // GET /health — unauthenticated liveness probe for the load balancer / deploy platform.
    app.get("health") { _ async in
        HealthResponse(status: "ok")
    }

    // Auth routes: POST /v1/auth/apple
    try app.register(collection: AuthController())

    // StoreKit routes (need the App Store verifier configured in configure()).
    let appStoreVerifier = app.appStoreVerifier
    try app.register(collection: CreditsController(appStoreVerifier: appStoreVerifier))
    try app.register(collection: AppStoreNotificationsController(appStoreVerifier: appStoreVerifier))
}

// Server-internal only; not a shared DTO.
private struct HealthResponse: Content {
    var status: String
}
