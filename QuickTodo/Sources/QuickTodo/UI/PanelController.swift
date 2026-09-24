import AppKit
import QuartzCore
import SwiftUI

/// 桌面悬浮面板。
///
/// 用 `NSPanel` + `.nonactivatingPanel`：点击面板展开待办时**不会**把前台 App 抢走，
/// 这是「后台常驻、不打断工作」的关键。配合 `.canJoinAllSpaces` 让它跟着用户
/// 在所有桌面/全屏空间里都在，`level = .floating` 保证它在普通窗口之上。
final class FloatingPanel: NSPanel {

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovableByWindowBackground = false   // 拖拽自己实现，避免和列表滚动打架
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        // 面板里常驻一个输入框：点哪儿都能直接打字，比「只在需要时成为 key」更可预期
        becomesKeyOnlyIfNeeded = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        animationBehavior = .utilityWindow
        isReleasedWhenClosed = false
    }

    // 无边框窗口默认不能成为 key，输入框就没法打字，这里显式允许
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 面板的位置、尺寸、贴边吸附与自动隐藏。
@MainActor
final class PanelController {

    enum Edge: Equatable { case left, right, top }

    static let ballSize = NSSize(width: 58, height: 58)
    static let panelSize = NSSize(width: 348, height: 480)
    /// 贴边隐藏后仍露在屏幕内的宽度
    static let peek: CGFloat = 5
    /// 吸附触发距离
    private static let snapThreshold: CGFloat = 28

    private let panel: FloatingPanel
    private let settings: AppSettings

    private var dragOrigin: NSPoint?
    private var dragMouseOrigin: NSPoint?
    private var snappedEdge: Edge?
    private var isHiddenAtEdge = false
    private var mouseOutsideSince: Date?
    private var pollTimer: Timer?
    private var moveObserver: NSObjectProtocol?

    /// 截图/解析进行中时不要自动隐藏，否则用户会看不到加载状态。
    var suppressAutoHide = false

    var window: NSWindow { panel }

