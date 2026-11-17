import CalmFrameKit
import XCTest

@testable import CalmFrame

/// 购买切片的单测：JWT sub 提取、finish 判定、StoreViewModel 购买流程。
/// 真 StoreKit 不在这里测（B-store-6 用模拟器 .storekit 与真机沙盒验）。
final class StoreTests: XCTestCase {

    // MARK: - JWT sub

    func testJWTSubjectExtractsSub() {
        let token = fakeJWT(sub: "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(JWTSubject.subject(from: token), "11111111-2222-3333-4444-555555555555")
    }

    func testJWTSubjectRejectsMalformedTokens() {
        XCTAssertNil(JWTSubject.subject(from: "not-a-jwt"))
        XCTAssertNil(JWTSubject.subject(from: "a.b"))
        XCTAssertNil(JWTSubject.subject(from: "a.!!!.c"))
        XCTAssertNil(JWTSubject.subject(from: fakeJWT(payload: "{}")))
        XCTAssertNil(JWTSubject.subject(from: fakeJWT(payload: "{\"sub\":\"\"}")))
        XCTAssertNil(JWTSubject.subject(from: fakeJWT(payload: "{\"sub\":123}")))
    }

    // MARK: - finish 判定

    func testFinishDecision() {
        XCTAssertTrue(StoreViewModel.shouldFinishAfterRedeemFailure(APIClientError.server(status: 409)))
        XCTAssertFalse(StoreViewModel.shouldFinishAfterRedeemFailure(APIClientError.server(status: 422)))
        XCTAssertFalse(StoreViewModel.shouldFinishAfterRedeemFailure(APIClientError.server(status: 500)))
        XCTAssertFalse(StoreViewModel.shouldFinishAfterRedeemFailure(APIClientError.network("down")))
        XCTAssertFalse(StoreViewModel.shouldFinishAfterRedeemFailure(APIClientError.unauthorized))
        XCTAssertFalse(StoreViewModel.shouldFinishAfterRedeemFailure(APIClientError.decoding))
        XCTAssertFalse(StoreViewModel.shouldFinishAfterRedeemFailure(NSError(domain: "x", code: 1)))
    }

    // MARK: - 商品

    @MainActor
    func testLoadProductsSortsByPlanOrder() async {
        let store = MockStoreService()
        store.products = [
            StoreProduct(id: "credits.50", displayName: "50 点", displayPrice: "¥25.00"),
            StoreProduct(id: "credits.10", displayName: "10 点", displayPrice: "¥6.00"),
        ]
        let (viewModel, _, _) = makeViewModelWithStub(store: store)
        await viewModel.loadProducts()
        XCTAssertEqual(viewModel.products.map(\.id), ["credits.10", "credits.50"])
    }

    /// 真 StoreKit + .storekit 配置：两个商品能拉出来（id 为准；显示名与
    /// 价格只断非空——它们随模拟器 locale 走，zh-Hans 下是“10 点 / ¥6.00”）。
    /// 这条测试只在 scheme 的 Test 动作挂了 CalmFrame.storekit 时才过；
    /// 没有配置时 Product.products(for:) 在模拟器上返回空数组。
    func testLiveStoreServiceLoadsProductsFromStoreKitConfiguration() async throws {
        let service = LiveStoreService()
        let products = try await service.fetchProducts(ids: ["credits.10", "credits.50"])
        XCTAssertEqual(Set(products.map(\.id)), ["credits.10", "credits.50"])
        for product in products {
            XCTAssertFalse(product.displayName.isEmpty)
            XCTAssertFalse(product.displayPrice.isEmpty)
        }
        // 注意：这里不直接断 Product.price 的 Decimal 值。实测：.storekit 里
        // 配的 6 / 25（CHN storefront，¥6 / ¥25）到了没登沙盒账号的模拟器上
        // 会按 App Store 价格档位换算成美区等价值（0.99 / 3.99 美元），
        // displayPrice 显示 US$0.99 / US$3.99——这是模拟器地区（未登录，
        // 默认美区店面）的换算，不是配置错。上线后用户看到的价格以
        // App Store Connect 里建的商品为准（¥6 / ¥25），不在 .storekit 里定。
    }

    // MARK: - 购买流程

    @MainActor
    func testPurchaseSuccessFinishesAndRefreshesBalance() async {
        let store = MockStoreService()
        store.purchaseJWS = "fake-jws-10"
        let (viewModel, authViewModel, stub) = makeViewModelWithStub(store: store)
        stub.redeemHandler = { _ in (200, Data("{\"balance\":15}".utf8)) }
        await viewModel.purchase(productID: "credits.10")
        XCTAssertEqual(store.finishCallCount, 1)
        XCTAssertEqual(viewModel.purchaseMessage, "已到账，余额 15 点")
        XCTAssertNil(viewModel.errorMessage)
        // 余额以服务端为准：购买后调 refreshBalance，GET /v1/credits 桩回 15。
        XCTAssertEqual(authViewModel.balance, 15)
    }

    @MainActor
    func testPurchaseSendsAppAccountTokenFromJWTSub() async {
        let store = MockStoreService()
        let (viewModel, _, _) = makeViewModelWithStub(store: store, sub: "11111111-2222-3333-4444-555555555555")
        await viewModel.purchase(productID: "credits.10")
        XCTAssertEqual(store.lastAppAccountToken?.uuidString, "11111111-2222-3333-4444-555555555555")
    }

    @MainActor
    func testRedeem409FinishesWithoutCredit() async {
        let store = MockStoreService()
        let (viewModel, _, stub) = makeViewModelWithStub(store: store)
        stub.redeemHandler = { _ in (409, Data()) }
        await viewModel.purchase(productID: "credits.10")
        XCTAssertEqual(store.finishCallCount, 1)
        XCTAssertEqual(viewModel.errorMessage, "这笔交易已处理过，不再记账")
    }

    @MainActor
    func testRedeem422DoesNotFinish() async {
        let store = MockStoreService()
        let (viewModel, _, stub) = makeViewModelWithStub(store: store)
        stub.redeemHandler = { _ in (422, Data()) }
        await viewModel.purchase(productID: "credits.10")
        XCTAssertEqual(store.finishCallCount, 0)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    @MainActor
    func testUserCancelledIsQuiet() async {
        let store = MockStoreService()
        store.purchaseError = StoreServiceError.cancelled
        let (viewModel, _, _) = makeViewModelWithStub(store: store)
        await viewModel.purchase(productID: "credits.10")
        XCTAssertEqual(store.finishCallCount, 0)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.purchaseMessage)
    }

    @MainActor
    func testUnverifiedDoesNotRedeemOrFinish() async {
        let store = MockStoreService()
        store.purchaseError = StoreServiceError.unverified
        let (viewModel, _, stub) = makeViewModelWithStub(store: store)
        stub.redeemHandler = { _ in XCTFail("unverified must not reach redeem"); return (200, Data()) }
        await viewModel.purchase(productID: "credits.10")
        XCTAssertEqual(store.finishCallCount, 0)
        XCTAssertEqual(viewModel.errorMessage, "交易未通过验证，未记账")
    }

    @MainActor
    func testRedeem401RetriesAfterSilentReLogin() async {
        let store = MockStoreService()
        let (viewModel, _, stub) = makeViewModelWithStub(store: store)
        let counter = Counter()
        stub.redeemHandler = { _ in
            counter.value += 1
            return counter.value == 1 ? (401, Data()) : (200, Data("{\"balance\":15}".utf8))
        }
        await viewModel.purchase(productID: "credits.10")
        XCTAssertEqual(counter.value, 2)
        XCTAssertEqual(store.finishCallCount, 1)
        XCTAssertEqual(viewModel.purchaseMessage, "已到账，余额 15 点")
    }

    // MARK: - 搭建

    /// 造一个已登录的 view model：session 里放一个 sub 为给定 UUID 的假 JWT。
    @MainActor
    private func makeViewModelWithStub(
        store: MockStoreService,
        sub: String = "11111111-2222-3333-4444-555555555555"
    ) -> (StoreViewModel, AuthViewModel, StubURLProtocol.Type) {
        let session = SessionStore(keychain: InMemoryKeychainStore())
        session.save(token: fakeJWT(sub: sub), appleSub: "mock-apple-sub", balance: 5)
        let stubSession = Self.stubSession()
        let authViewModel = AuthViewModel(
            authService: MockAuthService(),
            session: session,
            baseURL: URL(string: "https://example.invalid")!,
            urlSession: stubSession
        )
        let viewModel = StoreViewModel(
            storeService: store,
            session: session,
            authViewModel: authViewModel,
            baseURL: URL(string: "https://example.invalid")!,
            urlSession: stubSession
        )
        return (viewModel, authViewModel, StubURLProtocol.self)
    }

    /// 桩 session：/v1/auth/apple 永远 200（换新 token）；GET /v1/credits 桩回 15；
    /// redeem 走每个测试自己设的 redeemHandler。
    private static func stubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.reset()
        return URLSession(configuration: config)
    }
}

