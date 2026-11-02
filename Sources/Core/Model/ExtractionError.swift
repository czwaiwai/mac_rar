import Foundation

/// 解压过程中可能抛出的领域错误。
public enum ExtractionError: Error, LocalizedError {
    /// 归档文件不存在。
    case archiveNotFound(URL)
    /// 不支持的格式 / 分卷。
    case unsupportedFormat(String)
    /// 数据损坏 / 分卷缺失。
    case corruptedArchive(String)
    /// 需要密码但用户取消。
    case passwordRequired
    /// 密码错误。
    case passwordIncorrect
    /// 路径穿越（entry 名）。
    case pathTraversalAttempt(String)
    /// 磁盘不足。
    case diskFull
    /// 目标冲突且无法命名。
    case targetExists(URL)
    /// 底层解压引擎错误。
    case underlying(Error)

    public var errorDescription: String? {
        switch self {
        case .archiveNotFound(let url):
            return "归档不存在：\(url.lastPathComponent)"
        case .unsupportedFormat(let name):
            return "不支持的格式：\(name)"
        case .corruptedArchive(let name):
            return "归档损坏或分卷缺失：\(name)"
        case .passwordRequired:
            return "需要密码"
        case .passwordIncorrect:
            return "密码错误"
        case .pathTraversalAttempt(let path):
            return "检测到非法路径：\(path)"
        case .diskFull:
            return "磁盘空间不足"
        case .targetExists(let url):
            return "目标已存在：\(url.lastPathComponent)"
        case .underlying(let error):
            return error.localizedDescription
        }
    }
}
