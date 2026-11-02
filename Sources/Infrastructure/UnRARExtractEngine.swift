import Foundation
import Core
import UnRAR

// =============================================================================
// UnRARExtractEngine — 基于 RARLAB UnRAR 官方源码的解压引擎实现
// =============================================================================
//
// 两阶段：
//   1. header scan（RAR_OM_LIST_INCSPLIT 只读 header，不解压）—— 遍历 entry 收集
//      顶层路径 + 总字节 + 逐条路径穿越校验；
//   2. 流式解压到临时目录（RAR_OM_EXTRACT）→ 原子移动到最终目录。
//
// 密码流程：文件级加密（RHDF_ENCRYPTED）在 scan 阶段即可见；头部加密（-hp）在
// open 时即失败（ERAR_MISSING_PASSWORD），先索要密码再 scan。密码回调是同步 C
// 回调，采用「先 await 拿密码 → 预置进回调桥 → open」的顺序，绝不在回调内跑 async。
//
// 许可（UnRAR license.txt 第 2 条原文，纯解压用途合规）：
//   UnRAR source code may be used in any software to handle
//   RAR archives without limitations free of charge, but cannot be
//   used to develop RAR (WinRAR) compatible archiver and to
//   re-create RAR compression algorithm, which is proprietary.
//   Distribution of modified UnRAR source code in separate form
//   or as a part of other software is permitted, provided that
//   full text of this paragraph, starting from "UnRAR source code"
//   words, is included in license, or in documentation if license
//   is not available, and in source code comments of resulting package.
//
// =============================================================================

public struct UnRARExtractEngine: ExtractEngine {

    public init() {}

    public func extract(
        _ request: ExtractionRequest,
        progress: @escaping @Sendable (ExtractionProgress) -> Void,
        passwordProvider: @escaping @Sendable () async throws -> String?
    ) async throws -> ExtractionResult {
        guard FileManager.default.fileExists(atPath: request.archiveURL.path) else {
            throw ExtractionError.archiveNotFound(request.archiveURL)
        }

        // 阶段 A：header scan（头部加密 -hp 时可能先索要密码）。
        let (scan, scanPassword) = try await Self.scanHeader(request, passwordProvider: passwordProvider)
        guard scan.fileCount > 0 || !scan.topLevelEntries.isEmpty else {
            throw ExtractionError.unsupportedFormat(request.archiveURL.lastPathComponent)
        }

        // 命名判定（在落盘前完成）。
        let naming = NamingResolver.resolve(
            archiveURL: request.archiveURL,
            topLevelEntries: scan.topLevelEntries,
            destinationDirectory: request.destinationDirectory
        )

        // 阶段 B：解压到临时目录（含密码重试）。头部加密时 scan 已拿到正确密码。
        var password = request.password ?? scanPassword
        var attemptedPassword = password != nil
        var tempRoot: URL
        while true {
            tempRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("MacRAR-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
                try Self.performExtraction(request, scan, tempRoot: tempRoot, password: password, progress: progress)
                break
            } catch is PasswordFailure {
                try? FileManager.default.removeItem(at: tempRoot)
                guard let pw = try await passwordProvider() else {
                    // 用户取消：已尝试过密码（预置或曾输入）但失败 → 密码错误；
                    // 从未提供过密码就取消 → 需要密码。
                    throw attemptedPassword ? ExtractionError.passwordIncorrect : ExtractionError.passwordRequired
                }
                password = pw
                attemptedPassword = true
                continue
            } catch {
                try? FileManager.default.removeItem(at: tempRoot)
                throw error
            }
        }

        // 原子移动：临时目录 → 最终目标目录。
        try Self.moveIntoPlace(tempRoot: tempRoot, naming: naming)

        return ExtractionResult(
            outputURL: naming.outputURL,
            extractedFileCount: scan.fileCount,
            totalBytes: scan.totalBytes,
            namingDecision: naming.decision
        )
    }

    // MARK: - 阶段 A：header scan

    private struct HeaderScan {
        let topLevelEntries: [String]
        let totalBytes: Int64
        let fileCount: Int
        let hasEncrypted: Bool
    }

