import AppKit
import Foundation

/// 截图/语音 → AI 解析 → 导入 的流水线状态。
enum CaptureStage: Equatable {
    case idle
    case capturing                      // 正在等用户框选
    case recognizing                    // Vision OCR 中
    case analyzing                      // 云端 DeepSeek 分析中
    case ready(CaptureDraft)            // 解析完成，等用户确认导入
    case failed(message: String, rawText: String)

    var isBusy: Bool {
        switch self {
        case .capturing, .recognizing, .analyzing: return true
        case .idle, .ready, .failed: return false
        }
    }

    var busyLabel: String {
        switch self {
        case .capturing: return "请框选要识别的区域…"
        case .recognizing: return "正在识别文字…"
        case .analyzing: return "AI 正在整理待办…"
        default: return ""
        }
    }
}

/// 待确认的导入草稿：每条都能改内容 / 改时间 / 改优先级 / 取消勾选。
struct CaptureDraft: Equatable {
    var rawText: String
    var source: TodoSource
    var engineNote: String
    var items: [DraftItem]

    var selectedCount: Int { items.filter(\.selected).count }
}

struct DraftItem: Identifiable, Equatable {
    var id = UUID()
    var selected = true
    var content: String
    var deadline: Int64?
    var priority: TodoPriority

    init(content: String, deadline: Int64? = nil, priority: TodoPriority = .normal) {
        self.content = content
        self.deadline = deadline
        self.priority = priority
    }

    init(parsed: ParsedTodo) {
        content = parsed.content
        deadline = parsed.deadline
        priority = parsed.priority
    }
}

struct ToastMessage: Identifiable, Equatable {
    enum Kind: Equatable { case info, success, warning, error }
    let id = UUID()
    var text: String
    var kind: Kind
}

/// 全局状态中枢：UI 只跟它说话，它负责调度存储、同步、截图/AI 流水线。
@MainActor
final class AppState: ObservableObject {

    let settings: AppSettings
    let store: LocalStore
    let api: QuickTodoAPI
    let login: LoginService

    @Published private(set) var groups = TodoGroups()
    @Published private(set) var capture: CaptureStage = .idle
    @Published private(set) var toast: ToastMessage?
    @Published private(set) var sessionToken: String?
    @Published private(set) var isLoggedIn = false

    /// 面板展开/收起（持久化）。
    @Published var isExpanded: Bool {
        didSet {
            settings.expanded = isExpanded
            panelController?.setExpanded(isExpanded)
        }
    }

    /// 底部快速新增输入框内容。
    @Published var quickAddText = ""
    /// 正在编辑的待办（nil 表示没有弹窗）。
    @Published var editing: Todo? {
        didSet { if editing != nil { panelController?.prepareForSheet() } }
    }
    /// 是否显示设置页。
    @Published var showSettings = false {
        didSet { if showSettings { panelController?.prepareForSheet() } }
    }

    private(set) var sync: SyncEngine!
    weak var panelController: PanelController?
    private var toastTask: Task<Void, Never>?

    init(settings: AppSettings? = nil,
         store: LocalStore? = nil,
         api: QuickTodoAPI? = nil) {
        let settings = settings ?? AppSettings()
        let store = store ?? LocalStore()
        let api = api ?? QuickTodoAPI()
        self.settings = settings
        self.store = store
        self.api = api
        self.login = LoginService(api: api)
        self.isExpanded = settings.expanded
        self.sessionToken = KeychainStore.loadToken()
        self.isLoggedIn = !(sessionToken ?? "").isEmpty

        self.sync = SyncEngine(
            store: store,
            settings: settings,
            api: api,
            tokenProvider: { [weak self] in self?.sessionToken },
            onUnauthorized: { [weak self] in self?.handleUnauthorized() },
            onDataChanged: { [weak self] in self?.refresh() }
        )

        self.login.onSuccess = { [weak self] token, openid in
            guard let self else { return }
            self.sessionToken = token
            self.isLoggedIn = true
            if !openid.isEmpty { self.store.setOpenid(openid) }
            self.showToast("已登录，开始同步", kind: .success)
            Task { await self.sync.syncNow() }
        }

        refresh()
    }

    func start() {
        sync.start()
        applyHotKey()
        if settings.hasCloud && isLoggedIn {
            Task { await sync.syncNow() }
        }
    }

