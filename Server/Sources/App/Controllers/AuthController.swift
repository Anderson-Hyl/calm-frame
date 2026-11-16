import CalmFrameKit
import Fluent
import JWTKit
import Vapor

// Make CalmFrameKit DTOs work as Vapor Content (request/response bodies).
// Conformances are declared here rather than in CalmFrameKit so the shared
// package stays free of Vapor dependencies.
extension AuthRequest: Content {}
extension AuthResponse: Content {}

/// Handles `POST /v1/auth/apple`.
///
/// Flow:
/// 1. Decode `AuthRequest` (identity token string).
/// 2. Verify the Apple identity token via `AppleTokenVerifier`.
/// 3. Find or create the `User` row keyed on `appleSub`.
/// 4. Inside a database transaction, grant the 5-credit starter bonus
///    (idempotent via the unique `(reason, ref_id)` constraint).
/// 5. Sign and return a server JWT plus the current credit balance.
struct AuthController: RouteCollection {
    private let appleVerifier: any AppleTokenVerifier
    private let ledger: LedgerService

    init(
        appleVerifier: any AppleTokenVerifier = LiveAppleTokenVerifier(),
        ledger: LedgerService = LedgerService()
    ) {
        self.appleVerifier = appleVerifier
        self.ledger = ledger
    }

    func boot(routes: any RoutesBuilder) throws {
        let v1 = routes.grouped("v1")
        v1.post("auth", "apple", use: appleSignIn)
    }

    // MARK: - POST /v1/auth/apple

    @Sendable
    func appleSignIn(req: Request) async throws -> AuthResponse {
        // 1. Decode request body.
        let body = try req.content.decode(AuthRequest.self)

        // 2. Read config from environment.
        let bundleID = Environment.get("APPLE_BUNDLE_ID") ?? "app.calmframe.dev"

        // 3. Verify Apple identity token → appleSub.
        let appleSub: String
        do {
            appleSub = try await appleVerifier.verify(body.identityToken, audience: bundleID)
        } catch {
            throw Abort(.unauthorized, reason: "Invalid Apple identity token")
        }

        // 4. Upsert user + grant starter in a single transaction.
        let userID = try await req.db.transaction { db in
            // Find existing user or create a new one.
            let existing = try await User.query(on: db)
                .filter(\.$appleSub == appleSub)
                .first()

            let user: User
            if let found = existing {
                user = found
            } else {
                let newUser = User(appleSub: appleSub)
                try await newUser.save(on: db)
                user = newUser
            }

            guard let id = user.id else {
                throw Abort(.internalServerError, reason: "User ID missing after save")
            }

            // Grant starter credits (idempotent — safe to call for existing users).
            try await LedgerService().grantStarter(to: id, appleSub: appleSub, on: db)

            return id
        }

        // 5. Read balance outside the transaction (reads committed data).
        let balance = try await ledger.balance(for: userID, on: req.db)

        // 6. Sign a server JWT valid for 30 days.
        let payload = ServerJWTPayload(
            subject: SubjectClaim(value: userID.uuidString),
            expiration: ExpirationClaim(value: Date().addingTimeInterval(30 * 24 * 60 * 60))
        )
        let token = try req.application.jwtSigners.sign(payload)

        return AuthResponse(token: token, balance: balance)
    }
}
