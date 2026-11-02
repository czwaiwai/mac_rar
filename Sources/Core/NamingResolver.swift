import Foundation

/// 命名判定（单顶层文件夹 vs 新建文件夹 + 序号消歧）。
///
/// 严格按架构文档 4.4 伪代码：
/// - 单顶层文件夹 → 原样输出该文件夹，不额外包一层；
/// - 多个顶层条目 / 单个顶层文件 → 新建文件夹（名 = basename 去扩展名）；
/// - 冲突时追加序号（Name 2, Name 3, ...）。
public struct NamingResolver {

    /// 判定结果。
    public struct ResolvedNaming: Sendable, Equatable {
        /// 命名决策。
        public let decision: NamingDecision
        /// 最终落盘目录（已含序号消歧）。
        public let outputURL: URL
    }

    /// 执行命名判定。
    ///
    /// - Parameters:
    ///   - archiveURL: 归档文件 URL。
    ///   - topLevelEntries: header scan 得到的顶层条目路径列表（目录条目以 `/` 结尾）。
    ///   - destinationDirectory: 最终输出目录的父目录（默认 archiveURL.deletingLastPathComponent()）。
    ///   - fileExists: 文件存在性判定（默认 FileManager.default.fileExists），供测试注入。
    public static func resolve(
        archiveURL: URL,
        topLevelEntries: [String],
        destinationDirectory: URL? = nil,
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> ResolvedNaming {
        let destination = destinationDirectory ?? archiveURL.deletingLastPathComponent()

        // 去重（保序）每个 entry 的首段路径组件。
        var seen: Set<String> = []
        var topLevel: [String] = []
        for entry in topLevelEntries {
            let component = firstComponent(of: entry)
            if seen.insert(component).inserted {
                topLevel.append(component)
            }
        }

        if topLevel.count == 1, isDirectoryEntry(named: topLevel[0], in: topLevelEntries) {
            let folderName = topLevel[0]
            let finalURL = uniquify(
                destination.appendingPathComponent(folderName),
                fileExists: fileExists
            )
            return ResolvedNaming(
                decision: .singleTopLevelFolder(name: folderName),
                outputURL: finalURL
            )
        } else {
            // 情形 2：分卷主卷（split.part1.rar）应输出 baseName "split" 而非 "split.part1"；
            // 普通 .rar 直接去掉扩展名；非 RAR 兜底用 deletingPathExtension。
            let base = SplitArchiveDetector.detect(archiveURL).baseName
                ?? archiveURL.deletingPathExtension().lastPathComponent
            let finalURL = uniquify(
                destination.appendingPathComponent(base),
                fileExists: fileExists
            )
            return ResolvedNaming(
                decision: .newFolder(name: base),
                outputURL: finalURL
            )
        }
    }

    // MARK: - 内部

    /// 提取 entry 路径的首段组件（去除前导 `/`、尾部 `/`）。
    private static func firstComponent(of entryPath: String) -> String {
        var path = entryPath
        while path.hasPrefix("/") { path.removeFirst() }
        if let slash = path.firstIndex(of: "/") {
            return String(path[..<slash])
        }
        return path
    }

    /// 判定某顶层组件是否为目录：存在以该组件为目录的 entry（路径为 "name/"）。
    private static func isDirectoryEntry(named name: String, in entries: [String]) -> Bool {
        entries.contains { entry in
            var p = entry
            while p.hasPrefix("/") { p.removeFirst() }
            return p == name + "/"
        }
    }

    /// 序号消歧：Name, Name 2, Name 3, ...（对齐 Finder 风格）。
    private static func uniquify(
        _ candidate: URL,
        fileExists: @escaping @Sendable (String) -> Bool
    ) -> URL {
        var result = candidate
        var counter = 2
        while fileExists(result.path) {
            let dir = candidate.deletingLastPathComponent()
            let base = candidate.lastPathComponent
            result = dir.appendingPathComponent("\(base) \(counter)")
            counter += 1
        }
        return result
    }
}
