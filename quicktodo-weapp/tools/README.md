# tools/ —— 本地联调桩（cloud-harness）

`cloud-harness.js` 用**内存 Map 桩掉 `wx-server-sdk`**，让 `cloudfunctions/` 下的三个云函数
（`todo` / `ai` / `auth`）**源码零改动**地在本地跑起来。用途有两个：

1. **回归自检**：一条命令跑完 todo / auth / ai 的全部断言（含契约字段、LWW、分页、降级、鉴权）；
2. **Mac 客户端 ↔ 云函数 端到端联调**：起一个本地 HTTP 服务器，按**云接入（HTTP 访问服务）的 event 形状**
   投递给云函数，Mac 端的 `baseURL` 直接填 `http://127.0.0.1:<port>` 即可，不用等云端部署。

> 只拦截 `require('wx-server-sdk')` 与 `require('https')`；云函数代码里没有任何 mock 分支。

---

## 1. 快速开始

```bash
cd quicktodo-weapp

# ① 跑自检（不需要任何环境变量，不需要联网）
node tools/cloud-harness.js

# ② 起本地联调服务（Mac 端把 baseURL 指向它）
node tools/cloud-harness.js --serve 8787
```

自检输出示例（全部通过时退出码为 0，失败为非 0，可直接接 CI）：

```
==========================================
cloud-harness 自检全部通过: 103 passed, 0 failed
==========================================
```

## 2. `--serve` 模式的地址与调用示例

启动后会打印：

```
cloud-harness 已启动（内存库，数据不落盘）
  监听地址   : http://127.0.0.1:8787
  云函数路径 : http://127.0.0.1:8787/todo  http://127.0.0.1:8787/ai  http://127.0.0.1:8787/auth
  预置 token : 6cb8699b...70b26095   （已写入 auth_sessions，openid=oMAC）
  Mac 端 baseURL 就填: http://127.0.0.1:8787
```

- 路径映射与云接入一致：`/todo`→`todo` 函数、`/ai`→`ai`、`/auth`→`auth`；其他路径返回 404。
- 启动时**自动预置一个合法会话 token**（省去小程序扫码），把它填到 Mac 端设置页即可直接联调。
  用 `HARNESS_OPENID=oXXXX node tools/cloud-harness.js --serve 8787` 可改绑定的 openid。
- 端口传 `0` 表示随机可用端口（编程调用时用）。

```bash
TOKEN=<启动日志里的预置 token>

# 连通性 / 会话校验
curl -s -X POST http://127.0.0.1:8787/todo \
  -H 'Content-Type: application/json' -H "x-todo-token: $TOKEN" \
  -d '{"action":"ping"}'
# → {"ok":true,"openid":"oMAC","count":0,"serverTime":...,"version":"v1"}

# 写入 + 增量拉取
curl -s -X POST http://127.0.0.1:8787/todo -H 'Content-Type: application/json' -H "x-todo-token: $TOKEN" \
  -d '{"action":"upsert","item":{"id":"aaaaaaaa-1111-4111-8111-111111111111","content":"Mac 端联调任务","priority":"high"}}'
curl -s -X POST http://127.0.0.1:8787/todo -H 'Content-Type: application/json' -H "x-todo-token: $TOKEN" \
  -d '{"action":"list","since":0,"limit":100}'

# AI 解析（需要 token；未配 DEEPSEEK_API_KEY 时自动走 engine:"rule"）
curl -s -X POST http://127.0.0.1:8787/ai -H 'Content-Type: application/json' -H "x-todo-token: $TOKEN" \
  -d '{"action":"parse","text":"明天下午三点前把季度报表发给张总 还要买牛奶","timezone":"Asia/Shanghai","maxItems":8}'

# 扫码登录（本地桩上也可跑，ticket 会写进内存库）
curl -s -X POST http://127.0.0.1:8787/auth -H 'Content-Type: application/json' \
  -d '{"action":"createTicket","deviceName":"MacBook Pro"}'

# 预检 / 未授权 / 404
curl -s -i -X OPTIONS http://127.0.0.1:8787/todo | head -3      # 204 + CORS
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:8787/todo -d '{"action":"ping"}'   # 401
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:8787/nope -d '{}'                  # 404
```

**ai 是否真调 DeepSeek**：仍然由环境变量决定，与线上一致。

```bash
DEEPSEEK_API_KEY=sk-xxx node tools/cloud-harness.js --serve 8787   # 真调模型（engine:"deepseek"）
node tools/cloud-harness.js --serve 8787                           # 不配 key（engine:"rule"）
```

> 编程调用时若想**拦截**上游请求（不打真实网络），用 `h.mockUpstream({...})`，见 §3。

---

## 3. 编程接口

```js
const { createHarness, startServer } = require('./tools/cloud-harness');
const h = createHarness();
```

