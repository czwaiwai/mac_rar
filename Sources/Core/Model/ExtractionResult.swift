import Foundation

/// 命名判定结果。
public enum NamingDecision: Sendable, Equatable {
    /// 单顶层文件夹，原样输出（不额外包一层）。
    case singleTopLevelFolder(name: String)
    /// 新建文件夹（名已含序号消歧）。
    case newFolder(name: String)
}

/// 解压结果。
public struct ExtractionResult: Sendable {
    /// 最终落盘目录。
    public let outputURL: URL
    /// 解压出的文件数。
    public let extractedFileCount: Int
    /// 总字节数。
    public let totalBytes: Int64
    /// 命名判定结果。
    public let namingDecision: NamingDecision

    public init(
        outputURL: URL,
        extractedFileCount: Int,
        totalBytes: Int64,
        namingDecision: NamingDecision
    ) {
        self.outputURL = outputURL
        self.extractedFileCount = extractedFileCount
        self.totalBytes = totalBytes
        self.namingDecision = namingDecision
    }
}
