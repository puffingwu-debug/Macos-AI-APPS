import SwiftUI

/// 待办列表：分组（未完成 / 已完成）+ 排序切换 + 下拉刷新式的同步按钮。
struct TodoListView: View {

    @ObservedObject var state: AppState
    @ObservedObject var settings: AppSettings
    let controller: PanelController

    @State private var showDone = true

    var body: some View {
        VStack(spacing: 0) {
            filterBar

            if state.groups.isEmpty {
                EmptyStateView(hasCloud: settings.hasCloud)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        section(title: "未完成", count: state.groups.pending.count, todos: state.groups.pending)
                        if !state.groups.done.isEmpty {
                            doneSectionHeader
                            if showDone {
                                section(title: nil, count: 0, todos: state.groups.done)
                            }
                        }
                        Color.clear.frame(height: 4)
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                }
            }
        }
    }

    // MARK: - 顶部筛选条

    private var filterBar: some View {
        HStack(spacing: 6) {
            Text("\(state.groups.pending.count) 项待办")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Menu {
                ForEach(TodoSortMode.allCases) { mode in
                    Button {
                        state.setSortMode(mode)
                    } label: {
                        if settings.sortMode == mode {
                            Label(mode.label, systemImage: "checkmark")
                        } else {
                            Text(mode.label)
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 9))
                    Text(settings.sortMode.label)
                        .font(.system(size: 10))
                }
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            if !state.groups.done.isEmpty {
                Button {
                    state.clearDone()
                } label: {
                    Text("清空已完成")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var doneSectionHeader: some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) { showDone.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: showDone ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                Text("已完成 \(state.groups.done.count)")
                    .font(.system(size: 10, weight: .medium))
                Spacer()
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
    }

    // MARK: - 分组

    @ViewBuilder
    private func section(title: String?, count: Int, todos: [Todo]) -> some View {
        if todos.isEmpty, title != nil {
            HStack {
                Spacer()
                Text("暂无待办，按 \(HotKeyManager.describe(keyCode: settings.hotKeyCode, modifiers: settings.hotKeyModifiers)) 截个图试试")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.vertical, 18)
        } else {
            ForEach(todos) { todo in
                TodoRowView(
                    todo: todo,
                    onToggle: { state.toggleDone(todo) },
                    onEdit: { state.editing = todo },
                    onDelete: { state.delete(todo) }
                )
            }
        }
    }
}

// MARK: - 单条待办

struct TodoRowView: View {
    let todo: Todo
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // 勾选框
            Button(action: onToggle) {
                ZStack {
                    Circle()
                        .strokeBorder(todo.isDone ? Palette.accent : Color.secondary.opacity(0.5), lineWidth: 1.5)
                        .frame(width: 15, height: 15)
                    if todo.isDone {
                        Circle().fill(Palette.accent).frame(width: 15, height: 15)
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.top, 1)

            // 优先级色条
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Palette.color(for: todo.priority).opacity(todo.isDone ? 0.35 : 1))
                .frame(width: 3)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 3) {
                Text(todo.content)
                    .font(.system(size: 12))
                    .foregroundStyle(todo.isDone ? .secondary : .primary)
                    .strikethrough(todo.isDone, color: .secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Image(systemName: todo.source.symbol)
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .help("来源：\(todo.source.label)")

                    if let deadline = todo.deadline {
                        HStack(spacing: 2) {
                            Image(systemName: "clock")
                                .font(.system(size: 8))
                            Text(TimeText.deadline(deadline))
                                .font(.system(size: 9))
                        }
                        .foregroundStyle(todo.isOverdue ? Palette.high : .secondary)
                        .help(todo.isDone ? "" : TimeText.remaining(deadline))
                    }

                    if todo.priority == .high {
                        Text("高优")
                            .font(.system(size: 8, weight: .medium))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Palette.high.opacity(0.14)))
                            .foregroundStyle(Palette.high)
                    }

                    Spacer(minLength: 0)

                    if hovering {
                        Button(action: onEdit) {
                            Image(systemName: "pencil")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("编辑")

                        Button(action: onDelete) {
                            Image(systemName: "trash")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("删除")
                    } else {
                        Text(TimeText.relative(todo.createTime))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.055) : Color.primary.opacity(0.025))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button(todo.isDone ? "标记为未完成" : "标记为已完成") { onToggle() }
            Button("编辑…") { onEdit() }
            if let deadline = todo.deadline {
                Text("截止：\(TimeText.deadline(deadline))")
            }
            if !todo.rawText.isEmpty {
                Button("查看原文") { onEdit() }
            }
            Divider()
            Button("删除") { onDelete() }
        }
    }
}

// MARK: - 空状态

struct EmptyStateView: View {
    let hasCloud: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text("还没有待办")
                .font(.system(size: 12, weight: .medium))
            Text(hasCloud
                 ? "按下快捷键截图，或在下方输入框添加"
                 : "当前为本地模式：配置云环境后可多端同步")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
    }
}
