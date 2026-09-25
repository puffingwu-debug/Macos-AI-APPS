# QuickTodo — macOS 桌面悬浮待办客户端

跨端轻量待办工具的 **Mac 端**：常驻桌面边缘的悬浮球 / 待办面板，
核心是「**按下 ⌘⇧A 框一块屏幕 → 系统 Vision 本地 OCR → 云端 DeepSeek 结构化 → 一键导入**」。

- 纯 Swift + SwiftUI 原生，**零第三方依赖**，SwiftPM 工程（不需要 Xcode 工程文件）
- 后台常驻：`LSUIElement` 无 Dock 图标、`.nonactivatingPanel` 不抢前台焦点
- 语音/截图识别为异步链路，全程不阻塞界面；离线可读可写，联网自动增量同步
- 图片只在本地识别，识别完**立即删除**；DeepSeek 密钥只存在于云函数环境变量

配套：
- 小程序端与云函数 → [`../quicktodo-weapp/`](../quicktodo-weapp/)
- 跨端接口契约（唯一真相来源）→ [`../docs/SYNC-PROTOCOL.md`](../docs/SYNC-PROTOCOL.md)

---

## 1. 构建与运行

```bash
./build.sh              # release 构建 → dist/QuickTodo.app
./build.sh debug        # 开发期更快
./build.sh release run  # 构建并启动
```

`build.sh` 做三件事：`swift build` → 组装 `.app`（拷贝 `Resources/Info.plist`）→ ad-hoc 签名。
ad-hoc 签名是为了让系统「屏幕录制」权限能稳定记住这个 App。

> 受限沙箱环境里 SwiftPM 无法嵌套 `sandbox-exec`，可加一层：
> `SWIFTPM_FLAGS=--disable-sandbox ./build.sh`

### 首次运行必做：授予屏幕录制权限

区域截图调用系统 `/usr/sbin/screencapture`，需要「屏幕录制」权限：

1. 第一次按 ⌘⇧A 会弹系统授权（或到 系统设置 → 隐私与安全性 → 屏幕录制 勾选 QuickTodo）
2. **授权后必须重启 QuickTodo**（macOS 的既定行为，不重启拿到的是壁纸而不是窗口内容）
3. 设置面板「系统权限」一节会实时显示当前状态，并提供「打开设置」直达按钮

### 自检（不需要 GUI、不需要云环境）

```bash
./dist/QuickTodo.app/Contents/MacOS/QuickTodo --selftest
```

40 项断言，覆盖：契约字段集合与取值、服务端额外字段 / `null` deadline 的容错解码、
分组排序（含同毫秒兜底）、本地规则解析（中文数字钟点、时段词、列表序号、时间词剥离、
只给日期→23:59:59.999）、**本机时钟偏差保护**、
以及**真实 OCR 链路**（渲染一张中文 PNG → Vision 识别 → 校验阅读顺序 → 解析成待办）。

### 跨端联调（真实客户端 ↔ 真实云函数）

```bash
# 终端 A：在本地以微信云开发的 event/response 形状托管云函数
cd ../quicktodo-weapp && node tools/cloud-harness.js --serve 8787

# 终端 B：拿到 harness 打印的 sessionToken 后
./dist/QuickTodo.app/Contents/MacOS/QuickTodo --integration http://127.0.0.1:8787 <sessionToken>
```

50 项断言，用的是**真实的 `QuickTodoAPI` / `LocalStore` / `SyncEngine`**，不是 mock：
连通性与鉴权（含非法 token 拒绝）、字段往返、LWW 冲突两个方向、软删除下发、
增量游标、150 条分页推进、AI 解析（含未登录拒绝）、
以及「本地改动 → 上抛 → 另一台设备全量拉取看到一致状态」的完整同步闭环。

> 完整的验证记录（真实命令与输出）见 [`../docs/VERIFICATION.md`](../docs/VERIFICATION.md)；
> 跨端契约一致性机械校验：`node ../tools/check-contract.js`。

---

## 2. 目录结构

```
QuickTodo/
├── Package.swift                 # macOS 15+，Swift 6 工具链，语言模式 v5
├── build.sh                      # 构建 + 打包 .app + ad-hoc 签名
├── Resources/Info.plist           # LSUIElement=true（后台常驻、无 Dock 图标）
└── Sources/QuickTodo/
    ├── App/
    │   ├── QuickTodoApp.swift     # @main、AppDelegate、菜单栏入口
    │   ├── AppState.swift         # 状态中枢：调度存储 / 同步 / 截图-AI 流水线
    │   ├── HotKeyManager.swift     # Carbon 全局热键（无需辅助功能权限）
    │   ├── SelfTest.swift          # --selftest 离线自检
    │   └── IntegrationTest.swift   # --integration 跨端联调自检
    ├── Core/
    │   ├── Todo.swift              # 数据模型 + 契约字段编解码 + 分组排序
    │   ├── LocalStore.swift        # 本地持久化 + outbox 离线队列 + LWW 应用
    │   ├── SyncEngine.swift        # 推 outbox → 增量拉取 → 指数退避重试
    │   ├── QuickTodoAPI.swift      # 云接入 HTTP 客户端（统一信封拆解）
    │   ├── LoginService.swift      # 扫码登录：ticket + CoreImage 画二维码 + 轮询
    │   ├── ScreenshotService.swift  # 区域截图（screencapture -i）+ 权限引导
    │   ├── OCRService.swift        # Vision 文字识别 + 阅读顺序重排
    │   ├── LocalQuickParser.swift  # 离线规则解析（云端不可用时的降级）
    │   ├── KeychainStore.swift     # 会话 token 存 Keychain
    │   ├── AppSettings.swift       # UserDefaults 设置（不含任何密钥）
    │   └── Formatting.swift        # 时间/优先级/配色
    └── UI/
        ├── PanelController.swift   # NSPanel 定位、贴边吸附、自动隐藏、拖拽
        ├── RootView.swift          # 悬浮球 ⇄ 面板切换、毛玻璃背景、Toast
        ├── BallView.swift          # 侧边小球（拖拽 / 单击 / 右键菜单）
        ├── TodoListView.swift      # 待办列表、分组、悬停操作
        ├── CaptureViews.swift      # 加载态、AI 导入预览、失败降级、截止时间选择
        ├── EditorView.swift        # 新增/编辑
        ├── LoginView.swift         # 扫码登录
        └── SettingsView.swift      # 设置 + 快捷键录制
```

