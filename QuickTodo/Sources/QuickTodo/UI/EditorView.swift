import SwiftUI

/// 新增 / 编辑待办。
struct EditorView: View {

    @ObservedObject var state: AppState
    @State var todo: Todo
    @Environment(\.dismiss) private var dismiss

    private let isNew: Bool

    init(state: AppState, todo: Todo) {
        self.state = state
        _todo = State(initialValue: todo)
        // 内容为空视为「新增」
        isNew = todo.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isNew ? "新增待办" : "编辑待办")
                .font(.system(size: 13, weight: .semibold))

            TextEditor(text: $todo.content)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(5)
                .frame(height: 68)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                .overlay(alignment: .topLeading) {
                    if todo.content.isEmpty {
                        Text("要做什么？")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }

            HStack(spacing: 8) {
                Text("截止")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                DeadlineInline(millis: $todo.deadline)
                Spacer()
            }

            HStack(spacing: 8) {
                Text("优先级")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Picker("", selection: $todo.priority) {
                    ForEach(TodoPriority.allCases) { priority in
                        Text(priority.label).tag(priority)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                Spacer()
            }

            if !todo.rawText.isEmpty {
                DisclosureGroup {
                    Text(todo.rawText)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("来源：\(todo.source.label) · 查看原始识别文本")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                if !isNew {
                    Button("删除") {
                        state.delete(todo)
                        dismiss()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.high)
                }

                Spacer()

                Button("取消") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Button {
                    state.save(todo, isNew: isNew)
                    dismiss()
                } label: {
                    Text("保存")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Palette.accent))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(todo.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}

/// 编辑器里的截止时间行：一个按钮 + 弹层。
struct DeadlineInline: View {
    @Binding var millis: Int64?

    @State private var showPicker = false

    var body: some View {
        HStack(spacing: 4) {
            Button {
                showPicker.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                        .font(.system(size: 10))
                    Text(millis.map { TimeText.deadline($0) } ?? "未设置")
                        .font(.system(size: 11))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showPicker, arrowEdge: .bottom) {
                DeadlinePicker(millis: $millis)
            }

            if millis != nil {
                Button {
                    millis = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
