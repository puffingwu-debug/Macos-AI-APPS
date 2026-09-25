# QuickTodo 微信小程序端

跨端轻量待办工具 **QuickTodo** 的微信原生小程序实现（Mac 客户端 / 小程序 / 云函数三端之一）。

- 接口契约唯一真相来源：`../docs/SYNC-PROTOCOL.md`（**契约版本 v1**）
- 不引入任何第三方 UI 库，全部 WXSS 手写；单位统一 rpx（1px 边框除外）
- 主题色 `#07C160`，圆角 12~20rpx，微信原生风格

---

## 1. 目录结构

```
quicktodo-weapp/
├── project.config.json          # 项目配置：appid=touristappid，miniprogramRoot/cloudfunctionRoot
├── project.private.config.json  # 本地私有配置：urlCheck=false（便于开发期调试）
├── README.md                    # 本文件
├── tools/                       # 本地联调与自检工具
│   ├── cloud-harness.js         #   云函数联调：无需部署即可按云开发 event/response 形状跑云函数
│   └── miniprogram-tests.js     # ★ 小程序端回归自检：node tools/miniprogram-tests.js（105 条断言）
├── cloudfunctions/              # 云函数 todo / ai / auth，部署步骤见 cloudfunctions/README.md
└── miniprogram/
    ├── app.js                   # 入口：云开发初始化 / 本地模式判定 / 缓存 windowInfo
    ├── app.json                 # 页面、tabBar、同声传译插件声明、下拉刷新
    ├── app.wxss                 # 设计变量（含 @media 深色模式）+ 通用原子类
    ├── sitemap.json
    ├── config.js                # ★ 唯一配置入口：cloudEnv / 插件版本 / 同步参数 / UI 常量
    ├── utils/
    │   ├── api.js               # 云函数调用封装：统一错误码、loading、友好错误文案
    │   ├── store.js             # ★ 本地仓库：缓存 + outbox + LWW 合并 + 契约 §5.5 排序
    │   ├── sync.js              # ★ 同步引擎：增量拉取 + outbox 上抛 + 指数退避
    │   ├── voice.js             # 同声传译插件封装 + 权限引导 + 手动输入降级
    │   └── format.js            # 展示格式化：截止时间/相对时间/优先级/来源/openid 脱敏
    ├── components/
    │   ├── todo-item/           # 单条待办：复选框动画、优先级色条、截止时间、来源标签
    │   ├── float-ball/          # 常驻悬浮球：拖拽吸附 + 长按语音 + 上滑取消
    │   └── todo-sheet/          # 底部面板：语音状态 / 快捷新增·编辑 / AI 预览导入
    └── pages/
        ├── index/               # 主列表：分类切换、排序、空状态、同步状态条
        └── mine/                # 我的：环境与登录态、统计、扫码登录 Mac、浮窗指引、危险操作
```

---

## 2. 导入微信开发者工具

1. 打开「微信开发者工具」→ **导入项目**。
2. 目录选择 **`quicktodo-weapp`**（注意：选这一层，不要选 `miniprogram`）。
   工具会读取 `project.config.json`，自动识别 `miniprogramRoot = miniprogram/`。
3. AppID 三种情况：
   - 只跑本地模式 / 看 UI：选「测试号」或直接用占位的 `touristappid`。
   - 要用云开发与语音插件：填**你自己的小程序 AppID**（见第 3、4 节）。
4. 基础库版本建议 **2.20.0 及以上**（用到 `wx.getWindowInfo`、`wx.showModal({editable})`、
   `@media (prefers-color-scheme: dark)`；低版本有兜底但体验略差）。

> ⚠️ **`touristappid` + 同声传译插件会编译报错**：`app.json` 里声明了 `WechatSI` 插件，
> 而测试号/游客 appid 无法使用插件。要真正跑起来，请换成自己的 AppID 并在后台添加插件（第 4 节）。
> 换 AppID 前，语音入口会走「插件不可用 → 手动输入」的降级路径，其余功能（列表/同步/手动待办）完全正常。

---

## 3. 填写 `cloudEnv`（云环境 ID）

打开 `miniprogram/config.js`：

```js
const config = {
  cloudEnv: '',   // ← 在这里填云环境 ID，例如 'quicktodo-1g2h3i4j5k6l'
  ...
};
```

