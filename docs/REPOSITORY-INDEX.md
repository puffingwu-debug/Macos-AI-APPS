# macOS 工具与跨端待办：内容索引

盘点日期：2026-11-14。来源：默认分支 main，提交 `c0d806d28f59fa2c912580c0ecf1a55790dc3c26`。

AI 用量工具独立管理；待办的 Mac 客户端、小程序和云函数作为一个共享协议的产品组导航。

## 分类入口

| 分类 | 入口与内容 |
| --- | --- |
| AI 用量工具 | [AI 用量工具](<../AITokenBar/README.md>)：SwiftPM；zstd 静态链接，缺失时构建脚本可降级。 |
| 待办 Mac 客户端 | [待办 Mac 客户端](<../QuickTodo/README.md>)：SwiftPM 与原生界面。 |
| 待办微信端 | [待办微信端](<../quicktodo-weapp/README.md>)：小程序与 auth、todo、ai 云函数。 |
| 同步契约 | [同步契约](<../docs/SYNC-PROTOCOL.md>)：三端共享接口约定，保持现有位置。 |
| 验证记录 | [验证记录](<../docs/VERIFICATION.md>)：历史验证证据，未冒充本次重新运行结果。 |

## 依赖与保留原则

Package.swift 的 target.path、build.sh 的 Resources 相对位置、QuickTodo 与小程序间 ../docs 链接均保持。未拆仓或移动运行目录。当前 Windows 环境未重新编译 macOS 应用、签名或验证真实云端。

本次不改默认分支，不自动合并、不删除仓库、不将活跃源码标记为停用。目录树未被 GitHub 截断；下列清单覆盖盘点提交的 105 个文件，其中 100 个文本文件已读取。其余文件仅依据路径、类型、大小和 Git blob 标识归类，未声称检查二进制内部内容。未发现 .github/workflows、action.yml/action.yaml 或插件清单文件。

## 逐文件清单

这是盘点提交的清单，不包括本次新增索引。归档后的链接指向新位置；原始路径、大小和 blob SHA 可在 [FILES.json](FILES.json) 查询。

