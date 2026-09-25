# QuickTodo 云函数部署手册（微信云开发）

本目录是 QuickTodo 的**云函数层**，实现 `docs/SYNC-PROTOCOL.md`（契约 v1）。
小程序走 `wx.cloud.callFunction`，Mac 端走 **HTTP 访问服务（云接入）**，两条通道共用同一套 action 与响应结构。

> 契约是唯一真相来源：字段名 / action 名 / 错误码 / 响应结构一律以 `docs/SYNC-PROTOCOL.md` 为准。
> 本手册只讲「怎么部署、怎么配、怎么验」。

---

## 1. 目录结构

```
quicktodo-weapp/cloudfunctions/
├── todo/                 # 待办 CRUD 与增量同步（契约 §2）
│   ├── index.js          # 双通道解包 + 身份解析 + list/upsert/bulkUpsert/remove/clearDone/ping
│   └── package.json      # 依赖 wx-server-sdk ~2.6.3
├── ai/                   # DeepSeek 结构化待办解析 + 规则降级（契约 §3）
│   ├── index.js          # action: parse；先校验登录态；https 直连 /chat/completions，失败一律降级
│   ├── prompt.js         # 系统/用户提示词构造（注入当前时间与时区）
│   ├── parser.js         # 零依赖降级规则解析器（中文时间词、优先级、切分）
│   └── package.json
├── auth/                 # Mac 扫码登录（契约 §4）
│   ├── index.js          # createTicket / pollTicket / confirmTicket / check / logout
│   └── package.json
└── README.md             # 本文件

quicktodo-weapp/tools/     # 本地联调桩（不属于云函数，不用上传）
├── cloud-harness.js       # 内存版 wx-server-sdk + 自检 + 本地云接入服务
└── README.md
```

三个云函数**互相独立、各自自包含**：响应封装 / CORS / 鉴权 / 校验在每个目录里各有一份精简实现，
不存在跨目录 `require`，可以单独上传、单独回滚。

各云函数的 action 一览：

| 云函数 | action | 说明 |
|---|---|---|
| `todo` | `list` | 增量拉取，`updateTime >= since` 闭区间，升序，返回 `items/cursor/hasMore/serverTime` |
| `todo` | `upsert` | 单条写入（LWW，服务端盖 `updateTime`） |
| `todo` | `bulkUpsert` | 批量写入（离线补同步 / AI 批量导入） |
| `todo` | `remove` | 软删除（`deleted:true` + 新 `updateTime`） |
| `todo` | `clearDone` | 清空已完成（把该用户 `status==='done'` 全部软删除） |
| `todo` | `ping` | 连通性 + 会话校验（Mac 设置页「测试连接」） |
| `ai` | `parse` | 文本 → `[{content, deadline, priority}]`，`engine: deepseek \| rule`；**需登录态** |
| `auth` | `createTicket` | Mac 生成登录二维码 |
| `auth` | `pollTicket` | Mac 轮询扫码结果 |
| `auth` | `confirmTicket` | 小程序确认（**必须在小程序内调用**，见 §6.3） |
| `auth` | `check` | 校验 token 是否有效 |
| `auth` | `logout` | 删除会话 |
| 全部 | 身份解析 | `cloud.getWXContext().OPENID` 优先，其次 HTTP 头 `x-todo-token` / `payload.token` 查 `auth_sessions`；拿不到 → 401 |

---

## 2. 部署云函数

### 2.1 创建云开发环境

1. 用**微信开发者工具**打开小程序项目（`quicktodo-weapp`，含 `miniprogram/` 与 `cloudfunctions/`）。
2. 点顶部工具栏 **「云开发」** → 首次使用点 **「开通」** → 同意协议。
3. 新建环境：名称随意（如 `quicktodo-prod`），记下**环境 ID**（形如 `quicktodo-1a2b3c-1300000000`，后面配域名要用）。
4. 确认 `project.config.json` 里的 `cloudfunctionRoot` 指向 `cloudfunctions/`（本仓库已是该结构）。
   - 若左侧看不到云函数列表：右键 `cloudfunctions` 目录 → **「当前环境」** 选到刚建的环境。

### 2.2 上传三个云函数

在开发者工具左侧资源管理器中，**分别右键** `todo`、`ai`、`auth` 三个目录：