    // MARK: - 快捷键

    func applyHotKey() {
        let ok = hotKeyManager.register(
            keyCode: settings.hotKeyCode,
            modifiers: settings.hotKeyModifiers
        ) { [weak self] in
            self?.runScreenshotFlow()
        }
        if !ok {
            showToast("快捷键 \(HotKeyManager.describe(keyCode: settings.hotKeyCode, modifiers: settings.hotKeyModifiers)) 注册失败，可能被其他 App 占用", kind: .warning)
        }
    }

    private let hotKeyManager = HotKeyManager()

    // MARK: - 数据

    func refresh() {
        groups = store.visibleTodos.groupedAndSorted(by: settings.sortMode)
    }

    func setSortMode(_ mode: TodoSortMode) {
        settings.sortMode = mode
        refresh()
    }

    func toggleDone(_ todo: Todo) {
        store.toggleDone(todo.id)
        refresh()
        scheduleSync()
    }

    func delete(_ todo: Todo) {
        store.remove(todo.id)
        refresh()
        scheduleSync()
        showToast("已删除", kind: .info)
    }

    func save(_ todo: Todo, isNew: Bool) {
        let content = todo.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            showToast("内容不能为空", kind: .warning)
            return
        }
        var value = todo
        value.content = content
        store.upsert(value)
        refresh()
        scheduleSync()
        showToast(isNew ? "已新增" : "已保存", kind: .success)
    }

    func addQuick() {
        let text = quickAddText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        quickAddText = ""
        // 手动快速新增也走一遍本地解析，用户写「明天下午3点交周报」时能自动带上时间
        let parsed = LocalQuickParser.parse(text, source: .manual, maxItems: 1).first
        var todo = Todo(content: parsed?.content ?? text, source: .manual)
        todo.deadline = parsed?.deadline
        todo.priority = parsed?.priority ?? .normal
        store.upsert(todo)
        refresh()
        scheduleSync()
    }

    func clearDone() {
        let count = groups.done.count
        guard count > 0 else { return }
        store.removeDone()
        refresh()
        scheduleSync()
        showToast("已清空 \(count) 条已完成", kind: .info)
    }

    func syncNow() {
        Task { await sync.syncNow() }
    }

    private func scheduleSync() {
        guard settings.hasCloud, isLoggedIn else { return }
        Task { await sync.sync(force: false) }
    }

    // MARK: - 截图 → OCR → AI → 导入

    /// 全局快捷键 / 菜单触发的完整流程。
    func runScreenshotFlow() {
        guard !capture.isBusy else { return }
        guard ScreenshotService.hasPermission else {
            // 没有屏幕录制权限：先弹系统授权，并给出降级路径
            ScreenshotService.requestPermission()
            capture = .failed(
                message: "需要「屏幕录制」权限才能截图。授权后请重启 QuickTodo；也可以直接把文字粘贴到下方手动整理。",
                rawText: ""
            )
            isExpanded = true
            return
        }
        isExpanded = true
        capture = .capturing

        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await ScreenshotService.captureRegion()
                self.capture = .recognizing
                let text = try await OCRService.recognizeText(in: url)
                // 隐私：识别完立刻删掉截图，不留用户屏幕内容在磁盘上
                ScreenshotService.cleanup(url)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    self.capture = .failed(
                        message: "没识别到文字。若是首次使用，请到「系统设置 → 隐私与安全性 → 屏幕录制」勾选 QuickTodo 后重启本 App。",
                        rawText: ""
                    )
                    return
                }
                await self.analyze(text: trimmed, source: .macScreenshot)
            } catch let error as ScreenshotError {
                if case .cancelled = error {
                    self.capture = .idle       // 用户自己取消的，静默恢复
                } else {
                    self.capture = .failed(message: error.localizedDescription, rawText: "")
                }
            } catch {
                self.capture = .failed(message: error.localizedDescription, rawText: "")
            }
        }
    }

    /// 手动粘贴文本 → 同样的 AI 解析流程（截图失败时的降级入口）。
    func analyzeManualText(_ text: String, source: TodoSource = .manual) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        capture = .analyzing
        Task { [weak self] in
            await self?.analyze(text: trimmed, source: source)
        }
    }

    /// 调用云端 `ai` 云函数解析；云端不可用时退回本地规则解析。
    private func analyze(text: String, source: TodoSource) async {
        capture = .analyzing
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if settings.hasCloud, isLoggedIn {
            do {
                let result = try await api.parse(
                    baseURL: settings.normalizedBaseURL,
                    token: sessionToken,
                    text: trimmed,
                    source: source
                )
                let items = (result.todos ?? []).map { DraftItem(parsed: $0) }.filter { !$0.content.isEmpty }
                if !items.isEmpty {
                    let engine = result.engine == "deepseek" ? "DeepSeek 解析" : "云端规则解析"
                    let notice = result.notice.map { "（\($0)）" } ?? ""
                    capture = .ready(CaptureDraft(rawText: trimmed, source: source, engineNote: engine + notice, items: items))
                    return
                }
                // 模型没给出可用条目 → 走本地兜底
                capture = .ready(localDraft(from: trimmed, source: source, reason: "云端未返回条目"))
                return
            } catch let error as CloudError {
                if error.isUnauthorized {
                    handleUnauthorized()
                }
                capture = .ready(localDraft(from: trimmed, source: source, reason: error.message))
                return
            } catch {
                capture = .ready(localDraft(from: trimmed, source: source, reason: error.localizedDescription))
                return
            }
        }

        capture = .ready(localDraft(from: trimmed, source: source, reason: "未配置云端"))
    }

    private func localDraft(from text: String, source: TodoSource, reason: String) -> CaptureDraft {
        let parsed = LocalQuickParser.parse(text, source: source)
        return CaptureDraft(
            rawText: text,
            source: source,
            engineNote: "本地规则解析 · \(reason)",
            items: parsed.map { DraftItem(parsed: $0) }
        )
    }

    /// 一键导入勾选条目。
    func importDraft() {
        guard case .ready(let draft) = capture else { return }
        let selected = draft.items.filter { $0.selected && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !selected.isEmpty else {
            showToast("至少勾选一条", kind: .warning)
            return
        }
        let todos = selected.map { item -> Todo in
            Todo(
                content: item.content,
                deadline: item.deadline,
                priority: item.priority,
                source: draft.source,
                rawText: draft.rawText
            )
        }
        store.upsertBatch(todos)
        refresh()
        scheduleSync()
        capture = .idle
        showToast("已导入 \(todos.count) 条待办", kind: .success)
    }

    /// 把降级展示的原始文本当作一条待办导入。
    func importRawText(_ text: String, source: TodoSource = .macScreenshot) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.upsertBatch([Todo(content: trimmed, source: source, rawText: trimmed)])
        refresh()
        scheduleSync()
        capture = .idle
        showToast("已导入原文", kind: .success)
    }

    func discardCapture() {
        capture = .idle
    }

    func updateDraft(_ draft: CaptureDraft) {
        capture = .ready(draft)
    }

    // MARK: - 登录

    func startLogin() {
        guard settings.hasCloud else {
            showToast("请先填写云环境地址", kind: .warning)
            showSettings = true
            return
        }
        login.begin(baseURL: settings.normalizedBaseURL)
    }

    func logout() {
        sessionToken = nil
        isLoggedIn = false
        KeychainStore.deleteToken()
        store.resetForLogout()
        refresh()
        showToast("已退出登录", kind: .info)
    }

    private func handleUnauthorized() {
        sessionToken = nil
        isLoggedIn = false
        KeychainStore.deleteToken()
        showToast("登录态已失效，请重新扫码登录", kind: .warning)
    }

    /// 启动时校验一次本地 token 是否还有效。
    func validateSession() {
        guard settings.hasCloud, let token = sessionToken, !token.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.api.checkToken(baseURL: self.settings.normalizedBaseURL, token: token)
                if let openid = result.openid, !openid.isEmpty {
                    self.store.setOpenid(openid)
                }
                self.isLoggedIn = true
            } catch let error as CloudError where error.isUnauthorized {
                self.handleUnauthorized()
            } catch {
                // 网络问题不算登录失效，保持现状
            }
        }
    }

    // MARK: - Toast

    func showToast(_ text: String, kind: ToastMessage.Kind = .info) {
        toast = ToastMessage(text: text, kind: kind)
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    func dismissToast() {
        toastTask?.cancel()
        toast = nil
    }
}