获取方式：**微信开发者工具 → 云开发 → 设置 → 环境 ID**（形如 `xxx-1g2h3i4j5k6l`）。

| `cloudEnv` | 行为 |
|---|---|
| `''`（默认空字符串） | **本地模式**：不初始化云开发、不发任何网络请求，数据只写 `wx.setStorageSync`。首页顶部显示「本地模式」提示条，「我的」页同步按钮给出提示。功能完全可用，只是不同步。 |
| `'xxx-xxx'` | 云同步开启：`app.js` 执行 `wx.cloud.init({ env: cloudEnv, traceUser: true })`，`onShow` / 下拉刷新 / 每次增删改后触发同步。 |

> 小程序端**没有任何密钥**：不出现 `DEEPSEEK_API_KEY`，不直连 `api.deepseek.com`（契约 §3.3）。
> 云环境 ID 不是密钥，写在这里是安全的。

---

## 4. 同声传译插件（语音转文字）

### 4.1 在小程序后台添加

1. 登录 **微信公众平台** → 小程序后台 → 左侧「设置」→「第三方设置」→「插件管理」。
2. 点「添加插件」→ 搜索 **同声传译**（AppID `wx069ba97219f66d99`）→ 申请添加（即时通过）。
3. `app.json` 中已声明（与 `config.js` 的 `voice` 段保持一致）：

```json
"plugins": {
  "WechatSI": { "version": "0.3.6", "provider": "wx069ba97219f66d99" }
}
```

4. 开发者工具里「详情 → 本地设置」勾选 **不校验合法域名**（插件会访问微信内部域名，`urlCheck: false` 已在
   `project.private.config.json` 里配好）。

### 4.2 代码里的用法

`utils/voice.js`：

```js
const plugin = requirePlugin('WechatSI');
const manager = plugin.getRecordRecognitionManager();
manager.start({ duration: 60000, lang: 'zh_CN' });  // duration 上限 60000ms
manager.onRecognize = res => { /* 实时中间结果 res.result */ };
manager.onStop      = res => { /* 最终结果 res.result */ };
manager.onError     = res => { /* res.retcode / res.msg */ };
```

对外暴露 `start() / stop() / cancel() / onPartial / onFinal / onError`（`start` 入参即回调集合）。

### 4.3 降级策略（**不会让功能死掉**）

| 情况 | 表现 |
|---|---|
| 未添加插件 / 测试号 / 基础库不支持 | `onError({code:'plugin_unavailable'})` → 自动弹出**可编辑文本框**让用户直接输入 |
| 用户拒绝录音授权 | `wx.showModal` 引导 → `wx.openSetting`（`scope.record`）；用户选「手动输入」则直接进输入框 |
| 识别结果为空（说得太短/太轻） | `onError({code:'empty_result'})` → 手动输入框 |
| 插件 4 秒内没回调 | 兜底 `onError({code:'timeout'})` → 手动输入框 |
| 面板内永远提供 textarea | 不想说话时可以打字，一样走 AI 解析 |

---

## 5. 录音权限说明

- 使用 `wx.authorize({ scope: 'scope.record' })` 申请麦克风权限。
- **首次**申请会弹系统弹窗；**被拒绝过**之后 `authorize` 不再弹窗，代码会自动改用
  `wx.showModal` + `wx.openSetting` 引导用户去设置页手动打开。
- 权限只在**按住悬浮球 350ms 后**才申请，不会一进小程序就要权限。
- 声明位置：`utils/voice.js → ensureRecordAuth()`。`app.json` 无需额外 `permission` 字段
  （`scope.record` 不属于 `permission` 配置项，写了会被开发者工具判为无效配置）。

---

## 6. 扫码登录 Mac 的使用流程

背景：小程序侧 openid 由云函数上下文天然提供，**不需要登录页**；`auth` 云函数只服务于
「让 Mac 端拿到登录态」（契约 §4）。

1. Mac 端打开设置 → 点「登录」→ 本地渲染二维码（内容 `quicktodo://login?ticket=<32位hex>`）。
2. 小程序「我的」页 → 点 **扫码登录 Mac**。
3. `wx.scanCode({ onlyFromCamera: false, scanType: ['qrCode'] })`：
   - 支持相机扫码，也支持从**相册选二维码**；
   - 用户取消扫码 → 静默返回，不报错。
