import Foundation

/// 路径穿越校验（Zip Slip 的 RAR 变体），纯函数。
public struct PathSafetyValidator {

    /// 校验失败的具体原因。
    public enum ValidationError: Error, LocalizedError, Equatable, Sendable {
        case emptyPath
        case absolutePath(String)
        case traversal(String)
        case symlink(String)
        case escapeTarget(String)

        public var errorDescription: String? {
            switch self {
            case .emptyPath: return "空路径"
            case .absolutePath(let p): return "绝对路径：\(p)"
            case .traversal(let p): return "包含 .. 的路径：\(p)"
            case .symlink(let p): return "符号链接：\(p)"
            case .escapeTarget(let p): return "路径越界：\(p)"
            }
        }
    }

    /// 校验 entry 路径是否安全，返回规范化后的相对路径（不含前导 `/`）。
    ///
    /// 规则：
    /// 1. 拒绝空路径、绝对路径、含 `..` 组件的路径；
    /// 2. 默认拒绝符号链接 entry；
    /// 3. 返回去除前导斜杠后的相对路径。
    public static func validate(
        entryPath: String,
        isSymbolicLink: Bool = false
    ) throws -> String {
        if isSymbolicLink {
            throw ValidationError.symlink(entryPath)
        }
        if entryPath.isEmpty {
            throw ValidationError.emptyPath
        }

        // 统一 Windows 反斜杠分隔符（RAR 常见）。
        let normalized = entryPath.replacingOccurrences(of: "\\", with: "/")
        if normalized.hasPrefix("/") {
            throw ValidationError.absolutePath(entryPath)
        }

        let components = normalized.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if components.contains("..") {
            throw ValidationError.traversal(entryPath)
        }
        // 路径末尾的 "."（如 "a/."）也视为可疑。
        if components.contains(".") {
            throw ValidationError.traversal(entryPath)
        }

        return components.joined(separator: "/")
    }

    /// 校验 entry 路径并拼接为落盘 URL，做标准化后越界双保险校验。
    ///
    /// - Returns: 位于 `targetDir` 内的安全目标 URL。
    public static func resolveSafely(
        entryPath: String,
        relativeTo targetDir: URL,
        isSymbolicLink: Bool = false
    ) throws -> URL {
        let relative = try validate(entryPath: entryPath, isSymbolicLink: isSymbolicLink)
        guard !relative.isEmpty else {
            throw ValidationError.emptyPath
        }

        let target = targetDir.appendingPathComponent(relative).standardizedFileURL
        let dirPath = targetDir.standardizedFileURL.path
        let prefix = dirPath.hasSuffix("/") ? dirPath : dirPath + "/"

        guard target.path == dirPath || target.path.hasPrefix(prefix) else {
            throw ValidationError.escapeTarget(entryPath)
        }
        return target
    }
}
