import AppKit
import ServiceManagement
import SwiftUI

/// 设置：云端与账号、快捷键、外观行为、权限、关于。
struct SettingsView: View {

    @ObservedObject var state: AppState
    @ObservedObject var settings: AppSettings
    let controller: PanelController

    @Environment(\.dismiss) private var dismiss
    @State private var showLogin = false
    @State private var testResult: String?
    @State private var testing = false
    @State private var recording = false

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("设置")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.accent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider().opacity(0.4)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    cloudSection
                    shortcutSection
                    appearanceSection
                    permissionSection
                    aboutSection
                }
                .padding(16)
            }
        }
        .frame(width: 396, height: 520)
        .sheet(isPresented: $showLogin) {
            LoginView(state: state, settings: settings)
        }
    }

    // MARK: - 云端与账号

    private var cloudSection: some View {
        SettingsGroup(title: "云端与账号", symbol: "cloud") {
            VStack(alignment: .leading, spacing: 8) {
                Text("云函数 HTTP 访问地址（云接入域名）")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                TextField("https://<env-id>.<region>.app.tcloudbase.com", text: $settings.cloudBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .onSubmit { testConnection() }

                HStack(spacing: 8) {
                    Button(testing ? "测试中…" : "测试连接") { testConnection() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.normal)
                        .disabled(testing || !settings.hasCloud)

                    Button(state.isLoggedIn ? "已登录 · 重新扫码" : "微信扫码登录") {
                        showLogin = true
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.accent)

                    if state.isLoggedIn {
                        Button("退出登录") { state.logout() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.high)
                    }

                    Spacer()

                    Button("立即同步") { state.syncNow() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .disabled(!settings.hasCloud || !state.isLoggedIn)
                }

                if let testResult {
                    Text(testResult)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(state.sync.lastSummary)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                if !settings.hasCloud {
                    Text("留空即为纯本地模式：截图识别与手动待办都能用，AI 解析会退化为本地规则解析。")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func testConnection() {
        guard settings.hasCloud else { return }
        testing = true
        testResult = nil
        Task {
            do {
                let result = try await state.api.ping(baseURL: settings.normalizedBaseURL, token: state.sessionToken)
                let count = result.count ?? 0
                let openid = (result.openid ?? "").suffix(6)
                testResult = "✅ 连接成功 · 云端 \(count) 条待办 · 账号 …\(openid) · 契约 \(result.version ?? "v1")"
            } catch {
                let message = (error as? CloudError)?.message ?? error.localizedDescription
                testResult = "⚠️ 连接失败：\(message)"
            }
            testing = false
        }
    }

    // MARK: - 快捷键

    private var shortcutSection: some View {
        SettingsGroup(title: "全局快捷键", symbol: "command") {
            HStack(spacing: 10) {
                Text("区域截图识别")
                    .font(.system(size: 11))

                Spacer()

                ShortcutRecorder(keyCode: $settings.hotKeyCode, modifiers: $settings.hotKeyModifiers) {
                    state.applyHotKey()
                }
                .frame(width: 116, height: 24)

                Button("恢复默认") {
                    settings.hotKeyCode = 0            // kVK_ANSI_A
                    settings.hotKeyModifiers = 0x0100 | 0x0200   // ⌘⇧
                    state.applyHotKey()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }

            Text("点右侧按键框后直接按下想要的组合键（需含 ⌘/⌥/⌃ 之一）。当前：\(HotKeyManager.describe(keyCode: settings.hotKeyCode, modifiers: settings.hotKeyModifiers))")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 外观与行为

    private var appearanceSection: some View {
        SettingsGroup(title: "外观与行为", symbol: "slider.horizontal.3") {
            HStack {
                Text("面板不透明度")
                    .font(.system(size: 11))
                Slider(value: $settings.panelOpacity, in: 0.55...1.0)
                    .controlSize(.small)
                Text("\(Int(settings.panelOpacity * 100))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }

            Toggle("拖拽后自动吸附到屏幕边缘", isOn: $settings.snapToEdge)
                .font(.system(size: 11))
                .toggleStyle(.checkbox)

            Toggle("贴边后自动隐藏（鼠标移到边缘再滑出）", isOn: $settings.autoHide)
                .font(.system(size: 11))
                .toggleStyle(.checkbox)

            HStack {
                Text("未完成排序")
                    .font(.system(size: 11))
                Picker("", selection: Binding(
                    get: { settings.sortMode },
                    set: { state.setSortMode($0) }
                )) {
                    ForEach(TodoSortMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                Spacer()
            }

            Toggle("开机自动启动", isOn: Binding(
                get: { settings.launchAtLogin },
                set: { newValue in
                    settings.launchAtLogin = newValue
                    applyLaunchAtLogin(newValue)
                }
            ))
            .font(.system(size: 11))
            .toggleStyle(.checkbox)

            HStack {
                Text("悬浮球位置")
                    .font(.system(size: 11))
                Spacer()
                Button("回到默认位置") {
                    settings.ballOriginX = -1
                    settings.ballOriginY = -1
                    state.showToast("下次启动生效；现在可拖动悬浮球调整", kind: .info)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
        }
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            settings.launchAtLogin = false
            state.showToast("开机启动设置失败：请先把 QuickTodo.app 放到「应用程序」目录", kind: .warning)
        }
    }

    // MARK: - 权限

    private var permissionSection: some View {
        SettingsGroup(title: "系统权限", symbol: "lock.shield") {
            HStack(spacing: 6) {
                Image(systemName: ScreenshotService.hasPermission ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(ScreenshotService.hasPermission ? Palette.accent : Palette.warning)
                Text(ScreenshotService.hasPermission ? "屏幕录制权限已获得" : "尚未获得屏幕录制权限（截图需要）")
                    .font(.system(size: 11))
                Spacer()
                Button("打开设置") { ScreenshotService.openPermissionSettings() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.normal)
            }

            if !ScreenshotService.hasPermission {
                Text("授权后需要重启 QuickTodo 才会生效（macOS 的既定要求）。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 6) {
                Image(systemName: "key.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.accent)
                Text("DeepSeek API Key 只存在云函数环境变量，本机不保存任何密钥")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        SettingsGroup(title: "关于", symbol: "info.circle") {
            HStack {
                Text("版本")
                    .font(.system(size: 11))
                Spacer()
                Text(appVersion)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("本地数据")
                    .font(.system(size: 11))
                Spacer()
                Button("在访达中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([state.store.storeFileURL])
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(Palette.normal)
            }
            HStack {
                Text("云端待办")
                    .font(.system(size: 11))
                Spacer()
                Text("\(state.store.visibleTodos.count) 条本地 · \(state.store.hasPendingChanges ? "有改动待上传" : "全部已同步")")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Text("截图 → 系统 Vision 本地 OCR → 云端 DeepSeek 结构化解析 → 一键导入。图片识别后立即删除，不上传原图。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 分组容器

struct SettingsGroup<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.accent)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            content
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }
}

// MARK: - 快捷键录制

/// 点一下，然后直接按组合键。
struct ShortcutRecorder: NSViewRepresentable {

    @Binding var keyCode: UInt32
    @Binding var modifiers: UInt32
    var onChanged: () -> Void

    func makeNSView(context: Context) -> ShortcutCaptureView {
        let view = ShortcutCaptureView()
        view.onCapture = { code, mods in
            keyCode = code
            modifiers = mods
            onChanged()
        }
        return view
    }

    func updateNSView(_ view: ShortcutCaptureView, context: Context) {
        view.display = HotKeyManager.describe(keyCode: keyCode, modifiers: modifiers)
        view.onCapture = { code, mods in
            keyCode = code
            modifiers = mods
            onChanged()
        }
    }
}

final class ShortcutCaptureView: NSView {

    var onCapture: ((UInt32, UInt32) -> Void)?
    var display: String = "" { didSet { needsDisplay = true } }

    private var isRecording = false

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 116, height: 24) }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.18) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = 1
        path.stroke()

        let text = isRecording ? "按下组合键…" : display
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: isRecording ? NSColor.controlAccentColor : NSColor.labelColor
        ]
        let size = text.size(withAttributes: attributes)
        let point = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        text.draw(at: point, withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
        needsDisplay = true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        needsDisplay = true
        return true
    }

    override func keyDown(with event: NSEvent) {
        // Esc 取消录制
        if event.keyCode == 53 {
            isRecording = false
            needsDisplay = true
            return
        }
        let mods = HotKeyManager.carbonModifiers(from: event.modifierFlags)
        // 必须带修饰键，否则会和普通打字冲突
        guard mods != 0 else {
            NSSound.beep()
            return
        }
        isRecording = false
        needsDisplay = true
        onCapture?(UInt32(event.keyCode), mods)
    }
}
