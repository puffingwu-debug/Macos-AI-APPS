import AppKit
import SwiftUI

/// 面板根视图：同一个窗口在「侧边小球」和「待办面板」两种形态间切换。
struct RootView: View {

    @ObservedObject var state: AppState
    @ObservedObject var settings: AppSettings
    let controller: PanelController

    var body: some View {
        ZStack {
            if state.isExpanded {
                expandedPanel
            } else {
                BallView(state: state, settings: settings, controller: controller)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .overlay(alignment: .top) {
            if let toast = state.toast {
                ToastView(message: toast) { state.dismissToast() }
                    .padding(.top, state.isExpanded ? 52 : 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: state.toast)
        .sheet(isPresented: $state.showSettings) {
            SettingsView(state: state, settings: settings, controller: controller)
        }
        .sheet(item: $state.editing) { todo in
            EditorView(state: state, todo: todo)
        }
        .onChange(of: state.capture) { _, newValue in
            // 截图/AI 流程进行中或等待确认时，禁止自动隐藏，否则用户看不到结果
            controller.suppressAutoHide = newValue.isBusy || newValue != .idle
        }
    }

    // MARK: - 展开形态

    private var expandedPanel: some View {
        VStack(spacing: 0) {
            PanelHeader(state: state, controller: controller)
            Divider().opacity(0.35)

            Group {
                switch state.capture {
                case .idle:
                    TodoListView(state: state, settings: settings, controller: controller)
                case .ready(let draft):
                    ImportPreviewView(state: state, draft: draft)
                case .failed(let message, let rawText):
                    CaptureFailedView(state: state, message: message, rawText: rawText)
                case .capturing, .recognizing, .analyzing:
                    CaptureBusyView(stage: state.capture) { state.discardCapture() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().opacity(0.35)
            QuickAddBar(state: state)
        }
        .background(PanelBackground(opacity: settings.panelOpacity))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        )
        .padding(6)
    }
}

// MARK: - 面板背景

/// 半透明毛玻璃 + 可调不透明度。窗口本身透明，圆角由这里负责。
///
/// 透明度只作用在**背景**上（而不是整个窗口的 alphaValue），
/// 这样调低透明度时文字依然清晰可读。
struct PanelBackground: View {
    var opacity: Double

    var body: some View {
        VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
            .overlay(Color(nsColor: .windowBackgroundColor).opacity(min(max(opacity, 0.35), 1.0)))
            .ignoresSafeArea()
    }
}

/// NSVisualEffectView 的 SwiftUI 包装。
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
    }
}

// MARK: - 头部

struct PanelHeader: View {
    @ObservedObject var state: AppState
    let controller: PanelController

    @State private var dragging = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checklist")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.accent)

            VStack(alignment: .leading, spacing: 1) {
                Text("闪记待办")
                    .font(.system(size: 13, weight: .semibold))
                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 5, height: 5)
                    Text(statusText)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if state.sync.state.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            }

            HeaderButton(symbol: "viewfinder", help: "区域截图识别（\(HotKeyManager.describe(keyCode: state.settings.hotKeyCode, modifiers: state.settings.hotKeyModifiers))）") {
                state.runScreenshotFlow()
            }
            HeaderButton(symbol: "arrow.clockwise", help: "立即同步") {
                state.syncNow()
            }
            HeaderButton(symbol: "gearshape", help: "设置") {
                state.showSettings = true
            }
            HeaderButton(symbol: "chevron.right", help: "收起为悬浮球") {
                state.isExpanded = false
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .gesture(
            // 拖拽头部移动窗口：用全局鼠标位置计算，避免窗口移动造成坐标系反馈
            DragGesture(minimumDistance: 3)
                .onChanged { _ in
                    if !dragging {
                        dragging = true
                        controller.beginDrag()
                    }
                    controller.updateDrag()
                }
                .onEnded { _ in
                    dragging = false
                    controller.endDrag()
                }
        )
    }

    private var statusColor: Color {
        switch state.sync.state {
        case .idle: return Palette.accent
        case .syncing: return Palette.normal
        case .localOnly, .unauthorized: return Palette.low
        case .offline, .error: return Palette.warning
        }
    }

    private var statusText: String {
        if state.store.hasPendingChanges {
            return "\(state.sync.state.label) · 有本地改动待上传"
        }
        return state.sync.state.label
    }
}

struct HeaderButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? Color.primary.opacity(0.10) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

// MARK: - 底部快速新增

struct QuickAddBar: View {
    @ObservedObject var state: AppState
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Palette.accent)

            TextField("添加待办，支持「明天下午3点…」", text: $state.quickAddText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($focused)
                .onSubmit { state.addQuick() }

            if !state.quickAddText.isEmpty {
                Button {
                    state.analyzeManualText(state.quickAddText, source: .manual)
                } label: {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.accent)
                }
                .buttonStyle(.plain)
                .help("交给 AI 拆分成多条待办")

                Button {
                    state.addQuick()
                } label: {
                    Text("添加")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Palette.accent.opacity(0.16)))
                        .foregroundStyle(Palette.accent)
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .help("先输入或粘贴文本，再用 AI 拆分")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

// MARK: - Toast

struct ToastView: View {
    let message: ToastMessage
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Palette.color(for: message.kind))
                .frame(width: 6, height: 6)
            Text(message.text)
                .font(.system(size: 11))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        )
        .padding(.horizontal, 12)
    }
}