| 成员 | 说明 |
|---|---|
| `callFunction(name, event, openid?)` | 模拟小程序 `wx.cloud.callFunction`；`event` 即业务参数，身份来自 `getWXContext().OPENID`。传 `openid` 会临时切换登录态（传 `''` = 无登录态） |
| `httpRequest(path, headers, body?, method?)` | 模拟云接入请求，返回 `{statusCode, headers, body, json}`。执行期间 **OPENID 被置空**（真实 HTTP 通道不携带微信登录态） |
| `setOpenid(x)` / `getOpenid()` | 设置/读取 `getWXContext().OPENID` |
| `reset()` | 清空内存库 + 卸载云函数模块缓存（重置 `nextStamp` 等模块级状态）+ 关掉上游 mock |
| `seedSession(openid, {expired, ttlMs, token})` | 直接造一个合法 `auth_sessions` 会话，返回 token（省去扫码流程） |
| `seedTicket(openid, {status, expired, ticket})` | 直接造一张票据 |
| `mockUpstream({status, body, throwErr, enabled})` | 控制 DeepSeek 假响应；`{enabled:false}` 恢复真实 https。每次调用完整描述期望状态 |
| `lastUpstreamRequest()` | 取最近一次「云函数 → DeepSeek」请求 `{url, method, headers, body}`（断言用） |
| `setNow(ms)` / `now()` | 冻结 / 恢复 `Date.now()`，做时间相关断言 |
| `collections(name)` | 直接读某个集合的全部文档（断言用） |
| `store` / `db` | 原始内存表和数据库对象 |

例子：

```js
const h = createHarness();

// 小程序通道（OPENID）
let r = await h.callFunction('todo', { action: 'ping' }, 'oUSER1');
console.log(r); // { ok:true, openid:'oUSER1', count:0, ... }

// Mac 通道（HTTP + token）
const token = h.seedSession('oMAC');
const res = await h.httpRequest('/todo', { 'x-todo-token': token },
  { action: 'upsert', item: { id: 'aaaaaaaa-1111-4111-8111-111111111111', content: '写周报' } });
console.log(res.statusCode, res.json.applied);

// ai：拦截上游，验证「模型返回脏 JSON」时的容错
h.mockUpstream({ status: 200, body: JSON.stringify({ choices: [{ message: { content: '```json\n{"todos":[{"content":"买牛奶","deadline":null,"priority":"HIGH"}]}\n```' } }] }) });
process.env.DEEPSEEK_API_KEY = 'sk-test';
const ai = await h.httpRequest('/ai', { 'x-todo-token': token }, { action: 'parse', text: '买牛奶' });
console.log(ai.json.engine); // 'deepseek'

// 起本地服务（返回 http.Server，额外挂了 baseUrl / port）
const srv = await startServer(0);
console.log(srv.baseUrl);          // http://127.0.0.1:随机端口
await new Promise((r) => srv.close(r));
```

## 4. 怎么加用例

自检用例都写在 `cloud-harness.js` 的 `runSelfTest()` 里，用两个小工具：

```js
R.section('我的新功能');                       // 打印分组标题
R.ok('用例名（中文，会打印 PASS/FAIL）', 布尔条件, 失败时想看到的额外信息);
```

加完后 `node tools/cloud-harness.js`，失败会列出用例名并以退出码 1 结束。
约定：每个 section 先 `h.reset()`，用 `h.seedSession()` 造登录态，用 `h.collections('todos')` 直接查库断言。

## 5. 与真实云开发的差异（重要）

| 项目 | 桩行为 | 说明 |
|---|---|---|
| 数据持久化 | **纯内存，进程退出即丢** | 每次 `reset()` 或重启都会清空；不要当数据库用 |
| `doc(id).set()` | 整文档覆盖，文档 `_id` = `id` | 与云开发一致 |
| `doc(id).get()` 不存在 | **抛错**（`document.get:fail document not exists`） | 与 SDK 一致，云函数里都做了 try/catch |
| `where().get()` | 默认上限 100 条 | 与云开发单次上限一致，用于验证分页 |
| `orderBy` | 支持多字段、`asc`/`desc` | 与云开发一致（同值顺序不稳定，与线上同理） |
| `command` | `gte/gt/lte/lt/eq/neq/in/nin/exists/inc/set/remove/and/or` | 云函数只用到其中一部分 |
| 索引 / 权限 | 不模拟 | 索引缺失导致的慢查询、权限问题只能在真实环境验证 |
| `_openid` 自动注入 | 不模拟 | 三个云函数都用显式 `openid` 字段，不依赖 `_openid` |
| 并发 / 多容器 | 单进程模拟 | `nextStamp()` 的跨容器同毫秒极端情况无法在此复现 |
| https 请求 | 默认**透传真实模块** | 只有 `mockUpstream()` 后才返回假响应；`--serve` 下 ai 会真调 DeepSeek（若配了 key） |
| 云函数超时 | 不模拟 | 平台 3s/30s 超时只能在真实验证 |

## 6. 常见问题

- **`未知路径（只支持 /todo、/ai、/auth）`**：`httpRequest` 的第一个参数必须是 `/todo`、`/ai`、`/auth`
  （可以带查询串，如 `/todo?action=list&since=0`）。
- **HTTP 请求总是 401**：HTTP 通道没有 OPENID，必须带 `x-todo-token`（`h.seedSession()` 造一个）。
- **ai 一直返回 `engine:"rule"`**：没配 `DEEPSEEK_API_KEY`，或调用了 `mockUpstream()` 后忘了 `{enabled:false}`。
- **自检里出现 `[ai] 降级到规则解析：...` 日志**：这是**故意**打的降级日志（异常分支用例），不代表失败。
- **端口被占用**：换一个端口，或传 `0` 让系统分配（`startServer(0)`，地址看 `srv.baseUrl`）。
- **想让 Mac 端连真云端**：把 Mac 的 baseURL 换成云接入默认域名（见 `cloudfunctions/README.md` §6），
  本地桩只在开发期用。
