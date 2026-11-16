import CalmFrameKit
import Foundation
import Observation
import SwiftUI

/// 相框的状态机（@MainActor）：mood → 内置画，换画时做 3 秒 crossfade。
/// 不碰麦克风、不碰网络；远端画作（APIClient）本轮不接线（无真 JWT），
/// 离线画就是完整通路（方案节点 4）。
@MainActor
@Observable
public final class FrameViewModel {

    /// crossfade 时长（方案节点 4：≥ 3 秒，录屏计时）。
    public static let crossfadeDuration: TimeInterval = 3.0

    public private(set) var currentPainting: BundledPainting
    public private(set) var previousPainting: BundledPainting?
    public private(set) var transitionOpacity: Double = 1
    public var captionEnabled = true

    public private(set) var currentMood: Mood

    /// 铭牌文案（精确到字，方案节点 4）：`房间：<mood> · 正在展示：<title>`。
    public var nameplateText: String {
        "房间：\(currentMood.chineseName) · 正在展示：\(currentPainting.title)"
    }

    /// caption 开启时在铭牌下显示的一句话；关闭时不显示。
    public var captionText: String? {
        captionEnabled ? currentPainting.caption : nil
    }

    private let transitionDuration: TimeInterval
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?

    public init(initialMood: Mood = .calm, transitionDuration: TimeInterval = crossfadeDuration) {
        self.currentMood = initialMood
        self.currentPainting = BundledPaintings.painting(for: initialMood)
        self.transitionDuration = transitionDuration
    }

    /// mood 变化 → 换画：旧图留底、新图 3 秒淡入；淡入结束清掉旧图。
    /// 同一 mood 或 nil 不做任何事。
    public func setMood(_ mood: Mood?) {
        guard let mood, mood != currentMood else { return }
        previousPainting = currentPainting
        currentPainting = BundledPaintings.painting(for: mood)
        currentMood = mood
        transitionOpacity = 0
        withAnimation(.easeInOut(duration: transitionDuration)) {
            transitionOpacity = 1
        }
        cleanupTask?.cancel()
        cleanupTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(transitionDuration))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.previousPainting = nil
        }
    }
}