---

## 3. 功能与实现位置

| 需求 | 实现 |
|---|---|
| 桌面边缘可拖拽悬浮球，点击展开面板 | `PanelController` + `BallView`（拖拽用全局鼠标坐标计算，避免窗口移动导致的坐标系反馈抖动） |
| 贴边自动隐藏 | `PanelController.pollMouse()`：0.2s 轮询 `NSEvent.mouseLocation`（**不需要任何系统权限**），贴边后滑出只留 5pt，鼠标碰触热区再滑出；正在输入时宽限 2.5s |
| 透明度调节 | 设置面板滑杆 55%–100%，作用在背景层而非窗口 `alphaValue`，保证文字始终清晰 |
| 始终置顶不遮挡工作区 | `level = .floating` + `canJoinAllSpaces` + 贴边自动隐藏 |
| 手动新增/编辑/删除/勾选 | `TodoListView` / `EditorView` / `LocalStore`（勾选、编辑、删除都是本地立即生效） |
| 未完成/已完成分组 + 排序 | `Todo.groupedAndSorted(by:)`，规则与小程序端逐条一致（契约 §5.5） |
| 全局快捷键触发区域截图（默认 ⌘⇧A） | `HotKeyManager`（Carbon `RegisterEventHotKey`，**不需要辅助功能权限**），可在设置里点一下直接按组合键录制新快捷键 |
| 截图后系统 Vision 本地 OCR | `ScreenshotService`（`screencapture -i` 原生框选）+ `OCRService`（macOS 15 Swift Vision API，中英混排 + 语言纠正 + 按几何位置重排阅读顺序） |
| OCR 文本异步调用云端 DeepSeek 提取结构化待办 | `AppState.analyze()` → 云函数 `ai`；无云端配置或调用失败时自动降级为 `LocalQuickParser` |
| 一键导入 + 解析加载态 + 失败降级可编辑 | `CaptureViews.swift`：三步进度指示（截图→识别文字→AI 整理）；失败时把原始文本放进可编辑文本框，可「再解析一次」或「按原文保存」 |
| 微信扫码授权登录 | `LoginService`：Mac 生成 ticket → CoreImage 画二维码 → 小程序扫码确认 → 轮询拿 session token → 存 Keychain（Mac 端不接触 AppSecret，也不需要开放平台账号） |
| 实时同步 + 离线缓存增量同步 | 前台 15s / 后台 60s 轮询；本地优先写入 + outbox 按序上抛 + 指数退避（1s→60s）+ 增量游标；冲突 LWW by 服务端 `updateTime` |
| 低内存后台常驻 | 无第三方依赖、无轮询定时器滥用（空闲 5s 心跳只在到期时才发请求）、识别完立即释放图片 |

---

## 4. 数据与隐私

- **截图不落盘**：`screencapture` 写到临时目录，OCR 读完立刻 `removeItem`，原图不上传、不保留。
- **无密钥**：App 内不存在 DeepSeek key；它只配在云函数环境变量里（见 `../quicktodo-weapp/cloudfunctions/README.md`）。
- **token 存 Keychain**：`kSecClassGenericPassword`，不写明文文件。
- **本地数据**：`~/Library/Application Support/QuickTodo/store.json`（设置页「关于 → 在访达中显示」可直接打开）。
- **无损降级**：任何网络失败都不丢数据——改动留在本地 outbox，恢复后自动补传。

---

## 5. 快捷键与其他行为

| 操作 | 说明 |
|---|---|
| ⌘⇧A（可改） | 区域截图 → OCR → AI 解析 → 导入预览 |
| 单击悬浮球 | 展开待办面板 |
| 拖拽悬浮球 / 面板头部 | 移动位置，松手按设置吸附到最近边缘（可关） |
| 右键悬浮球 | 展开面板 / 截图识别 / 立即同步 / 设置 / 退出 |
| 菜单栏图标 | 同上，另有「新增待办…」（无 Dock 图标时的稳定入口） |
| 输入框回车 | 快速新增；输入内容里的「明天下午3点」会被自动解析成截止时间 |

---

## 6. 已知限制

- **首次截图前必须授予并重启**：macOS 的屏幕录制权限只在进程启动时读取一次，这是系统行为，不是 App 的 bug。
- **深度降级**：未配置云环境时是纯本地模式（本地规则解析 + 本地存储），AI 结构化能力要配好云函数才完整。
- **贴边自动隐藏在输入时会宽限**：正在面板里打字时鼠标移开不会立刻隐藏，避免输入被打断。
- **`--selftest` / `--integration` 是开发工具**，正常双击启动不会触发。
- 未做代码签名公证（ad-hoc 签名），分发给别人时对方需要右键打开一次；正式发布请替换 `build.sh` 里的签名步骤为 Developer ID。
