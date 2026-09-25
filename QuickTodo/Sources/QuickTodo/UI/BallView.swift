import AppKit
import SwiftUI

/// 收起形态：桌面边缘的悬浮小球。
///
/// 支持拖拽移动（拖动超过 3px 才进入拖动，避免误触），单击展开待办面板，
/// 右键弹出菜单，悬停显示待办数量。
struct BallView: View {

    @ObservedObject var state: AppState
    @ObservedObject var settings: AppSettings
    let controller: PanelController

    @State private var dragging = false
    @State private var hovering = false

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Palette.accent.opacity(0.98), Palette.accent.opacity(0.78)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: .black.opacity(hovering ? 0.34 : 0.22), radius: hovering ? 9 : 6, y: 2)

            if state.capture.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            } else {
                VStack(spacing: -1) {
                    Image(systemName: "checklist")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    if state.store.pendingCount > 0 {
                        Text("\(state.store.pendingCount)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    } else {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
            }

            // 有未上传改动时右上角一个小黄点
            if state.store.hasPendingChanges {
                Circle()
                    .fill(Palette.warning)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1))
                    .offset(x: 17, y: -17)
            }
        }
        .frame(width: PanelController.ballSize.width, height: PanelController.ballSize.height)
        .scaleEffect(hovering && !dragging ? 1.06 : 1.0)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
        .help("单击展开待办 · 拖动可移动 · \(HotKeyManager.describe(keyCode: settings.hotKeyCode, modifiers: settings.hotKeyModifiers)) 截图识别")
        .contextMenu {
            Button("展开待办面板") { state.isExpanded = true }
            Button("区域截图识别") { state.runScreenshotFlow() }
            Divider()
            Button("立即同步") { state.syncNow() }
            Button("设置…") { state.showSettings = true }
            Divider()
            Button("退出 QuickTodo") { NSApplication.shared.terminate(nil) }
        }
        .gesture(
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
        .onTapGesture {
            state.isExpanded = true
        }
    }
}
