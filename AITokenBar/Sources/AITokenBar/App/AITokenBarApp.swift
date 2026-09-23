import SwiftUI
import AppKit

/// Explicit entry point so the binary doubles as a diagnostic tool:
/// `AITokenBar --scan-once` prints what each data source found and exits;
/// `AITokenBar --render out.png` draws the widget to an image.
@main
enum Main {
    static func main() async {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--render") {
            let path = args.count > index + 1 ? args[index + 1] : "widget-preview.png"
            var backdrop: NSColor?
            if let index = args.firstIndex(of: "--bg"), args.count > index + 1 {
                let parts = args[index + 1].split(separator: ",").compactMap { Double($0) }
                if parts.count == 3 {
                    backdrop = NSColor(srgbRed: parts[0]/255, green: parts[1]/255, blue: parts[2]/255, alpha: 1)
                }
            }
            await CLIDiagnostics.renderWidget(
                to: path,
                scheme: args.contains("--light") ? .light : .dark,
                backdrop: backdrop
            )
            exit(0)
        }
        if args.contains("--grid") {
            let ok = CLIDiagnostics.dumpGrid()
            exit(ok ? 0 : 1)
        }
        if args.contains("--self-test") {
            let ok = CLIDiagnostics.selfTest()
            exit(ok ? 0 : 1)
        }
        if args.contains("--scan-once") {
            await CLIDiagnostics.run()
            exit(0)
        }
        AITokenBarApp.main()
    }
}

struct AITokenBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = UsageStore.shared
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel(store: store, settings: settings)
        } label: {
            if settings.showMenuBarText {
                Text(store.menuBarTitle)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
            } else {
                Image(systemName: "gauge.with.dots.needle.67percent")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only agent: no Dock icon, no app switcher entry.
        NSApp.setActivationPolicy(.accessory)

        UsageStore.shared.start()
        WidgetPanelController.shared.applyVisibility()

        NotificationCenter.default.addObserver(
            forName: .aiTokenBarSettingsChanged,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                WidgetPanelController.shared.applyWindowTraits()
                WidgetPanelController.shared.applyVisibility()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

/// Contents of the menu bar popover — a compact mirror of the floating widget
/// plus the controls that are easier to reach from the menu bar.
@MainActor
struct MenuBarPanel: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The popover always has room, so it renders the widget at full
            // density regardless of how small the floating window is set.
            WidgetView(
                store: store,
                settings: settings,
                onOpenSettings: { SettingsWindowController.shared.show() },
                onQuit: { NSApp.terminate(nil) },
                densityOverride: .full
            )

            Divider()

            HStack(spacing: 8) {
                Button(settings.showWidget ? "隐藏悬浮窗" : "显示悬浮窗") {
                    settings.showWidget.toggle()
                    WidgetPanelController.shared.applyVisibility()
                }
                Button("刷新") { store.refreshNow() }
                Spacer()
                Text(store.isScanning ? "扫描中…" : "就绪")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: WidgetDensity.full.width + 24)
    }
}