4. 从扫码结果里正则提取 `ticket`（依次匹配 `quicktodo://login?ticket=xxx`、`?ticket=xxx`、纯 32 位 hex）。
   解析不到 → 弹窗提示二维码无法识别并附上原文前 80 字。
5. 调 `auth` 云函数 `{ action: 'confirmTicket', ticket }`（**openid 由云函数上下文取，小程序不传**）。
   - 成功 → 弹窗「登录成功」并展示脱敏 openid；
   - `bad_request` → 提示「二维码已过期或已被使用」（ticket 5 分钟有效、一票一用）；
   - 云环境不可用 → 提示检查 `config.js` 的 `cloudEnv`。

---

## 7. 「添加到微信浮窗 / 手机桌面」的能力边界

**微信没有对外开放这类 API**：小程序**无法**用代码把自己加到浮窗或桌面，也没有 `wx.addToFloatingWindow`
之类的接口。任何号称能一键添加的小程序，实际都是引导用户手动操作。

因此本项目的做法是：在「我的 → 快速唤起」里提供一个**分机型的操作指引面板**
（`pages/mine/index.js` 的 `GUIDE` 常量 + 自定义弹层 `guide`）：

| 平台 | 指引内容 |
|---|---|
| iOS | ①右上角「⋯」→ 浮窗；②「⋯」→ 在浏览器打开 → Safari 分享 → 添加到主屏幕；③快捷指令「打开 App/URL」放到桌面或用 Siri 唤起；④小程序卡片发给文件传输助手并置顶 |
| Android | ①右上角「⋯」→ 添加到桌面；②「⋯」→ 浮窗；③「发现 → 小程序 → 最近使用」长按置顶 |
| 开发者工具 | 模拟器无真实入口，提示用「预览」在真机上体验 |

---

## 8. 已实现的功能对照

| 需求 | 实现位置 |
|---|---|
| 悬浮球常驻 + 拖拽 + 边缘吸附 + 位置持久化 | `components/float-ball/index.js`（`position:fixed` + 自算坐标，`touchstart/move/end`，位移 >8px 进拖拽态，松手吸附最近左右边缘，写 storage `qt_float_pos`） |
| 长按 350ms 录音 + 震动 + 放大 + 波纹 + 实时文字气泡 | 同上 `beginRecord()` / WXML `.rings` `.bubble` 动画 |
| 上滑 >80px 松手取消 | 同上 `onTouchMove()` 的 `canceling` 判定 |
| 单击球展开/收起底部面板，展开时球变「关闭」态 | `index.js onBallTap()` + `float-ball` 的 `expanded` 属性（`.ball.open` 显示 ×） |
| 语音识别 + 插件降级 | `utils/voice.js`（全程 try/catch + `promptManualText` 手动输入兜底） |
| AI 解析 → 可编辑预览（改内容/时间/优先级、勾选、删除）→ 一键导入 | `pages/index/index.js parseText()/onImport()` + `components/todo-sheet`（`source: 'mini-voice'`，`rawText` 存原始转写） |
| 手动新增/编辑/删除/勾选 | `todo-sheet` 的快捷新增与编辑表单、`index.js confirmRemove()`（`wx.showModal` 二次确认）、勾选带 `wx.vibrateShort` |
| 分类切换 + 数量 | `index.wxml .tabs` ↔ `store.counts()` |
| 排序严格按契约 §5.5 | `utils/store.js sortTodos()` |
| 同步：onShow + 下拉刷新 + 变更后上抛 + 退避重试 | `utils/sync.js`（`trigger()` / 1s→2s→…→60s） |
| 冷启动先渲染缓存 | `app.js onLaunch → store.init()` |
| 深色模式 | `app.wxss` 的 `@media (prefers-color-scheme: dark)` 覆盖 CSS 变量（**选的是这套**，不依赖 theme.json，真机/工具都能跑通） |
| 空状态纯 CSS 插画 | `pages/index/index.wxss .illus/.paper/.clip/.done-mark` |

---

## 9. 数据与同步要点（契约 §5 落地说明）

- **本地优先**：所有写操作先落 `store`（`wx.setStorageSync`）并立即 `emit` 刷新 UI，网络永远在后台。
- **outbox**：每次写本地同时入队（`upsert` / `remove`），同一 `id` 的旧条目会被替换（先建后删只剩一条 `remove`）；
  上抛时按入队顺序把连续同类操作合批 → `bulkUpsert` / `remove`，成功后按 `key` 出队（不用下标，避免并发写入错位）。
