import SwiftUI

/// 相框模式（C4）：全屏、无任何控件、禁锁屏。
/// 点画面本轮什么都不做（呼吸引导是 W3 任务 21）；
/// 退出靠系统手势（Home / 切 App），验证时用启动参数 `--frame-mode` 直接进入。
struct FrameModeView: View {
    @ObservedObject var viewModel: FrameViewModel

    var body: some View {
        FramedPaintingView(viewModel: viewModel)
            .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}
