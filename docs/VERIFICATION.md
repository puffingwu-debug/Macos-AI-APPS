# 验证记录（Verification）

本文件记录的是**实际执行过的命令与真实输出**，不是设计意图。
所有用例都在本机 macOS 26.6.2 / Swift 6.3.3 上跑通，退出码均为 0。

复现方式见每一节顶部的命令。

| 层 | 命令 | 结果 |
|---|---|---|
| **跨端契约一致性** | `node tools/check-contract.js` | **56 passed / 0 failed**，exit 0 |
| Mac 端（离线） | `QuickTodo --selftest` | **40 passed / 0 failed**，exit 0 |
| 云函数（内存库） | `node quicktodo-weapp/tools/cloud-harness.js` | **103 passed / 0 failed**，exit 0 |
| **跨端真实联调** | `QuickTodo --integration <harness地址> <token>` | **50 passed / 0 failed**，exit 0 |
| 小程序端（静态） | `node --check` × 12 个 JS + 9 个 JSON parse | 全部通过 |
| 小程序端（逻辑回归） | `node quicktodo-weapp/tools/miniprogram-tests.js` | 见 §6 |

> 跨端联调用的是**真实的 `QuickTodoAPI` / `LocalStore` / `SyncEngine`**，
> 打到**真实的云函数代码**（`quicktodo-weapp/cloudfunctions/`，由 harness 以微信云开发的
> event/response 形状托管），中间隔着真实的 HTTP 云接入信封。三方都不是 mock。

---

## 1. 跨端契约一致性（机械校验）

```bash
node tools/check-contract.js
```

```
契约一致性校验全部通过: 56 passed, 0 failed
```

这份交付由三层组成，最容易出的不是「写错一行」而是**悄悄漂移**：某端把 `limit` 写回 200、
字段改名、客户端里塞了 DeepSeek key、或者新 action 只在云函数里实现了。
这类问题往往要到真机联调才暴露，所以用脚本在提交前机械拦一道。检查项：

1. 10 个契约字段在三端源码里都存在；
2. 云函数实现了契约里的全部 action（`todo` 6 个 + `ai` 1 个 + `auth` 5 个）；
3. 两端调用的每个 action 都能在云函数里找到实现；
4. 分页上限两端都是 100，且云函数不再出现 `limit: 200`；
5. **密钥边界**：客户端代码里没有 `sk-xxx` 字面量、没有 `api.deepseek.com`、不引用 `DEEPSEEK_API_KEY`，
   云函数确实从 `process.env` 读取；
6. **`ai` 先鉴权再解析**（否则任何人拿到云接入地址就能白烧额度）；
7. 契约版本号 `v1` 在三端一致；
8. 各层交付文档与联调工具存在。

> 检查器会**先去注释再判断**，但保留字符串字面量 ——
> 否则注释里那句「不得出现 DEEPSEEK_API_KEY」会被误报，而真正的
> `"https://api.deepseek.com"` 又可能被注释剥离逻辑剪掉导致漏报（假阴性比假阳性危险得多）。

## 2. Mac 端离线自检

```bash
cd QuickTodo && ./build.sh release
./dist/QuickTodo.app/Contents/MacOS/QuickTodo --selftest
```

```
== 结果：40 项通过，0 项失败 ==
```

覆盖：

- **契约字段**：`Todo` 编码后的字段集合与 `SYNC-PROTOCOL.md` §1 逐字一致（10 个字段），
  `source` / `priority` / `status` 取值正确；能容错解析服务端回传的 `_id` / `openid` / `seq` 与 `deadline: null`。
- **分组排序**：未完成按「优先级 → 截止时间（null 最后）→ 创建时间倒序」，已完成 `updateTime` 倒序。
- **本地规则解析**：中文数字钟点（「三点」「十点半」）、时段词（下午→15:00 / 上午→10:00 / 晚上→20:00）、
  列表序号（`1.` / `①`）、时间词从内容里剥离（「明天下午三点前把季度报表发给张总」→ `把季度报表发给张总` + 明天 15:00）、
  只给日期 → 当天 23:59:59.999、连接词拆句（「还要」）。
- **真实 OCR 链路**：渲染一张中文 PNG → 系统 Vision 识别 → 校验识别出「报表 / 张总 / 牛奶」、
  阅读顺序正确、并能解析成 2 条待办。
- **本地时钟保护**：见 §4。

## 3. 云函数自检（无需部署、无需云环境）

```bash
cd quicktodo-weapp && node tools/cloud-harness.js
```

```
cloud-harness 自检全部通过: 103 passed, 0 failed
```

