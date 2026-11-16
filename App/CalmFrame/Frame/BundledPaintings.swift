import CalmFrameKit
import UIKit

/// 一张内置画（C5 离线兜底）：每 mood 1 张，共 5 张，calm 也有。
/// 画作均为 19 世纪风景油画的公共领域复制品（Wikimedia Commons），
/// 画家去世均已超过 70 年；标题与 caption 为本 App 的中文呈现。
public struct BundledPainting: Sendable, Equatable {
    public var mood: Mood
    public var imageName: String
    public var title: String
    public var artist: String
    public var caption: String
}

public enum BundledPaintings {
    public static let all: [BundledPainting] = [
        BundledPainting(
            mood: .calm, imageName: "calm",
            title: "干草车", artist: "约翰·康斯特布尔",
            caption: "田野安静下来，时间也慢了下来。"
        ),
        BundledPainting(
            mood: .hectic, imageName: "hectic",
            title: "雨、蒸汽和速度", artist: "约瑟夫·特纳",
            caption: "再快的车，也追不上窗外的云。"
        ),
        BundledPainting(
            mood: .noisy, imageName: "noisy",
            title: "暴风雪：汉尼拔越过阿尔卑斯山", artist: "约瑟夫·特纳",
            caption: "风雪再大，山还在那里。"
        ),
        BundledPainting(
            mood: .tenseQuiet, imageName: "tenseQuiet",
            title: "雾海上的漫游者", artist: "卡斯帕·弗里德里希",
            caption: "站得高一点，雾就低一点。"
        ),
        BundledPainting(
            mood: .drowsy, imageName: "drowsy",
            title: "日出·印象", artist: "克劳德·莫奈",
            caption: "天刚亮，世界还带着睡意。"
        ),
    ]

    /// mood → 内置画（全覆盖；找不到时回落到 calm，永不空手）。
    public static func painting(for mood: Mood) -> BundledPainting {
        all.first { $0.mood == mood } ?? all[0]
    }

    /// 从 bundle 读图（NSCache 兜底，避免 crossfade 每帧都读盘）。
    /// 图在 bundle 根目录；若以文件夹引用打进去，退到全 bundle 扫描。
    public static func image(for painting: BundledPainting) -> UIImage? {
        if let cached = cache.object(forKey: painting.imageName as NSString) {
            return cached
        }
        let url = Bundle.main.url(forResource: painting.imageName, withExtension: "jpg")
            ?? Bundle.main.urls(forResourcesWithExtension: "jpg", subdirectory: nil)?
                .first { $0.deletingPathExtension().lastPathComponent == painting.imageName }
        guard let url, let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
            return nil
        }
        cache.setObject(image, forKey: painting.imageName as NSString)
        return image
    }

    private static let cache = NSCache<NSString, UIImage>()
}
