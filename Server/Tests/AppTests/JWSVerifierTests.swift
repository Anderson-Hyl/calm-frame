import XCTest
@testable import App

/// Tests the REAL `LiveAppStoreVerifier` (Apple's `SignedDataVerifier`).
/// No fake is used here — a passing verification proves the chain code works.
///
/// The positive tests need a real Apple-signed sandbox JWS fixture. Without one
/// they report skipped ("blocked"), never a fake pass. Xcode StoreKit Testing
/// fixtures are NOT used: for `.xcode` / `.localTesting` environments the
/// library only decodes without chain verification, so they would prove nothing.
final class JWSVerifierTests: XCTestCase {

    // MARK: - Fixture loading

    /// Reads a fixture file from `Server/Tests/AppTests/Fixtures/` (the working
    /// directory for `swift test` is the package root, i.e. `Server/`).
    /// Returns nil when the file is absent — the caller must then skip.
    private func fixture(named name: String) -> String? {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tests")
            .appendingPathComponent("AppTests")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        guard let data = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return data.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeLiveVerifier() throws -> LiveAppStoreVerifier {
        try LiveAppStoreVerifier.fromEnvironment(workingDirectory: FileManager.default.currentDirectoryPath)
    }

    // MARK: - Constructor failures

    /// A missing root certificate must fail at construction — never silently
    /// fall back to an unverified verifier.
    func testLiveVerifierInitFailsWithoutRootCertificate() throws {
        XCTAssertThrowsError(
            try LiveAppStoreVerifier.fromEnvironment(workingDirectory: "/nonexistent-working-dir"),
            "verifier construction without the root certificate must throw"
        )
    }

    // MARK: - Malformed JWS is rejected (no fixture needed)

    func testLiveVerifierRejectsMalformedJWS() async throws {
        let verifier = try makeLiveVerifier()

        let empty = await verifier.verifyTransaction("")
        guard case .failure(let emptyError) = empty else {
            return XCTFail("empty JWS must not verify")
        }
        XCTAssertEqual(emptyError, .invalidFormat)

        let garbage = await verifier.verifyTransaction("not-a-jws")
        guard case .failure(let garbageError) = garbage else {
            return XCTFail("malformed JWS must not verify")
        }
        XCTAssertEqual(garbageError, .invalidFormat)

        let badNotification = await verifier.verifyNotification("also.not.jws")
        guard case .failure = badNotification else {
            return XCTFail("malformed notification must not verify")
        }
    }

    // MARK: - Real sandbox fixtures (blocked until recorded)

    /// Positive transaction test: a real Apple-signed sandbox JWS must verify.
    func testLiveVerifierAcceptsSandboxTransactionFixture() async throws {
        guard let jws = fixture(named: "sandbox-signed-transaction.txt") else {
            throw XCTSkip("blocked: no sandbox JWS fixture — record a real sandbox purchase JWS into Server/Tests/AppTests/Fixtures/sandbox-signed-transaction.txt (never paste it in chat)")
        }
        let verifier = try makeLiveVerifier()
        let result = await verifier.verifyTransaction(jws)
        guard case .success(let transaction) = result else {
            return XCTFail("real sandbox JWS must verify, got \(result)")
        }
        XCTAssertEqual(transaction.bundleId, "app.calmframe.dev")
        XCTAssertEqual(transaction.environment, "Sandbox")
        XCTAssertEqual(transaction.type, "Consumable")
        XCTAssertFalse(transaction.transactionId.isEmpty)
    }

    /// Tampering with one character of a real fixture must break verification.
    func testLiveVerifierRejectsTamperedFixture() async throws {
        guard var jws = fixture(named: "sandbox-signed-transaction.txt") else {
            throw XCTSkip("blocked: no sandbox JWS fixture — see Fixtures/README.md")
        }
        // Flip one character in the payload segment (between the two dots).
        guard let firstDot = jws.firstIndex(of: "."), let secondDot = jws[jws.index(after: firstDot)...].firstIndex(of: ".") else {
            return XCTFail("fixture is not a three-part JWS")
        }
        let payloadStart = jws.index(after: firstDot)
        guard payloadStart < secondDot else {
            return XCTFail("fixture payload segment is empty")
        }
        let original = jws[payloadStart]
        let replacement: Character = original == "A" ? "B" : "A"
        jws.replaceSubrange(payloadStart...payloadStart, with: String(replacement))

        let verifier = try makeLiveVerifier()
        let result = await verifier.verifyTransaction(jws)
        guard case .failure = result else {
            return XCTFail("tampered JWS must not verify")
        }
    }

    /// Positive notification test: a real Apple-signed sandbox notification
    /// must verify, and its inner transaction must verify too.
    func testLiveVerifierAcceptsSandboxNotificationFixture() async throws {
        guard let payload = fixture(named: "sandbox-refund-notification.txt") else {
            throw XCTSkip("blocked: no sandbox notification fixture — see Fixtures/README.md")
        }
        let verifier = try makeLiveVerifier()
        let result = await verifier.verifyNotification(payload)
        guard case .success(let notification) = result else {
            return XCTFail("real sandbox notification must verify, got \(result)")
        }
        XCTAssertEqual(notification.notificationType, "REFUND")
        XCTAssertNotNil(notification.notificationUUID, "notificationUUID must be present")
        guard let signedTransactionInfo = notification.signedTransactionInfo else {
            return XCTFail("REFUND notification must carry signedTransactionInfo")
        }
        let inner = await verifier.verifyTransaction(signedTransactionInfo)
        guard case .success(let transaction) = inner else {
            return XCTFail("inner transaction of a real notification must verify, got \(inner)")
        }
        XCTAssertEqual(transaction.bundleId, "app.calmframe.dev")
    }
}
