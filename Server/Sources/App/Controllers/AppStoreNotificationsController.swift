import Fluent
import Vapor

/// Request body for `POST /v1/appstore/notifications` (server-local DTO).
struct NotificationRequest: Content {
    var signedPayload: String
}

/// Response body for `POST /v1/appstore/notifications` (server-local DTO).
struct NotificationResponse: Content {
    var received: Bool
}

/// Outcome of handling one notification, decided inside the DB transaction.
private enum NotificationOutcome {
    /// The notificationUUID was already recorded — a duplicate delivery.
    case duplicate
    /// Handled (credited, deducted, restored, ignored, or parked).
    case handled
}

/// Handles `POST /v1/appstore/notifications` (App Store Server Notifications V2).
///
/// No JWT auth — the JWS signature is the authentication. Verify first, then act.
/// Verified-but-unprocessable notifications (unknown type, unknown product,
/// unattributed refund, out-of-order reversal) are parked and answered 200:
/// Apple retries non-2xx in production, so a 400 is reserved for genuinely
/// unverifiable payloads, where a retry is the only remedy.
struct AppStoreNotificationsController: RouteCollection {
    private let ledger: LedgerService
    private let appStoreVerifier: any AppStoreVerifier

    init(ledger: LedgerService = LedgerService(), appStoreVerifier: any AppStoreVerifier) {
        self.ledger = ledger
        self.appStoreVerifier = appStoreVerifier
    }

    func boot(routes: any RoutesBuilder) throws {
        routes.grouped("v1").post("appstore", "notifications", use: handleNotification)
    }

    // MARK: - POST /v1/appstore/notifications

    @Sendable
    func handleNotification(req: Request) async throws -> NotificationResponse {
        let logger = req.logger
        let body = try req.content.decode(NotificationRequest.self)
        guard !body.signedPayload.isEmpty else {
            throw Abort(.badRequest, reason: "signedPayload must not be empty")
        }

        // 1. Verify the outer signed payload. Failure → 400 (Apple retries).
        let verification = await appStoreVerifier.verifyNotification(body.signedPayload)
        let notification: VerifiedNotification
        switch verification {
        case .success(let verified):
            notification = verified
        case .failure(let error):
            logger.warning("notify: outer payload verification failed", metadata: ["error": .string(error.rawValue)])
            throw Abort(.badRequest, reason: "Notification verification failed")
        }

        // 2. notificationUUID is required — it is the de-duplication key.
        guard let notificationUUID = notification.notificationUUID, !notificationUUID.isEmpty else {
            throw Abort(.badRequest, reason: "Notification has no notificationUUID")
        }
        let rawType = notification.notificationType ?? ""

        // 3. For refund-type notifications, verify the inner transaction before
        //    touching the database. A failed inner verification is a 400 and
        //    leaves no inbox row, so Apple's retry can still deliver it.
        //    (`let`, not `var`: the DB transaction closure below is @Sendable
        //    and cannot capture a mutable variable.)
        let innerTransaction = try await verifyInnerTransaction(for: notification, logger: logger)

        // 4. One transaction: inbox insert (de-dup) + ledger writes + status.
        let outcome = try await req.db.transaction { db -> NotificationOutcome in
            let inbox = AppStoreNotification(
                notificationUUID: notificationUUID,
                notificationType: rawType,
                transactionID: innerTransaction?.transactionId,
                signedPayload: body.signedPayload,
                status: "processed"
            )
            do {
                try await inbox.save(on: db)
            } catch {
                if let dbError = error as? any DatabaseError, dbError.isConstraintFailure {
                    return .duplicate
                }
                throw error
            }
            switch rawType {
            case "REFUND":
                try await self.applyRefund(notificationUUID: notificationUUID, inner: innerTransaction, inbox: inbox, on: db, logger: logger)
            case "REFUND_REVERSED":
                try await self.applyReversal(notificationUUID: notificationUUID, inner: innerTransaction, inbox: inbox, on: db, logger: logger)
            case "TEST":
                logger.info("notify: TEST notification ignored", metadata: ["uuid": .string(notificationUUID)])
            case "CONSUMPTION_REQUEST":
                // Logged only — consumption data is not sent back (plan §4.5).
                logger.info("notify: CONSUMPTION_REQUEST logged, no consumption data sent", metadata: ["uuid": .string(notificationUUID)])
            default:
                // Unknown present/future type — log and accept, never reject.
                logger.info("notify: unknown notification type", metadata: ["type": .string(rawType), "uuid": .string(notificationUUID)])
            }
            inbox.processedAt = Date()
            try await inbox.update(on: db)
            return .handled
        }

        if case .duplicate = outcome {
            logger.info("notify: duplicate delivery ignored", metadata: ["uuid": .string(notificationUUID)])
        }
        return NotificationResponse(received: true)
    }

    // MARK: - Refund handling

