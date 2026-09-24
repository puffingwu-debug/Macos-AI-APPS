import AppKit
import SwiftUI

@main
struct QuickTodoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // 悬浮面板由 AppDelegate 直接管理（NSPanel + NSHostingView），
        // 这里只需要一个空场景满足 App 协议。
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var state: AppState!
    private var controller: PanelController!
    private var statusBar: StatusBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 开发期自检：`QuickTodo --selftest` 只跑离线校验、不启动界面
        if CommandLine.arguments.contains("--selftest") {
            exit(SelfTest.run())
        }
        // 跨端联调：`QuickTodo --integration <baseURL> <sessionToken>`
        // 用真实客户端代码打本地托管的云函数（quicktodo-weapp/tools/cloud-harness.js）
        if let index = CommandLine.arguments.firstIndex(of: "--integration") {
            let arguments = CommandLine.arguments
            let baseURL = index + 1 < arguments.count ? arguments[index + 1] : ""
            let token = index + 2 < arguments.count ? arguments[index + 2] : ""
            guard !baseURL.isEmpty, !token.isEmpty else {
                print("用法：QuickTodo --integration <baseURL> <sessionToken>")
                exit(2)
            }
            exit(IntegrationTest.run(baseURL: baseURL, token: token))
        }

        // 后台常驻工具：不占 Dock、不抢焦点
        NSApp.setActivationPolicy(.accessory)

        let state = AppState()
        let controller = PanelController(settings: state.settings)
        state.panelController = controller

        let hosting = NSHostingView(rootView: RootView(state: state, settings: state.settings, controller: controller))
        hosting.autoresizingMask = [.width, .height]
        controller.window.contentView = hosting
        controller.window.setContentSize(state.isExpanded ? PanelController.panelSize : PanelController.ballSize)

        controller.show()
        state.start()
        state.validateSession()

        statusBar = StatusBarController(state: state, controller: controller)

        self.state = state
        self.controller = controller
    }

    func applicationWillTerminate(_ notification: Notification) {
        state?.store.save()
        state?.sync.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// 菜单栏图标：给「无 Dock 图标」的后台 App 一个稳定的入口和退出方式。
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let state: AppState
    private let controller: PanelController

    init(state: AppState, controller: PanelController) {
        self.state = state
        self.controller = controller
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "QuickTodo")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        rebuild(menu)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()

        let pending = state.store.pendingCount
        let header = NSMenuItem(title: "闪记待办 · \(pending) 项未完成", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let status = NSMenuItem(title: "状态：\(state.sync.state.label)\(state.store.hasPendingChanges ? "（有改动待上传）" : "")", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        menu.addItem(.separator())

        menu.addItem(makeItem("显示 / 隐藏面板", #selector(togglePanel)))
        menu.addItem(makeItem("区域截图识别  \(HotKeyManager.describe(keyCode: state.settings.hotKeyCode, modifiers: state.settings.hotKeyModifiers))", #selector(capture)))
        menu.addItem(makeItem("新增待办…", #selector(newTodo)))
        menu.addItem(makeItem("立即同步", #selector(syncNow)))

        menu.addItem(.separator())
        menu.addItem(makeItem("设置…", #selector(openSettings)))

        menu.addItem(.separator())
        menu.addItem(makeItem("退出 QuickTodo", #selector(quit)))
    }

    private func makeItem(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - Actions

    @objc private func togglePanel() {
        state.isExpanded.toggle()
        controller.bringIntoView()
    }

    @objc private func capture() {
        controller.bringIntoView()
        state.runScreenshotFlow()
    }

    @objc private func newTodo() {
        controller.bringIntoView()
        state.isExpanded = true
        state.editing = Todo(content: "", source: .manual)
    }

    @objc private func syncNow() {
        state.syncNow()
    }

    @objc private func openSettings() {
        controller.bringIntoView()
        state.isExpanded = true
        state.showSettings = true
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
