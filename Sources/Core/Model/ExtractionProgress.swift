import Foundation

/// 解压进度。
public struct ExtractionProgress: Sendable {
    /// 已解压字节数。
    public let completedBytes: Int64
    /// 总字节数（由 header scan 阶段估算）。
    public let totalBytes: Int64
    /// 当前正在解压的条目路径。
    public let currentEntry: String

    public init(completedBytes: Int64, totalBytes: Int64, currentEntry: String) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.currentEntry = currentEntry
    }
}
