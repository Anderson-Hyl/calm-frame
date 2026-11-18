import CalmFrameKit
import Foundation
import Observation
import StoreKit

/// 购买的协调者（@MainActor）：拉商品 → 购买 → redeem → 刷新余额。
/// finish 只在 redeem 200（或 409 终态）后调用；别的失败都不 finish，
/// 交易留在 StoreKit 未完成队列里，下次启动经 Transaction.updates 重发。
@MainActor
@Observable
public final class StoreViewModel {
    /// App Store Connect 里的两个商品（顺序即展示顺序）。
    public static let productIDs: [String] = ["credits.10", "credits.50"]

    public private(set) var products: [StoreProduct] = []
    public private(set) var isLoadingProducts = false
    public private(set) var isPurchasing = false
    public private(set) var purchasingProductID: String?
    public private(set) var errorMessage: String?
    public private(set) var purchaseMessage: String?

    private let storeService: any StoreService
    private let session: SessionStore
    private let authViewModel: AuthViewModel
    private var apiClient: APIClient
    private var listenerTask: Task<Void, Never>?

    public init(
        storeService: any StoreService = LiveStoreService(),
        session: SessionStore,
        authViewModel: AuthViewModel,
        baseURL: URL = AuthViewModel.localBaseURL,
        urlSession: URLSession = .shared
    ) {
        self.storeService = storeService
        self.session = session
        self.authViewModel = authViewModel
        self.apiClient = APIClient(baseURL: baseURL, token: session.serverToken, session: urlSession)
    }

    // 注意：没有 deinit 取消 listenerTask——deinit 不是 @MainActor 隔离，
    // 碰 listenerTask 会编译错；这个 view model 本来就跟 App 同寿，
    // 进程退出时 Task 随之结束，不需要手动取消。
    // MARK: - 商品

    /// 拉两个商品。已拉到就不再重复拉（失败时 products 为空，下次进页面会再拉）。
    public func loadProducts() async {
        guard !isLoadingProducts, products.isEmpty else { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            let fetched = try await storeService.fetchProducts(ids: Set(Self.productIDs))
            let order = Self.productIDs
            products = fetched.sorted {
                (order.firstIndex(of: $0.id) ?? Int.max) < (order.firstIndex(of: $1.id) ?? Int.max)
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - 购买

    /// 买一个商品：购买 → redeem → finish → 刷新余额。
    /// 用户取消静默回闲置态，不是错误；未登录不买。
    public func purchase(productID: String) async {
        guard !isPurchasing, authViewModel.isSignedIn else { return }
        isPurchasing = true
        purchasingProductID = productID
        errorMessage = nil
        purchaseMessage = nil
        defer {
            isPurchasing = false
            purchasingProductID = nil
        }
        do {
            let purchased = try await storeService.purchase(
                productID: productID,
                appAccountToken: appAccountTokenFromSession()
            )
            await handleRedeemOutcome(await redeemAndFinish(purchased))
        } catch StoreServiceError.cancelled {
            return
        } catch StoreServiceError.unverified {
            errorMessage = "交易未通过验证，未记账"
        } catch StoreServiceError.pending {
            errorMessage = "购买待批准，通过后会自动到账"
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// appAccountToken = server JWT 的 sub（服务端用户 UUID）。
    /// sub 读不出或不是 UUID 时降级为 nil（服务端只做记账归属的弱关联，
    /// 退款归因退化——已在实现记录里写明，不偷偷降级）。
    private func appAccountTokenFromSession() -> UUID? {
        guard let token = session.serverToken,
              let sub = JWTSubject.subject(from: token) else { return nil }
        return UUID(uuidString: sub)
    }

    // MARK: - redeem + finish

    /// redeem 结果（内部：测试直接调 handleRedeemOutcome 用）。
    enum RedeemOutcome {
        case credited(balance: Int)
        case terminalNoCredit
        case retryable(message: String)
    }

    /// redeem 一笔交易后的结果处理（purchase 与监听共用同一口径）：
    /// .credited → 显示“已到账”并刷新余额（余额以服务端为准）；
    /// 其余只显示文案，不刷新。
    func handleRedeemOutcome(_ outcome: RedeemOutcome) async {
        switch outcome {
        case .credited(let balance):
            purchaseMessage = "已到账，余额 \(balance) 点"
            await authViewModel.refreshBalance()
        case .terminalNoCredit:
            errorMessage = "这笔交易已处理过，不再记账"
        case .retryable(let message):
            errorMessage = message
        }
    }

    /// redeem 一笔交易，成败都按判定表处理 finish。
    /// 200 → finish；409 → 不记账但 finish（终态）；其余失败都不 finish。
    private func redeemAndFinish(_ purchased: PurchasedTransaction) async -> RedeemOutcome {
        switch await attemptRedeem(purchased.jwsRepresentation) {
        case .success(let response):
            await purchased.finish()
            return .credited(balance: response.balance)
        case .failure(let error):
            if Self.shouldFinishAfterRedeemFailure(error) {
                await purchased.finish()
                return .terminalNoCredit
            }
            return .retryable(message: message(for: error))
        }
    }

    /// 发 redeem；401 → 静默重登一次再试，仍失败就把错原样带回。
    private func attemptRedeem(_ jws: String) async -> Result<BalanceResponse, any Error> {
        apiClient.token = session.serverToken
        do {
            return .success(try await apiClient.redeem(signedTransaction: jws))
        } catch APIClientError.unauthorized {
            guard await authViewModel.silentReLogin() else {
                return .failure(APIClientError.unauthorized)
            }
            apiClient.token = session.serverToken
            do {
                return .success(try await apiClient.redeem(signedTransaction: jws))
            } catch {
                return .failure(error)
            }
        } catch {
            return .failure(error)
        }
    }

    /// 纯函数：redeem 失败后要不要 finish。200 与 409 是终态，其余都留着重发。
    /// 不碰任何状态，标 nonisolated，单测可以直接调。
    nonisolated public static func shouldFinishAfterRedeemFailure(_ error: any Error) -> Bool {
        guard let apiError = error as? APIClientError else { return false }
        if case .server(let status) = apiError, status == 409 { return true }
        return false
    }

    private func message(for error: any Error) -> String {
        if let apiError = error as? APIClientError, apiError == .unauthorized {
            return "登录已过期，请重新登录后再试"
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: - 未完成交易监听

    /// 启动未完成交易监听：App 启动时调一次。StoreKit 会把上次没 finish 的
    /// 交易重新发出来，这里原样重发 redeem（服务端幂等），200 就 finish。
    public func startUnfinishedTransactionListener() {
        guard listenerTask == nil else { return }
        listenerTask = Task { [weak self] in
            // Transaction.updates 发的是 VerificationResult<Transaction>，
            // 不是裸 Transaction——先验签再决定。
            for await verification in Transaction.updates {
                guard let self else { return }
                switch verification {
                case .verified(let transaction):
                    let purchased = PurchasedTransaction(jwsRepresentation: verification.jwsRepresentation) {
                        await transaction.finish()
                    }
                    // 跟 purchase() 同一口径：到账了就刷新余额、显示文案；
                    // 之前这里直接丢了结果，监听重发到账后余额一直不刷（线上验收发现）。
                    await self.handleRedeemOutcome(await self.redeemAndFinish(purchased))
                case .unverified(let transaction, _):
                    // 验证不过的交易不记账；finish 清出队列，否则会一直重发。
                    await transaction.finish()
                }
            }
        }
    }
}
