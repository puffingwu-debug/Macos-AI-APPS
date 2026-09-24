# QuickTodo 跨端契约（SYNC-PROTOCOL）

本文件是 **Mac 客户端 / 微信小程序 / 云函数** 三层之间唯一的接口真相来源。
任何一端改动接口，必须同步修改本文件，并把版本号 +1。

- 契约版本：`v1`
- 云数据库集合：`todos`、`auth_tickets`、`auth_sessions`、`counters`（可选）
- 云函数：`todo`、`ai`、`auth`
- 传输：小程序侧走 `wx.cloud.callFunction`；Mac 侧走 HTTP 访问服务（云接入）

---

## 1. 待办数据结构（集合 `todos`）

```jsonc
{
  "_id":        "string",   // 云数据库文档 _id，等于 id（客户端生成，保证跨端一致）
  "id":         "string",   // 业务主键，UUID v4，客户端生成，全局唯一
  "openid":     "string",   // 归属用户，仅云函数写入，客户端永不传（服务端按登录态填充）
  "content":    "string",   // 待办内容，非空，去首尾空格，最长 500 字
  "deadline":   0,          // 截止时间，Unix 毫秒；无截止时间为 null
  "priority":   "normal",   // "high" | "normal" | "low"
  "status":     "todo",     // "todo" | "done"
  "source":     "manual",   // "mac-screenshot" | "mini-voice" | "manual"
  "rawText":    "string",   // 原始 OCR / 语音转写文本（AI 降级展示与溯源用，可为空串）
  "deleted":    false,      // 软删除标记，true 表示已删除（同步删除必须靠它）
  "createTime": 0,          // 创建时间，Unix 毫秒（客户端生成，用于展示与排序）
  "updateTime": 0,          // 最后修改时间，Unix 毫秒（**服务端盖章**，冲突判定唯一依据）
  "seq":        0           // 服务端自增同步序号，仅供调试与排序展示，客户端不依赖它做游标
}
```

### 1.1 字段规则

| 字段 | 谁生成 | 规则 |
|---|---|---|
| `id` | 客户端 | UUID v4（小写带连字符）。离线创建的待办也要有 id，同步时幂等 |
| `content` | 客户端 | 去首尾空格，**1–500 字**（超长截断，空则拒收） |
| `rawText` | 客户端 | **≤ 4000 字**，超长截断（OCR/语音原文只用于溯源与降级展示） |
| `updateTime` | **服务端** | 云函数写入时**必须**用服务端时钟 `Date.now()` 覆盖客户端传值，避免多端时钟漂移 |
| `updateTime`（客户端上抛时填的临时值） | 客户端 | 离线时只能用本机时钟，但**必须**取逻辑时间戳：`max(本机时间, 见过的最大 serverTime + 1, 本机上次发号 + 1)`。否则本机时钟偏慢时，本地新改动的 `updateTime` 会小于服务端已存版本 → 上抛被判 `stale` → 服务端旧版本反覆盖本地，用户刚改的内容"自己变回去"。每次同步响应都要用 `serverTime` 抬高本机水位，并持久化 |
| `createTime` | 客户端 | 首次创建时生成，之后不可变；服务端仅在缺失时补 `Date.now()` |
| `score` | — | 不存储。排序由客户端本地完成（见 §5） |

### 1.2 索引（云开发控制台手动建）

| 集合 | 索引 | 说明 |
|---|---|---|
| `todos` | `openid`(升) + `updateTime`(升) | 增量拉取主索引，必须 |
| `todos` | `openid`(升) + `deleted`(升) + `updateTime`(降) | 列表查询 |
| `auth_tickets` | `expireAt`(升) | 过期清理 |
| `auth_sessions` | `openid`(升) | 会话查询 |

### 1.3 权限

全部集合权限设置为 **「仅创建者可读写」/ 私有**，客户端不直连数据库，
一切读写经云函数（云函数使用 admin 权限）。这是密钥与数据安全的前提。

---

## 2. 云函数 `todo` —— 数据 CRUD 与增量同步

### 2.1 入参信封

两种通道统一解到同一个 `payload`：

| 通道 | 解包方式 |
|---|---|
| 小程序 `callFunction` | `payload = event`（event 即业务参数） |
| HTTP 访问 | `payload = JSON.parse(event.body)`；`GET` 时取 `event.queryStringParameters` |
| HTTP 鉴权 | 请求头 `x-todo-token: <sessionToken>`；也接受 `payload.token` |

**身份解析顺序**：`cloud.getWXContext().OPENID` → 若为空则用 `x-todo-token` / `payload.token` 查 `auth_sessions`。
两者都拿不到 → 返回 `401 unauthorized`。

### 2.2 通用响应

