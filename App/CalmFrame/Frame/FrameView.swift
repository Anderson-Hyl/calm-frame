import SwiftUI

/// C1 空壳相框：占位色块 + 铭牌占位。业务逻辑（聆听、分类器、真画作、crossfade）
/// 在后续节点里接进来，本文件只保证工程能跑起来。
struct FrameView: View {
    var body: some View {
        ZStack {
            Color(red: 0.12, green: 0.10, blue: 0.08)
            VStack(spacing: 12) {
                Text("房间：— · 正在展示：—")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Calm Frame · 占位")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .ignoresSafeArea()
    }
}

#Preview {
    FrameView()
}
