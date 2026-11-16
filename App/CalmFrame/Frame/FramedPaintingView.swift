import SwiftUI

/// 相框本体（C4，方案节点 4）：鎏金框 + crossfade 画作 + 铭牌 + caption。
/// 首页与相框模式共用这一个视图；区别只在外层是否隐藏控件、禁锁屏。
struct FramedPaintingView: View {
    let viewModel: FrameViewModel

    var body: some View {
        ZStack {
            // 墙面：深暖灰，画框浮在上面。
            Color(red: 0.07, green: 0.06, blue: 0.05)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                paintingArea
                nameplate
            }
            .frame(maxWidth: 640)
            .padding(14)
            .background(goldGradient, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.black.opacity(0.45), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.6), radius: 24, y: 12)
            .padding()
        }
    }

    private var goldGradient: some ShapeStyle {
        LinearGradient(
            colors: [
                Color(red: 0.55, green: 0.42, blue: 0.16),
                Color(red: 0.85, green: 0.68, blue: 0.25),
                Color(red: 0.96, green: 0.87, blue: 0.55),
                Color(red: 0.72, green: 0.55, blue: 0.18),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// 画作区：旧图留底、新图按 transitionOpacity 淡入（3 秒）。
    /// 图没加载出来时是深色底，永不白屏。
    private var paintingArea: some View {
        // 尺寸由 4:3 的占位色块决定；图片放在 overlay 里，scaledToFill 的
        // 溢出不会再把外层撑出屏幕（之前画作左右溢出、金框侧边被挤没）。
        Color(red: 0.12, green: 0.10, blue: 0.08)
            .aspectRatio(4 / 3, contentMode: .fit)
            .overlay {
                ZStack {
                    if let previous = viewModel.previousPainting,
                       let image = BundledPaintings.image(for: previous) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    }
                    if let image = BundledPaintings.image(for: viewModel.currentPainting) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .opacity(viewModel.transitionOpacity)
                    }
                }
            }
            .clipped()
            .overlay(Rectangle().stroke(.black.opacity(0.5), lineWidth: 2))
    }

    /// 铭牌：深铜底 + 金字；caption 开启时在下一行显示一句话。
    private var nameplate: some View {
        VStack(spacing: 4) {
            Text(viewModel.nameplateText)
                .font(.system(.headline, design: .serif))
                .foregroundStyle(Color(red: 0.92, green: 0.85, blue: 0.62))
                .multilineTextAlignment(.center)
            if let caption = viewModel.captionText {
                Text(caption)
                    .font(.system(.subheadline, design: .serif))
                    .italic()
                    .foregroundStyle(Color(red: 0.92, green: 0.85, blue: 0.62).opacity(0.8))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .background(Color(red: 0.16, green: 0.12, blue: 0.07))
    }
}