| 分类 | 文件 | 字节 | 内容读取 |
| --- | --- | ---: | --- |
| 版本管理与配置 | [.gitignore](<../.gitignore>) | 275 | 仅元数据 |
| AI 用量工具 | [AITokenBar/Package.swift](<../AITokenBar/Package.swift>) | 1208 | 已读文本 |
| AI 用量工具 | [AITokenBar/README.md](<../AITokenBar/README.md>) | 13398 | 已读文本 |
| AI 用量工具 | [AITokenBar/Resources/Info.plist](<../AITokenBar/Resources/Info.plist>) | 961 | 仅元数据 |
| AI 用量工具 | [AITokenBar/Sources/AITokenBar/App/AITokenBarApp.swift](<../AITokenBar/Sources/AITokenBar/App/AITokenBarApp.swift>) | 4545 | 已读文本 |
| AI 用量工具 | [AITokenBar/Sources/AITokenBar/App/CLIDiagnostics.swift](<../AITokenBar/Sources/AITokenBar/App/CLIDiagnostics.swift>) | 17387 | 已读文本 |
| AI 用量工具 | [AITokenBar/Sources/AITokenBar/Core/AppSettings.swift](<../AITokenBar/Sources/AITokenBar/Core/AppSettings.swift>) | 7489 | 已读文本 |
| AI 用量工具 | [AITokenBar/Sources/AITokenBar/Core/Formatting.swift](<../AITokenBar/Sources/AITokenBar/Core/Formatting.swift>) | 3376 | 已读文本 |
| AI 用量工具 | [AITokenBar/Sources/AITokenBar/Core/Models.swift](<../AITokenBar/Sources/AITokenBar/Core/Models.swift>) | 10397 | 已读文本 |
| AI 用量工具 | [AITokenBar/Sources/AITokenBar/Core/ScanSupport.swift](<../AITokenBar/Sources/AITokenBar/Core/ScanSupport.swift>) | 3793 | 已读文本 |
| AI 用量工具 | [AITokenBar/Sources/AITokenBar/Core/UsageStore.swift](<../AITokenBar/Sources/AITokenBar/Core/UsageStore.swift>) | 17336 | 已读文本 |
| AI 用量工具 | [AITokenBar/Sources/AITokenBar/Providers/BalanceLedger.swift](<../AITokenBar/Sources/AITokenBar/Providers/BalanceLedger.swift>) | 4291 | 已读文本 |
| AI 用量工具 | [AITokenBar/Sources/AITokenBar/Providers/CodexLiveProvider.swift](<../AITokenBar/Sources/AITokenBar/Providers/CodexLiveProvider.swift>) | 5138 | 已读文本 |
| AI 用量工具 | [AITokenBar/Sources/AITokenBar/Providers/CodexPlanReader.swift](<../AITokenBar/Sources/AITokenBar/Providers/CodexPlanReader.swift>) | 4959 | 已读文本 |
| AI 用量工具 | [AITokenBar/Sources/AITokenBar/Providers/CodexScanner.swift](<../AITokenBar/Sources/AITokenBar/Providers/CodexScanner.swift>) | 17844 | 已读文本 |
| AI 用量工具 | [AITokenBar/Sources/AITokenBar/Providers/CredentialStore.swift](<../AITokenBar/Sources/AITokenBar/Providers/CredentialStore.swift>) | 1992 | 已读文本 |
| AI 用量工具 | [AITokenBar/Sources/AITokenBar/Providers/DSHLogScanner.swift](<../AITokenBar/Sources/AITokenBar/Providers/DSHLogScanner.swift>) | 14915 | 已读文本 |
| AI 用量工具 | [AITokenBar/Sources/AITokenBar/Providers/DeepSeekPlatformProvider.swift](<../AITokenBar/Sources/AITokenBar/Providers/DeepSeekPlatformProvider.swift>) | 11253 | 已读文本 |
| AI 用量工具 | [AITokenBar/Sources/AITokenBar/Providers/DeepSeekProvider.swift](<../AITokenBar/Sources/AITokenBar/Providers/DeepSeekProvider.swift>) | 3180 | 已读文本 |
| AI 用量工具 | [AITokenBar/Sources/AITokenBar/Views/SettingsView.swift](<../AITokenBar/Sources/AITokenBar/Views/SettingsView.swift>) | 10971 | 已读文本 |
| AI 用量工具 | [AITokenBar/Sources/AITokenBar/Views/Theme.swift](<../AITokenBar/Sources/AITokenBar/Views/Theme.swift>) | 9054 | 已读文本 |
| AI 用量工具 | [AITokenBar/Sources/AITokenBar/Views/WidgetPanel.swift](<../AITokenBar/Sources/AITokenBar/Views/WidgetPanel.swift>) | 26095 | 已读文本 |
| AI 用量工具 | [AITokenBar/Sources/AITokenBar/Views/WidgetStyle.swift](<../AITokenBar/Sources/AITokenBar/Views/WidgetStyle.swift>) | 5324 | 已读文本 |
| AI 用量工具 | [AITokenBar/Sources/AITokenBar/Views/WidgetView.swift](<../AITokenBar/Sources/AITokenBar/Views/WidgetView.swift>) | 19900 | 已读文本 |
| AI 用量工具 | [AITokenBar/Sources/CZstdShim/include/zstd_shim.h](<../AITokenBar/Sources/CZstdShim/include/zstd_shim.h>) | 875 | 仅元数据 |
| AI 用量工具 | [AITokenBar/Sources/CZstdShim/zstd_shim.c](<../AITokenBar/Sources/CZstdShim/zstd_shim.c>) | 2410 | 仅元数据 |
| AI 用量工具 | [AITokenBar/build.sh](<../AITokenBar/build.sh>) | 2138 | 已读文本 |
| 跨端待办 / Mac | [QuickTodo/Package.swift](<../QuickTodo/Package.swift>) | 699 | 已读文本 |
| 跨端待办 / Mac | [QuickTodo/README.md](<../QuickTodo/README.md>) | 10161 | 已读文本 |
| 跨端待办 / Mac | [QuickTodo/Resources/Info.plist](<../QuickTodo/Resources/Info.plist>) | 1347 | 仅元数据 |
| 跨端待办 / Mac | [QuickTodo/Sources/QuickTodo/App/AppState.swift](<../QuickTodo/Sources/QuickTodo/App/AppState.swift>) | 15353 | 已读文本 |
| 跨端待办 / Mac | [QuickTodo/Sources/QuickTodo/App/HotKeyManager.swift](<../QuickTodo/Sources/QuickTodo/App/HotKeyManager.swift>) | 4974 | 已读文本 |
| 跨端待办 / Mac | [QuickTodo/Sources/QuickTodo/App/IntegrationTest.swift](<../QuickTodo/Sources/QuickTodo/App/IntegrationTest.swift>) | 19011 | 已读文本 |
| 跨端待办 / Mac | [QuickTodo/Sources/QuickTodo/App/QuickTodoApp.swift](<../QuickTodo/Sources/QuickTodo/App/QuickTodoApp.swift>) | 5632 | 已读文本 |
| 跨端待办 / Mac | [QuickTodo/Sources/QuickTodo/App/SelfTest.swift](<../QuickTodo/Sources/QuickTodo/App/SelfTest.swift>) | 14289 | 已读文本 |
| 跨端待办 / Mac | [QuickTodo/Sources/QuickTodo/Core/AppSettings.swift](<../QuickTodo/Sources/QuickTodo/Core/AppSettings.swift>) | 4450 | 已读文本 |
| 跨端待办 / Mac | [QuickTodo/Sources/QuickTodo/Core/Formatting.swift](<../QuickTodo/Sources/QuickTodo/Core/Formatting.swift>) | 3619 | 已读文本 |
| 跨端待办 / Mac | [QuickTodo/Sources/QuickTodo/Core/KeychainStore.swift](<../QuickTodo/Sources/QuickTodo/Core/KeychainStore.swift>) | 1748 | 已读文本 |
| 跨端待办 / Mac | [QuickTodo/Sources/QuickTodo/Core/LocalQuickParser.swift](<../QuickTodo/Sources/QuickTodo/Core/LocalQuickParser.swift>) | 16262 | 已读文本 |
| 跨端待办 / Mac | [QuickTodo/Sources/QuickTodo/Core/LocalStore.swift](<../QuickTodo/Sources/QuickTodo/Core/LocalStore.swift>) | 11216 | 已读文本 |
| 跨端待办 / Mac | [QuickTodo/Sources/QuickTodo/Core/LoginService.swift](<../QuickTodo/Sources/QuickTodo/Core/LoginService.swift>) | 5813 | 已读文本 |
| 跨端待办 / Mac | [QuickTodo/Sources/QuickTodo/Core/OCRService.swift](<../QuickTodo/Sources/QuickTodo/Core/OCRService.swift>) | 2716 | 已读文本 |
| 跨端待办 / Mac | [QuickTodo/Sources/QuickTodo/Core/QuickTodoAPI.swift](<../QuickTodo/Sources/QuickTodo/Core/QuickTodoAPI.swift>) | 10879 | 已读文本 |
| 跨端待办 / Mac | [QuickTodo/Sources/QuickTodo/Core/ScreenshotService.swift](<../QuickTodo/Sources/QuickTodo/Core/ScreenshotService.swift>) | 3624 | 已读文本 |
| 跨端待办 / Mac | [QuickTodo/Sources/QuickTodo/Core/SyncEngine.swift](<../QuickTodo/Sources/QuickTodo/Core/SyncEngine.swift>) | 9382 | 已读文本 |
| 跨端待办 / Mac | [QuickTodo/Sources/QuickTodo/Core/Todo.swift](<../QuickTodo/Sources/QuickTodo/Core/Todo.swift>) | 9553 | 已读文本 |
| 跨端待办 / Mac | [QuickTodo/Sources/QuickTodo/UI/BallView.swift](<../QuickTodo/Sources/QuickTodo/UI/BallView.swift>) | 3551 | 已读文本 |
| 跨端待办 / Mac | [QuickTodo/Sources/QuickTodo/UI/CaptureViews.swift](<../QuickTodo/Sources/QuickTodo/UI/CaptureViews.swift>) | 14225 | 已读文本 |
| 跨端待办 / Mac | [QuickTodo/Sources/QuickTodo/UI/EditorView.swift](<../QuickTodo/Sources/QuickTodo/UI/EditorView.swift>) | 5293 | 已读文本 |
| 跨端待办 / Mac | [QuickTodo/Sources/QuickTodo/UI/LoginView.swift](<../QuickTodo/Sources/QuickTodo/UI/LoginView.swift>) | 4322 | 已读文本 |
| 跨端待办 / Mac | [QuickTodo/Sources/QuickTodo/UI/PanelController.swift](<../QuickTodo/Sources/QuickTodo/UI/PanelController.swift>) | 11921 | 已读文本 |
| 跨端待办 / Mac | [QuickTodo/Sources/QuickTodo/UI/RootView.swift](<../QuickTodo/Sources/QuickTodo/UI/RootView.swift>) | 10383 | 已读文本 |
| 跨端待办 / Mac | [QuickTodo/Sources/QuickTodo/UI/SettingsView.swift](<../QuickTodo/Sources/QuickTodo/UI/SettingsView.swift>) | 16066 | 已读文本 |
| 跨端待办 / Mac | [QuickTodo/Sources/QuickTodo/UI/TodoListView.swift](<../QuickTodo/Sources/QuickTodo/UI/TodoListView.swift>) | 9763 | 已读文本 |
| 跨端待办 / Mac | [QuickTodo/build.sh](<../QuickTodo/build.sh>) | 1817 | 已读文本 |
| 仓库说明 | [README.md](<../README.md>) | 3473 | 已读文本 |
| 接口与验证文档 | [docs/SYNC-PROTOCOL.md](<../docs/SYNC-PROTOCOL.md>) | 17039 | 已读文本 |
| 接口与验证文档 | [docs/VERIFICATION.md](<../docs/VERIFICATION.md>) | 12104 | 已读文本 |
| 仓库工具 | [push-to-github.sh](<../push-to-github.sh>) | 3756 | 已读文本 |
| 跨端待办 / 微信及云函数 | [quicktodo-weapp/README.md](<../quicktodo-weapp/README.md>) | 23604 | 已读文本 |
| 跨端待办 / 微信及云函数 | [quicktodo-weapp/cloudfunctions/README.md](<../quicktodo-weapp/cloudfunctions/README.md>) | 22328 | 已读文本 |
| 跨端待办 / 微信及云函数 | [quicktodo-weapp/cloudfunctions/ai/index.js](<../quicktodo-weapp/cloudfunctions/ai/index.js>) | 22418 | 已读文本 |
| 跨端待办 / 微信及云函数 | [quicktodo-weapp/cloudfunctions/ai/package.json](<../quicktodo-weapp/cloudfunctions/ai/package.json>) | 293 | 已读文本 |
| 跨端待办 / 微信及云函数 | [quicktodo-weapp/cloudfunctions/ai/parser.js](<../quicktodo-weapp/cloudfunctions/ai/parser.js>) | 23383 | 已读文本 |
| 跨端待办 / 微信及云函数 | [quicktodo-weapp/cloudfunctions/ai/prompt.js](<../quicktodo-weapp/cloudfunctions/ai/prompt.js>) | 9443 | 已读文本 |
| 跨端待办 / 微信及云函数 | [quicktodo-weapp/cloudfunctions/auth/index.js](<../quicktodo-weapp/cloudfunctions/auth/index.js>) | 12649 | 已读文本 |
| 跨端待办 / 微信及云函数 | [quicktodo-weapp/cloudfunctions/auth/package.json](<../quicktodo-weapp/cloudfunctions/auth/package.json>) | 291 | 已读文本 |
| 跨端待办 / 微信及云函数 | [quicktodo-weapp/cloudfunctions/todo/index.js](<../quicktodo-weapp/cloudfunctions/todo/index.js>) | 24919 | 已读文本 |
| 跨端待办 / 微信及云函数 | [quicktodo-weapp/cloudfunctions/todo/package.json](<../quicktodo-weapp/cloudfunctions/todo/package.json>) | 279 | 已读文本 |
| 跨端待办 / 微信及云函数 | [quicktodo-weapp/miniprogram/app.js](<../quicktodo-weapp/miniprogram/app.js>) | 2903 | 已读文本 |
| 跨端待办 / 微信及云函数 | [quicktodo-weapp/miniprogram/app.json](<../quicktodo-weapp/miniprogram/app.json>) | 804 | 已读文本 |
| 跨端待办 / 微信及云函数 | [quicktodo-weapp/miniprogram/app.wxss](<../quicktodo-weapp/miniprogram/app.wxss>) | 2669 | 已读文本 |
| 跨端待办 / 微信及云函数 | [quicktodo-weapp/miniprogram/components/float-ball/index.js](<../quicktodo-weapp/miniprogram/components/float-ball/index.js>) | 9212 | 已读文本 |
| 跨端待办 / 微信及云函数 | [quicktodo-weapp/miniprogram/components/float-ball/index.json](<../quicktodo-weapp/miniprogram/components/float-ball/index.json>) | 49 | 已读文本 |
| 跨端待办 / 微信及云函数 | [quicktodo-weapp/miniprogram/components/float-ball/index.wxml](<../quicktodo-weapp/miniprogram/components/float-ball/index.wxml>) | 1502 | 已读文本 |
| 跨端待办 / 微信及云函数 | [quicktodo-weapp/miniprogram/components/float-ball/index.wxss](<../quicktodo-weapp/miniprogram/components/float-ball/index.wxss>) | 3887 | 已读文本 |
| 跨端待办 / 微信及云函数 | [quicktodo-weapp/miniprogram/components/todo-item/index.js](<../quicktodo-weapp/miniprogram/components/todo-item/index.js>) | 1202 | 已读文本 |
| 跨端待办 / 微信及云函数 | [quicktodo-weapp/miniprogram/components/todo-item/index.json](<../quicktodo-weapp/miniprogram/components/todo-item/index.json>) | 49 | 已读文本 |
| 跨端待办 / 微信及云函数 | [quicktodo-weapp/miniprogram/components/todo-item/index.wxml](<../quicktodo-weapp/miniprogram/components/todo-item/index.wxml>) | 807 | 已读文本 |
| 跨端待办 / 微信及云函数 | [quicktodo-weapp/miniprogram/components/todo-item/index.wxss](<../quicktodo-weapp/miniprogram/components/todo-item/index.wxss>) | 3006 | 已读文本 |
| 跨端待办 / 微信及云函数 | [quicktodo-weapp/miniprogram/components/todo-sheet/index.js](<../quicktodo-weapp/miniprogram/components/todo-sheet/index.js>) | 10134 | 已读文本 |
| 跨端待办 / 微信及云函数 | [quicktodo-weapp/miniprogram/components/todo-sheet/index.json](<../quicktodo-weapp/miniprogram/components/todo-sheet/index.json>) | 49 | 已读文本 |
| 跨端待办 / 微信及云函数 | [quicktodo-weapp/miniprogram/components/todo-sheet/index.wxml](<../quicktodo-weapp/miniprogram/components/todo-sheet/index.wxml>) | 5433 | 已读文本 |
| 跨端待办 / 微信及云函数 | [quicktodo-weapp/miniprogram/components/todo-sheet/index.wxss](<../quicktodo-weapp/miniprogram/components/todo-sheet/index.wxss>) | 7855 | 已读文本 |
| 跨端待办 / 微信及云函数 | [quicktodo-weapp/miniprogram/config.js](<../quicktodo-weapp/miniprogram/config.js>) | 2241 | 已读文本 |
| 跨端待办 / 微信及云函数 | [quicktodo-weapp/miniprogram/pages/index/index.js](<../quicktodo-weapp/miniprogram/pages/index/index.js>) | 17594 | 已读文本 |
| 跨端待办 / 微信及云函数 | [quicktodo-weapp/miniprogram/pages/index/index.json](<../quicktodo-weapp/miniprogram/pages/index/index.json>) | 317 | 已读文本 |
| 跨端待办 / 微信及云函数 | [quicktodo-weapp/miniprogram/pages/index/index.wxml](<../quicktodo-weapp/miniprogram/pages/index/index.wxml>) | 2912 | 已读文本 |
| 跨端待办 / 微信及云函数 | [quicktodo-weapp/miniprogram/pages/index/index.wxss](<../quicktodo-weapp/miniprogram/pages/index/index.wxss>) | 3847 | 已读文本 |
| 跨端待办 / 微信及云函数 | [quicktodo-weapp/miniprogram/pages/mine/index.js](<../quicktodo-weapp/miniprogram/pages/mine/index.js>) | 11715 | 已读文本 |
| 跨端待办 / 微信及云函数 | [quicktodo-weapp/miniprogram/pages/mine/index.json](<../quicktodo-weapp/miniprogram/pages/mine/index.json>) | 98 | 已读文本 |
| 跨端待办 / 微信及云函数 | [quicktodo-weapp/miniprogram/pages/mine/index.wxml](<../quicktodo-weapp/miniprogram/pages/mine/index.wxml>) | 4595 | 已读文本 |
| 跨端待办 / 微信及云函数 | [quicktodo-weapp/miniprogram/pages/mine/index.wxss](<../quicktodo-weapp/miniprogram/pages/mine/index.wxss>) | 4362 | 已读文本 |
| 跨端待办 / 微信及云函数 | [quicktodo-weapp/miniprogram/sitemap.json](<../quicktodo-weapp/miniprogram/sitemap.json>) | 210 | 已读文本 |
| 跨端待办 / 微信及云函数 | [quicktodo-weapp/miniprogram/utils/api.js](<../quicktodo-weapp/miniprogram/utils/api.js>) | 6339 | 已读文本 |
| 跨端待办 / 微信及云函数 | [quicktodo-weapp/miniprogram/utils/format.js](<../quicktodo-weapp/miniprogram/utils/format.js>) | 7188 | 已读文本 |
| 跨端待办 / 微信及云函数 | [quicktodo-weapp/miniprogram/utils/store.js](<../quicktodo-weapp/miniprogram/utils/store.js>) | 26227 | 已读文本 |
| 跨端待办 / 微信及云函数 | [quicktodo-weapp/miniprogram/utils/sync.js](<../quicktodo-weapp/miniprogram/utils/sync.js>) | 9381 | 已读文本 |
| 跨端待办 / 微信及云函数 | [quicktodo-weapp/miniprogram/utils/voice.js](<../quicktodo-weapp/miniprogram/utils/voice.js>) | 9242 | 已读文本 |
| 跨端待办 / 微信及云函数 | [quicktodo-weapp/project.config.json](<../quicktodo-weapp/project.config.json>) | 1013 | 已读文本 |
| 跨端待办 / 微信及云函数 | [quicktodo-weapp/project.private.config.json](<../quicktodo-weapp/project.private.config.json>) | 246 | 已读文本 |
| 跨端待办 / 微信及云函数 | [quicktodo-weapp/tools/README.md](<../quicktodo-weapp/tools/README.md>) | 9428 | 已读文本 |
| 跨端待办 / 微信及云函数 | [quicktodo-weapp/tools/cloud-harness.js](<../quicktodo-weapp/tools/cloud-harness.js>) | 59064 | 已读文本 |
| 跨端待办 / 微信及云函数 | [quicktodo-weapp/tools/miniprogram-tests.js](<../quicktodo-weapp/tools/miniprogram-tests.js>) | 39638 | 已读文本 |
| 仓库工具 | [tools/check-contract.js](<../tools/check-contract.js>) | 11349 | 已读文本 |
