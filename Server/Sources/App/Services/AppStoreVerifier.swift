import AppStoreServerLibrary
import Foundation
import Vapor

/// The App Store environment, as used by `SignedDataVerifier`.
/// v2.3.0 of the library names this type `Environment`, which collides with
/// Vapor's `Environment`, so it is aliased here. (v6 renamed it to
/// `AppStoreEnvironment`; this alias keeps the code identical if we upgrade.)
typealias AppStoreEnvironment = AppStoreServerLibrary.Environment

// MARK: - Decoded payloads (our own Sendable value types)
//
// The library's payload types are not Sendable (v2.3.0), so the verifier
// boundary maps them into these plain structs. Controllers never touch
// library types, which also keeps a future library upgrade to one file.

/// A verified StoreKit transaction.
struct VerifiedTransaction: Sendable {
    var transactionId: String
    var originalTransactionId: String?
    var bundleId: String?
    var productId: String?
    var quantity: Int
    /// Raw `type` value, e.g. "Consumable".
    var type: String?
    var appAccountToken: UUID?
    /// Raw `environment` value, e.g. "Sandbox".
    var environment: String?
    var revocationDate: Date?
    var revocationReason: Int32?
    var purchaseDate: Date?
    var signedDate: Date?
    var currency: String?
    /// Price in milliunits — a currency amount, never used for credits.
    var price: Int64?
    var storefront: String?
}

/// A verified App Store Server Notification (outer payload only; the inner
/// signed transaction is verified separately).
struct VerifiedNotification: Sendable {
    /// Raw `notificationType` value, e.g. "REFUND". Unknown future types
    /// arrive as their raw string and are handled by the default branch.
    var notificationType: String?
    var subtype: String?
    var notificationUUID: String?
    /// The inner signed transaction JWS, if the notification carries one.
    var signedTransactionInfo: String?
    var bundleId: String?
    /// Raw `environment` value, e.g. "Sandbox".
    var environment: String?
}

/// Why a JWS failed verification.
enum AppStoreVerificationError: String, Sendable, Error {
    case invalidFormat
    case invalidCertificate
    case verificationFailure
    case invalidAppIdentifier
    case invalidEnvironment
}

// MARK: - Protocol

/// Abstracts StoreKit JWS verification so tests can inject a fake.
/// The live implementation delegates to Apple's `SignedDataVerifier`
/// (app-store-server-library-swift) — the x5c chain is never hand-rolled.
protocol AppStoreVerifier: Sendable {
    /// Verify a StoreKit 2 signed transaction JWS (`jwsRepresentation`).
    func verifyTransaction(_ signedTransaction: String) async -> Result<VerifiedTransaction, AppStoreVerificationError>
    /// Verify an App Store Server Notifications V2 signed payload JWS.
    func verifyNotification(_ signedPayload: String) async -> Result<VerifiedNotification, AppStoreVerificationError>
}

// MARK: - Live implementation

/// Live implementation backed by Apple's `SignedDataVerifier`.
///
/// A struct holding only Sendable configuration; each verification constructs
/// a fresh `SignedDataVerifier` from that configuration. This is required by
/// Swift 6 region isolation: the library type is a non-Sendable struct, so
/// awaiting on a stored instance — even a local copy of one — is rejected
/// ("sending 'verifier' risks causing data races"). A freshly constructed
/// local has no such origin and compiles. Construction is cheap (it only
/// stores configuration and parses the root certificate), and verification
/// calls are rare — one per purchase or notification.
struct LiveAppStoreVerifier: AppStoreVerifier {
    private let rootCertificates: [Foundation.Data]
    private let bundleId: String
    private let appAppleId: Int64?
    // Stored as a raw String, not `Environment`: the library's `Environment`
    // enum (v2.3.0, pre-Swift 6) is not Sendable, and a Sendable-conforming
    // struct cannot store it. The string is validated at init, so the
    // `?? .sandbox` fallback in makeVerifier() is unreachable in practice.
    private let environmentRawValue: String
    private let enableOnlineChecks: Bool

    init(rootCertificates: [Foundation.Data], bundleId: String, appAppleId: Int64?, environment: AppStoreEnvironment, enableOnlineChecks: Bool) throws {
        // Validate once at startup: a malformed root certificate, or a
        // production environment without an app Apple ID, must fail fast
        // instead of failing the first purchase.
        _ = try SignedDataVerifier(
            rootCertificates: rootCertificates,
            bundleId: bundleId,
            appAppleId: appAppleId,
            environment: environment,
            enableOnlineChecks: enableOnlineChecks
        )
        self.rootCertificates = rootCertificates
        self.bundleId = bundleId
        self.appAppleId = appAppleId
        self.environmentRawValue = environment.rawValue
        self.enableOnlineChecks = enableOnlineChecks
    }

    /// Builds a fresh verifier from the stored configuration. The inputs were
    /// validated at startup, so construction cannot fail in practice; a failure
    /// here is reported as a verification failure (fail closed) rather than a crash.
    private func makeVerifier() -> Result<SignedDataVerifier, AppStoreVerificationError> {
        do {
            return .success(try SignedDataVerifier(
                rootCertificates: rootCertificates,
                bundleId: bundleId,
                appAppleId: appAppleId,
                environment: AppStoreEnvironment(rawValue: environmentRawValue) ?? .sandbox,
                enableOnlineChecks: enableOnlineChecks
            ))
        } catch {
            return .failure(.verificationFailure)
        }
    }

