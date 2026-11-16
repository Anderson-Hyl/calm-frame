import Vapor

/// Handles `GET /v1/credits`.
///
/// Flow:
/// 1. `JWTAuthMiddleware` verifies the `Authorization: Bearer <token>` header
///    and stores the decoded `ServerJWTPayload` on `req.auth` (401 otherwise).
/// 2. Read the caller's current credit balance (SUM of ledger deltas).
struct CreditsController: RouteCollection {
    private let ledger: LedgerService

    init(ledger: LedgerService = LedgerService()) {
        self.ledger = ledger
    }

    func boot(routes: any RoutesBuilder) throws {
        let v1 = routes.grouped("v1")
        let authed = v1.grouped(JWTAuthMiddleware())
        authed.get("credits", use: getCredits)
    }

    // MARK: - GET /v1/credits

    @Sendable
    func getCredits(req: Request) async throws -> CreditsResponse {
        let payload = try req.auth.require(ServerJWTPayload.self)
        let userID = try payload.userID
        let balance = try await ledger.balance(for: userID, on: req.db)
        return CreditsResponse(balance: balance)
    }
}

// Server-internal only; not a shared DTO.
struct CreditsResponse: Content {
    var balance: Int
}
