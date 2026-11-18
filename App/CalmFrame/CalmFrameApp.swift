import StoreKit
import SwiftUI

/// 调试页路由。启动参数 `--debug` 可直接进调试页（用于截图验证）。
enum DebugRoute: Hashable {
    case debug
}

extension CalmFrameApp {
    /// 从启动参数读 `--api-base-url <url>`；没有或非法则返回 nil（调用方用默认值）。
    static func apiBaseURLFromArguments(_ arguments: [String] = CommandLine.arguments) -> URL? {
        guard let index = arguments.firstIndex(of: "--api-base-url"),
              index + 1 < arguments.count,
              let url = URL(string: arguments[index + 1]),
              url.scheme != nil, url.host != nil
        else { return nil }
        return url
    }

    /// 从启动参数读 `--dump-jws <transaction-id>`；没有或非法则返回 nil。
    /// 一次性调试口子：只在显式传参时才把该交易的 JWS 打到 stdout，抓完即删。
    static func dumpJWSTransactionID(from arguments: [String] = CommandLine.arguments) -> UInt64? {
        guard let index = arguments.firstIndex(of: "--dump-jws"),
              index + 1 < arguments.count,
              let id = UInt64(arguments[index + 1])
        else { return nil }
        return id
    }

    /// 一次性调试：按商品取最新一笔交易，核对 id 后把它的 jwsRepresentation
    /// 打到 stdout（前缀 JWS_DUMP:），抓完即删。
    /// 只在显式传 `--dump-jws <id>` 时跑；找不到就打 JWS_DUMP:NOT_FOUND。
    /// 注意：StoreKit 2 没有 Transaction.history（只有 currentEntitlements /
    /// updates / latest(for:)）；已 finish 的消耗型交易只能用 latest(for:)
    /// 按商品取最新一笔再按 id 核对（本 App 只有 credits.10 / credits.50）。
    /// 注意：Transaction 在 SwiftUI 与 StoreKit 里都有同名类型，必须写全 StoreKit.Transaction。
    static func dumpJWS(forTransactionID targetID: UInt64) async {
        for productID in StoreViewModel.productIDs {
            guard let verification = await StoreKit.Transaction.latest(for: productID) else { continue }
            switch verification {
            case .verified(let transaction):
                if transaction.id == targetID {
                    print("JWS_DUMP:\(verification.jwsRepresentation)")
                    return
                }
            case .unverified:
                continue
            }
        }
        print("JWS_DUMP:NOT_FOUND")
    }
}

@main
struct CalmFrameApp: App {
    @State private var listeningViewModel: ListeningViewModel
    @State private var frameViewModel = FrameViewModel()
    @State private var authViewModel: AuthViewModel
    @State private var storeViewModel: StoreViewModel
    @State private var path = NavigationPath()

    private let mockConfiguration: MockListeningConfiguration?
    private let autoFrameMode: Bool

    init() {
        mockConfiguration = MockListeningConfiguration.fromArguments()
        autoFrameMode = CommandLine.arguments.contains("--frame-mode")
        // 真机联调用：--api-base-url <url> 覆盖服务端地址（默认 localhost:8080 只在
        // 模拟器上通，真机上的 localhost 是手机自己）。不用这个参数时行为不变。
        let apiBaseURL = CalmFrameApp.apiBaseURLFromArguments() ?? AuthViewModel.localBaseURL
        // 购买切片：AuthViewModel 与 StoreViewModel 共用同一个 SessionStore——
        // token 只有一份来源（Keychain），静默重登换新 token 后两边都读到新的。
        let session = SessionStore()
        let authVM = AuthViewModel(session: session, baseURL: apiBaseURL)
        _authViewModel = State(wrappedValue: authVM)
        _storeViewModel = State(wrappedValue: StoreViewModel(session: session, authViewModel: authVM, baseURL: apiBaseURL))
        let engine: any ListeningEngine
        if let mock = mockConfiguration {
            engine = MockListeningEngine(moods: mock.moods, cycleSeconds: mock.cycleSeconds)
        } else {
            engine = AmbienceListener()
        }
        _listeningViewModel = State(wrappedValue: ListeningViewModel(engine: engine))
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack(path: $path) {
                FrameView(
                    listeningViewModel: listeningViewModel,
                    frameViewModel: frameViewModel,
                    autoFrameMode: autoFrameMode
                )
                .navigationDestination(for: DebugRoute.self) { _ in
                    DebugView(
                        viewModel: listeningViewModel,
                        frameViewModel: frameViewModel,
                        authViewModel: authViewModel,
                        storeViewModel: storeViewModel
                    )
                }
            }
            .onAppear {
                if CommandLine.arguments.contains("--debug") && path.isEmpty {
                    path.append(DebugRoute.debug)
                }
                if mockConfiguration != nil {
                    // mock 不用麦克风：跳过说明页，直接开始聆听。
                    listeningViewModel.hasShownExplainer = true
                    listeningViewModel.startListening()
                }
                Task { await authViewModel.restoreSession() }
                storeViewModel.startUnfinishedTransactionListener()
                // 一次性调试口子：--dump-jws <交易ID> 时把该交易的 JWS 打到 stdout，
                // 供服务端重放 fixture 用；抓完即删（见 client-plan-round3-followup.md）。
                if let dumpID = CalmFrameApp.dumpJWSTransactionID() {
                    Task { await CalmFrameApp.dumpJWS(forTransactionID: dumpID) }
                }
            }
        }
    }
}
