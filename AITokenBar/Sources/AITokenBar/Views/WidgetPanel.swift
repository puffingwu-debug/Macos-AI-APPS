import AppKit
import SwiftUI
import Combine

/// Borderless floating window that hosts the widget.
///
/// `.nonactivatingPanel` keeps the widget from stealing focus when clicked, and
/// `.canJoinAllSpaces` keeps it visible on every Space and over full-screen apps.
final class WidgetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A click-through outline shown while dragging near a screen edge, mirroring the
/// preview macOS itself draws when you tile a window.
final class SnapGuideWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        // `contentRect` would resolve to NSWindow's own method after super.init,
        // so the initial bounds are kept in a local.
        let bounds = NSRect(x: 0, y: 0, width: 200, height: 200)
        super.init(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false

        let host = NSHostingView(rootView: SnapGuideView())
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        contentView = host
    }
}

private struct SnapGuideView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.accentColor.opacity(0.14))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 2)
            }
            .padding(1)
    }
}

/// The grid macOS lays desktop widgets out on.
///
/// Read from the live window list rather than hard-coded, so the widget lines up
/// with whatever widgets actually exist on this machine. On the reference machine
/// that is: left margin 8 pt, columns every 180 pt, rows every 180 pt starting
/// flush under the menu bar.
struct DesktopWidgetGrid: Equatable {
    /// AppKit x of each column's left edge.
    var columns: [CGFloat] = []
    /// AppKit y of each row's top edge.
    var rowTops: [CGFloat] = []
    var margin: CGFloat = 8
    var pitch: CGFloat = 180
    /// False when no desktop widgets were found and the defaults are in use.
    var detected = false

    static let `default` = DesktopWidgetGrid()

    /// Candidate y origins that put the widget's top edge on a grid row.
    ///
    /// Only rows that currently hold a widget are detectable, so the lattice is
    /// projected from the top row downwards — otherwise the empty row below the
    /// last widget would not be a snap target, which is exactly the gap that made
    /// the widget sit a few points off.
    func rowOrigins(forHeight height: CGFloat, in visible: NSRect, inset: CGFloat) -> [CGFloat] {
        let anchor = rowTops.first ?? (visible.maxY - inset)
        var origins: [CGFloat] = []
        var top = anchor
        while top - height >= visible.minY - 0.5 {
            origins.append(top - height)
            top -= pitch
        }
        return origins
    }

    /// Candidate x origins.
    ///
    /// The widget is centred inside the smallest whole number of columns it fits
    /// in. When it fills that span exactly the centred position *is* the flush-left
    /// one, so both cases are handled by a single rule — and a widget trimmed a few
    /// percent smaller ends up with even margins instead of a gap on one side.
    func columnOrigins(forWidth width: CGFloat, in visible: NSRect, inset: CGFloat) -> [CGFloat] {
        let anchor = columns.first ?? (visible.minX + inset)
        let span = max(1, Int((width / pitch).rounded(.up)))
        let slot = CGFloat(span) * pitch
        let centring = max(0, (slot - width) / 2)

        var origins: [CGFloat] = []
        var x = anchor
        while x + slot <= visible.maxX + 0.5 {
            origins.append(x + centring)
            x += pitch
        }
        return origins
    }

    /// Reads the frames of the system's desktop widgets.
    static func detect(on screen: NSScreen) -> DesktopWidgetGrid {
        var grid = DesktopWidgetGrid()
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return grid }

        // CGWindowList speaks top-left origin; convert through the primary screen.
        let primaryHeight = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
            ?? screen.frame.height

        var frames: [NSRect] = []
        for info in list {
            let layer = (info[kCGWindowLayer as String] as? Int) ?? 0
            // Desktop widgets live far below normal windows but above the wallpaper.
            guard layer < -1_000_000 else { continue }
            guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? Double,
                  let y = bounds["Y"] as? Double,
                  let width = bounds["Width"] as? Double,
                  let height = bounds["Height"] as? Double,
                  width >= 100, width <= 900, height >= 100, height <= 900
            else { continue }

            let rect = NSRect(x: x, y: primaryHeight - y - height, width: width, height: height)
            guard screen.frame.intersects(rect) else { continue }
            frames.append(rect)
        }

        guard !frames.isEmpty else { return grid }

        grid.columns = Array(Set(frames.map(\.minX))).sorted()
        grid.rowTops = Array(Set(frames.map(\.maxY))).sorted(by: >)
        grid.margin = max(0, (grid.columns.first ?? screen.frame.minX) - screen.frame.minX)