- **逻辑时间戳（HLC-lite，契约 §1.1 硬性要求）**：客户端上抛的 `updateTime` 一律取
  `max(本机时间, 见过的最大 serverTime + 1, 本机上次发号 + 1, 该条现有版本 + 1)`。
  **为什么必须这样做**：若手机时间比服务器慢（哪怕只慢几分钟），离线改动的 `updateTime` 会小于服务端已存版本，
  上抛被判 `stale` → 服务端旧版本反覆盖本地 → **用户刚改的内容"自己变回去"（静默数据丢失）**。
  抬高到服务端水位之上即可根治。相关实现：
  - `store.observeServerTime(t)` 把每次响应里的 `serverTime`（`list` / `bulkUpsert` / `remove`，另加 `ping`）
    合并进水位并**持久化**（storage key `qt_server_time_v1`，冷启动恢复；「清空本地缓存」刻意不重置它，
    否则清完缓存到首次拉取之间的改动又会暴露在时钟偏慢风险下）；
  - 水位只增不减，连续新建/连续编辑严格递增（批量导入的多条也依次 +1）；
  - `createTime` 仍用本机时钟（只影响展示与排序），逻辑时钟只作用于 `updateTime`。
- **LWW**：服务端 `updateTime` 是唯一权威时钟。`applied` 回执后本地严格对齐服务端盖章值，
  但**加了并发保护**：只有当本地该条的 `updateTime` 仍等于本次上抛时用的值（推送期间用户没再改过）才覆盖，
  否则跳过——避免把用户的新改动连同时间戳一起改小/改回去。**`stale` 回执同样受这条保护**
  （stale 是针对"我们上抛的那个版本"的结论，若期间用户又改了就不能拿它覆盖；该条新的 outbox 条目会在下一轮重新上抛）。
- **stale**：未被并发修改时，服务端版本覆盖本地（服务端为准）；**rejected**：本地丢弃并 toast 提示，避免 outbox 死循环。
- **增量拉取**：`list(since=cursor, limit=100, includeDeleted=true)`，`hasMore` 为真就用新 `cursor` 继续拉空（单轮最多 20 页）。
- 平台限制：本地模式下 outbox 会持续累积，等填好 `cloudEnv` 后会自动补同步，**不会丢数据**。

---

## 10. 常见问题（FAQ）

**Q1：首页一直显示「本地模式」？**
`config.js` 的 `cloudEnv` 仍为空，或 `wx.cloud.init` 失败（AppID 未开通云开发）。填好环境 ID 并确认
云开发已开通即可，控制台会打印 `[qt:app] 云开发初始化失败…`。

**Q2：提示「云函数「todo」未部署，或未选择云环境」？**
`cloudfunctions/` 下的三个云函数需要在开发者工具里**右键 → 上传并部署（云端安装依赖）**；
同时确认工具左上角云环境切换到了 `config.js` 里填的那一个。云函数由另一位同学负责，本目录不含其代码。

**Q3：语音没反应 / 报「语音识别插件不可用」？**
1) 是否用的测试号或 `touristappid`（插件不可用）；2) 后台是否添加了同声传译插件；
3) `app.json` 的 `plugins` 是否被改动；4) 麦克风权限是否被拒（去「设置 → 授权」打开）。
以上都不行时会自动弹出**手动输入框**，功能不会中断。

**Q4：扫码登录报「二维码已过期或已被使用」？**
ticket 有效期 5 分钟且一票一用。请在 Mac 端重新生成二维码后再扫。

**Q5：深色模式下 tabBar 还是白色的？**
tabBar 是原生组件，`@media` 覆盖不到它。本端刻意**不使用** `"darkmode": true` + `theme.json`
（需要额外维护一份主题文件，且部分基础库表现不一致），只对页面内容做深色适配。如需 tabBar 也变深色，
需要改成 `darkmode: true` + `themeLocation` 方案，属于后续可选优化。

**Q6：为什么点击悬浮球有时没反应？**
悬浮球是三态手势互斥的：位移 >8px 视为拖拽，按住 ≥350ms 视为录音，只有**快速轻点**才会展开面板。
录音中手指上滑超过 80px 会进入「松开取消」态。

