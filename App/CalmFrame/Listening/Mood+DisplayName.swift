import CalmFrameKit
import Foundation

/// Mood 的中文显示（放客户端，不进 Kit，见共享契约）。
/// 铭牌格式：`房间：<mood> · 正在展示：<title>`。
public extension Mood {
    var chineseName: String {
        switch self {
        case .hectic: return "忙乱"
        case .noisy: return "嘈杂"
        case .tenseQuiet: return "紧绷的安静"
        case .drowsy: return "犯困"
        case .calm: return "平静"
        }
    }
}