    init(settings: AppSettings) {
        self.settings = settings
        let size = settings.expanded ? Self.panelSize : Self.ballSize
        let origin = Self.restoredOrigin(settings: settings, size: size)
        panel = FloatingPanel(contentRect: NSRect(origin: origin, size: size))
        // 透明度由 SwiftUI 侧的背景层控制（保持文字清晰），窗口自身始终全不透明
        panel.alphaValue = 1
        panel.setFrame(NSRect(origin: origin, size: size), display: false)

        // 记录拖动后的位置，用于重启恢复
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.persistOrigin() }
        }
    }

    deinit {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
    }

    // MARK: - 生命周期

    func show() {
        panel.orderFrontRegardless()
        startPolling()
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// 透明度由背景层承担，这里只保证窗口本身不叠加 alpha。
    func applyOpacity() {
        panel.alphaValue = 1
    }

    func setExpanded(_ expanded: Bool) {
        let target = expanded ? Self.panelSize : Self.ballSize
        var frame = panel.frame
        let oldMaxY = frame.maxY
        frame.size = target
        // 收起/展开时保持右上角不动，视觉上更稳
        frame.origin.y = oldMaxY - target.height
        frame = clamped(frame)
        isHiddenAtEdge = false
        animate(frame: frame)
        suppressAutoHide = false
        persistOrigin()
    }

    // MARK: - 拖动（用全局鼠标位置计算，避免窗口移动导致的坐标系反馈抖动）

    func beginDrag() {
        dragOrigin = panel.frame.origin
        dragMouseOrigin = NSEvent.mouseLocation
    }

    func updateDrag() {
        guard let dragOrigin, let dragMouseOrigin else { return }
        let current = NSEvent.mouseLocation
        let target = NSPoint(x: dragOrigin.x + (current.x - dragMouseOrigin.x),
                            y: dragOrigin.y + (current.y - dragMouseOrigin.y))
        isHiddenAtEdge = false
        panel.setFrameOrigin(target)
    }

    func endDrag() {
        dragOrigin = nil
        dragMouseOrigin = nil
        if settings.snapToEdge {
            snapToNearestEdge()
        } else {
            snappedEdge = nil
            panel.setFrame(clamped(panel.frame), display: true)
        }
        persistOrigin()
    }

    // MARK: - 贴边

    private func snapToNearestEdge() {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = clamped(panel.frame)

        let distanceLeft = abs(frame.minX - visible.minX)
        let distanceRight = abs(visible.maxX - frame.maxX)
        let distanceTop = abs(visible.maxY - frame.maxY)

        let nearest = min(distanceLeft, distanceRight, distanceTop)
        if nearest > Self.snapThreshold {
            snappedEdge = nil
            panel.setFrame(frame, display: true)
            return
        }

        if nearest == distanceLeft {
            frame.origin.x = visible.minX
            snappedEdge = .left
        } else if nearest == distanceRight {
            frame.origin.x = visible.maxX - frame.width
            snappedEdge = .right
        } else {
            frame.origin.y = visible.maxY - frame.height
            snappedEdge = .top
        }
        animate(frame: frame)
    }

    /// 贴边状态下自动隐藏。
    func hideAtEdge() {
        guard let edge = snappedEdge, let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = panel.frame
        switch edge {
        case .left:  frame.origin.x = visible.minX - frame.width + Self.peek
        case .right: frame.origin.x = visible.maxX - Self.peek
        case .top:   frame.origin.y = visible.maxY - Self.peek
        }
        isHiddenAtEdge = true
        animate(frame: frame, duration: 0.28)
    }

    func revealFromEdge() {
        guard isHiddenAtEdge, let edge = snappedEdge, let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = panel.frame
        switch edge {
        case .left:  frame.origin.x = visible.minX
        case .right: frame.origin.x = visible.maxX - frame.width
        case .top:   frame.origin.y = visible.maxY - frame.height
        }
        isHiddenAtEdge = false
        animate(frame: frame, duration: 0.22)
    }

    /// 贴边隐藏后鼠标需要碰触的「热区」。
    private var hotZone: NSRect? {
        guard let edge = snappedEdge else { return nil }
        let frame = panel.frame
        let pad: CGFloat = 8
        switch edge {
        case .left:
            return NSRect(x: frame.minX, y: frame.minY, width: Self.peek + pad, height: frame.height)
        case .right:
            return NSRect(x: frame.minX + frame.width - Self.peek - pad, y: frame.minY,
                          width: Self.peek + pad, height: frame.height)
        case .top:
            return NSRect(x: frame.minX, y: frame.minY + frame.height - Self.peek - pad,
                          width: frame.width, height: Self.peek + pad)
        }
    }

    // MARK: - 鼠标轮询（读 NSEvent.mouseLocation 不需要任何系统权限）

    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollMouse() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func pollMouse() {
        guard settings.autoHide else {
            if isHiddenAtEdge { revealFromEdge() }
            mouseOutsideSince = nil
            return
        }
        // 拖动中、截图/解析中、设置页打开时都不打扰
        if dragOrigin != nil || suppressAutoHide || panel.isVisible == false {
            mouseOutsideSince = nil
            return
        }

        let mouse = NSEvent.mouseLocation
        if isHiddenAtEdge {
            if let zone = hotZone, zone.contains(mouse) {
                revealFromEdge()
            }
            return
        }

        let inside = panel.frame.insetBy(dx: -10, dy: -10).contains(mouse)
        if inside {
            mouseOutsideSince = nil
            return
        }
        guard snappedEdge != nil else { return }   // 没贴边就不隐藏

        // 正在输入时给更长的宽限期，避免打字途中面板跑掉
        let grace: TimeInterval = panel.isKeyWindow ? 2.5 : 0.7
        if let since = mouseOutsideSince {
            if Date().timeIntervalSince(since) >= grace {
                hideAtEdge()
                mouseOutsideSince = nil
            }
        } else {
            mouseOutsideSince = Date()
        }
    }

    // MARK: - 工具

    private func animate(frame: NSRect, duration: TimeInterval = 0.2) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func clamped(_ frame: NSRect) -> NSRect {
        guard let screen = panel.screen ?? NSScreen.main else { return frame }
        let visible = screen.visibleFrame
        var result = frame
        result.origin.x = min(max(result.origin.x, visible.minX), max(visible.minX, visible.maxX - result.width))
        result.origin.y = min(max(result.origin.y, visible.minY), max(visible.minY, visible.maxY - result.height))
        return result
    }

    private func persistOrigin() {
        guard !isHiddenAtEdge else { return }
        settings.ballOriginX = Double(panel.frame.origin.x)
        settings.ballOriginY = Double(panel.frame.origin.y)
    }

    private static func restoredOrigin(settings: AppSettings, size: NSSize) -> NSPoint {
        let visible = (NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900))
        let stored = NSPoint(x: settings.ballOriginX, y: settings.ballOriginY)
        if stored.x >= 0, stored.y >= 0, visible.insetBy(dx: -40, dy: -40).contains(stored) {
            return stored
        }
        // 默认位置：屏幕右侧靠上，符合「常驻侧边」的心理预期
        return NSPoint(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 120)
    }

    /// 保证面板可见（菜单里点「显示面板」时用）。
    func bringIntoView() {
        if isHiddenAtEdge { revealFromEdge() }
        if !panel.isVisible { show() }
        panel.orderFrontRegardless()
    }

    /// 要弹 sheet（设置 / 编辑器 / 登录）前调用。
    ///
    /// 无边框的 `.nonactivatingPanel` 平时不抢焦点是优点，但 SwiftUI 的 `.sheet`
    /// 需要一个 key window 作为父窗口才能正常聚焦与输入，所以在**明确的用户操作**下
    /// 主动激活一次 App（不影响「按快捷键截图不打断当前工作」的体验）。
    func prepareForSheet() {
        NSApp.activate(ignoringOtherApps: true)
        if !panel.isVisible { show() }
        panel.makeKeyAndOrderFront(nil)
    }
}