    func verifyTransaction(_ signedTransaction: String) async -> Result<VerifiedTransaction, AppStoreVerificationError> {
        guard case .success(let verifier) = makeVerifier() else {
            return .failure(.verificationFailure)
        }
        switch await verifier.verifyAndDecodeTransaction(signedTransaction: signedTransaction) {
        case .valid(let payload):
            return .success(VerifiedTransaction(from: payload))
        case .invalid(let error):
            return .failure(AppStoreVerificationError(from: error))
        }
    }

    func verifyNotification(_ signedPayload: String) async -> Result<VerifiedNotification, AppStoreVerificationError> {
        guard case .success(let verifier) = makeVerifier() else {
            return .failure(.verificationFailure)
        }
        switch await verifier.verifyAndDecodeNotification(signedPayload: signedPayload) {
        case .valid(let payload):
            return .success(VerifiedNotification(from: payload))
        case .invalid(let error):
            return .failure(AppStoreVerificationError(from: error))
        }
    }
}

// MARK: - Configuration

enum AppStoreVerifierConfigurationError: Error {
    case invalidEnvironment(String)
    case invalidAppAppleId(String)
    case missingRootCertificate(String)
}

extension LiveAppStoreVerifier {
    /// Build the verifier from the process environment and the bundled root
    /// certificate (`Resources/AppleRootCA-G3.cer`, relative to the working
    /// directory — the Server package root when run via `swift run` / `swift test`).
    static func fromEnvironment(workingDirectory: String) throws -> LiveAppStoreVerifier {
        let bundleId = Vapor.Environment.get("APPLE_BUNDLE_ID") ?? "app.calmframe.dev"
        let environmentRaw = Vapor.Environment.get("APP_STORE_ENVIRONMENT") ?? "sandbox"
        let environment: AppStoreEnvironment
        switch environmentRaw.lowercased() {
        case "sandbox":
            environment = .sandbox
        case "production":
            environment = .production
        default:
            throw AppStoreVerifierConfigurationError.invalidEnvironment(environmentRaw)
        }
        let appAppleId: Int64?
        if let raw = Vapor.Environment.get("APP_STORE_APP_APPLE_ID"), !raw.isEmpty {
            guard let id = Int64(raw) else {
                throw AppStoreVerifierConfigurationError.invalidAppAppleId(raw)
            }
            appAppleId = id
        } else {
            appAppleId = nil
        }
        let certURL = URL(fileURLWithPath: workingDirectory)
            .appendingPathComponent("Resources")
            .appendingPathComponent("AppleRootCA-G3.cer")
        let certData: Foundation.Data
        do {
            certData = try Foundation.Data(contentsOf: certURL)
        } catch {
            throw AppStoreVerifierConfigurationError.missingRootCertificate(certURL.path)
        }
        // Online (OCSP) checks stay OFF: in v2.3.0 they run through an
        // AsyncHTTPClient the library shuts down synchronously, which
        // deadlocks on a Vapor event loop
        // (apple/app-store-server-library-swift#113, fixed in v5).
        // Offline chain verification still proves the signature is Apple's;
        // only revocation freshness is reduced. Production online checks
        // need a library/Vapor upgrade — see verify-calm-frame/SKILL.md.
        return try LiveAppStoreVerifier(
            rootCertificates: [certData],
            bundleId: bundleId,
            appAppleId: appAppleId,
            environment: environment,
            enableOnlineChecks: false
        )
    }
}

// MARK: - Mapping (library types → our Sendable types)

extension VerifiedTransaction {
    init(from payload: JWSTransactionDecodedPayload) {
        self.transactionId = payload.transactionId ?? ""
        self.originalTransactionId = payload.originalTransactionId
        self.bundleId = payload.bundleId
        self.productId = payload.productId
        self.quantity = Int(payload.quantity ?? 1)
        self.type = payload.rawType
        self.appAccountToken = payload.appAccountToken
        self.environment = payload.rawEnvironment
        self.revocationDate = payload.revocationDate
        self.revocationReason = payload.rawRevocationReason
        self.purchaseDate = payload.purchaseDate
        self.signedDate = payload.signedDate
        self.currency = payload.currency
        self.price = payload.price
        self.storefront = payload.storefront
    }
}

extension VerifiedNotification {
    init(from payload: ResponseBodyV2DecodedPayload) {
        self.notificationType = payload.rawNotificationType
        self.subtype = payload.rawSubtype
        self.notificationUUID = payload.notificationUUID
        self.signedTransactionInfo = payload.data?.signedTransactionInfo
        self.bundleId = payload.data?.bundleId
        self.environment = payload.data?.rawEnvironment
    }
}

extension AppStoreVerificationError {
    init(from error: VerificationError) {
        switch error {
        case .INVALID_JWT_FORMAT:
            self = .invalidFormat
        case .INVALID_CERTIFICATE:
            self = .invalidCertificate
        case .VERIFICATION_FAILURE:
            self = .verificationFailure
        case .INVALID_APP_IDENTIFIER:
            self = .invalidAppIdentifier
        case .INVALID_ENVIRONMENT:
            self = .invalidEnvironment
        }
    }
}

// MARK: - Application storage

/// Stored on the `Application` by `configure()` (like `JWTSignersBox`).
struct AppStoreVerifierKey: StorageKey {
    typealias Value = any AppStoreVerifier
}

extension Application {
    /// The shared StoreKit JWS verifier for this application instance.
    /// Traps if `configure()` has not set it — routes must not run without it.
    var appStoreVerifier: any AppStoreVerifier {
        get {
            guard let verifier = storage[AppStoreVerifierKey.self] else {
                fatalError("AppStoreVerifier not configured — configure() must set it before routes()")
            }
            return verifier
        }
        set {
            storage[AppStoreVerifierKey.self] = newValue
        }
    }
}