        // The pitch is the smallest positive gap between neighbouring rows/columns.
        var gaps: [CGFloat] = []
        for values in [grid.columns, grid.rowTops.sorted()] where values.count > 1 {
            for index in 1..<values.count {
                let delta = values[index] - values[index - 1]
                if delta > 1 { gaps.append(delta) }
            }
        }
        grid.pitch = gaps.min() ?? (frames.map(\.width).min() ?? 180)
        grid.detected = true
        return grid
    }
}

/// Pure geometry for snapping, kept separate from the window plumbing so it can be
/// reasoned about — and tested — without a running app.
enum SnapMath {

    /// The frame `frame` should adopt when released inside `visible`.
    ///
    /// Considers the screen edges *and* the desktop-widget grid, then takes the
    /// nearest candidate per axis, so corners and shared rows both work.
    /// Returns nil when nothing is close enough to snap to.
    static func snapped(
        _ frame: NSRect,
        in visible: NSRect,
        threshold: CGFloat,
        inset: CGFloat,
        grid: DesktopWidgetGrid? = nil
    ) -> NSRect? {
        guard visible.width > 0, visible.height > 0 else { return nil }

        // Grid positions are consulted first and win over the raw screen edge:
        // otherwise a widget already sitting flush at x = margin would never move
        // to its centred slot, because flushing is zero distance away.
        var gridX: [CGFloat] = []
        var gridY: [CGFloat] = []
        if let grid, grid.detected {
            gridX = grid.columnOrigins(forWidth: frame.width, in: visible, inset: inset)
            gridY = grid.rowOrigins(forHeight: frame.height, in: visible, inset: inset)
        }
        let edgeX: [CGFloat] = [visible.minX + inset, visible.maxX - frame.width - inset]
        let edgeY: [CGFloat] = [visible.maxY - frame.height - inset, visible.minY + inset]

        var origin = frame.origin
        var didSnap = false

        if let best = nearest(in: gridX, to: frame.origin.x, within: threshold)
            ?? nearest(in: edgeX, to: frame.origin.x, within: threshold) {
            origin.x = best
            didSnap = true
        }
        if let best = nearest(in: gridY, to: frame.origin.y, within: threshold)
            ?? nearest(in: edgeY, to: frame.origin.y, within: threshold) {
            origin.y = best
            didSnap = true
        }

        guard didSnap else { return nil }
        return NSRect(origin: origin, size: frame.size)
    }

    private static func nearest(in candidates: [CGFloat], to value: CGFloat, within threshold: CGFloat) -> CGFloat? {
        var best: CGFloat?
        var bestDistance = threshold
        for candidate in candidates {
            let distance = abs(candidate - value)
            if distance < bestDistance {
                bestDistance = distance
                best = candidate
            }
        }
        return best
    }

    /// Keeps a frame fully inside `visible` (used when snapping is off).
    static func clamped(_ frame: NSRect, in visible: NSRect, margin: CGFloat = 4) -> NSRect {
        var result = frame
        result.origin.x = min(max(frame.origin.x, visible.minX + margin), max(visible.minX + margin, visible.maxX - frame.width - margin))
        result.origin.y = min(max(frame.origin.y, visible.minY + margin), max(visible.minY + margin, visible.maxY - frame.height - margin))
        return result
    }
}

/// Distance from an edge at which the widget gives in and snaps.
private let snapThreshold: CGFloat = 30

@MainActor
final class WidgetPanelController {

    static let shared = WidgetPanelController()

    private var panel: WidgetPanel?
    private var guide: SnapGuideWindow?
    private var hostingView: NSHostingView<WidgetView>?
    private var cancellables = Set<AnyCancellable>()
    private let originKey = "widgetOrigin"
    private let anchorKey = "widgetAnchor"
    private var snapWorkItem: DispatchWorkItem?

    /// Which screen edges the widget is currently resting against. Remembered so
    /// that changing density keeps it flush instead of drifting off the corner.
    struct EdgeAnchor: Codable {
        var left = false
        var right = false
        var top = false
        var bottom = false

        var isEmpty: Bool { !left && !right && !top && !bottom }
    }

    private var anchor = EdgeAnchor()
    private var grid: DesktopWidgetGrid = .default
    private var gridCheckedAt: Date?
    private var hasRestoredOrigin = false
    private var refitScheduled = false

    private init() {}

    // MARK: - Visibility

    var isVisible: Bool { panel?.isVisible ?? false }

    func applyVisibility() {
        if AppSettings.shared.showWidget {
            show()
        } else {
            hide()
        }
    }