```
右键 todo  → 上传并部署：云端安装依赖（不上传 node_modules）
右键 ai    → 上传并部署：云端安装依赖（不上传 node_modules）
右键 auth  → 上传并部署：云端安装依赖（不上传 node_modules）
```

- 必须选 **「云端安装依赖」**：本地没有 `node_modules`，选「所有文件」会因为缺 `wx-server-sdk` 报
  `Cannot find module 'wx-server-sdk'`。
- 每次改完 `index.js` 都要**重新上传**才会生效（云函数不会热更新）。
- 上传成功后在 **云开发控制台 → 云函数 → 函数列表** 里能看到三个函数及其「最后更新时间」。

### 2.3 调大 `ai` 的超时时间（重要）

云函数默认超时约 **3 秒**，而 DeepSeek 解析通常要 1~20 秒。
**云开发控制台 → 云函数 → ai → 配置 → 超时时间** 改成 **30 秒**（内存 256MB 足够）。
否则会出现「本地看是 upstream 超时、日志显示函数被平台杀掉」的现象。
`todo`、`auth` 保持默认即可。

---

## 3. 创建数据库集合与权限

**云开发控制台 → 数据库 → 集合管理**，依次新建 4 个集合（名字必须完全一致）：

| 集合 | 用途 | 权限设置 |
|---|---|---|
| `todos` | 待办数据（契约 §1） | **仅创建者可读写** |
| `auth_tickets` | 扫码登录票据（5 分钟） | **仅创建者可读写** |
| `auth_sessions` | Mac 登录会话（30 天） | **仅创建者可读写** |
| `counters` | `seq` 自增序号（可选） | **仅创建者可读写** |

- 权限选择 **「仅创建者可读写」**（或控制台提供的「私有」）。客户端**不直连数据库**，一切读写经云函数；
  云函数使用 **admin 权限**，不受该规则限制。
- 千万不要为图省事选「所有用户可读」：那样小程序/ Mac 端就能绕过云函数校验直接改库，契约 §6 的安全清单就废了。
- `counters` 只用来给待办盖 `seq` 序号（契约 §1 的调试字段）。**不建也能跑**：
  代码里取序号失败会自动退化为 `Date.now()`，不影响写入（`seq` 客户端不依赖）。

---

## 4. 建索引（契约 §1.2，必须手动建）

**云开发控制台 → 数据库 → 选择集合 → 索引管理 → 添加索引**：

| 集合 | 索引名（随意） | 字段与排序 | 唯一 | 说明 |
|---|---|---|---|---|
| `todos` | `openid_updateTime` | `openid` **升序** + `updateTime` **升序** | 否 | **增量拉取主索引，必须建**，否则数据量上来后 `list` 会变慢甚至超时 |
| `todos` | `openid_deleted_updateTime` | `openid` **升序** + `deleted` **升序** + `updateTime` **降序** | 否 | 列表查询 / `clearDone` / `ping` 计数 |
| `auth_tickets` | `expireAt_asc` | `expireAt` **升序** | 否 | 过期票据清理；`createTicket` 的防刷计数也会用到 |
| `auth_sessions` | `openid_asc` | `openid` **升序** | 否 | 会话查询（按用户踢下线、统计） |

补充说明：

- `auth_tickets` 的 `_id` 就是 32 位 ticket，`auth_sessions` 的 `_id` 就是 48 位 token，
  这两个集合的按主键查询不需要额外索引。
- 索引是**后台构建**的，建完等状态变成「已完成」再压测。
- 建索引不会影响已有数据，但构建期间写入会略慢。

---

## 5. 配置 `ai` 的环境变量（DeepSeek key 只在这里出现）

### 5.1 操作步骤（截图级）

1. 打开 **微信开发者工具 → 云开发 → 云开发控制台**。
2. 顶部确认环境是你部署的那个（如 `quicktodo-prod`）。
3. 左侧 **「云函数」→ 函数列表 → 点 `ai`** 进入函数详情。
4. 切到 **「配置」** 标签页（部分版本叫「版本与配置」/「函数配置」）。
5. 找到 **「环境变量」** 区域 → 点 **「编辑」/「新增」**，逐条填下面的键值对（键名大小写必须一致）。
6. 点 **「保存」**。环境变量变更后云函数会自动重新加载配置，无需重新上传代码；
   若不确定是否生效，再点一次「上传并部署：云端安装依赖」。
