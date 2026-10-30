import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var showMainWindow: (() -> Void)?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Self.showMainWindow?()
        AppModel.shared.accept(urls, route: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { Self.showMainWindow?() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppModel.shared.busy else { return .terminateNow }
        AppModel.shared.notice = Notice(title: "请等待任务完成", message: "正在处理备份。为避免中断文件写入，任务完成后再退出。")
        return .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct BackupApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("1P 备份助手", id: "main") {
            MainView(model: model)
                .task { await model.refresh() }
        }
        .defaultSize(width: 1040, height: 740)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("选择文件…") { model.chooseFile() }
                    .keyboardShortcut("o")
                    .disabled(model.busy)
            }
            CommandGroup(after: .appInfo) {
                Button("密钥与恢复…") { model.panel = .keys }
                    .keyboardShortcut(",")
                    .disabled(model.busy)
            }
            CommandGroup(replacing: .help) {
                Button("1P 备份助手使用指南") { model.panel = .guide }
            }
        }
    }
}
