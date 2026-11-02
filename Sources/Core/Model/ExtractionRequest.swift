import Foundation

/// 解压请求。
public struct ExtractionRequest: Sendable {
    /// 归档文件 URL。
    public let archiveURL: URL
    /// 最终输出目录的父目录（默认 = archiveURL.deletingLastPathComponent()）。
    public let destinationDirectory: URL
    /// 预置密码（可空）。
    public var password: String?
    /// 分卷主卷标记（由 SplitArchiveDetector 填入）。
    public let isSplit: Bool

    public init(
        archiveURL: URL,
        destinationDirectory: URL? = nil,
        password: String? = nil,
        isSplit: Bool = false
    ) {
        self.archiveURL = archiveURL
        self.destinationDirectory = destinationDirectory ?? archiveURL.deletingLastPathComponent()
        self.password = password
        self.isSplit = isSplit
    }
}
