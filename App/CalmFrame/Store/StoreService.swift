import Foundation
import StoreKit

/// 购买失败的分类：UI 只需要区分“用户取消”和“别的错”。
public enum StoreServiceError: Error, Sendable, Equatable {
    /// 用户在系统购买页点了取消——不是错误，静默回闲置态。
    case cancelled
    /// StoreKit 没能验证这笔交易——不发 redeem、不 finish。
    case unverified
    /// 购买待批准（例如家长审批）——交易会经 Transaction.updates 再回来。
    case pending
    case failed(String)
}

/// 一笔已购交易：只带兑换要的东西。finish 闭包调 StoreKit 的 finish，
/// 只能在 redeem 返回 200（或 409 终态）后调用——判定在 StoreViewModel。
public struct PurchasedTransaction: Sendable {
    /// 原样发给 redeem 的 JWS，不解析、不改写。
    public var jwsRepresentation: String
    /// 完成这笔交易（从 StoreKit 未完成队列里清掉）。
    public var finish: @Sendable () async -> Void

    public init(jwsRepresentation: String, finish: @escaping @Sendable () async -> Void) {
        self.jwsRepresentation = jwsRepresentation
        self.finish = finish
    }
}

/// 商品的展示形状：UI 只要 id、显示名、本地化价格。真实 Product 只在
/// StoreService 内部出现，测试可以自由构造 StoreProduct。
public struct StoreProduct: Sendable, Equatable, Identifiable {
    /// App Store Connect 里的商品 id（credits.10 / credits.50）。
    public var id: String
    /// StoreKit 的 displayName（ASC 里填的“10 点”“50 点”）。
    public var displayName: String
    /// StoreKit 的 displayPrice（本地化价格，例如 ¥6.00）。
    public var displayPrice: String

    public init(id: String, displayName: String, displayPrice: String) {
        self.id = id
        self.displayName = displayName
        self.displayPrice = displayPrice
    }
}

/// StoreKit 2 的购买口。真实现走系统购买页；测试用 MockStoreService。
/// 全程只用 StoreKit 2 API，不用原 StoreKit（SKPaymentQueue 等）。
public protocol StoreService {
    func fetchProducts(ids: Set<String>) async throws -> [StoreProduct]
    func purchase(productID: String, appAccountToken: UUID?) async throws -> PurchasedTransaction
}

/// 真实现：StoreKit 2。
public final class LiveStoreService: StoreService {
    public init() {}

    public func fetchProducts(ids: Set<String>) async throws -> [StoreProduct] {
        let products = try await Product.products(for: ids)
        return products.map {
            StoreProduct(id: $0.id, displayName: $0.displayName, displayPrice: $0.displayPrice)
        }
    }

    public func purchase(productID: String, appAccountToken: UUID?) async throws -> PurchasedTransaction {
        // 购买时按 id 重新取 Product：StoreKit 内部有缓存，取到的就是拉商品那一批；
        // 这样购买口只需要商品 id，测试不用构造真实 Product。
        guard let product = try await Product.products(for: [productID]).first else {
            throw StoreServiceError.failed("product not found: \(productID)")
        }
        let options: Set<Product.PurchaseOption> = appAccountToken.map { [.appAccountToken($0)] } ?? []
        let result = try await product.purchase(options: options)
        switch result {
        case .success(let verification):
            switch verification {
            case .verified(let transaction):
                // JWS 在 VerificationResult 上，不在 Transaction 上——
                // 取 verification.jwsRepresentation，原样发 redeem。
                return PurchasedTransaction(jwsRepresentation: verification.jwsRepresentation) {
                    await transaction.finish()
                }
            case .unverified:
                throw StoreServiceError.unverified
            }
        case .userCancelled:
            throw StoreServiceError.cancelled
        case .pending:
            throw StoreServiceError.pending
        @unknown default:
            throw StoreServiceError.failed("unknown purchase result")
        }
    }
}

/// 测试替身：商品与购买结果都可配；finish 只记调用次数，不碰真 StoreKit。
public final class MockStoreService: StoreService {
    public var products: [StoreProduct] = []
    public var fetchProductsError: (any Error)?
    /// 购买成功时返回的 JWS（假串，只走通路，不验签）。
    public var purchaseJWS: String = "fake-jws"
    public var purchaseError: (any Error)?
    public private(set) var finishCallCount = 0
    public private(set) var lastProductID: String?
    public private(set) var lastAppAccountToken: UUID?

    public init() {}

    public func fetchProducts(ids: Set<String>) async throws -> [StoreProduct] {
        if let fetchProductsError { throw fetchProductsError }
        return products
    }

    public func purchase(productID: String, appAccountToken: UUID?) async throws -> PurchasedTransaction {
        lastProductID = productID
        lastAppAccountToken = appAccountToken
        if let purchaseError { throw purchaseError }
        return PurchasedTransaction(jwsRepresentation: purchaseJWS) { [weak self] in
            self?.finishCallCount += 1
        }
    }
}

// MARK: - JWT sub

/// 从 server JWT 里读 `sub`（服务端用户 UUID），只读 claim、不验签。
/// 验签是服务端的事；客户端只把 sub 原样带回给购买流程当 appAccountToken。
public enum JWTSubject {
    public static func subject(from token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        guard let data = Data(base64URLEncoded: String(parts[1])) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = json["sub"] as? String, !sub.isEmpty else { return nil }
        return sub
    }
}

private extension Data {
    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        self.init(base64Encoded: base64)
    }
}
