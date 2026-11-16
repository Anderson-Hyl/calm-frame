import CalmFrameKit
import Fluent
import Vapor

// Make CalmFrameKit DTOs work as Vapor Content (request/response bodies).
// Conformances are declared here rather than in CalmFrameKit so the shared
// package stays free of Vapor dependencies.
extension RedeemRequest: Content {}
extension BalanceResponse: Content {}

/// Handles `GET /v1/credits` and `POST /v1/credits/redeem`.
///
/// Flow for redeem:
/// 1. `JWTAuthMiddleware` verifies the `Authorization: Bearer <token>` header
///    and stores the decoded `ServerJWTPayload` on `req.auth` (401 otherwise).
/// 2. Decode `RedeemRequest` (the StoreKit 2 `jwsRepresentation`).
/// 3. Verify the JWS with Apple's `SignedDataVerifier` via `AppStoreVerifier`.
/// 4. Check the business fields (consumable, known product, not revoked,
///    `appAccountToken` matches the JWT user when present).
/// 5. Record the purchase as a ledger row inside a transaction — the
///    `(reason, ref_id)` unique constraint is the idempotency key.
/// 6. Return the new balance.
struct CreditsController: RouteCollection {
    private let ledger: LedgerService
    private let appStoreVerifier: any AppStoreVerifier

    init(ledger: LedgerService = LedgerService(), appStoreVerifier: any AppStoreVerifier) {
        self.ledger = ledger
        self.appStoreVerifier = appStoreVerifier
    }

    func boot(routes: any RoutesBuilder) throws {
        let v1 = routes.grouped("v1")
        let authed = v1.grouped(JWTAuthMiddleware())
        authed.get("credits", use: getCredits)
        authed.post("credits", "redeem", use: redeem)
    }

    // MARK: - GET /v1/credits

    @Sendable
    func getCredits(req: Request) async throws -> CreditsResponse {
        let payload = try req.auth.require(ServerJWTPayload.self)
        let userID = try payload.userID
        let balance = try await ledger.balance(for: userID, on: req.db)
        return CreditsResponse(balance: balance)
    }

    // MARK: - POST /v1/credits/redeem

    @Sendable
    func redeem(req: Request) async throws -> BalanceResponse {
        // 1. Decode request body.
        let body = try req.content.decode(RedeemRequest.self)

        // 2. Reject an empty or malformed JWS before verification (400, not 401:
        //    this is a client bug, not a failed signature).
        let segments = body.signedTransaction.split(separator: ".", omittingEmptySubsequences: false)
        guard !body.signedTransaction.isEmpty, segments.count == 3 else {
            throw Abort(.badRequest, reason: "signedTransaction must be a three-part JWS")
        }

        // 3. Verify the JWS (signature + x5c chain + bundleId + environment,
        //    all inside the library).
        let verification = await appStoreVerifier.verifyTransaction(body.signedTransaction)
        let transaction: VerifiedTransaction
        switch verification {
        case .success(let verified):
            transaction = verified
        case .failure(let error):
            // A malformed JWS is a 400; every other verification failure is a 401.
            if error == .invalidFormat {
                throw Abort(.badRequest, reason: "signedTransaction is not a valid JWS")
            }
            req.logger.warning("redeem: transaction verification failed", metadata: ["error": .string(error.rawValue)])
            throw Abort(.unauthorized, reason: "Transaction verification failed")
        }

        // 4. Business-field checks (the library already checked bundleId and
        //    environment; assert them again here as defense in depth).
        let bundleId = Environment.get("APPLE_BUNDLE_ID") ?? "app.calmframe.dev"
        guard transaction.bundleId == bundleId else {
            throw Abort(.unauthorized, reason: "Transaction bundleId mismatch")
        }
        let configuredEnvironment = Environment.get("APP_STORE_ENVIRONMENT") ?? "sandbox"
        if let environment = transaction.environment,
           environment.lowercased() != configuredEnvironment.lowercased() {
            throw Abort(.unauthorized, reason: "Transaction environment mismatch")
        }
        guard !transaction.transactionId.isEmpty else {
            throw Abort(.badRequest, reason: "Transaction has no transactionId")
        }
        let transactionId = transaction.transactionId

        // A revoked transaction (already refunded) cannot be redeemed.
        if transaction.revocationDate != nil {
            throw Abort(.conflict, reason: "Transaction has been revoked")
        }
        // Only consumables are sold.
        guard transaction.type == "Consumable" else {
            throw Abort(.unprocessableEntity, reason: "Only consumable transactions can be redeemed")
        }
        guard let productId = transaction.productId,
              let unitCredits = ProductCatalog.creditsByProductId[productId] else {
            throw Abort(.unprocessableEntity, reason: "Unknown productId")
        }
        let quantity = transaction.quantity
        if quantity != 1 {
            req.logger.warning("redeem: consumable quantity is not 1", metadata: [
                "transactionId": .string(transactionId),
                "quantity": .string(String(quantity)),
            ])
        }
        let credits = unitCredits * quantity

        // 5. The authenticated user, and the appAccountToken cross-check.
        //    appAccountToken is downgraded per plan: absent → record-only, no
        //    hard check; present but mismatched → 409.
        let payload = try req.auth.require(ServerJWTPayload.self)
        let userID = try payload.userID
        if let appAccountToken = transaction.appAccountToken, appAccountToken != userID {
            throw Abort(.conflict, reason: "appAccountToken does not match the authenticated user")
        }

        // 6. Record the purchase in a transaction. The (reason, ref_id) unique
        //    constraint is the idempotency key — no SELECT-then-INSERT.
        let outcome = try await req.db.transaction { db in
            try await ledger.grantPurchase(to: userID, transactionID: transactionId, credits: credits, on: db)
        }
        if case .grantedToOtherUser = outcome {
            req.logger.warning("redeem: transaction already credited to another user", metadata: ["transactionId": .string(transactionId)])
            throw Abort(.conflict, reason: "Transaction already redeemed by another user")
        }

        // 7. Read balance outside the transaction (reads committed data).
        let balance = try await ledger.balance(for: userID, on: req.db)
        return BalanceResponse(balance: balance)
    }
}

// Server-internal only; not a shared DTO.
struct CreditsResponse: Content {
    var balance: Int
}