**Q7：清空本地缓存会不会把云端数据也删了？**
不会。清空只删本机缓存并把 `cursor` 归零，随后会重新从云端拉全量。若本机有未同步的改动，会先弹窗
提示「这些改动会丢失」。

**Q8：`node --check` 能过吗？**
能，全部 `.js`（含组件与页面）均为标准 CommonJS，可直接用 `node --check` 做语法校验，见第 11 节。

---

## 11. 本地回归测试

小程序代码没法在命令行编译运行，但**与契约强相关的纯逻辑**（排序 / outbox / LWW / 逻辑时间戳 / 截断 / 降级）
恰恰是最容易一改就静默丢数据的地方。所以这里有一层可在命令行复跑的回归自检，
它直接 `require` 真实的 `miniprogram/utils/*.js` 与 `pages/index/index.js`，
用内存桩替掉 `wx`（storage / showToast / `cloud.callFunction`）与 `getApp`：

```bash
cd quicktodo-weapp
node tools/miniprogram-tests.js; echo $?     # 0 = 全部通过，1 = 有失败
```

预期输出（末尾）：

```
=== 6. AI 解析降级（契约 §2.2 unauthorized / §3.2 / §3.3） ===
  PASS  未授权状态下仍能导入（导入走本地 + outbox，不依赖 ai）

小程序端自检全部通过: 105 passed, 0 failed
```

共 105 条断言，分 6 节（每节开始前清空模块缓存与内存存储，节与节之间零依赖；
每一节也都能在独立进程里单独跑通）：

| 分节 | 条数 | 覆盖 |
|---|---|---|
| 1. 存储与排序 | 12 | §5.5 排序（含已完成组同毫秒 `createTime` 兜底）、分组过滤与计数、uuid 形态、游标、清缓存 |
| 2. outbox 与 LWW | 12 | 同 id 合并、先建后删只剩 `remove`、墓碑、LWW 双向、`applied`/`stale`/`rejected` 回执、上行字段白名单 |
| 3. 同步引擎 | 27 | 本地优先、批量上抛与出队、失败保留 + 退避计数、`hasMore` 循环、`maxPullPages` 上限、本地模式零请求 |
| 4. 时钟保护 | 27 | §1.1 逻辑时间戳：水位抬高/持久化/冷启动恢复/只增不减、`applied`·`stale` 的并发保护、空 `stale` 忽略 |
| 5. 输入规范化与默认时间 | 19 | §1.1 `content` 500 / `rawText` 4000 截断（四条写入路径）、空内容本地拦截、§3.4 只给日期 = 23:59:59.999 |
| 6. AI 解析降级 | 8 | `ai` 返回 `unauthorized` 时不白屏、不丢原文、给出恢复路径、仍可导入 |

**它覆盖什么**：与 `SYNC-PROTOCOL.md` 逐条对应的纯逻辑（§1.1 字段与逻辑时间戳、§2.2 错误码、§2.3–2.5 增量与写回执、
§3.4 默认时刻、§5.1–5.6 同步策略）。改动 `store.js` / `sync.js` / `format.js` / `api.js` / `pages/index/index.js` 后请务必跑一遍。

**它不覆盖什么**（这些仍需在微信开发者工具 + 真机预览里验证）：
- WXML/WXSS 渲染、布局、深色模式、动画与悬浮球手势手感；
- 真实 `wx.cloud.callFunction`（网络、云函数部署、云环境 ID）、数据库权限与索引；
- 同声传译插件、麦克风权限、`wx.scanCode`、`wx.showModal({editable})` 等真机能力；
- storage 实际容量与持久化行为、iOS/Android 差异。

### 语法自检

```bash
cd quicktodo-weapp
for f in $(find miniprogram -name "*.js"); do node --check "$f" || echo "FAIL $f"; done
```

校验结果（本次交付实测，全部通过）：

```
OK  miniprogram/app.js
OK  miniprogram/config.js
OK  miniprogram/utils/api.js  store.js  sync.js  voice.js  format.js
OK  miniprogram/components/todo-item/index.js  float-ball/index.js  todo-sheet/index.js
OK  miniprogram/pages/index/index.js  pages/mine/index.js
```

---

## 12. 契约一致性自查

- 云函数 action：`todo` → `list` / `upsert` / `bulkUpsert` / `remove` / `ping`；
  `ai` → `parse`；`auth` → `confirmTicket`（另附 `check` / `createTicket` / `pollTicket` / `logout` 备用）。
  契约 §2.5.1 的 `clearDone` 是**可选**动作，两端统一用「本地软删除 + outbox 批量 `remove`」实现，
  本端**不调用** `clearDone`（语义等价）。