覆盖：`list`/`upsert`/`bulkUpsert`/`remove`/`clearDone`/`ping` 双通道（callFunction + HTTP 云接入）、
身份解析（OPENID 优先 → `x-todo-token` / `payload.token` → `auth_sessions` 且校验过期）、
LWW（旧版本判 `stale` 且**不覆盖**、回传完整文档）、软删除下发、
**严格递增 `updateTime` 导致的分页推进**（150 条 = 100 + 50，边界重发 1 条，去重后无遗漏）、
`ai` 鉴权（无 token / 伪造 token / 过期 session 全部 401）、
`ai` 降级（无 key / 超时 / 非 200 / 非法 JSON → `engine:'rule'`，绝不整体失败）、
`auth` 票据一票一用，以及 CORS / OPTIONS / 404 / GET 查询串。

## 4. 跨端真实联调（Mac 客户端 ↔ 云函数）

```bash
# 终端 A
cd quicktodo-weapp && node tools/cloud-harness.js --serve 8787     # 内存库，启动日志会打印预置 token
# 终端 B
cd QuickTodo && ./.build/debug/QuickTodo --integration http://127.0.0.1:8787 <预置token>
```

> harness 是内存库，请用**刚启动**的实例跑（用例里有「首次全量拉取」这类依赖空库的断言）。

真实输出（完整）：

```
== QuickTodo 跨端联调自检 ==
   云端：http://127.0.0.1:8793

[1] 连通性与鉴权
  ✅ ping 返回契约版本 v1 — version=v1
  ✅ ping 带回 openid — oMAC
  ✅ 非法 token 被拒绝（401 unauthorized） — unauthorized

[2] 写入与字段往返
  ✅ 批量写入 3 条 — applied=3
  ✅ 写入未被拒绝
  ✅ 服务端盖章 updateTime — 最早 1790235471565 vs 本地 1790235471556
  ✅ 首次全量拉取包含这 3 条 — 共 3 条
  ✅ 游标前进 — cursor=1790235471567
  ✅ hasMore=false
  ✅ content 往返一致
  ✅ deadline 往返一致 — 1790239071556 vs 1790239071556
  ✅ priority 往返一致 — high
  ✅ source 往返一致 — mac-screenshot
  ✅ rawText 往返一致
  ✅ status 往返一致 — todo
  ✅ deleted 默认 false
  ✅ createTime 保留客户端值 — 1790235468556 vs 1790235468556
  ✅ updateTime 由服务端盖章（≠ 客户端原值或已更新）
  ✅ 已完成状态往返一致 — done

[3] LWW 冲突解决（契约 §2.4）
  ✅ 旧版本被判 stale — stale=1
  ✅ 旧版本未被 applied
  ✅ stale 回传完整文档（客户端可据此纠正本地） — 【联调71556】交给张总的季度报表
  ✅ 新版本被接受 — applied=1

[4] 软删除与增量游标（契约 §2.5 / §2.3）
  ✅ remove 回执列出被删 id
  ✅ 增量只下发变化过的条目 — 2 条：["【联调71556】买牛奶（已改）", "【联调71556】整理桌面"]
  ✅ 删除以 deleted=true 下发（其他端才能同步删除）
  ✅ 被拒的旧版本确实没写进去
  ✅ 改动后的内容已下发

[5] 分页推进（契约 §2.3：limit=100 + 严格递增 updateTime 游标）
  ✅ 150 条全部写入 — applied=150
  ✅ 第一轮返回整页 100 条 — 100 条
  ✅ 游标持续推进到拉空 — 2 轮
  ✅ 150 条全部拉到且无重复丢失 — 共收到 151 条

[6] AI 结构化解析（契约 §3）
  ✅ 返回结构化待办 — 2 条：["把季度报表发给张总", "买牛奶"]
  ✅ engine 取值合法 — rule
  ✅ 每条都有内容
  ✅ 规则引擎识别出「报表」任务 — 把季度报表发给张总 | 买牛奶
  ✅ 规则引擎拆出「买牛奶」
  ✅ 未登录调用 ai 被拒绝（401） — unauthorized

[7] 本地优先 + 增量同步闭环（真实 SyncEngine）
  ✅ 写入本地后立即有数据（UI 不等网络）
  ✅ 上抛后 outbox 清空 — 仍有 0 条待上传
  ✅ 同步状态正常 — 已同步
  ✅ 云端已存在本地新增的 A
  ✅ 云端已存在本地新增的 B
  ✅ 服务端盖章时间已回写本地 — 1790235471720 vs 1790235471720
  ✅ 第二轮同步后 outbox 清空
  ✅ 完成状态已同步到云端 — done
  ✅ 删除已同步到云端（软删除）
  ✅ 新设备全量拉取拿到同样的数据 — 155 vs 155
  ✅ 新设备看到 A 是已完成
  ✅ 新设备看到 B 已删除

== 结果：50 项通过，0 项失败 ==
```

