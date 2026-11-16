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
}

@main
struct CalmFrameApp: App {
    @StateObject private var listeningViewModel: ListeningViewModel
    @StateObject private var frameViewModel = FrameViewModel()
    @StateObject private var authViewModel: AuthViewModel
    @State private var path = NavigationPath()

    private let mockConfiguration: MockListeningConfiguration?
    private let autoFrameMode: Bool

    init() {
        mockConfiguration = MockListeningConfiguration.fromArguments()
        autoFrameMode = CommandLine.arguments.contains("--frame-mode")
        // 真机联调用：--api-base-url <url> 覆盖服务端地址（默认 localhost:8080 只在
        // 模拟器上通，真机上的 localhost 是手机自己）。不用这个参数时行为不变。
        let apiBaseURL = CalmFrameApp.apiBaseURLFromArguments() ?? AuthViewModel.localBaseURL
        _authViewModel = StateObject(wrappedValue: AuthViewModel(baseURL: apiBaseURL))
        let engine: any ListeningEngine
        if let mock = mockConfiguration {
            engine = MockListeningEngine(moods: mock.moods, cycleSeconds: mock.cycleSeconds)
        } else {
            engine = AmbienceListener()
        }
        _listeningViewModel = StateObject(wrappedValue: ListeningViewModel(engine: engine))
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
                        authViewModel: authViewModel
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
            }
        }
    }
}