    func toggle() {
        AppSettings.shared.showWidget.toggle()
        applyVisibility()
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        applyWindowTraits()

        // Order matters: the saved position is a *top* edge, so it can only be
        // applied once the window has its real content height. Restoring it before
        // the first fit is what pushed the widget 105 pt off the grid.
        resizeToFit(animated: false)
        if !hasRestoredOrigin {
            hasRestoredOrigin = true
            restoreOrigin(on: panel)
            if anchor.isEmpty {
                // A window already sitting in a corner counts as anchored, even if
                // it was placed by an older build that had no anchoring at all.
                anchor = anchorFor(panel.frame, on: panel)
                saveAnchor()
            }
        }
        // Snap without a distance limit on launch: a raw pixel position saved
        // earlier should be normalised onto the grid rather than left drifting.
        if AppSettings.shared.snapToEdges {
            snapWorkItem?.cancel()
            snapIfNeeded(animated: false, force: true)
        }
        // Restoring the origin fires didMove, which briefly raises the alignment
        // preview; make sure a launch never leaves it behind.
        hideGuide()
        panel.orderFrontRegardless()
    }

    func hide() {
        hideGuide()
        panel?.orderOut(nil)
    }

    func applyWindowTraits() {
        guard let panel else { return }
        panel.level = AppSettings.shared.level.nsLevel
    }

    // MARK: - Construction

    private func makePanel() -> WidgetPanel {
        let density = AppSettings.shared.density
        let panel = WidgetPanel(
            contentRect: NSRect(x: 0, y: 0, width: density.width, height: 240),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.title = "AI 用量"

        let root = WidgetView(
            store: UsageStore.shared,
            settings: AppSettings.shared,
            onOpenSettings: { SettingsWindowController.shared.show() },
            onQuit: { NSApp.terminate(nil) }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.translatesAutoresizingMaskIntoConstraints = true
        panel.contentView = hosting
        hostingView = hosting

        anchor = loadAnchor()

        // Re-fit the window whenever the content or the settings change.
        let refit: () -> Void = { [weak self] in
            guard let self, !self.refitScheduled else { return }
            self.refitScheduled = true
            DispatchQueue.main.async {
                self.refitScheduled = false
                self.resizeToFit(animated: true)
            }
        }
        UsageStore.shared.objectWillChange.sink { _ in refit() }.store(in: &cancellables)
        AppSettings.shared.objectWillChange.sink { _ in refit() }.store(in: &cancellables)

        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            // Delivered on the main queue; the closure itself is not isolated.
            MainActor.assumeIsolated { self?.handleMove() }
        }

        return panel
    }

    // MARK: - Sizing

    /// Keeps the window exactly as tall as its SwiftUI content, anchored top-left
    /// so the widget grows downward instead of jumping.
    private func resizeToFit(animated: Bool) {
        guard let panel, let hostingView else { return }
        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize
        guard fitting.height > 1 else { return }

        let newSize = NSSize(width: AppSettings.shared.density.width, height: fitting.height)
        guard abs(panel.frame.height - newSize.height) > 0.5 || abs(panel.frame.width - newSize.width) > 0.5 else { return }

        let top = panel.frame.maxY
        var frame = panel.frame
        frame.size = newSize
        frame.origin.y = top - newSize.height
        panel.setFrame(frame, display: true, animate: animated)

        // A density change moves the far edge; re-pin the edges the widget was
        // resting against so it stays flush instead of drifting off the corner.
        if AppSettings.shared.snapToEdges {
            reapplyAnchor(on: panel)
            snapIfNeeded(animated: animated)
        } else {
            clampToScreen(panel)
        }
    }

    /// Re-pins a resized window to whichever edges it was anchored to.
    private func reapplyAnchor(on panel: NSWindow) {
        guard !anchor.isEmpty, let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let inset = AppSettings.shared.density.snapInset
        var frame = panel.frame
        if anchor.left { frame.origin.x = visible.minX + inset }
        if anchor.right { frame.origin.x = visible.maxX - frame.width - inset }
        if anchor.bottom { frame.origin.y = visible.minY + inset }
        if anchor.top { frame.origin.y = visible.maxY - frame.height - inset }
        if frame != panel.frame {
            panel.setFrame(frame, display: true)
            storeOrigin()
        }
    }

    private func clampToScreen(_ panel: NSWindow) {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let clamped = SnapMath.clamped(panel.frame, in: screen.visibleFrame)
        if clamped != panel.frame { panel.setFrame(clamped, display: true) }
    }

    // MARK: - Edge snapping

    /// During a drag we debounce: once the pointer pauses, snap. Snapping mid-drag
    /// fights the cursor, and AppKit gives no "drag ended" callback for
    /// `isMovableByWindowBackground`.
    private func handleMove() {
        storeOrigin()
        guard AppSettings.shared.snapToEdges else { return }
        showGuideForCurrentPosition()

        snapWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.snapIfNeeded(animated: true)
                self?.hideGuide()
            }
        }
        snapWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    /// The frame this panel would occupy if it snapped right now, or nil when it
    /// is not near an edge.
    private func snapTarget(for panel: NSWindow, force: Bool = false) -> NSRect? {
        guard let screen = panel.screen ?? NSScreen.main else { return nil }
        return SnapMath.snapped(
            panel.frame,
            in: screen.visibleFrame,
            // Forcing means "find the nearest grid line no matter how far".
            threshold: force ? 400 : snapThreshold,
            inset: AppSettings.shared.density.snapInset,
            grid: currentGrid(on: screen)
        )
    }

