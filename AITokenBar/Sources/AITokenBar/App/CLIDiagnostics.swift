import Foundation
import AppKit
import SwiftUI

/// `AITokenBar --scan-once` runs every data source once, prints what it found and
/// exits. Handy for verifying the log parsers without opening the widget.
///
/// `AITokenBar --render <path.png>` additionally draws the widget off-screen, which
/// is how the layout is checked without needing Screen Recording permission.
enum CLIDiagnostics {

    /// Renders the widget at every density using live data, so the three layouts
    /// can be checked without Screen Recording permission.
    @MainActor
    static func renderWidget(to path: String, scheme: ColorScheme = .dark, backdrop: NSColor? = nil) async {
        _ = NSApplication.shared
        let store = UsageStore.shared
        store.start()
        // Give the first log scan and the balance call time to land.
        try? await Task.sleep(nanoseconds: 4_000_000_000)

        let settings = AppSettings.shared
        let saved = settings.density
        let base = (path as NSString).deletingPathExtension
        let ext = (path as NSString).pathExtension.isEmpty ? "png" : (path as NSString).pathExtension

        for density in WidgetDensity.allCases {
            settings.density = density
            // Let SwiftUI settle on the new layout before snapshotting it.
            try? await Task.sleep(nanoseconds: 400_000_000)

            let view = WidgetView(
                store: store,
                settings: settings,
                onOpenSettings: {},
                onQuit: {}
            )
            // Stand-in for the desktop the material would normally blur. Defaults
            // to the wallpaper colour measured behind the real widget, so a
            // rendered body colour can be compared against the system's widgets.
            .environment(\.colorScheme, scheme)
            .background(Color(nsColor: backdrop ?? NSColor(srgbRed: 86/255, green: 96/255, blue: 82/255, alpha: 1)))

            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:])
            else {
                print("渲染失败：\(density.rawValue)")
                continue
            }
            let target = "\(base)-\(density.rawValue).\(ext)"
            do {
                try png.write(to: URL(fileURLWithPath: target))
                print("已渲染 \(density.title) \(Int(image.size.width))x\(Int(image.size.height)) → \(target)")
            } catch {
                print("写入失败：\(error.localizedDescription)")
            }
        }
        settings.density = saved
    }

    /// Prints what the desktop-widget grid detector actually sees.
    @MainActor
    static func dumpGrid() -> Bool {
        print("=== 桌面小组件网格 ===")
        guard let screen = NSScreen.main else {
            print("没有可用屏幕")
            return false
        }
        let visible = screen.visibleFrame
        print(String(format: "屏幕 frame      : %@", NSStringFromRect(screen.frame)))
        print(String(format: "可见区 visibleFrame: %@", NSStringFromRect(visible)))
        let grid = DesktopWidgetGrid.detect(on: screen)
        if grid.detected {
            print("检测到系统小组件：")
            print("  列左边缘 x    : \(grid.columns.map { String(format: "%.0f", $0) }.joined(separator: ", "))")
            print("  行顶边   y    : \(grid.rowTops.map { String(format: "%.0f", $0) }.joined(separator: ", "))")
            print(String(format: "  左边距        : %.0f", grid.margin))
            print(String(format: "  网格间距      : %.0f", grid.pitch))
        } else {
            print("未检测到系统小组件，将使用默认网格")
        }

        let size = NSSize(width: AppSettings.shared.density.width, height: 135)
        print("\n以 \(Int(size.width))x\(Int(size.height)) 的窗口为例，各投放位置会吸附到：")
        for probe in [(8.0, 257.0), (8.0, 249.0), (200.0, 400.0), (600.0, 300.0)] {
            let frame = NSRect(x: probe.0, y: probe.1, width: size.width, height: size.height)
            if let snapped = SnapMath.snapped(frame, in: visible, threshold: 30,
                                              inset: AppSettings.shared.density.snapInset, grid: grid) {
                // CG y, so it can be compared with the window list directly.
                let cgY = screen.frame.height - snapped.origin.y - snapped.height
                print(String(format: "  (%.0f, %.0f) → x=%.0f y=%.0f  (CG y=%.0f)",
                             probe.0, probe.1, snapped.origin.x, snapped.origin.y, cgY))
            } else {
                print(String(format: "  (%.0f, %.0f) → 不吸附", probe.0, probe.1))
            }
        }
        return true
    }

    /// Checks the snapping geometry against synthetic screen sizes. Runs headless.
    @MainActor
    static func selfTest() -> Bool {
        var failures = 0
        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            if condition {
                print("  ✓ \(name)")
            } else {
                failures += 1
                print("  ✗ \(name) \(detail)")
            }
        }

        let screen = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let inset: CGFloat = 8
        let widget = NSRect(x: 0, y: 0, width: 238, height: 300)

        print("=== 吸附几何自检 ===")

        var frame = widget
        frame.origin = NSPoint(x: 3, y: 300)
        var result = SnapMath.snapped(frame, in: screen, threshold: 30, inset: inset)
        check("贴左边缘", result?.minX == screen.minX + inset,
              "got \(result.map { String(describing: $0.minX) } ?? "nil")")
        check("贴左边缘不改动 Y", result?.minY == 300)

        frame.origin = NSPoint(x: screen.maxX - widget.width - 5, y: 300)
        result = SnapMath.snapped(frame, in: screen, threshold: 30, inset: inset)
        check("贴右边缘", result?.maxX == screen.maxX - inset,
              "got \(result.map { String(describing: $0.maxX) } ?? "nil")")

        frame.origin = NSPoint(x: screen.maxX - widget.width - 4, y: screen.maxY - widget.height - 4)
        result = SnapMath.snapped(frame, in: screen, threshold: 30, inset: inset)
        check("吸附右上角（双轴）", result?.maxX == screen.maxX - inset && result?.maxY == screen.maxY - inset,
              "got \(String(describing: result))")

        frame.origin = NSPoint(x: 600, y: 400)
        result = SnapMath.snapped(frame, in: screen, threshold: 30, inset: inset)
        check("屏幕中央不吸附", result == nil)

        // Distance is measured to where the widget would land (minX + inset), not
        // to the raw screen edge.
        frame.origin = NSPoint(x: 45, y: 400)
        result = SnapMath.snapped(frame, in: screen, threshold: 30, inset: inset)
        check("超出阈值不吸附", result == nil, "got \(String(describing: result))")

        frame.origin = NSPoint(x: inset, y: inset)
        result = SnapMath.snapped(frame, in: screen, threshold: 30, inset: inset)
        check("已对齐时位置不变", result?.origin == frame.origin)

        let stray = NSRect(x: 5000, y: 5000, width: 238, height: 300)
        let clamped = SnapMath.clamped(stray, in: screen)
        check("越界回拉", clamped.maxX <= screen.maxX && clamped.maxY <= screen.maxY, "got \(clamped)")

        // The grid measured on this machine: columns every 180 from x=8,
        // rows every 180 with the top row flush under the menu bar.
        var grid = DesktopWidgetGrid()
        grid.columns = [8, 188]
        grid.rowTops = [941, 761, 581, 401, 221]
        grid.margin = 8
        grid.pitch = 180
        grid.detected = true

        // The screen used here is 875 tall, so the lattice is anchored at 867.
        let tall = NSRect(x: 8, y: 249, width: 306, height: 135)   // top edge at 384
        result = SnapMath.snapped(tall, in: screen, threshold: 30, inset: 8, grid: grid)
        check("吸附到网格行", result?.maxY == 401, "got \(String(describing: result?.maxY))")

        // A row with no system widget on it must still be a snap target.
        let emptyRow = NSRect(x: 8, y: 60, width: 306, height: 135)  // top edge at 195
        result = SnapMath.snapped(emptyRow, in: screen, threshold: 30, inset: 8, grid: grid)
        check("空白行也是吸附目标", result?.maxY == 221, "got \(String(describing: result?.maxY))")

        // A 342-wide widget needs 2 columns (360), so it centres with 9 pt margins.
        let trimmed = NSRect(x: 8, y: 249, width: 342, height: 135)
        result = SnapMath.snapped(trimmed, in: screen, threshold: 30, inset: 8, grid: grid)
        check("槽位居中（8 + (360-342)/2 = 17）", result?.minX == 17, "got \(String(describing: result?.minX))")

        // A widget that fills its span exactly stays flush: centred == flush.
        let exact = NSRect(x: 8, y: 249, width: 360, height: 135)
        result = SnapMath.snapped(exact, in: screen, threshold: 30, inset: 8, grid: grid)
        check("正好占满两列时保持齐平", result?.minX == 8, "got \(String(describing: result?.minX))")

        let offColumn = NSRect(x: 200, y: 249, width: 342, height: 135)
        result = SnapMath.snapped(offColumn, in: screen, threshold: 30, inset: 8, grid: grid)
        check("吸附到第二列槽位（188 + 9 = 197）", result?.minX == 197, "got \(String(describing: result?.minX))")

        let rightAligned = NSRect(x: 56, y: 249, width: 342, height: 135)
        result = SnapMath.snapped(rightAligned, in: screen, threshold: 30, inset: 8, grid: grid)
        check("右边缘对齐列边界（8+180=188 → x=-118 越界时不选）",
              result?.minX != nil)

        let alreadyOnGrid = NSRect(x: 17, y: 266, width: 342, height: 135)
        result = SnapMath.snapped(alreadyOnGrid, in: screen, threshold: 30, inset: 8, grid: grid)
        check("已在网格上时位置不变", result?.origin == alreadyOnGrid.origin,
              "got \(String(describing: result?.origin))")

        // A 312 pt widget cannot fit one 180 pt row, so when it is dropped onto an
        // occupied slot the snap must move it somewhere that is clear for its whole
        // height rather than letting it sit under the system widget.
        let occupied = [NSRect(x: 8, y: 41, width: 180, height: 180),
                        NSRect(x: 188, y: 41, width: 180, height: 180),
                        NSRect(x: 8, y: 221, width: 360, height: 180)]
        let tallWidget = NSRect(x: 17, y: 629, width: 342, height: 312)   // top edge 941
        let placed = SnapMath.snapped(tallWidget, in: screen, threshold: 30, inset: 8,
                                      grid: grid, avoiding: occupied)
        let clearsOccupied = placed.map { candidate in
            !occupied.contains { $0.intersects(candidate) }
        } ?? false
        check("落在已占用槽位时让开", clearsOccupied, "got \(String(describing: placed))")

        let onGridRow = placed.map { candidate in
            grid.rowOrigins(forHeight: 312, in: screen, inset: 8)
                .contains { abs($0 - candidate.minY) < 1 }
        } ?? false
        check("让位后仍贴合网格行", onGridRow, "got \(String(describing: placed?.minY))")

        let freeSpot = NSRect(x: 377, y: 629, width: 342, height: 312)    // nothing under it
        let kept = SnapMath.snapped(freeSpot, in: screen, threshold: 30, inset: 8,
                                    grid: grid, avoiding: occupied)
        check("空位不受影响", kept?.origin == freeSpot.origin, "got \(String(describing: kept?.origin))")

        let noGrid = SnapMath.snapped(tall, in: screen, threshold: 30, inset: 8, grid: nil)
        check("无网格时退回边缘吸附", noGrid != nil)

        print(failures == 0 ? "全部通过" : "\(failures) 项失败")
        return failures == 0
    }

    @MainActor
    static func run() async {
        let settings = AppSettings.shared
        let config = ScanConfig(retentionDays: max(2, settings.codexRetentionDays), scanBudget: 15)
        let started = Date()
        let output = ScanWorker().scan(config: config)
        let elapsed = Date().timeIntervalSince(started)

        print("=== AI 用量 · 本地扫描诊断 ===")
        print(String(format: "耗时 %.2fs  日志根目录: %@", elapsed, ScanPaths.codexSessions.path))

        print("\n--- ChatGPT / Codex ---")
        let codex = output.codex
        if let window = codex.headlineWindow {
            print("窗口        : \(window.label) (window_minutes=\(window.windowMinutes.map(String.init) ?? "nil"))")
            print("已用        : \(Fmt.percent1(window.usedPercent))")
            print("剩余        : \(Fmt.percent1(window.remainingPercent))")
            if let reset = window.resetsAt {
                print("重置时间    : \(Fmt.shortDateTime(reset))  倒计时 \(Fmt.countdown(window.timeRemaining() ?? 0))")
            }
        } else {
            print("窗口        : 未找到")
        }
        for window in codex.windows where window.id != codex.headlineWindow?.id {
            print("其它窗口    : \(window.label) 已用 \(Fmt.percent1(window.usedPercent))")
        }
        print("今日 tokens : \(Fmt.grouped(codex.todayUsage.total)) (入 \(Fmt.grouped(codex.todayUsage.input)) / 缓存 \(Fmt.grouped(codex.todayUsage.cachedInput)) / 出 \(Fmt.grouped(codex.todayUsage.output)))")
        print("近 7 天     : \(Fmt.grouped(codex.weekUsage.total))")
        print("最近活动    : \(codex.lastActivityAt.map { Fmt.relative($0) } ?? "无")")
        print("已解析文件  : \(codex.scannedFiles)")
        print("状态        : \(codex.health.label)")
        let planName = codex.plan.displayName + (codex.plan.accountName.map { " · \($0)" } ?? "")
        print("会员等级    : \(planName)（来源：\(codex.plan.source ?? "未知")）")

        print("\n--- DeepSeek ---")
        let local = output.deepSeekLocal
        print("今日 tokens : \(Fmt.grouped(local.today.total))  请求 \(local.today.requests)")
        print("近 7 天     : \(Fmt.grouped(local.week.total))")
        print("近 30 天    : \(Fmt.grouped(local.month.total))")
        print("本地日志    : \(local.available ? "可用" : (local.errorText ?? "不可用"))")

        if let resolved = CredentialStore.deepSeekKey(override: settings.deepSeekKeyOverride) {
            print("API Key     : \(CredentialStore.mask(resolved.key)) （来源：\(resolved.source)）")
            do {
                let balance = try await DeepSeekProvider().fetchBalance(key: resolved.key)
                let pricing = settings.pricing
                print("余额        : \(Fmt.money(balance.total, currency: balance.currency)) \(balance.currency)")
                print("充值 / 赠金 : \(Fmt.money(balance.toppedUp, currency: balance.currency)) / \(Fmt.money(balance.granted, currency: balance.currency))")
                print("预估今日成本: \(Fmt.money(pricing.cost(for: local.today, peakUsage: local.peakToday), currency: balance.currency))")
                print("预估 7 天   : \(Fmt.money(pricing.cost(for: local.week, peakUsage: local.peakWeek), currency: balance.currency))")
                print("当前时段    : \(ModelPricing.isPeak() ? "高峰（2×）" : "低谷（1×）")")
            } catch {
                print("余额        : 获取失败 - \(error.localizedDescription)")
            }
        } else {
            print("API Key     : 未找到")
        }

        if let auth = CodexLiveProvider.loadAuth() {
            print("\n--- 实时额度接口 ---")
            print("凭据        : 已找到 ChatGPT token (\(CredentialStore.mask(auth.token)))")
            do {
                let live = try await CodexLiveProvider().fetch()
                print("结果        : 成功，\(live.windows.count) 个窗口，套餐 \(live.planType ?? "未知")")
                for window in live.windows {
                    print("  · \(window.label) 已用 \(Fmt.percent1(window.usedPercent))")
                }
            } catch {
                print("结果        : 不可用（\(error.localizedDescription)）→ 将使用本地日志")
            }
        }

        let platformToken = settings.deepSeekPlatformToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !platformToken.isEmpty {
            print("\n--- DeepSeek 平台用量接口 ---")
            do {
                let figures = try await DeepSeekPlatformProvider().fetch(token: platformToken, days: 1)
                print("累计消费    : \(Fmt.money(figures.cumulativeSpend ?? 0, currency: figures.currency))")
                print("今日消费    : \(Fmt.money(figures.periodCost, currency: figures.currency))")
                print("今日 Tokens : \(Fmt.grouped(figures.periodTokens))")
                print("今日请求    : \(Fmt.grouped(figures.periodRequests))")
            } catch {
                print("结果        : 不可用（\(error.localizedDescription)）")
            }
        }
        print("\n=== 完成 ===")
    }
}
