import XCTest
@testable import App

/// Test double for `AppStoreVerifier`: returns canned verification results
/// keyed by the exact JWS string.
///
/// It only proves controller logic — never verification itself (see
/// `JWSVerifierTests` for the real verifier). A JWS string not present in
/// the map fails verification, like an unknown token would.
struct FakeAppStoreVerifier: AppStoreVerifier {
    var transactionResults: [String: Result<VerifiedTransaction, AppStoreVerificationError>]
    var notificationResults: [String: Result<VerifiedNotification, AppStoreVerificationError>]

    init(
        transactionResults: [String: Result<VerifiedTransaction, AppStoreVerificationError>] = [:],
        notificationResults: [String: Result<VerifiedNotification, AppStoreVerificationError>] = [:]
    ) {
        self.transactionResults = transactionResults
        self.notificationResults = notificationResults
    }

    func verifyTransaction(_ signedTransaction: String) async -> Result<VerifiedTransaction, AppStoreVerificationError> {
        transactionResults[signedTransaction] ?? .failure(.verificationFailure)
    }

    func verifyNotification(_ signedPayload: String) async -> Result<VerifiedNotification, AppStoreVerificationError> {
        notificationResults[signedPayload] ?? .failure(.verificationFailure)
    }
}

// MARK: - Canned payload builders

/// A verified consumable purchase. Defaults to `credits.10` for `transactionId`.
func cannedPurchase(
    transactionId: String,
    productId: String = "credits.10",
    quantity: Int = 1,
    type: String? = "Consumable",
    appAccountToken: UUID? = nil,
    revocationDate: Date? = nil
) -> VerifiedTransaction {
    VerifiedTransaction(
        transactionId: transactionId,
        originalTransactionId: transactionId,
        bundleId: "app.calmframe.dev",
        productId: productId,
        quantity: quantity,
        type: type,
        appAccountToken: appAccountToken,
        environment: "Sandbox",
        revocationDate: revocationDate,
        revocationReason: nil,
        purchaseDate: Date(),
        signedDate: Date(),
        currency: "CNY",
        price: 6000,
        storefront: "CHN"
    )
}

/// A verified notification envelope.
func cannedNotification(
    type: String,
    uuid: String,
    signedTransactionInfo: String? = nil
) -> VerifiedNotification {
    VerifiedNotification(
        notificationType: type,
        subtype: nil,
        notificationUUID: uuid,
        signedTransactionInfo: signedTransactionInfo,
        bundleId: "app.calmframe.dev",
        environment: "Sandbox"
    )
}
