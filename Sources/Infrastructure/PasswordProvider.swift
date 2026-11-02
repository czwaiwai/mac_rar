import AppKit
import Foundation

/// 系统弹窗索要密码（NSAlert）。
public struct PasswordProvider: Sendable {
    /// 归档显示名（用于弹窗文案）。
    public let archiveName: String

    public init(archiveName: String) {
        self.archiveName = archiveName
    }

    /// 供 `ExtractEngine` 使用的密码回调。
    /// 返回 `nil` 表示用户取消。
    public var provider: @Sendable () async throws -> String? {
        let name = archiveName
        return {
            await Self.prompt(archiveName: name, isRetry: false)
        }
    }

    /// 密码错误后的重试回调。
    public var retryProvider: @Sendable () async throws -> String? {
        let name = archiveName
        return {
            await Self.prompt(archiveName: name, isRetry: true)
        }
    }

    // MARK: - 内部

    /// 主线程弹窗，返回输入的密码；取消返回 nil。
    @MainActor
    private static func prompt(archiveName: String, isRetry: Bool) -> String? {
        let alert = NSAlert()
        alert.messageText = isRetry ? "密码错误，请重试" : "需要密码"
        alert.informativeText = "归档「\(archiveName)」已加密，请输入解压密码。"
        alert.alertStyle = .informational

        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        input.placeholderString = "解压密码"
        alert.accessoryView = input

        alert.addButton(withTitle: "解压")
        alert.addButton(withTitle: "取消")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            return nil
        }
        let password = input.stringValue
        return password.isEmpty ? nil : password
    }
}