7. 验证：`curl` 调一次 `ai` 的 `parse`，响应里 `engine` 为 `deepseek` 即说明 key 已生效；
   若为 `rule` 且 `notice` 提示「未配置 DEEPSEEK_API_KEY」，说明变量没保存成功或存到了别的函数上。

### 5.2 变量清单

| 变量名 | 必填 | 默认值 | 说明 |
|---|---|---|---|
| `DEEPSEEK_API_KEY` | 是（不填则永远走规则降级） | 无 | DeepSeek 控制台申请的 key，形如 `sk-xxxx` |
| `DEEPSEEK_BASE_URL` | 否 | `https://api.deepseek.com` | 兼容自建网关 / 代理；代码会自动去掉结尾 `/` |
| `DEEPSEEK_MODEL` | 否 | `deepseek-flash` | 模型名 |
| `DEEPSEEK_TIMEOUT_MS` | 否 | `20000` | 单次请求超时（代码内限幅 1000~60000）；**要小于 §2.3 的函数超时** |

### 5.3 安全红线

- **key 只能存在于云函数环境变量**：小程序端、Mac 端代码里永远不出现 key，也不直连 `api.deepseek.com`。
- 不要把 key 写进 `index.js`、`package.json`、README、`.env` 提交到仓库。
- 云函数日志里也不会打印 key：出错信息统一做了脱敏（`sk-***` / `Bearer ***`）。
- `todo`、`auth` **不需要**任何环境变量。

---

## 6. 配置 HTTP 访问服务（云接入）

Mac 端不走微信登录态，靠 HTTP + `x-todo-token` 访问，所以三个函数都要各绑一个触发路径。

### 6.1 绑定路径

1. **云开发控制台 → 左侧「HTTP 访问服务」**（不同版本可能叫 **「云接入」/「访问服务」**）。
2. 首次使用先点 **「开通」**（若提示需要实名/资质，按引导完成）。
3. 点 **「添加触发路径」/「新建」**，绑定关系如下（路径名可自定义，但要与 Mac 端 baseURL 拼接一致）：

   | 触发路径 | 绑定的云函数 | 鉴权方式 |
   |---|---|---|
   | `/todo` | `todo` | **不需要鉴权（免鉴权）** |
   | `/ai` | `ai` | **不需要鉴权（免鉴权）** |
   | `/auth` | `auth` | **不需要鉴权（免鉴权）** |

4. **鉴权方式务必选「免鉴权 / 不需要鉴权」**：Mac 端用的是自建 `x-todo-token` 会话，
   若选「微信鉴权」，普通 HTTPS 请求不带微信登录态会被网关直接拦掉。
   真正的鉴权由 `todo` 云函数内部完成（无有效 token 一律 401）。
5. 保存后等待状态变为「已生效」（约 1 分钟）。

### 6.2 默认域名的两种形态

绑定成功后控制台会在路径旁给出完整访问地址，默认域名有两种形态，**都可用**：

```
https://<env-id>.<region>.app.tcloudbase.com/<path>
https://<env-id>.service.tcloudbase.com/<path>
```

例如环境 ID 为 `quicktodo-1a2b3c-1300000000`、地域 `ap-shanghai`：

```
https://quicktodo-1a2b3c-1300000000.ap-shanghai.app.tcloudbase.com/todo
https://quicktodo-1a2b3c-1300000000.service.tcloudbase.com/todo
```

- 域名部分（协议 + 主机，不含 `/todo`）就是 **Mac 端设置页要填的 baseURL**：
  - 形态一 baseURL：`https://quicktodo-1a2b3c-1300000000.ap-shanghai.app.tcloudbase.com`
  - 形态二 baseURL：`https://quicktodo-1a2b3c-1300000000.service.tcloudbase.com`
- Mac 端会自动拼成 `<baseURL>/todo`、`<baseURL>/ai`、`<baseURL>/auth`，所以 **baseURL 结尾不要带 `/`**。
- 默认域名只支持 **HTTPS**，且**不能自定义端口**；用 IP 或 `http://` 会失败。
- 默认域名的 QPS 有限（免费额度），个人使用完全够；商用建议绑自定义域名 + CDN。

### 6.3 谁能走 HTTP 通道

