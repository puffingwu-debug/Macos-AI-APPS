import Foundation

/// 全局设置：UserDefaults 持久化，改动后立即生效。
///
/// 注意这里**不存任何密钥**。DeepSeek 的 key 只存在于云函数环境变量，
/// 本机只保存「云函数 HTTP 地址」和 Keychain 里的会话 token。
final class AppSettings: ObservableObject {

    private enum Key {
        static let cloudBaseURL = "cloudBaseURL"
        static let hotKeyCode = "hotKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
        static let panelOpacity = "panelOpacity"
        static let snapToEdge = "snapToEdge"
        static let autoHide = "autoHide"
        static let sortMode = "sortMode"
        static let expanded = "expandedPanel"
        static let ballOriginX = "ballOriginX"
        static let ballOriginY = "ballOriginY"
        static let launchAtLogin = "launchAtLogin"
    }

    /// 允许注入自定义 UserDefaults（联调自检用独立 suite，避免污染用户设置）
    private let defaults: UserDefaults

    /// 云函数 HTTP 访问服务（云接入）的 base URL，例如
    /// `https://<env-id>.<region>.app.tcloudbase.com`。留空 = 纯本地模式。
    @Published var cloudBaseURL: String {
        didSet { defaults.set(cloudBaseURL, forKey: Key.cloudBaseURL) }
    }

    /// 全局截图快捷键，默认 ⌘⇧A。
    @Published var hotKeyCode: UInt32 {
        didSet { defaults.set(Int(hotKeyCode), forKey: Key.hotKeyCode) }
    }

    /// Carbon 修饰键掩码（cmdKey / shiftKey / optionKey / controlKey 的按位或）。
    @Published var hotKeyModifiers: UInt32 {
        didSet { defaults.set(Int(hotKeyModifiers), forKey: Key.hotKeyModifiers) }
    }

    /// 面板不透明度 0.55...1.0。
    @Published var panelOpacity: Double {
        didSet { defaults.set(panelOpacity, forKey: Key.panelOpacity) }
    }

    /// 拖拽结束后是否自动吸附到最近的屏幕边缘。
    @Published var snapToEdge: Bool {
        didSet { defaults.set(snapToEdge, forKey: Key.snapToEdge) }
    }

    /// 贴边后是否自动隐藏（只留一条细边，鼠标移过去再滑出）。
    @Published var autoHide: Bool {
        didSet { defaults.set(autoHide, forKey: Key.autoHide) }
    }

    @Published var sortMode: TodoSortMode {
        didSet { defaults.set(sortMode.rawValue, forKey: Key.sortMode) }
    }

    /// 上次是展开还是收起状态，重启后恢复。
    @Published var expanded: Bool {
        didSet { defaults.set(expanded, forKey: Key.expanded) }
    }

    /// 悬浮球位置（屏幕坐标，左下原点），拖动后记住。
    @Published var ballOriginX: Double {
        didSet { defaults.set(ballOriginX, forKey: Key.ballOriginX) }
    }

    @Published var ballOriginY: Double {
        didSet { defaults.set(ballOriginY, forKey: Key.ballOriginY) }
    }

    @Published var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Key.launchAtLogin) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedCode = defaults.object(forKey: Key.hotKeyCode) as? Int
        hotKeyCode = UInt32(storedCode ?? 0)          // 0 = kVK_ANSI_A
        let storedMods = defaults.object(forKey: Key.hotKeyModifiers) as? Int
        hotKeyModifiers = UInt32(storedMods ?? 0x0100 | 0x0200)  // cmd + shift
        cloudBaseURL = defaults.string(forKey: Key.cloudBaseURL) ?? ""
        panelOpacity = defaults.object(forKey: Key.panelOpacity) as? Double ?? 0.92
        snapToEdge = defaults.object(forKey: Key.snapToEdge) as? Bool ?? true
        autoHide = defaults.object(forKey: Key.autoHide) as? Bool ?? true
        sortMode = TodoSortMode(rawValue: defaults.string(forKey: Key.sortMode) ?? "") ?? .smart
        expanded = defaults.object(forKey: Key.expanded) as? Bool ?? true
        ballOriginX = defaults.object(forKey: Key.ballOriginX) as? Double ?? -1
        ballOriginY = defaults.object(forKey: Key.ballOriginY) as? Double ?? -1
        launchAtLogin = defaults.object(forKey: Key.launchAtLogin) as? Bool ?? false
    }

    /// 云端是否已配置（决定同步与 AI 解析是否可用）。
    var hasCloud: Bool {
        !cloudBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var normalizedBaseURL: String {
        var text = cloudBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }
}
