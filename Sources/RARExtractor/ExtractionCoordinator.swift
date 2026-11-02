import Foundation
import AppKit
import Core
import Infrastructure

// ===========================================================================
// ExtractionCoordinator —— 编排主流程
// ---------------------------------------------------------------------------
// open-file 事件 → 分卷判定 → 构造请求 → 解压 → 通知 → 退出
//
// 职责边界（与后端已确认）：命名判定（NamingResolver）与原子移动在
// `ExtractEngine.extract` 内部完成，协调器拿到最终 `ExtractionResult.outputURL`
// 后只负责通知与退出，不再重复调用 NamingResolver。
// ===========================================================================

@MainActor
final class ExtractionCoordinator {
    private let engine: any ExtractEngine
    private let notifier: UserNotifier
    private let state: AppState

    /// 幂等保护：同一归档处理期间，忽略重复的 open-file 事件。
    private var isProcessing = false

    init(engine: any ExtractEngine, notifier: UserNotifier, state: AppState) {
        self.engine = engine
        self.notifier = notifier
        self.state = state
    }

    /// open-file 事件入口（由 AppDelegate.application(_:openFile:) 调用）。
    func start(with url: URL) {
        guard !isProcessing else { return }
        let archiveName = url.lastPathComponent

        // 分卷识别（Core.SplitArchiveDetector.detect）。
        let detection = SplitArchiveDetector.detect(url)
        switch detection.classification {
        case .partContinuation, .oldContinuation:
            // 从卷：静默忽略，避免对同一归档重复解压。
            return
        case .notRAR:
            let message = "不是有效的 RAR 文件"
            state.phase = .failure(fileName: archiveName, message: message)
            Task { await self.notifier.postFailure(archiveName: archiveName, message: message) }
            return
        case .mainVolume, .singleArchive:
            break
        }

        // 构造 ExtractionRequest：destinationDirectory 默认 = 归档同目录。
        let request = ExtractionRequest(
            archiveURL: url,
            destinationDirectory: url.deletingLastPathComponent(),
            password: nil,
            isSplit: detection.isSplit
        )

        isProcessing = true
        state.phase = .extracting(fileName: archiveName)
        Task { await self.run(request) }
    }

    // MARK: - 主流程

    private func run(_ request: ExtractionRequest) async {
        let archiveName = request.archiveURL.lastPathComponent

        // 密码弹窗（Infrastructure.PasswordProvider）：
        // 首次索要用 provider（「需要密码」），密码错误重试用 retryProvider（「密码错误，请重试」）。
        let password = PasswordProvider(archiveName: archiveName)
        let gate = PasswordPromptGate(first: password.provider, retry: password.retryProvider)

        do {
            // 调用引擎解压。引擎内部完成 header scan → 命名判定 → 流式解压 → 原子移动。
            let result = try await engine.extract(
                request,
                progress: { [weak self] progress in
                    // 引擎在后台线程回调进度，派发回主线程刷新 UI。
                    Task { @MainActor in self?.apply(progress) }
                },
                passwordProvider: {
                    // 加密归档降级：回调密码弹窗；返回 nil 表示用户取消（引擎抛 passwordRequired）。
                    try await gate.prompt()
                }
            )

            apply(result, archiveName: archiveName)
            await notifier.postSuccess(archiveName: archiveName, outputURL: result.outputURL)

            // 单文件场景：解压完成后退出应用。
            NSApp.terminate(nil)

        } catch {
            let message = Self.message(for: error)
            state.phase = .failure(fileName: archiveName, message: message)
            await notifier.postFailure(archiveName: archiveName, message: message)
            // 失败不立即退出：保留窗口展示错误，用户可关闭窗口退出。
        }

        isProcessing = false
    }

    // MARK: - 状态刷新

    private func apply(_ progress: ExtractionProgress) {
        state.currentEntry = progress.currentEntry
        state.completedBytes = progress.completedBytes
        state.totalBytes = progress.totalBytes
        state.progress = progress.totalBytes > 0
            ? min(1.0, Double(progress.completedBytes) / Double(progress.totalBytes))
            : 0
    }

    private func apply(_ result: ExtractionResult, archiveName: String) {
        state.phase = .success(
            fileName: archiveName,
            output: result.outputURL.path,
            fileCount: result.extractedFileCount,
            totalBytes: result.totalBytes
        )
    }

    // MARK: - 错误映射

    /// 复用后端 `ExtractionError` 的中文文案（LocalizedError.errorDescription）。
    private static func message(for error: Error) -> String {
        error.localizedDescription
    }
}

// ===========================================================================
// PasswordPromptGate —— 首次 / 重试密码弹窗切换
// ---------------------------------------------------------------------------
// 引擎在每次密码失败后都会重新回调 passwordProvider，因此需要一个状态来区分
// 「首次索要密码」与「密码错误后重试」两种弹窗文案。actor 保证后台回调线程安全。
// ===========================================================================

private actor PasswordPromptGate {
    private var didPrompt = false
    private let first: @Sendable () async throws -> String?
    private let retry: @Sendable () async throws -> String?

    init(
        first: @escaping @Sendable () async throws -> String?,
        retry: @escaping @Sendable () async throws -> String?
    ) {
        self.first = first
        self.retry = retry
    }

    func prompt() async throws -> String? {
        if didPrompt {
            return try await retry()
        }
        didPrompt = true
        return try await first()
    }
}
