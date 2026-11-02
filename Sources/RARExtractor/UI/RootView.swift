import SwiftUI

/// 应用级 UI 状态。
///
/// 由 `ExtractionCoordinator`（主线程）驱动，`RootView` 订阅渲染。
/// 状态机枚举 `Phase` 覆盖「空闲 / 解压中 / 成功 / 失败」四态。
@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case idle
        case extracting(fileName: String)
        case success(fileName: String, output: String, fileCount: Int, totalBytes: Int64)
        case failure(fileName: String, message: String)
    }

    @Published var phase: Phase = .idle
    @Published var progress: Double = 0          // 0...1，totalBytes 未知时为 0
    @Published var completedBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var currentEntry: String = ""
}

/// 极简状态视图：显示解压进度、成功结果或失败原因。
struct RootView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 16) {
            switch state.phase {
            case .idle:
                idleView
            case .extracting(let fileName):
                extractingView(fileName: fileName)
            case .success(let fileName, let output, let fileCount, let totalBytes):
                successView(fileName: fileName, output: output, fileCount: fileCount, totalBytes: totalBytes)
            case .failure(let fileName, let message):
                failureView(fileName: fileName, message: message)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    // MARK: - 子视图

    private var idleView: some View {
        VStack(spacing: 10) {
            Image(systemName: "archivebox")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("双击 .rar 文件即可自动解压")
                .font(.headline)
            Text("解压结果会输出到归档所在目录")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    private func extractingView(fileName: String) -> some View {
        VStack(spacing: 12) {
            ProgressView(value: state.progress)
                .progressViewStyle(.linear)
                .frame(maxWidth: .infinity)

            Text("正在解压 \(fileName)")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)

            if state.totalBytes > 0 {
                Text("\(state.completedBytes.formatted(.byteCount(style: .file))) / \(state.totalBytes.formatted(.byteCount(style: .file)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !state.currentEntry.isEmpty {
                Text(state.currentEntry)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    private func successView(fileName: String, output: String, fileCount: Int, totalBytes: Int64) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("解压完成")
                .font(.headline)
            Text(fileName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(fileCount) 个文件 · \(totalBytes.formatted(.byteCount(style: .file)))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(output)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    private func failureView(fileName: String, message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("解压失败")
                .font(.headline)
            Text(fileName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }
}