```jsonc
// 成功
{ "ok": true, ... }
// 失败（HTTP 通道同时给出对应 statusCode，见 §2.7）
{ "ok": false, "error": { "code": "unauthorized", "message": "登录态已失效" } }
```

错误码枚举：`unauthorized` / `bad_request` / `not_found` / `rate_limited` / `upstream_error` / `internal`。

### 2.3 `list` —— 增量拉取

```jsonc
// 请求
{ "action": "list", "since": 1712345678901, "limit": 100, "includeDeleted": true }
```

- `since`：上次响应的 `cursor`；首次同步传 `0` 或省略。
- `limit`：**固定 100**，服务端一律 clamp 到 100（微信云开发单次 `where().get()` 上限就是 100）。
- 语义为 **`updateTime >= since`**（闭区间）。同一毫秒的并发写在闭区间下不会丢，
  代价是**边界那一条会被重复下发一次**（`updateTime === since`），
  客户端按 `id` 去重即可 —— 这是刻意的取舍：宁可重发，不可丢失。
- **服务端所有写入的 `updateTime` 必须严格单调递增**
  （同一容器内 `nextStamp() = max(Date.now(), 上次发号 + 1)`）。
  这是分页能推进的前提：一次 `bulkUpsert` 150 条会拿到 150 个互不相同的毫秒值，
  否则「一页 100 条 + `cursor = max(updateTime)`」会原地打转。
  防御分支：满页且 `cursor === since`（跨容器同毫秒的极端情况）时返回 `hasMore:false` 并打 warn，
  宁可这轮少给也不能让客户端空转。
- `includeDeleted` 默认 `true`：删除也要同步给其他端。

```jsonc
// 响应
{
  "ok": true,
  "items": [ /* Todo 数组，按 updateTime 升序 */ ],
  "cursor": 1712345699999,   // = 本次 items 的 max(updateTime)，空结果时原样回传 since
  "hasMore": false,          // true 表示还有更多，客户端应立刻用新 cursor 再拉一次
  "serverTime": 1712345700000
}
```

**客户端拉取循环**（两端一致）：`while hasMore { page = list(since: cursor); cursor = page.cursor; }`，
并按 `id` + `updateTime` 去重。必须留一个迭代上限（Mac 20 轮 / 小程序 `maxPullPages = 20`）
作为防御；未拉完的部分下一轮从已持久化的 `cursor` 继续，不会丢数据。

### 2.4 `upsert` / `bulkUpsert` —— 写入（LWW 冲突解决）

```jsonc
// 请求（单个）
{ "action": "upsert", "item": { "id": "...", "content": "...", "deadline": null,
  "priority": "high", "status": "todo", "source": "mac-screenshot",
  "rawText": "...", "createTime": 1712345678901, "updateTime": 1712345678901 } }

// 请求（批量，Mac 离线补同步、AI 批量导入用）
{ "action": "bulkUpsert", "items": [ /* Todo */ ] }
```

服务端逐条处理：

1. 校验：`id` 匹配 `^[0-9a-fA-F-]{8,64}$`，`content` 去空格后非空且 ≤500 字；
   非法条目跳过并记入 `rejected`，不影响其他条目。
2. 查现存文档（`_id = id` 且 `openid` 一致）。
3. **冲突判定**：若现存 `updateTime >= 入参 updateTime` → 判为 `stale`，**不覆盖**，
   把服务端当前值回给客户端（客户端据此纠正本地缓存）。
   > **`stale` 数组必须回传完整文档**（`id/content/deadline/priority/status/source/rawText/deleted/updateTime`），
   > 因为客户端会用服务端版本整体覆盖本地；只回 `id` + `updateTime` 会让客户端拿到残缺数据。
   > 客户端侧也要防御：`content` 为空的 `stale` 条目直接忽略。
4. 否则写入，`updateTime = Date.now()`（服务端盖章），并回传。

```jsonc
// 响应
{
  "ok": true,
  "applied":  [ { "id": "...", "updateTime": 1712345700123 } ],  // 已落库
  "stale":    [ { "id": "...", "updateTime": 1712300000000, "content": "服务端更新版本" } ],
  "rejected": [ { "id": "...", "reason": "empty_content" } ],
  "serverTime": 1712345700123
}
```

### 2.5 `remove` —— 软删除

```jsonc
{ "action": "remove", "ids": ["id1", "id2"] }
// → { "ok": true, "removed": ["id1","id2"], "serverTime": 1712345700123 }
```

实现为 `deleted = true, updateTime = Date.now()`，保证删除能增量下发到所有端。

### 2.5.1 `clearDone`（可选便捷动作）

```jsonc
{ "action": "clearDone" }
// → { "ok": true, "removed": ["id1","id2"], "serverTime": 1712345700123 }
```

