import Foundation

/// 分卷识别（RAR 多卷命名）。
///
/// 命名模式：
/// - 新式：`name.part1.rar` / `name.part01.rar` → `^(.*)\.part(\d+)\.rar$`
/// - 旧式：`name.r00`（配合 `name.rar`）→ `^(.*)\.r(\d{2})$`
///
/// 策略：仅当双击主卷（`name.rar` 或 `name.part1.rar`）时启动；`.part2+` / `.r01+` 忽略。
public struct SplitArchiveDetector {

    /// 分卷分类。
    public enum Classification: Sendable, Equatable {
        /// 分卷主卷（`name.part1.rar`）。
        case mainVolume(baseName: String)
        /// 后续卷（`name.partN.rar`，N ≥ 2），应忽略。
        case partContinuation(baseName: String)
        /// 旧式后续卷（`name.rNN`），应忽略。
        case oldContinuation(baseName: String)
        /// 普通单卷 `.rar`（也可能是旧式分卷主卷）。
        case singleArchive(baseName: String)
        /// 非 RAR 文件。
        case notRAR
    }

    /// 检测结果。
    public struct Detection: Sendable, Equatable {
        public let classification: Classification

        /// 是否应启动解压（主卷 / 普通单卷）。
        public var shouldProcess: Bool {
            switch classification {
            case .mainVolume, .singleArchive:
                return true
            case .partContinuation, .oldContinuation, .notRAR:
                return false
            }
        }

        /// 是否为分卷主卷。
        public var isSplit: Bool {
            if case .mainVolume = classification { return true }
            return false
        }

        /// 归档基名（去掉 `.rar` / `.partN` / `.rNN`）。
        /// 例如 `split.part1.rar` → `split`、`split.rar` → `split`、`split.r00` → `split`。
        /// 非 RAR 文件返回 `nil`。
        public var baseName: String? {
            switch classification {
            case .mainVolume(let name),
                 .partContinuation(let name),
                 .oldContinuation(let name),
                 .singleArchive(let name):
                return name
            case .notRAR:
                return nil
            }
        }
    }

    private static let partRegex = try! NSRegularExpression(
        pattern: #"^(.*)\.part(\d+)\.rar$"#,
        options: [.caseInsensitive]
    )
    private static let oldRegex = try! NSRegularExpression(
        pattern: #"^(.*)\.r(\d{2})$"#,
        options: [.caseInsensitive]
    )

    /// 依据文件名检测分卷类型（纯函数，不访问文件系统）。
    public static func detect(_ url: URL) -> Detection {
        let filename = url.lastPathComponent
        let range = NSRange(location: 0, length: filename.utf16.count)

        if let match = partRegex.firstMatch(in: filename, options: [], range: range) {
            guard let baseRange = Range(match.range(at: 1), in: filename),
                  let numberRange = Range(match.range(at: 2), in: filename) else {
                return Detection(classification: .notRAR)
            }
            let base = String(filename[baseRange])
            let number = Int(filename[numberRange]) ?? 0
            if number <= 1 {
                return Detection(classification: .mainVolume(baseName: base))
            } else {
                return Detection(classification: .partContinuation(baseName: base))
            }
        }

        if let match = oldRegex.firstMatch(in: filename, options: [], range: range) {
            guard let baseRange = Range(match.range(at: 1), in: filename) else {
                return Detection(classification: .notRAR)
            }
            let base = String(filename[baseRange])
            return Detection(classification: .oldContinuation(baseName: base))
        }

        if filename.lowercased().hasSuffix(".rar") {
            let base = (filename as NSString).deletingPathExtension
            return Detection(classification: .singleArchive(baseName: base))
        }

        return Detection(classification: .notRAR)
    }
}