| action | HTTP 通道 | 原因 |
|---|---|---|
| `todo` 全部 action | ✅ | 身份来自 `x-todo-token` |
| `ai.parse` | ✅ **必须带 `x-todo-token`** | 云函数会校验登录态（OPENID 或会话 token），否则 401 —— 防止云接入地址被陌生人刷 DeepSeek 额度 |
| `auth.createTicket` / `pollTicket` / `check` / `logout` | ✅ | Mac 登录流程本身 |
| `auth.confirmTicket` | ❌ **必须在小程序内 callFunction** | openid 只能由 `cloud.getWXContext().OPENID` 提供，HTTP 请求没有微信登录态，会返回 `unauthorized`（这是设计如此，防止伪造他人身份） |

> 即 Mac 端**所有** HTTP 请求（含 `/ai`）都要带 `x-todo-token`；小程序端走 `callFunction` 天然有 OPENID，无需额外处理。

---

## 7. 用 curl 逐个验证

先设置变量（按 §6.2 换成自己的域名）：

```bash
export BASE="https://quicktodo-1a2b3c-1300000000.service.tcloudbase.com"
export TOKEN=""   # 扫码登录后填 pollTicket 返回的 token（/ai 也要用）
```

> 本地联调可以不起云环境：`node ../tools/cloud-harness.js --serve 8787` 会把三个云函数跑在
> `http://127.0.0.1:8787`（`/todo`、`/ai`、`/auth`），启动日志里会直接给出可用的预置 token，
> 详见 `../tools/README.md`。

### 7.1 `todo` 的 ping（连通性 / 会话校验）

```bash
curl -s -X POST "$BASE/todo" \
  -H 'Content-Type: application/json' \
  -H "x-todo-token: $TOKEN" \
  -d '{"action":"ping"}'
```

预期（未登录时是 401，属正常）：

```json
{"ok":true,"openid":"oXXXXXXXXXXXXXXXXXXXX","count":12,"serverTime":1712345700123,"version":"v1"}
```

预检与未授权对照：

```bash
curl -s -i -X OPTIONS "$BASE/todo"          # 预期: HTTP/1.1 204 + Access-Control-Allow-Origin: *
curl -s -i -X POST "$BASE/todo" -H 'Content-Type: application/json' -d '{"action":"ping"}'
# 预期: HTTP/1.1 401  {"ok":false,"error":{"code":"unauthorized","message":"未登录或登录态无效"}}
```

### 7.2 `ai` 的 parse

```bash
curl -s -X POST "$BASE/ai" \
  -H 'Content-Type: application/json' \
  -H "x-todo-token: $TOKEN" \
  -d '{
        "action": "parse",
        "text": "明天下午三点前把季度报表发给张总 还要买牛奶",
        "source": "mac-screenshot",
        "now": 1712345678901,
        "timezone": "Asia/Shanghai",
        "maxItems": 8
      }'
```

预期（配了 key 就是 `deepseek`，没配/上游失败降级为 `rule`，**两种都是 200**）：

```json
{"ok":true,"engine":"deepseek","model":"deepseek-flash",
 "todos":[{"content":"把季度报表发给张总","deadline":1712386800000,"priority":"high"},
          {"content":"买牛奶","deadline":null,"priority":"normal"}],
 "elapsedMs":1832}
```

降级时：

```json
{"ok":true,"engine":"rule","model":"deepseek-flash","todos":[...],
 "elapsedMs":3,"notice":"未配置 DEEPSEEK_API_KEY，已使用本地规则解析","fallbackText":"明天下午三点前把季度报表发给张总 还要买牛奶"}
```

不带 token 时（**必须先登录**，否则 401）：

```json
{"ok":false,"error":{"code":"unauthorized","message":"未登录或登录态无效"}}
```

### 7.3 `auth` 的 createTicket（Mac 扫码登录第一步）

```bash
curl -s -X POST "$BASE/auth" \
  -H 'Content-Type: application/json' \
  -d '{"action":"createTicket","deviceName":"Kun 的 MacBook Pro"}'
```

预期：

```json
{"ok":true,
 "ticket":"3f2a9c1d4b6e8f0a1c2d3e4f5a6b7c8d",
 "qrPayload":"quicktodo://login?ticket=3f2a9c1d4b6e8f0a1c2d3e4f5a6b7c8d",
 "expiresIn":300,
 "expireAt":1712346000123}
```

