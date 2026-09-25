import SwiftUI

// MARK: - 加载中（截图 → OCR → AI 解析）

struct CaptureBusyView: View {
    let stage: CaptureStage
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .controlSize(.regular)
            Text(stage.busyLabel)
                .font(.system(size: 12, weight: .medium))
            stepIndicator
            Spacer()
            Button("取消") { onCancel() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 三步进度提示，让「轻量加载状态」有明确预期。
    private var stepIndicator: some View {
        HStack(spacing: 6) {
            step("截图", active: stage == .capturing, done: stage != .capturing)
            line
            step("识别文字", active: stage == .recognizing, done: stage == .analyzing)
            line
            step("AI 整理", active: stage == .analyzing, done: false)
        }
    }

    private func step(_ title: String, active: Bool, done: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: done ? "checkmark.circle.fill" : (active ? "circle.inset.filled" : "circle"))
                .font(.system(size: 8))
                .foregroundStyle(done ? Palette.accent : (active ? Palette.normal : Color.secondary.opacity(0.5)))
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(active ? .primary : .secondary)
        }
    }

    private var line: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.3))
            .frame(width: 12, height: 1)
    }
}

// MARK: - 解析结果预览（导入前可编辑）

struct ImportPreviewView: View {

    @ObservedObject var state: AppState
    @State var draft: CaptureDraft

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.accent)
                Text("\(draft.engineNote) · 共 \(draft.items.count) 条")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            ScrollView {
                VStack(spacing: 6) {
                    ForEach($draft.items) { $item in
                        DraftRow(item: $item)
                    }

                    if !draft.rawText.isEmpty {
                        DisclosureGroup {
                            Text(draft.rawText)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                        } label: {
                            Text("查看原始识别文本")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }

            HStack(spacing: 8) {
                Button("取消") { state.discardCapture() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Spacer()

                Text("已选 \(draft.selectedCount) 条")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Button {
                    state.updateDraft(draft)
                    state.importDraft()
                } label: {
                    Text("导入待办")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Palette.accent))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(draft.selectedCount == 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .onChange(of: draft) { _, newValue in
            state.updateDraft(newValue)
        }
    }
}

/// 预览里的一条：勾选 + 改内容 + 改时间 + 改优先级。
struct DraftRow: View {
    @Binding var item: DraftItem

    @State private var showDatePicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 7) {
                Button {
                    item.selected.toggle()
                } label: {
                    Image(systemName: item.selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(item.selected ? Palette.accent : Color.secondary.opacity(0.5))
                }
                .buttonStyle(.plain)

                TextField("待办内容", text: $item.content)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }

            HStack(spacing: 6) {
                Spacer().frame(width: 20)

                Button {
                    showDatePicker.toggle()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "clock")
                            .font(.system(size: 8))
                        Text(item.deadline.map { TimeText.deadline($0) } ?? "设置截止")
                            .font(.system(size: 9))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                    .foregroundStyle(item.deadline == nil ? .secondary : .primary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showDatePicker, arrowEdge: .bottom) {
                    DeadlinePicker(millis: $item.deadline)
                }

                Menu {
                    ForEach(TodoPriority.allCases) { priority in
                        Button("\(priority.label)优先级") { item.priority = priority }
                    }
                    Divider()
                    Button("不设优先级") { item.priority = .normal }
                } label: {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(Palette.color(for: item.priority))
                            .frame(width: 6, height: 6)
                        Text("\(item.priority.label)优先级")
                            .font(.system(size: 9))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Palette.color(for: item.priority).opacity(0.12)))
                    .foregroundStyle(Palette.color(for: item.priority))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()

                Spacer(minLength: 0)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(item.selected ? 0.05 : 0.02))
        )
        .opacity(item.selected ? 1 : 0.55)
    }
}

// MARK: - 失败降级：直接编辑原始文本

struct CaptureFailedView: View {

    @ObservedObject var state: AppState
    let message: String
    @State var rawText: String

    init(state: AppState, message: String, rawText: String) {
        self.state = state
        self.message = message
        _rawText = State(initialValue: rawText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.warning)
                Text("自动识别没成功")
                    .font(.system(size: 11, weight: .medium))
            }

            Text(message)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // 降级：把原始文本给你，手动改完直接存
            TextEditor(text: $rawText)
                .font(.system(size: 11))
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
                .frame(minHeight: 80)

            HStack(spacing: 8) {
                Button("放弃") { state.discardCapture() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                if !ScreenshotService.hasPermission {
                    Button("打开屏幕录制设置") {
                        ScreenshotService.openPermissionSettings()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.normal)
                }

                Spacer()

                Button {
                    state.analyzeManualText(rawText)
                } label: {
                    Text("再解析一次")
                        .font(.system(size: 11))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .disabled(rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    state.importRawText(rawText)
                } label: {
                    Text("按原文保存")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Palette.accent))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - 截止时间选择器

struct DeadlinePicker: View {
    @Binding var millis: Int64?

    @State private var date = Date()
    @State private var hasTime = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DatePicker("截止时间", selection: $date, displayedComponents: hasTime ? [.date, .hourAndMinute] : [.date])
                .datePickerStyle(.compact)
                .font(.system(size: 11))

            Toggle("包含具体时间", isOn: $hasTime)
                .font(.system(size: 11))
                .toggleStyle(.checkbox)

            HStack(spacing: 6) {
                quickButton("今天 18:00") { makeToday(hour: 18) }
                quickButton("明天 09:00") { makeTomorrow(hour: 9) }
                quickButton("本周末") { makeWeekend() }
            }

            HStack {
                Button("清除") { millis = nil }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("确定") { millis = Int64(date.timeIntervalSince1970 * 1000) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.accent)
            }
        }
        .padding(12)
        .frame(width: 250)
        .onAppear {
            if let millis { date = Date(timeIntervalSince1970: Double(millis) / 1000) }
        }
    }

    private func quickButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
        }
        .buttonStyle(.plain)
    }

    private func makeToday(hour: Int) {
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: Date())
        components.hour = hour
        components.minute = 0
        date = calendar.date(from: components) ?? Date()
    }

    private func makeTomorrow(hour: Int) {
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: Date())
        components.day = (components.day ?? 0) + 1
        components.hour = hour
        components.minute = 0
        date = calendar.date(from: components) ?? Date()
    }

    private func makeWeekend() {
        let calendar = Calendar.current
        let now = Date()
        var delta = (7 - calendar.component(.weekday, from: now)) % 7   // 到周六
        if delta <= 0 { delta += 7 }
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.day = (components.day ?? 0) + delta
        components.hour = 10
        components.minute = 0
        date = calendar.date(from: components) ?? now
    }
}
