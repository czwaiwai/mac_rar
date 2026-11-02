import AppKit
import SwiftUI

/// NSApplicationDelegate。
///
/// 核心职责：接收系统 open-file Apple Event（`application(_:openFile:)`），
/// 将文件 URL 交给 `ExtractionCoordinator` 处理。
/// 注意：这里用的是 AppKit 的 open-file 回调，而不是 SwiftUI 的 `onOpenURL`
///（后者只处理自定义 URL scheme，无法接收双击文件事件）。
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator: ExtractionCoordinator
    private let state: AppState
    private var window: NSWindow?

    init(coordinator: ExtractionCoordinator, state: AppState) {
        self.coordinator = coordinator
        self.state = state
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 手动构造 SwiftUI 窗口（SPM 可执行 target 无 Xcode App 模板，需自建窗口）
        let hosting = NSHostingController(rootView: RootView(state: state))
        let window = NSWindow(contentViewController: hosting)
        window.title = "RAR 解压"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 420, height: 220))
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 系统双击 .rar（或通过「打开方式」）触发的回调，返回 true 表示已处理。
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        coordinator.start(with: URL(fileURLWithPath: filename))
        return true
    }

    /// 关闭窗口即退出（成功/失败后用户手动关窗的场景）。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
