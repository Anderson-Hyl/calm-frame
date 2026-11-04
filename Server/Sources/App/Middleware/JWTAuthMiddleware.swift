import JWTKit
import Vapor

// MARK: - Server JWT Payload

/// The payload embedded in every server-issued JWT.
struct ServerJWTPayload: JWTPayload, Authenticatable {
    enum CodingKeys: String, CodingKey {
        case subject = "sub"
        case expiration = "exp"
    }

    /// The authenticated user's UUID.
    var subject: SubjectClaim
    /// Token expiry (30 days from issuance).
    var expiration: ExpirationClaim

    func verify(using signer: JWTSigner) throws {
        try expiration.verifyNotExpired()
    }

    /// Convenience accessor for the UUID value of the subject claim.
    var userID: UUID {
        get throws {
            guard let id = UUID(uuidString: subject.value) else {
                throw Abort(.unauthorized, reason: "Malformed JWT subject")
            }
            return id
        }
    }
}

// MARK: - Middleware

/// Reads `Authorization: Bearer <token>`, verifies the server JWT, and stores
/// the decoded `ServerJWTPayload` on `req.auth` for downstream handlers.
///
/// Responds with 401 if the header is missing, the token is malformed, or the
/// signature / expiry check fails.
struct JWTAuthMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard let bearerToken = request.headers.bearerAuthorization?.token else {
            throw Abort(.unauthorized, reason: "Missing Bearer token")
        }

        let payload: ServerJWTPayload
        do {
            payload = try request.application.jwtSigners.verify(bearerToken, as: ServerJWTPayload.self)
        } catch {
            throw Abort(.unauthorized, reason: "Invalid or expired JWT")
        }

        request.auth.login(payload)
        return try await next.respond(to: request)
    }
}