    /// Verifies the inner transaction of a refund-type notification.
    /// Returns nil when the type is not refund-related or the notification
    /// carries no inner transaction (the caller parks it below). Throws 400
    /// when an inner transaction is present but fails verification.
    private func verifyInnerTransaction(for notification: VerifiedNotification, logger: Logger) async throws -> VerifiedTransaction? {
        guard let rawType = notification.notificationType,
              rawType == "REFUND" || rawType == "REFUND_REVERSED",
              let signedTransactionInfo = notification.signedTransactionInfo else {
            return nil
        }
        switch await appStoreVerifier.verifyTransaction(signedTransactionInfo) {
        case .success(let verified):
            return verified
        case .failure(let error):
            logger.warning("notify: inner transaction verification failed", metadata: [
                "uuid": .string(notification.notificationUUID ?? ""),
                "error": .string(error.rawValue),
            ])
            throw Abort(.badRequest, reason: "Inner transaction verification failed")
        }
    }

    /// Applies a REFUND: deduct the credited points from the owning user.
    /// Parks the notification (no deduction) when the product is unknown or
    /// the user cannot be attributed.
    private func applyRefund(notificationUUID: String, inner: VerifiedTransaction?, inbox: AppStoreNotification, on db: any Database, logger: Logger) async throws {
        guard let inner else {
            park(inbox, reason: "REFUND without signedTransactionInfo", logger: logger)
            return
        }
        guard let productId = inner.productId,
              let unitCredits = ProductCatalog.creditsByProductId[productId],
              inner.type == "Consumable" else {
            park(inbox, reason: "REFUND for unknown product or non-consumable type", logger: logger)
            return
        }
        let credits = unitCredits * inner.quantity
        guard let userID = try await resolveUser(for: inner, on: db) else {
            park(inbox, reason: "REFUND with no attributable user", logger: logger)
            return
        }
        let inserted = try await ledger.deductRefund(to: userID, notificationUUID: notificationUUID, credits: credits, on: db)
        logger.info("notify: REFUND applied", metadata: [
            "uuid": .string(notificationUUID),
            "transactionId": .string(inner.transactionId),
            "credits": .string(String(credits)),
            "inserted": .string(String(inserted)),
        ])
    }

    /// Applies a REFUND_REVERSED: restore the points, but only when a matching
    /// REFUND for the same transaction is already recorded. An out-of-order
    /// reversal is parked, never credited blindly.
    private func applyReversal(notificationUUID: String, inner: VerifiedTransaction?, inbox: AppStoreNotification, on db: any Database, logger: Logger) async throws {
        guard let inner else {
            park(inbox, reason: "REFUND_REVERSED without signedTransactionInfo", logger: logger)
            return
        }
        guard let productId = inner.productId,
              let unitCredits = ProductCatalog.creditsByProductId[productId],
              inner.type == "Consumable" else {
            park(inbox, reason: "REFUND_REVERSED for unknown product or non-consumable type", logger: logger)
            return
        }
        let priorRefund = try await AppStoreNotification.query(on: db)
            .filter(\.$transactionID == inner.transactionId)
            .filter(\.$notificationType == "REFUND")
            .filter(\.$status == "processed")
            .first()
        guard priorRefund != nil else {
            park(inbox, reason: "REFUND_REVERSED with no matching REFUND yet", logger: logger)
            return
        }
        let credits = unitCredits * inner.quantity
        guard let userID = try await resolveUser(for: inner, on: db) else {
            park(inbox, reason: "REFUND_REVERSED with no attributable user", logger: logger)
            return
        }
        let inserted = try await ledger.restoreRefund(to: userID, notificationUUID: notificationUUID, credits: credits, on: db)
        logger.info("notify: REFUND_REVERSED applied", metadata: [
            "uuid": .string(notificationUUID),
            "transactionId": .string(inner.transactionId),
            "credits": .string(String(credits)),
            "inserted": .string(String(inserted)),
        ])
    }

    /// Resolves the user a refund belongs to: first by the purchase ledger row
    /// (proves the money was recorded by us), then by `appAccountToken`.
    /// Returns nil when neither path attributes the transaction.
    private func resolveUser(for inner: VerifiedTransaction, on db: any Database) async throws -> UUID? {
        if let userID = try await ledger.purchaseUserID(forTransactionID: inner.transactionId, on: db) {
            return userID
        }
        if let appAccountToken = inner.appAccountToken {
            if try await User.find(appAccountToken, on: db) != nil {
                return appAccountToken
            }
        }
        return nil
    }

    /// Marks an inbox row parked (verified but not applied) and logs why.
    /// Parked rows stay for manual reconciliation; the endpoint still answers 200.
    private func park(_ inbox: AppStoreNotification, reason: String, logger: Logger) {
        inbox.status = "parked"
        logger.warning("notify: parked notification", metadata: ["uuid": .string(inbox.notificationUUID), "reason": .string(reason)])
    }
}