- 字段：`id / content / deadline / priority / status / source / rawText / createTime / updateTime / deleted`，
  上行对象**不含** `openid`、`_id`、`seq`（`openid` 由云函数按登录态填充，契约 §1）。
  `content` 在**四条写入路径**（手动新增 / 编辑 / AI 预览导入 / 语音导入）统一先 `trim` 再截断到 500 字，
  `rawText` 截断到 4000 字（§1.1）；`toWire()` 上抛前再兜一次截断，空内容在本地就被挡下，
  避免出现「写进本地又被云端 `rejected` 删掉」的假成功。
- 响应字段：`cursor` / `hasMore` / `serverTime` / `applied` / `stale` / `rejected` / `removed` / `items` 全部按契约解析。
- 排序：严格按 §5.5（未完成 priority → deadline(null 最后) → createTime 降序；已完成 **updateTime 降序 → 同毫秒 createTime 降序兜底**；未完成在前）。
- 逻辑时间戳（§1.1）：`updateTime` = `max(本机时间, 最大 serverTime + 1, 上次发号 + 1, 该条现值 + 1)`，
  水位由 `list` / `bulkUpsert` / `remove` / `ping` 的 `serverTime` 抬高并持久化（`qt_server_time_v1`）；
  `applied` 与 `stale` 覆盖前都会校验「推送期间是否被改过」，被改过则跳过，杜绝静默数据丢失。
- 拉取页数上限：`config.sync.maxPullPages = 20`（20 × 100 = 2000 条/轮），防止 `hasMore` 异常导致死循环；
  没拉完的部分下一轮从已持久化的游标继续，不丢数据。
- 默认时间（跨端统一）：**只给日期不给时间 → 当天 23:59:59.999**（`format.DEFAULT_TIME = '23:59'` + `endOfDay()`）；
  用户显式选了时间就用所选时间。`18:00` 之类的旧默认值已全部移除。
- AI 需要登录态：`ai` 云函数校验身份失败（`{ok:false,error:{code:'unauthorized'}}`）时，
  前端**不白屏、不丢文本**——保留原始转写为 1 条可编辑预览（`rawText` 一并保留），
  提示「登录态已失效，已保留原文」，用户可手动编辑/勾选后照常导入（导入走本地 + outbox，不依赖 `ai`）。

> **待主程确认的契约含糊点**（未擅自改动契约）：
> 1. ~~`clearDone` 在契约中不存在~~ → **已解决**：契约 §2.5.1 已补录为可选动作，且明确两端都用「软删除 + 批量 remove」，
>    本端实现无需改动。
> 2. ~~已完成组内 `updateTime` 相同时的次序未规定~~ → **已解决**：契约 §5.5 已写为
>    「`updateTime` 降序 → 同毫秒时 `createTime` 降序兜底」，本端 `store.sortTodos()` 与之一致。
> 3. **`stale` 回执里字段是否齐全**契约只示例了 `id/updateTime/content`。本端按「有则覆盖、无则保留本地」
>    处理，因此缺字段不会造成数据损坏，但若服务端能回传完整文档会更精确。
> 4. ~~`rawText` 长度上限契约未规定~~ → **已解决**：契约 §1.1 已写为 `≤4000`，本端一致。
> 5. ~~§3.1「ai 必须校验身份」与 §3.4「默认时间规则」未在契约中查到~~ → **已解决**：
>    契约 §3.3 已写明「`ai` 必须校验登录态，拿不到身份直接 401」；§3.4 已给出默认时刻表
>    （只给日期不给时间 → 当天 23:59:59.999；晚上 20:00 / 下午 15:00 / 上午 10:00 / 早上 8:00 / 中午 12:00）。
>    本端两处均已对齐：ai 401 优雅降级（见上）＋ `format.endOfDay()`/`DEFAULT_TIME` 实现「只给日期」那一行。
> 6. **§3.4 的词表（晚上/下午/上午/早上/中午、裸「X点」、顺延规则）属于服务端自然语言解析规则**，
>    小程序端不对文本做任何时间词推断（用户是显式选日期/时间的），因此只需对齐「只给日期」这一行，已实现。