    /// 头部加密（-hp）导致 open 需要密码的信号。
    private struct OpenNeedsPassword: Error {}
    /// 文件级加密遇到错误/缺失密码，触发外层重试的信号。
    private struct PasswordFailure: Error {}

    /// 阶段 A 入口：先无密码 LIST 打开，遇头部加密则索要密码重试，返回扫描结果与
    /// 可能已在扫描期间解析出的密码（供阶段 B 复用，避免头部加密二次弹窗）。
    private static func scanHeader(
        _ request: ExtractionRequest,
        passwordProvider: @escaping @Sendable () async throws -> String?
    ) async throws -> (HeaderScan, String?) {
        var password = request.password
        var didPrompt = false

        while true {
            do {
                let scan = try openAndScan(request, password: password)
                return (scan, password)
            } catch is OpenNeedsPassword {
                // 头部加密：只索要一次密码；已提供仍失败 → 密码错误。
                if didPrompt || password != nil {
                    throw ExtractionError.passwordIncorrect
                }
                guard let pw = try await passwordProvider() else {
                    throw ExtractionError.passwordRequired
                }
                password = pw
                didPrompt = true
            }
        }
    }

    /// 打开（LIST_INCSPLIT）→ 遍历 header → 关闭，全程在回调桥生命周期内。
    private static func openAndScan(_ request: ExtractionRequest, password: String?) throws -> HeaderScan {
        let bridge = CallbackBridge(password: password)
        return try withExtendedLifetime(bridge) {
            var callbacks = Self.makeCallbacks(bridge: bridge)
            var openResult: Int32 = 0
            let handle = request.archiveURL.path.withCString { path in
                unrar_open(path, UnRARMode.listIncSplit, &callbacks, &openResult)
            }
            guard let handle else {
                if openResult == UnRARCode.missingPassword {
                    throw OpenNeedsPassword()
                }
                if openResult == UnRARCode.badPassword {
                    throw ExtractionError.passwordIncorrect
                }
                throw ExtractionError.unsupportedFormat(request.archiveURL.lastPathComponent)
            }
            defer { unrar_close(handle) }
            return try iterateHeaders(handle, request: request)
        }
    }

    private static func iterateHeaders(_ handle: UnsafeMutableRawPointer, request: ExtractionRequest) throws -> HeaderScan {
        var topLevelEntries: [String] = []
        var totalBytes: Int64 = 0
        var fileCount = 0
        var hasEncrypted = false

        while true {
            var header = UnRARHeader()
            let rc = unrar_read_header(handle, &header)
            if rc == UnRARCode.endArchive { break }
            if rc != UnRARCode.success {
                throw ExtractionError.unsupportedFormat(request.archiveURL.lastPathComponent)
            }

            let rawPath = Self.headerFileName(&header)
            let isDir = header.isDirectory != 0
            let isLink = header.isSymlink != 0
            let isEncrypted = header.isEncrypted != 0
            // 跨卷文件的后续卷会重复出现同一 header（splitBefore=1），只统计首卷，
            // 避免 fileCount/totalBytes 被逐卷重复累加。
            let isContinuationVolume = header.splitBefore != 0

            do {
                _ = try PathSafetyValidator.validate(entryPath: rawPath, isSymbolicLink: isLink)
            } catch {
                throw ExtractionError.pathTraversalAttempt(rawPath)
            }

            if isEncrypted { hasEncrypted = true }
            if !isDir && !isLink && !isContinuationVolume {
                totalBytes += Int64(clamping: header.unpackedSize)
                fileCount += 1
            }

            // 目录条目以 `/` 结尾，供 NamingResolver 判定单顶层文件夹；
            // 跨卷后续卷 header 是同一文件的重复头，不重复计入顶层条目。
            if !isContinuationVolume {
                var topLevelPath = rawPath
                if isDir && !topLevelPath.hasSuffix("/") {
                    topLevelPath += "/"
                }
                topLevelEntries.append(topLevelPath)
            }

            // LIST 模式下必须显式 SKIP 才能前进到下一个 header 的文件数据之后。
            _ = unrar_process(handle, UnRAROp.skip, nil)
        }

        return HeaderScan(
            topLevelEntries: topLevelEntries,
            totalBytes: totalBytes,
            fileCount: fileCount,
            hasEncrypted: hasEncrypted
        )
    }

