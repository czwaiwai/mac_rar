import AppKit
import Core
import Infrastructure

// ===========================================================================
// RARExtractor 可执行入口（SPM executable target，非 Xcode App 模板）
// ---------------------------------------------------------------------------
// 职责：手动构造 NSApplication、装配 AppDelegate 与 ExtractionCoordinator（依赖注入）、
// 进入事件循环。双击文件的事件由系统经 Apple Event 派发给 AppDelegate
// （见 AppDelegate.swift 的 application(_:openFile:)）。
// ===========================================================================

/// 依赖注入装配：把真实的 Core / Infrastructure 实现注入可执行层。
@MainActor
private func assemble() -> (coordinator: ExtractionCoordinator, state: AppState) {
    let state = AppState()
    let coordinator = ExtractionCoordinator(
        engine: UnRARExtractEngine(), // Infrastructure：UnRAR 官方源码流式解压引擎
        notifier: UserNotifier(),          // Infrastructure：UNUserNotificationCenter 系统通知
        state: state
    )
    return (coordinator, state)
}

let app = NSApplication.shared
// 无 Dock 图标的轻量工具模式：双击 .rar → 解压 → 通知 → 退出（对齐 macOS 原生 zip 体验）。
app.setActivationPolicy(.accessory)

let (coordinator, state) = assemble()
// NSApplication.delegate 是 weak 属性，必须用全局强引用持有 AppDelegate，
// 否则实例会被立即释放，open-file 事件将无人处理。
let delegate = AppDelegate(coordinator: coordinator, state: state)
app.delegate = delegate

app.run()
