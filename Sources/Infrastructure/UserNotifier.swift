import Foundation
import UserNotifications

/// 系统通知（UNUserNotificationCenter）。
public struct UserNotifier: Sendable {

    public init() {}

    /// 发送成功通知。
    public func postSuccess(archiveName: String, outputURL: URL) async {
        await post(
            title: "解压完成",
            body: "「\(archiveName)」已解压到 \(outputURL.lastPathComponent)"
        )
    }

    /// 发送失败通知。
    public func postFailure(archiveName: String, message: String) async {
        await post(
            title: "解压失败",
            body: "「\(archiveName)」：\(message)"
        )
    }

    // MARK: - 内部

    /// 通用通知入口（title/body），供前端 DI 适配层直接调用。
    public func post(title: String, body: String) async {
        let center = UNUserNotificationCenter.current()
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            // 授权失败时静默，不阻断主流程。
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }
}