    // MARK: - 阶段 B：解压到临时目录

    private static func performExtraction(
        _ request: ExtractionRequest,
        _ scan: HeaderScan,
        tempRoot: URL,
        password: String?,
        progress: @escaping @Sendable (ExtractionProgress) -> Void
    ) throws {
        let bridge = CallbackBridge(password: password)
        bridge.totalBytes = scan.totalBytes
        bridge.progress = progress

        try withExtendedLifetime(bridge) {
            var callbacks = Self.makeCallbacks(bridge: bridge)
            var openResult: Int32 = 0
            let handle = request.archiveURL.path.withCString { path in
                unrar_open(path, UnRARMode.extract, &callbacks, &openResult)
            }
            guard let handle else {
                if openResult == UnRARCode.missingPassword || openResult == UnRARCode.badPassword {
                    throw PasswordFailure()
                }
                throw ExtractionError.unsupportedFormat(request.archiveURL.lastPathComponent)
            }
            defer { unrar_close(handle) }

            while true {
                var header = UnRARHeader()
                let rc = unrar_read_header(handle, &header)
                if rc == UnRARCode.endArchive { break }
                if rc != UnRARCode.success {
                    throw ExtractionError.corruptedArchive(request.archiveURL.lastPathComponent)
                }

                let rawPath = Self.headerFileName(&header)
                let isDir = header.isDirectory != 0
                let isLink = header.isSymlink != 0
                let isEncrypted = header.isEncrypted != 0

                let safeRel: String
                do {
                    safeRel = try PathSafetyValidator.validate(entryPath: rawPath, isSymbolicLink: isLink)
                } catch {
                    throw ExtractionError.pathTraversalAttempt(rawPath)
                }

                if safeRel.isEmpty {
                    _ = unrar_process(handle, UnRAROp.skip, nil)
                    continue
                }
                if isLink {
                    // 保守策略：跳过符号链接（与 UnRAR 官方解压策略一致，避免写入链接目标）。
                    _ = unrar_process(handle, UnRAROp.skip, nil)
                    continue
                }
                if isDir {
                    let targetURL = tempRoot.appendingPathComponent(safeRel)
                    try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
                    _ = unrar_process(handle, UnRAROp.skip, nil)
                    continue
                }

                if isEncrypted && password == nil {
                    throw PasswordFailure()
                }
                if isEncrypted, let pw = password {
                    pw.withCString { unrar_set_password(handle, $0) }
                }

                bridge.currentEntry = rawPath
                let rc2 = tempRoot.path.withCString { unrar_process(handle, UnRAROp.extract, $0) }
                if rc2 == UnRARCode.badPassword || rc2 == UnRARCode.missingPassword {
                    throw PasswordFailure()
                }
                if rc2 != UnRARCode.success {
                    throw ExtractionError.corruptedArchive(rawPath)
                }
            }

            // 收尾进度（totalBytes 由 scan 估算，可能略大于实际，clamp 交给上层）。
            progress(ExtractionProgress(
                completedBytes: bridge.completedBytes,
                totalBytes: scan.totalBytes,
                currentEntry: ""
            ))
        }
    }

    // MARK: - 原子移动

    private static func moveIntoPlace(tempRoot: URL, naming: NamingResolver.ResolvedNaming) throws {
        let fm = FileManager.default
        switch naming.decision {
        case .singleTopLevelFolder(let name):
            let src = tempRoot.appendingPathComponent(name)
            // 与 newFolder 分支一致：先确保输出目录的父目录存在，再原子移动。
            try fm.createDirectory(at: naming.outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: src, to: naming.outputURL)
        case .newFolder:
            try fm.createDirectory(at: naming.outputURL, withIntermediateDirectories: true)
            let items = try fm.contentsOfDirectory(at: tempRoot, includingPropertiesForKeys: nil)
            for item in items {
                try fm.moveItem(at: item, to: naming.outputURL.appendingPathComponent(item.lastPathComponent))
            }
        }
    }

    // MARK: - 回调桥与 C 函数指针