把 `qrPayload` 编码成二维码给小程序扫；然后用同一个 ticket 轮询：

```bash
curl -s -X POST "$BASE/auth" -H 'Content-Type: application/json' \
  -d '{"action":"pollTicket","ticket":"3f2a9c1d4b6e8f0a1c2d3e4f5a6b7c8d"}'
# 未扫码:   {"ok":true,"status":"pending"}
# 已确认:   {"ok":true,"status":"confirmed","token":"<48位hex>","openid":"oXXXX"}
# 已过期:   {"ok":true,"status":"expired"}      —— Mac 应停止轮询并重新出码

curl -s -X POST "$BASE/auth" -H 'Content-Type: application/json' \
  -d '{"action":"check","token":"<48位hex>"}'
# 预期: {"ok":true,"openid":"oXXXX","expireAt":1714938000123}
```

### 7.4 一条完整的同步冒烟命令（推荐部署后照抄）

```bash
# 1) 写入
curl -s -X POST "$BASE/todo" -H 'Content-Type: application/json' -H "x-todo-token: $TOKEN" \
  -d '{"action":"upsert","item":{"id":"aaaaaaaa-1111-4111-8111-111111111111","content":"写季度报表",
       "deadline":null,"priority":"high","status":"todo","source":"mac-screenshot",
       "rawText":"OCR 原文","createTime":1712345678901,"updateTime":1712345678901}}'
# 预期: {"ok":true,"applied":[{"id":"aaaaaaaa-1111-4111-8111-111111111111","updateTime":<服务端此刻>}],"stale":[],"rejected":[],"serverTime":...}

# 2) 再用一个更旧的 updateTime 写同一条 → 必须判 stale（服务端不被旧数据覆盖）
curl -s -X POST "$BASE/todo" -H 'Content-Type: application/json' -H "x-todo-token: $TOKEN" \
  -d '{"action":"upsert","item":{"id":"aaaaaaaa-1111-4111-8111-111111111111","content":"旧内容","updateTime":1}}'
# 预期: applied 为空，stale 里回传服务端当前版本

# 3) 增量拉取
curl -s -X POST "$BASE/todo" -H 'Content-Type: application/json' -H "x-todo-token: $TOKEN" \
  -d '{"action":"list","since":0,"limit":100,"includeDeleted":true}'
# 预期: {"ok":true,"items":[...按 updateTime 升序...],"cursor":<max updateTime>,"hasMore":false,"serverTime":...}

# 4) 软删除
curl -s -X POST "$BASE/todo" -H 'Content-Type: application/json' -H "x-todo-token: $TOKEN" \
  -d '{"action":"remove","ids":["aaaaaaaa-1111-4111-8111-111111111111"]}'
# 预期: {"ok":true,"removed":["aaaaaaaa-1111-4111-8111-111111111111"],"serverTime":...}
# 再 list 一次仍能拉到这条，但 deleted=true（删除必须能同步给其他端）
```

---

## 8. 常见问题排查

### 8.1 HTTP 404 / 502

| 现象 | 原因 | 处理 |
|---|---|---|
| `404 Not Found`（HTML 或 `{"message":"Not Found"}`） | 触发路径没绑 / 路径写错（大小写敏感）/ 用的是没绑路径的域名 | 回 §6 检查 `/todo`、`/ai`、`/auth` 三个路径，确认状态「已生效」 |
| 域名形态 A 通的、形态 B 404 | 绑定生效有延迟或两个形态指向不同环境 | 等 1 分钟；确认环境 ID 与地域抄写正确 |
| 函数内部 `404`（JSON 里 `code:"not_found"`） | 业务 404，如 `confirmTicket` 的 ticket 不存在 | 属正常业务返回，不是部署问题 |
| `502` / 空响应 | 云函数执行超时或抛异常被平台中断 | 看 **云开发控制台 → 云函数 → 日志**；`ai` 记得调大超时（§2.3） |
| 上传后行为没变 | 忘了重新上传部署 | 重新「上传并部署：云端安装依赖」 |

### 8.2 401 未授权（`{"ok":false,"error":{"code":"unauthorized"}}`）

1. **没带 token**：HTTP 请求必须带 `-H "x-todo-token: <token>"`（header 名就是这个，大小写不敏感但拼写要对）。
   `/ai` 也一样需要 token（§6.3）。
