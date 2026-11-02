import Foundation

/// 解压引擎协议（Port / 抽象）。
public protocol ExtractEngine: Sendable {
    /// 解压单个归档到目标目录，返回最终输出目录 URL。
    /// - Parameters:
    ///   - request: 解压请求
    ///   - progress: 进度回调（主线程派发）
    ///   - passwordProvider: 需要密码时被调用；返回 nil 表示用户取消
    /// - Throws: ExtractionError
    func extract(
        _ request: ExtractionRequest,
        progress: @escaping @Sendable (ExtractionProgress) -> Void,
        passwordProvider: @escaping @Sendable () async throws -> String?
    ) async throws -> ExtractionResult
}