// MARK: - 测试桩

/// 拦截 URLSession 的桩：按路径返回 canned 响应。只在测试 target 里。
/// handler 挂在静态属性上（URLProtocol 实例由系统创建，实例属性带不过去）。
final class StubURLProtocol: URLProtocol {
    /// 每个测试自己设：redeem 返回 (status, body)。
    static var redeemHandler: ((URLRequest) -> (Int, Data))?

    static func reset() {
        redeemHandler = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        let path = request.url?.path ?? ""
        let (status, data): (Int, Data)
        switch (request.httpMethod, path) {
        case ("POST", "/v1/auth/apple"):
            // 换新 token：sub 不变，balance 5。
            let body = "{\"token\":\"\(fakeJWT(sub: "11111111-2222-3333-4444-555555555555"))\",\"balance\":5}"
            (status, data) = (200, Data(body.utf8))
        case ("GET", "/v1/credits"):
            (status, data) = (200, Data("{\"balance\":15}".utf8))
        case ("POST", "/v1/credits/redeem"):
            (status, data) = Self.redeemHandler?(request) ?? (500, Data())
        default:
            (status, data) = (404, Data())
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// 计数器（引用类型）：桩闭包在 URLSession 的线程上跑，计数的可变状态
/// 放引用里，不直接捕获测试方法的局部 var。
private final class Counter {
    var value = 0
}

// MARK: - 假 JWT（测试用：alg none，只走通路，不验签）

private func fakeJWT(sub: String) -> String {
    fakeJWT(payload: "{\"sub\":\"\(sub)\"}")
}

private func fakeJWT(payload: String) -> String {
    func b64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    let header = b64url(Data("{\"alg\":\"none\"}".utf8))
    return "\(header).\(b64url(Data(payload.utf8))).sig"
}