2. **token 过期**：会话有效期 30 天，过期后重新走 §7.3 扫码登录。
3. **token 来自别的环境**：`auth_sessions` 只在当前环境的库里，切了环境要重新登录。
4. **在 HTTP 里调了 `confirmTicket`**：必然 401，改到小程序内 `wx.cloud.callFunction`（§6.3）。
5. 自查：`curl ... -d '{"action":"check","token":"..."}' $BASE/auth`，返回 `ok:true` 说明 token 有效，
   此时 `todo` 仍 401 就是 header 没带上。

### 8.3 上游超时 / 一直走规则降级

- 响应 `engine:"rule"` + `notice` 里已经写明原因，按原因处理：
  - `未配置 DEEPSEEK_API_KEY` → 回 §5 配环境变量（注意别配到别的函数上）。
  - `DeepSeek 请求超时（20000ms）` → 调大 `DEEPSEEK_TIMEOUT_MS`，同时把**云函数超时**调到更大（如 30s，见 §2.3）。
  - `DeepSeek 401/402` → key 无效或余额不足，去 DeepSeek 控制台确认。
  - `DeepSeek 响应不是合法 JSON` → 多半是 `DEEPSEEK_BASE_URL` 指向了自建网关，返回体不是 OpenAI 兼容格式。
- **降级是设计行为，不是故障**：没 key / 上游失败时仍返回 200 与 `engine:"rule"`，
  客户端能正常导入（预览可编辑），同时带上 `fallbackText` 供人工兜底。
- 云函数日志里搜 `[ai] 降级到规则解析` 可看到脱敏后的原因。

### 8.4 数据库权限不足 / 集合不存在

| 报错关键字 | 原因 | 处理 |
|---|---|---|
| `database collection not exists` / `-502005` | 集合没建 | 回 §3 建 `todos`/`auth_tickets`/`auth_sessions`（`counters` 可选） |
| `permission denied` / `-502003` | 集合权限过严且**不是**云函数访问（例如小程序端直连了数据库） | 客户端不要直连数据库；云函数是 admin，不受「仅创建者可读写」影响 |
| `db or table not exist` / 查询很慢 | 索引没建 | 回 §4 建 4 个索引 |
| `Cannot find module 'wx-server-sdk'` | 上传时没选云端安装依赖 | 重新「上传并部署：云端安装依赖」 |

### 8.5 其他

- **`rate_limited`**：`createTicket` 同一 `deviceName` 1 小时超过 30 次会拒绝，等待或换个设备名；这是防刷保护。
- **分页与 `hasMore`（严格递增 stamp）**：所有写入（`upsert`/`bulkUpsert`/`remove`/`clearDone`）的
  `updateTime` 都由服务端 `nextStamp()` 盖章（`max(当前毫秒, 上次值 + 1)`），**同一容器内每个文档严格递增且互不相同**。
  因此 `list` 的 `limit` 固定上限 100，`hasMore = items.length >= limit`，客户端用 `since = cursor` 循环必能拉空、不会死循环。
  闭区间语义下每轮会重发一条边界数据（`updateTime === since` 那条），客户端按 `id` + `updateTime` 去重即可。
  仅当出现「本页全部文档的 `updateTime` 都等于 `since`」（跨容器同毫秒的极端情况）时，
  服务端才会 warn 一行并保守返回 `hasMore:false`，宁可这轮少给也不让客户端空转。
- **`content_too_long`**：契约 §1.1/§2.4 规定 `content` 1–500 字；客户端负责先截断，
  服务端把超长条目计入 `rejected`（reason=`content_too_long`）而不是静默截断。
  `rawText` 上限 4000 字，超长由服务端**截断**（OCR/语音原文只用于溯源，截断无害）。
- **改了接口**：先改 `docs/SYNC-PROTOCOL.md` 并把版本号 +1，再改三端代码；`ping` 返回的 `version` 可用于确认线上版本。
- **本地先联调再上云**：`node ../tools/cloud-harness.js` 跑回归自检，
  `node ../tools/cloud-harness.js --serve 8787` 起本地云接入，Mac 端 baseURL 指向它即可（见 `../tools/README.md`）。
- **回滚**：云函数支持在控制台「版本管理」里回滚到上一个部署版本；数据库集合不做级联删除（软删除保证同步）。