语义 = 对该用户所有 `status === "done"` 的文档做软删除。
**不是必须调用的**：两端「清空已完成」都实现为本地软删除 + 批量 `remove` 上抛，
效果完全等价且少一个 action。云函数提供它只是为了给外部脚本/调试留个入口。

### 2.6 `ping` —— 连通性与会话校验（Mac 设置页「测试连接」用）

```jsonc
{ "action": "ping" }
// → { "ok": true, "openid": "oXXXX", "count": 12, "serverTime": 1712345700123, "version": "v1" }
```

### 2.7 HTTP 通道映射

| 场景 | `httpMethod` | 出参 |
|---|---|---|
| 正常 | 任意 | `{ statusCode: 200, headers: {...CORS...}, body: "<JSON 字符串>" }` |
| 未授权 | 任意 | `statusCode: 401`，body 为 `{"ok":false,"error":{"code":"unauthorized"}}` |
| 参数错 | 任意 | `statusCode: 400` |
| 预检 | `OPTIONS` | `statusCode: 204` + CORS 头 |

Mac 端只需 `POST <baseURL>/todo`，body 为上面的 JSON，头带 `x-todo-token`。

---

## 3. 云函数 `ai` —— DeepSeek 结构化待办解析

### 3.1 请求

```jsonc
{
  "action": "parse",
  "text": "明天下午三点前把季度报表发给张总 还要买牛奶",
  "source": "mac-screenshot",        // 或 "mini-voice"
  "now": 1712345678901,              // 客户端本地时间（用于解析「明天」等相对时间）
  "timezone": "Asia/Shanghai",
  "maxItems": 8
}
```

### 3.2 响应

```jsonc
{
  "ok": true,
  "engine": "deepseek",              // "deepseek"（真实模型）| "rule"（本地降级规则）
  "model": "deepseek-flash",
  "todos": [
    { "content": "把季度报表发给张总", "deadline": 1712386800000, "priority": "high" },
    { "content": "买牛奶",             "deadline": null,          "priority": "normal" }
  ],
  "elapsedMs": 1832
}
```

失败（**只有入参错误才算失败**）：

```jsonc
{ "ok": false, "error": { "code": "bad_request", "message": "text 不能为空" },
  "engine": "rule", "fallbackText": "原始文本原样返回，客户端降级为可编辑的纯文本导入" }
```

> 上游失败（无 key / 超时 / 非 200 / 返回非法 JSON）**不算失败**，必须降级为
> `{ "ok": true, "engine": "rule", "notice": "DeepSeek 不可用，已用本地规则解析", "todos": [...] }`，
> 绝不整条请求报错——用户刚框完一块屏幕，不能因为上游抖动就白干。

### 3.3 密钥、鉴权与降级（**硬性要求**）

- `DEEPSEEK_API_KEY` **只能**存在于云函数环境变量。小程序与 Mac 端代码中
  永远不出现 key、不直连 `api.deepseek.com`。
- **`ai` 必须校验登录态**：身份解析与 `todo` 相同（小程序 OPENID 优先，
  其次 HTTP 头 `x-todo-token` / `payload.token` 查 `auth_sessions`）。
  拿不到身份直接 401 —— 否则任何人拿到云接入地址就能白烧你的 DeepSeek 额度。
- 未配置 key 时，云函数**不得报错中断**，改用内置规则解析器（正则 + 中英文时间词表），
  返回 `engine: "rule"`，保证功能可用。
- 环境变量：`DEEPSEEK_API_KEY`、`DEEPSEEK_BASE_URL`（默认 `https://api.deepseek.com`）、
  `DEEPSEEK_MODEL`（默认 `deepseek-flash`）、`DEEPSEEK_TIMEOUT_MS`（默认 20000）。
- 调用 `/chat/completions`，`response_format: { type: "json_object" }`，
  系统提示词内注入当前时间与时区，要求只输出 `{"todos":[...]}`。
- 超时/异常时必须回传 `fallbackText`，两端都能退化为「原始文本手动编辑」。
- **云函数超时要调大**：`ai` 默认超时约 3s，必须改成 30s，否则 DeepSeek 还没返回就会被平台杀掉。

### 3.4 解析规则约定（两端 UI 需一致）

- `deadline` 为 `null` 或 Unix 毫秒；模型给的日期若早于 `now` 且未指定年份，
  按「明年」处理。
- 一条文本里的多个任务要**拆成多条**待办；纯寒暄/无信息量的行丢弃。
- `content` 要**去掉时间词**（时间信息进 `deadline`，不要留在内容里），
  例如「明天下午三点前把季度报表发给张总」→ content `把季度报表发给张总` + deadline 明天 15:00。
- `priority` 只能取 `high` / `normal` / `low`；出现
  「紧急/尽快/立刻/马上/立即/务必/必须/优先/asap」→ `high`。
