import SwiftUI

/// 调试页路由。启动参数 `--debug` 可直接进调试页（用于截图验证）。
enum DebugRoute: Hashable {
    case debug
}

@main
struct CalmFrameApp: App {
    @StateObject private var listeningViewModel: ListeningViewModel
    @StateObject private var frameViewModel = FrameViewModel()
    @StateObject private var authViewModel = AuthViewModel()
    @State private var path = NavigationPath()

    private let mockConfiguration: MockListeningConfiguration?
    private let autoFrameMode: Bool

    init() {
        mockConfiguration = MockListeningConfiguration.fromArguments()
        autoFrameMode = CommandLine.arguments.contains("--frame-mode")
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
