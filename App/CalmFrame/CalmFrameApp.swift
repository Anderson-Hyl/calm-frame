import SwiftUI

/// 调试页路由。启动参数 `--debug` 可直接进调试页（用于截图验证）。
enum DebugRoute: Hashable {
    case debug
}

@main
struct CalmFrameApp: App {
    @StateObject private var listeningViewModel = ListeningViewModel()
    @State private var path = NavigationPath()

    var body: some Scene {
        WindowGroup {
            NavigationStack(path: $path) {
                FrameView()
                    .navigationDestination(for: DebugRoute.self) { _ in
                        DebugView(viewModel: listeningViewModel)
                    }
            }
            .onAppear {
                if CommandLine.arguments.contains("--debug") && path.isEmpty {
                    path.append(DebugRoute.debug)
                }
            }
        }
    }
}