- **默认时刻（三端必须一致，否则同一个输入在两台设备上显示不同时间）**：

  | 输入形态 | deadline |
  |---|---|
  | 只给日期不给时间（明天 / 下周三 / 3月5日） | 当天 **23:59:59.999** |
  | 「晚上」「今晚」 | 20:00 |
  | 「下午」 | 15:00 |
  | 「上午」 | 10:00 |
  | 「早上」「早晨」 | 8:00 |
  | 「中午」 | 12:00 |
  | 裸「X点」 | 按字面取，不猜上下午（「三点」= 03:00） |
  | 显式写了「今天」且时刻已过 | **不顺延**（用户明确说了今天） |
  | 没写日期词、只有钟点/时段，且今天该时刻已过 | 顺延到明天 |

- 客户端导入前必须展示可编辑的预览列表（勾选 + 改内容 + 改时间 + 改优先级）。

---

## 4. 云函数 `auth` —— Mac 扫码登录

小程序侧 openid 由微信上下文天然提供，`auth` 只服务于 **Mac 端获得登录态**。

### 4.1 流程

```
Mac                         云函数 auth                    小程序
 |-- createTicket ----------->|  建 auth_tickets(pending)     |
 |<-- {ticket, qrPayload} ----|                              |
 |  (本地渲染二维码)            |                              |
 |                            |<---- confirmTicket(ticket) ---|  用户在小程序内扫码
 |-- pollTicket(ticket) ----->|  绑 openid，发 token          |
 |<-- {status:"confirmed",    |                              |
 |     token, openid} --------|                              |
```

### 4.2 动作定义

| action | 入参 | 出参 |
|---|---|---|
| `createTicket` | `{deviceName}` | `{ok,ticket,qrPayload,expiresIn,expireAt}` |
| `pollTicket` | `{ticket}` | `{ok,status:"pending"/"scanned"/"confirmed"/"expired",token?,openid?}` |
| `confirmTicket` | `{ticket}`（openid 取上下文） | `{ok,openid}` |
| `check` | `{token}` | `{ok,openid,expireAt}` |
| `logout` | `{token}` | `{ok}` |

- `ticket`：32 位随机十六进制串（`crypto.randomBytes(16)`）。
- `qrPayload`：`quicktodo://login?ticket=<ticket>`，Mac 直接把它编码成二维码。
- 小程序用 `wx.scanCode` 扫这个二维码，从结果里正则取出 `ticket`。
- `token`：48 位随机十六进制串，写入 `auth_sessions`，有效期 **30 天**（`expireAt`）。
- `ticket` 有效期 **5 分钟**，`pollTicket` 必须先判过期。
- 一票一用：`confirmTicket` 成功后 ticket 置 `confirmed`，重复 confirm 返回 409 语义的 `bad_request`。

---

## 5. 同步策略（两端一致实现）

1. **本地优先**：任何增删改**先写本地**并立即刷新 UI，UI 永不等待网络。
2. **待同步队列（outbox）**：写本地时同时把变更记入 outbox；同步循环按序 `bulkUpsert` / `remove` 上抛；
   成功后移出队列；失败保留并指数退避（1s→2s→4s…上限 60s）。
3. **增量拉取**：`list(since=cursor)`，成功后 `cursor = 响应.cursor`，并把 `hasMore` 循环拉空。
4. **冲突解决 = LWW by updateTime**：服务端 `updateTime` 是唯一权威时钟；
   收到 `stale` 回执时，用服务端版本覆盖本地（服务端为准）。
5. **排序（客户端本地计算，两端必须一致）** —— 三端代码注释/README 里简称 **§5.5**（本条第 5 项）：
   - 分组：`status == "done"` 归已完成，其余归未完成（未完成在前）。
   - 未完成组内：`priority` 权重（high 0 / normal 1 / low 2）升序 → `deadline` 升序（null 排最后）→ `createTime` 降序。
   - 已完成组内：`updateTime` 降序 → 同毫秒时 `createTime` 降序兜底（避免列表跳动）。
   - Mac 端可切换为「按创建时间」排序：`createTime` 降序，分组不变。
6. **离线可读可写**：Mac 端本地 JSON 持久化 + outbox；小程序端 `wx.setStorageSync` 缓存 + outbox。
7. **轮询频率**：Mac 前台 15s / 后台 60s；小程序 `onShow` 拉一次 + 下拉刷新 + 变更后立即回传。

---

## 6. 安全清单

- [x] DeepSeek key 仅存在于云函数环境变量（`DEEPSEEK_API_KEY`）。
- [x] 数据库集合权限为私有，客户端不直连数据库。
- [x] Mac 端 token 存于 Keychain（`kSecClassGenericPassword`），不落明文文件。
- [x] 所有请求 HTTPS；云函数校验登录态后才操作数据。
- [x] 云函数入参一律当作不可信输入做校验与长度截断。