    private static func makeCallbacks(bridge: CallbackBridge) -> UnRARCallbacks {
        var callbacks = UnRARCallbacks()
        callbacks.processData = unrarProcessDataCallback
        callbacks.changeVolume = unrarChangeVolumeCallback
        callbacks.needPassword = unrarNeedPasswordCallback
        callbacks.userData = Unmanaged.passUnretained(bridge).toOpaque()
        return callbacks
    }

    private static func headerFileName(_ header: inout UnRARHeader) -> String {
        withUnsafeBytes(of: &header.fileName) { raw in
            guard let base = raw.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }

    // MARK: - 常量

    private enum UnRARMode {
        static let listIncSplit: Int32 = 2   // RAR_OM_LIST_INCSPLIT
        static let extract: Int32 = 1        // RAR_OM_EXTRACT
    }

    private enum UnRAROp {
        static let skip: Int32 = 0           // RAR_SKIP
        static let extract: Int32 = 2        // RAR_EXTRACT
    }

    private enum UnRARCode {
        static let success: Int32 = 0        // ERAR_SUCCESS
        static let endArchive: Int32 = 10    // ERAR_END_ARCHIVE
        static let missingPassword: Int32 = 22  // ERAR_MISSING_PASSWORD
        static let badPassword: Int32 = 24   // ERAR_BAD_PASSWORD
    }
}

// =============================================================================
// CallbackBridge — 预置密码 / 进度跟踪的同步回调桥
// ---------------------------------------------------------------------------
// UnRAR 的 UCM_* 回调是同步 C 回调，不能在其中跑 async。本桥把「已解析的密码」
// 与「进度累计」作为可变状态预置进来，由 C 函数指针（经 userData）同步读取。
// 每个 extract 调用局部持有一个 bridge，回调在 RARProcessFile 调用线程同步执行，
// 不跨并发边界（UnRAR 回调在 RARProcessFile 调用线程同步执行），因此以 @unchecked Sendable 声明。
// =============================================================================
private final class CallbackBridge: @unchecked Sendable {
    var password: String?
    var progress: (@Sendable (ExtractionProgress) -> Void)?
    var totalBytes: Int64 = 0
    var completedBytes: Int64 = 0
    var lastReportedBytes: Int64 = 0
    var currentEntry: String = ""

    init(password: String?) {
        self.password = password
    }

    func appendProcessed(_ size: Int) {
        completedBytes += Int64(size)
        guard let progress else { return }
        if completedBytes - lastReportedBytes >= 4 * 1024 * 1024 {
            lastReportedBytes = completedBytes
            progress(ExtractionProgress(
                completedBytes: completedBytes,
                totalBytes: totalBytes,
                currentEntry: currentEntry
            ))
        }
    }
}

// MARK: - C 函数指针（@convention(c)，不捕获任何 Swift 状态，经 userData 取 bridge）

private let unrarProcessDataCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int32) -> Void = { userData, data, size in
    guard let userData, let data, size > 0 else { return }
    let bridge = Unmanaged<CallbackBridge>.fromOpaque(userData).takeUnretainedValue()
    bridge.appendProcessed(Int(size))
}

private let unrarChangeVolumeCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<CChar>?, Int32) -> Int32 = { _, _, mode in
    // mode=0(RAR_VOL_ASK)：不提供自定义卷名，返回 -1 中止（UnRAR 自动命名探测失败，
    //   即分卷缺失，映射为 corruptedArchive）；mode=1(RAR_VOL_NOTIFY)：继续。
    return mode == 0 ? -1 : 1
}

private let unrarNeedPasswordCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<CChar>?, Int32) -> Int32 = { userData, buffer, maxLen in
    guard let userData, let buffer, maxLen > 0 else { return -1 }
    let bridge = Unmanaged<CallbackBridge>.fromOpaque(userData).takeUnretainedValue()
    guard let pw = bridge.password, !pw.isEmpty else { return -1 }
    return pw.withCString { cstr in
        let len = strlen(cstr)
        let copyCount = min(len, Int(maxLen) - 1)
        if copyCount > 0 {
            buffer.update(from: cstr, count: copyCount)
        }
        buffer[copyCount] = 0
        return 1
    }
}
