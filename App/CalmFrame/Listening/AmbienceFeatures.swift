import Foundation

/// 一次 30 秒聆听窗口的声学特征。
///
/// 只在设备端使用：由 AmbienceListener（C2）在内存里算出，永不离开设备，
/// 不序列化、不写文件、不发网络。阈值语义见 `MoodThresholds`，分类规则见 `MoodClassifier`。
public struct AmbienceFeatures: Sendable, Equatable {
    /// 窗口内检测到打字声的时间占比，0…1。
    public var typingDensity: Double
    /// 窗口内检测到人声的时间占比，0…1。
    public var speechRatio: Double
    /// 窗口平均响度，dBFS（负值，越接近 0 越响）。
    public var meanDBFS: Double
    /// 窗口内是否出现突然安静（音量骤降事件）。
    public var quietDrop: Bool

    public init(typingDensity: Double, speechRatio: Double, meanDBFS: Double, quietDrop: Bool) {
        self.typingDensity = typingDensity
        self.speechRatio = speechRatio
        self.meanDBFS = meanDBFS
        self.quietDrop = quietDrop
    }
}