    /// The desktop-widget grid is re-read occasionally: the user can add or remove
    /// system widgets while we are running.
    private func currentGrid(on screen: NSScreen) -> DesktopWidgetGrid {
        if let checked = gridCheckedAt, Date().timeIntervalSince(checked) < 60 {
            return grid
        }
        grid = DesktopWidgetGrid.detect(on: screen)
        gridCheckedAt = Date()
        return grid
    }

    private func snapIfNeeded(animated: Bool, force: Bool = false) {
        guard let panel else { return }
        guard let target = snapTarget(for: panel, force: force) else {
            clampToScreen(panel)
            anchor = EdgeAnchor()
            saveAnchor()
            return
        }
        anchor = anchorFor(target, on: panel)
        saveAnchor()
        guard target.origin != panel.frame.origin else { return }
        panel.setFrame(target, display: true, animate: animated)
        storeOrigin()
    }

    /// Derives which edges a frame is resting against.
    private func anchorFor(_ frame: NSRect, on panel: NSWindow) -> EdgeAnchor {
        guard let screen = panel.screen ?? NSScreen.main else { return EdgeAnchor() }
        let visible = screen.visibleFrame
        let inset = AppSettings.shared.density.snapInset
        let tolerance: CGFloat = 2
        return EdgeAnchor(
            left: abs(frame.minX - (visible.minX + inset)) < tolerance,
            right: abs(frame.maxX - (visible.maxX - inset)) < tolerance,
            top: abs(frame.maxY - (visible.maxY - inset)) < tolerance,
            bottom: abs(frame.minY - (visible.minY + inset)) < tolerance
        )
    }

    private func showGuideForCurrentPosition() {
        guard let panel, let target = snapTarget(for: panel) else {
            hideGuide()
            return
        }
        let guide = self.guide ?? SnapGuideWindow()
        self.guide = guide
        guide.setFrame(target, display: true)
        guide.orderFrontRegardless()
    }

    private func hideGuide() {
        guide?.orderOut(nil)
    }

    // MARK: - Position persistence

    private func restoreOrigin(on panel: NSWindow) {
        let defaults = UserDefaults.standard
        if let saved = defaults.dictionary(forKey: originKey),
           let x = saved["x"] as? Double {
            // Older builds stored only the bottom-left origin; fall back to it.
            let top = (saved["top"] as? Double) ?? ((saved["y"] as? Double).map { $0 + panel.frame.height })
            if let top {
                panel.setFrameOrigin(NSPoint(x: x, y: top - panel.frame.height))
                clampToScreen(panel)
                return
            }
        }
        // First run: top-right, on the same grid the system widgets use.
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let detected = DesktopWidgetGrid.detect(on: screen)
        let inset = detected.detected ? detected.margin : AppSettings.shared.density.snapInset
        panel.setFrameOrigin(NSPoint(
            x: visible.maxX - panel.frame.width - inset,
            y: visible.maxY - panel.frame.height
        ))
    }

    private func loadAnchor() -> EdgeAnchor {
        guard let data = UserDefaults.standard.data(forKey: anchorKey),
              let decoded = try? JSONDecoder().decode(EdgeAnchor.self, from: data)
        else { return EdgeAnchor() }
        return decoded
    }

    private func saveAnchor() {
        guard let data = try? JSONEncoder().encode(anchor) else { return }
        UserDefaults.standard.set(data, forKey: anchorKey)
    }

    private func storeOrigin() {
        guard let panel else { return }
        // `top` is the durable value: the widget grows and shrinks downwards, so
        // the top edge is what the user actually positioned.
        UserDefaults.standard.set(
            [
                "x": panel.frame.origin.x,
                "top": panel.frame.maxY,
                "y": panel.frame.origin.y,
            ],
            forKey: originKey
        )
    }
}

/// Standalone settings window (built by hand so it behaves the same whether or not
/// the app is running as a bundled agent).
@MainActor
final class SettingsWindowController {

    static let shared = SettingsWindowController()

    private var window: NSWindow?

    private init() {}

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingView(rootView: SettingsView(settings: AppSettings.shared))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 720),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AI 用量 · 设置"
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.center()
        window.level = .normal
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