两个值得说明的细节：

- **[5] 收到 151 条不是 bug**：`since` 是 **gte 闭区间**（§2.3 的刻意取舍——宁可重发不可丢失），
  所以边界那一条会被重复下发一次；按 `id` 去重后正好 150 条，`hasMore` 随后收敛。
- **[6] engine = rule 是预期**：harness 没配 `DEEPSEEK_API_KEY`，走的是规则降级路径。
  配好 key 后同一条请求会返回 `engine: "deepseek"`，两条路径的响应结构完全一致。

## 5. 本机时钟偏差保护（易被忽略的一类静默数据丢失）

契约用 `updateTime` 做 LWW 判定，而客户端离线时只能用本机时钟。若本机时钟**比服务器慢**：

```
离线改一条待办（本机时间 = 服务器时间 - 10 分钟）
  → 上抛时 updateTime 小于服务端已存版本
  → 服务端判 stale，回传旧版本
  → 客户端用 stale 覆盖本地
  → 用户刚改的内容"自己变回去了"，且 UI 上曾显示"已保存"
```

两端都改为**逻辑时间戳（HLC-lite）**：

```
updateTime = max(本机时间, 见过的最大 serverTime + 1, 本机上次发号 + 1)
```

每次同步响应用 `serverTime` 抬高水位并持久化，上抛成功后采用服务端盖章值。
Mac 端的回归用例在 `--selftest` 第 [5] 节（5 项），小程序端用例见 §6。

## 6. 小程序端校验

### 6.1 静态校验

```bash
cd quicktodo-weapp
for f in $(find miniprogram -name "*.js"); do node --check "$f"; done   # 12/12 通过
for f in $(find . -name "*.json"); do node -e "JSON.parse(require('fs').readFileSync('$f','utf8'))"; done
```

### 6.2 核心逻辑回归（内存桩，无需开发者工具）

```bash
cd quicktodo-weapp && node tools/miniprogram-tests.js
```

```
小程序端自检全部通过: 105 passed, 0 failed      # 退出码 0
```

覆盖六块最容易出静默 bug 的逻辑（每节都做过**独立进程单跑**，确认节间零依赖）：

| 分节 | 条数 | 覆盖内容 |
|---|---|---|
| 存储与排序 | 12 | 契约 §5.5 三级排序键（含 `updateTime` 同毫秒时 `createTime` 兜底）、已完成分组、缓存读写 |
| outbox 与 LWW | 12 | 同一 id 写合并、`applied` / `stale` / `rejected` 三种回执处理、软删除墓碑 |
| 同步引擎 | 27 | 推 → 拉顺序、`hasMore` 循环与 `maxPullPages` 上限、失败保留 outbox + 指数退避、本地模式零请求 |
| 时钟保护 | 27 | 逻辑时间戳高于服务端水位、连续写入严格递增、`applied` 已改过则跳过覆盖、`stale` 保住并发编辑、水位持久化与冷启动恢复、**水位只增不减** |
| 输入规范化与默认时间 | 19 | 契约 §1.1 的 500 / 4000 截断、空内容本地拦下、只给日期 → 23:59:59.999 往返无损 |
| AI 解析降级 | 8 | `engine:'rule'`、未授权时保留原文仍可导入 |

> 这套用例还带一个**阳性对照**（「旧的 `Date.now()` 版本会被判 stale」），
> 用来证明「时钟保护」这组断言真的能抓到 bug，而不是恒真断言。

> 边界：小程序无法在 macOS 命令行里编译运行，以上只覆盖**纯逻辑层**。
> UI、同声传译插件、云开发真实环境必须在微信开发者工具里验证
> （步骤见 `quicktodo-weapp/README.md`），且语音功能必须换成自有 AppID 并在小程序后台添加插件。

## 7. 未验证的部分（诚实清单）

| 项 | 原因 |
|---|---|
| Mac 悬浮球的拖拽手感、贴边隐藏动画、透明度观感 | 需要人眼与鼠标交互，命令行环境无法断言 |
| 系统「屏幕录制」授权与首次截图 | 需要真实点击系统弹窗并重启 App |
| 微信小程序真机 UI、同声传译插件、云开发真实环境 | 需要微信开发者工具 + 自有 AppID + 云环境 |
| 真实 DeepSeek 调用 | 需要 `DEEPSEEK_API_KEY`；未配置时走规则降级（已充分测试） |
| 扫码登录的完整人类流程 | 需要手机微信扫码；ticket/轮询/会话的每一步都由 harness 用例覆盖 |
