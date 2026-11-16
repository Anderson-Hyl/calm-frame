import SwiftUI

/// 相框首页（C4）：画框 + 铭牌 + caption；右上角进调试页、进相框模式。
/// mood 变化由 ListeningViewModel 驱动，FrameViewModel 只管画作切换。
struct FrameView: View {
    let listeningViewModel: ListeningViewModel
    let frameViewModel: FrameViewModel
    var autoFrameMode: Bool = false

    @State private var showingFrameMode = false

    var body: some View {
        FramedPaintingView(viewModel: frameViewModel)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("相框") { showingFrameMode = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink("调试", value: DebugRoute.debug)
                }
            }
            .fullScreenCover(isPresented: $showingFrameMode) {
                FrameModeView(viewModel: frameViewModel)
            }
            .onChange(of: listeningViewModel.currentMood) { _, newMood in
                frameViewModel.setMood(newMood)
            }
            .onAppear {
                frameViewModel.setMood(listeningViewModel.currentMood)
                if autoFrameMode {
                    showingFrameMode = true
                }
            }
    }
}

#Preview {
    FrameView(
        listeningViewModel: ListeningViewModel(),
        frameViewModel: FrameViewModel()
    )
}
