import Foundation
import JWTKit

// MARK: - Protocol

/// Abstracts Apple identity token verification so tests can inject a fake.
protocol AppleTokenVerifier: Sendable {
    /// Verify the raw identity token string and return its `sub` claim on success.
    /// Throws on invalid signature, wrong issuer, wrong audience, or expiration.
    func verify(_ identityToken: String, audience: String) async throws -> String
}

// MARK: - Live Implementation

/// Caches Apple's JWKS for the process lifetime and performs verification inside
/// the actor to avoid crossing the `JWTSigners` (non-Sendable) boundary.
actor AppleJWKSCache {
    static let shared = AppleJWKSCache()

    /// Wraps the non-Sendable `JWTSigners` so it can be stored in the actor.
    private var signers: JWTSigners?

    private init() {}

    /// Verify an Apple identity token against the cached (or freshly fetched) JWKS.
    /// Returns the `sub` claim on success.
    func verify(_ identityToken: String, audience: String) async throws -> String {
        if signers == nil {
            signers = try await fetchSigners()
        }
        return try verifyWithCurrentSigners(identityToken, audience: audience)
    }

    // MARK: Private helpers

    private func verifyWithCurrentSigners(_ identityToken: String, audience: String) throws -> String {
        guard let signers else {
            throw AppleTokenVerificationError.jwksFetchFailed
        }
        // May throw JWTError.unknownKID if key set is stale — caller handles refresh.
        let payload = try signers.verify(identityToken, as: AppleIdentityToken.self)
        try payload.audience.verifyIntendedAudience(includes: audience)
        return payload.subject.value
    }

    private func fetchSigners() async throws -> JWTSigners {
        let url = URL(string: "https://appleid.apple.com/auth/keys")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw AppleTokenVerificationError.jwksFetchFailed
        }
        let jwksJSON = String(decoding: data, as: UTF8.self)
        let newSigners = JWTSigners()
        try newSigners.use(jwksJSON: jwksJSON)
        return newSigners
    }

    /// Force-refresh the cached JWKS (e.g. after a kid-not-found error) then re-verify.
    func refreshAndVerify(_ identityToken: String, audience: String) async throws -> String {
        signers = try await fetchSigners()
        return try verifyWithCurrentSigners(identityToken, audience: audience)
    }
}

struct LiveAppleTokenVerifier: AppleTokenVerifier {
    func verify(_ identityToken: String, audience: String) async throws -> String {
        do {
            return try await AppleJWKSCache.shared.verify(identityToken, audience: audience)
        } catch JWTError.unknownKID {
            // Stale cache — refresh once and retry
            return try await AppleJWKSCache.shared.refreshAndVerify(identityToken, audience: audience)
        } catch is JWTError {
            throw AppleTokenVerificationError.invalidToken
        }
    }
}

// MARK: - Errors

enum AppleTokenVerificationError: Error {
    case jwksFetchFailed
    case invalidToken
}
