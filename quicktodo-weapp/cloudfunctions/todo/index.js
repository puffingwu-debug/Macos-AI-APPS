'use strict';
/**
 * 云函数 todo —— QuickTodo 待办 CRUD 与增量同步
 * 契约：docs/SYNC-PROTOCOL.md v1（§1 数据结构 / §2 接口 / §2.7 HTTP 通道映射）
 *
 * 设计要点：
 *  1. 双通道解包：小程序 wx.cloud.callFunction 直接拿 event 当 payload；
 *     HTTP 访问服务（云接入）下 event.body 是字符串需 JSON.parse，GET 走 queryStringParameters。
 *  2. 身份：优先 cloud.getWXContext().OPENID（小程序天然带登录态）；
 *     为空则用 x-todo-token / payload.token 去 auth_sessions 换 openid（Mac 端扫码登录）。
 *  3. LWW：updateTime 一律由服务端 Date.now() 盖章，冲突判定只看它。
 *  4. 删除一律软删除（deleted:true + 新 updateTime），否则其他端拉不到删除。
 *  本文件自包含，不 require 其他云函数目录。
 */

const cloud = require('wx-server-sdk');

cloud.init({ env: cloud.DYNAMIC_CURRENT_ENV });

const db = cloud.database();
const _ = db.command;

// ---------------------------------------------------------------------------
// 常量
// ---------------------------------------------------------------------------
const VERSION = 'v1';
const MAX_CONTENT = 500;   // 契约 §1：content 最长 500 字
const MAX_RAWTEXT = 4000;  // rawText 与 ai 的 text 上限对齐（契约未规定，取实现值）
const MAX_LIMIT = 100;     // 云开发单次 where().get() 默认/最大 100 条
const MAX_BULK = 200;      // 单次 bulkUpsert 最多处理条数
const MAX_IDS = 200;       // 单次 remove 最多处理 id 数
const MAX_CLEAR_PAGES = 20;

const ID_RE = /^[0-9a-fA-F-]{8,64}$/;          // 契约 §2.4 校验规则
const TOKEN_RE = /^[0-9a-fA-F]{16,128}$/;      // 会话 token（auth 生成 48 位 hex）

const PRIORITIES = ['high', 'normal', 'low'];
const STATUSES = ['todo', 'done'];
const SOURCES = ['mac-screenshot', 'mini-voice', 'manual'];

// 需要登录态的动作
const AUTH_ACTIONS = ['list', 'upsert', 'bulkUpsert', 'remove', 'clearDone', 'ping'];

// ---------------------------------------------------------------------------
// 服务端盖章时钟：严格单调递增（契约 §2.3 游标语义的前提）
// ---------------------------------------------------------------------------
// 云开发单次 where().get() 最多 100 条，而 list 的游标只带时间戳（updateTime）。
// 若同一毫秒写入超过 100 条，客户端用 cursor = max(updateTime) 再拉会原地打转（游标不前进）。
// 因此所有写入统一走 nextStamp()：取 max(当前毫秒, 上次值 + 1)，保证同一容器内
// 每个文档拿到**互不相同且严格递增**的 updateTime（一次 bulkUpsert 150 条 → 150 个递增值），
// 于是 since（gte 闭区间）+ 严格递增 = 分页必然前进，既不丢数据也不会死循环。
// 注意：跨容器并发仍可能撞到同一毫秒，极端情况由 handleList 的防御分支兜底。
let lastStamp = 0;

function nextStamp() {
  const t = Date.now();
  lastStamp = t > lastStamp ? t : lastStamp + 1;
  return lastStamp;
}

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, x-todo-token, Authorization',
  'Access-Control-Max-Age': '86400'
};

// 错误码 → HTTP statusCode（契约 §2.2 / §2.7）
const STATUS_BY_CODE = {
  unauthorized: 401,
  bad_request: 400,
  not_found: 404,
  rate_limited: 429,
  upstream_error: 502,
  internal: 500
};

// ---------------------------------------------------------------------------
// 通用工具
// ---------------------------------------------------------------------------
function fail(code, message) {
  return { ok: false, error: { code: code, message: String(message || '') } };
}

/** 统一 HTTP 出参：固定 Content-Type + CORS，body 为 JSON 字符串 */
function httpResponse(result) {
  const statusCode = result && result.ok
    ? 200
    : (STATUS_BY_CODE[(result.error && result.error.code) || 'internal'] || 500);
  return {
    statusCode: statusCode,
    headers: Object.assign({ 'Content-Type': 'application/json; charset=utf-8' }, CORS_HEADERS),
    body: JSON.stringify(result)
  };
}

/** OPTIONS 预检：204 + CORS 头，无 body */
function preflightResponse() {
  return {
    statusCode: 204,
    headers: Object.assign({ 'Content-Type': 'application/json; charset=utf-8' }, CORS_HEADERS),
    body: ''
  };
}

/** 是否来自 HTTP 访问服务（云接入）；callFunction 的事件没有这些字段 */
function isHttpEvent(evt) {
  return !!(evt.httpMethod || evt.requestContext || evt.queryStringParameters ||
    typeof evt.body === 'string');
}

function safeJsonParse(text) {
  try {
    const v = JSON.parse(text);
    return (v && typeof v === 'object') ? v : {};
  } catch (e) {
    return {};
  }
}

function toInt(v, dflt) {
  const n = typeof v === 'string' ? Number(v.trim()) : Number(v);
  return Number.isFinite(n) ? Math.floor(n) : dflt;
}

function clampInt(v, min, max, dflt) {
  const n = toInt(v, dflt);
  if (!Number.isFinite(n)) return dflt;
  return Math.min(max, Math.max(min, n));
}

function toBool(v, dflt) {
  if (v === undefined || v === null) return dflt;
  if (typeof v === 'boolean') return v;
  if (typeof v === 'number') return v !== 0;
  if (typeof v === 'string') {
    const s = v.trim().toLowerCase();
    if (s === 'false' || s === '0' || s === 'no' || s === '') return false;
    if (s === 'true' || s === '1' || s === 'yes') return true;
  }
  return dflt;
}

/** 时间戳：只接受有限正数（兼容数字字符串），否则返回 null */
function toTimestamp(v, dflt) {
  if (v === null || v === undefined || v === '') return dflt === undefined ? null : dflt;
  const n = typeof v === 'string' ? Number(v.trim()) : Number(v);
  if (!Number.isFinite(n) || n <= 0) return dflt === undefined ? null : dflt;
  return Math.floor(n);
}

/** 从 header 中取 token；HTTP 下 header key 大小写不固定，故遍历并小写化后匹配 */
function readTokenFromHeaders(evt) {
  const headers = (evt && evt.headers) || {};
  const keys = Object.keys(headers);
  for (let i = 0; i < keys.length; i++) {
    const lower = String(keys[i]).toLowerCase();
    if (lower !== 'x-todo-token' && lower !== 'x-auth-token' && lower !== 'authorization') continue;
    let raw = String(headers[keys[i]] === undefined ? '' : headers[keys[i]]).trim();
    if (lower === 'authorization') raw = raw.replace(/^Bearer\s+/i, '').trim();
    if (TOKEN_RE.test(raw)) return raw;
  }
  return '';
}

function readToken(evt, payload) {
  // 契约 §2.1：请求头 x-todo-token 优先于 payload.token（两者都接受）
  const fromHeader = readTokenFromHeaders(evt);
  if (fromHeader) return fromHeader;
  const fromPayload = payload && typeof payload.token === 'string' ? payload.token.trim() : '';
  if (TOKEN_RE.test(fromPayload)) return fromPayload;
  const q = (evt && evt.queryStringParameters) || {};
  const fromQuery = typeof q.token === 'string' ? q.token.trim() : '';
  return TOKEN_RE.test(fromQuery) ? fromQuery : '';
}

/**
 * 双通道解包：把 callFunction 的 event 与 HTTP 的 body/query 统一成 payload
 * GET 用 queryStringParameters；POST 用 body（字符串需 JSON.parse，兼容已是对象的情况）
 */
function unwrapEvent(event) {
  const evt = (event && typeof event === 'object') ? event : {};
  const http = isHttpEvent(evt);
  const method = String(evt.httpMethod || '').toUpperCase();
  if (!http) return { payload: evt, isHttp: false, httpMethod: '' };

  const query = (evt.queryStringParameters && typeof evt.queryStringParameters === 'object')
    ? evt.queryStringParameters : {};

  let body = null;
  if (method === 'GET' || method === 'HEAD') {
    body = {};
  } else if (typeof evt.body === 'string') {
    let text = evt.body;
    // 云接入在二进制/特殊场景会 base64 编码 body
    if (evt.isBase64Encoded) {
      try { text = Buffer.from(text, 'base64').toString('utf8'); } catch (e) { text = ''; }
    }
    body = text && text.trim() ? safeJsonParse(text) : {};
  } else if (evt.body && typeof evt.body === 'object') {
    body = evt.body;
  } else {
    // 没带 body 的 POST（例如只靠 query 传参）也允许
    body = {};
  }
  // query 作为兜底默认值，body 优先
  const payload = Object.assign({}, query, body);
  return { payload: payload, isHttp: true, httpMethod: method };
}

/**
 * 身份解析：OPENID 优先，其次 auth_sessions 里的 token
 * 命中 token 时顺手刷新 lastSeen（失败不影响主流程）
 */
async function resolveIdentity(evt, payload) {
  let openid = '';
  try {
    const ctx = cloud.getWXContext() || {};
    openid = ctx.OPENID || '';
  } catch (e) {
    openid = '';
  }
  if (openid) return { openid: openid, via: 'wx' };

  const token = readToken(evt, payload);
  if (!token) return { openid: '', via: '', reason: 'no_token' };

  let session = null;
  try {
    const res = await db.collection('auth_sessions').doc(token).get();
    session = res && res.data;
  } catch (e) {
    session = null; // doc 不存在时 SDK 会抛错，这里统一当成无效 token
  }
  if (!session || !session.openid) return { openid: '', via: '', reason: 'invalid_token' };
  if (!(Number(session.expireAt) > Date.now())) return { openid: '', via: '', reason: 'expired_token' };

  db.collection('auth_sessions').doc(token)
    .update({ data: { lastSeen: Date.now() } })
    .catch(function () { /* lastSeen 只是活跃度统计，失败忽略 */ });

  return { openid: session.openid, via: 'token' };
}

/**
 * 文档 → 契约 §1 的 Todo 结构（字段名与 §1 逐条对齐；缺字段补默认值，杜绝脏值下发给客户端）
 * 注：openid 按 §1 原样回传（同一个人本来就通过 auth.check/pollTicket 拿到自己的 openid，
 * 不存在额外泄露）；若团队想彻底不下发，删掉下面这一行即可。
 */
function toClientTodo(doc) {
  if (!doc || typeof doc !== 'object') return null;
  return {
    _id: doc._id || doc.id,
    id: doc.id || doc._id,
    openid: typeof doc.openid === 'string' ? doc.openid : '',
    content: typeof doc.content === 'string' ? doc.content : '',
    deadline: toTimestamp(doc.deadline, null),
    priority: PRIORITIES.indexOf(doc.priority) >= 0 ? doc.priority : 'normal',
    status: STATUSES.indexOf(doc.status) >= 0 ? doc.status : 'todo',
    source: SOURCES.indexOf(doc.source) >= 0 ? doc.source : 'manual',
    rawText: typeof doc.rawText === 'string' ? doc.rawText : '',
    deleted: doc.deleted === true,
    createTime: toTimestamp(doc.createTime, 0) || 0,
    updateTime: toTimestamp(doc.updateTime, 0) || 0,
    seq: Number.isFinite(Number(doc.seq)) ? Number(doc.seq) : 0
  };
}

/**
 * seq：服务端自增同步序号（契约 §1 / counters 集合，仅供调试展示，客户端不依赖）
 * 用 counters/todos_seq 原子自增；集合不存在等异常一律退化为 Date.now()，绝不阻断写入。
 */
async function nextSeq() {
  try {
    const r = await db.collection('counters').doc('todos_seq').update({ data: { value: _.inc(1) } });
    if (r && r.stats && r.stats.updated > 0) {
      const doc = await db.collection('counters').doc('todos_seq').get();
      const v = doc && doc.data && Number(doc.data.value);
      if (Number.isFinite(v)) return v;
    } else {
      await db.collection('counters').doc('todos_seq').set({ data: { value: 1, createTime: Date.now() } });
      return 1;
    }
  } catch (e) {
    // counters 集合可能未创建（契约里它是可选的）
  }
  return Date.now();
}

/** 取单条待办；不存在返回 null（SDK 对不存在的 doc 会抛错） */
async function getTodo(id) {
  try {
    const res = await db.collection('todos').doc(id).get();
    return (res && res.data) || null;
  } catch (e) {
    return null;
  }
}

// ---------------------------------------------------------------------------
// 入参校验：把客户端传来的任意对象规整成合法 Todo（不可信输入）
// 返回 { ok:true, value } 或 { ok:false, id, reason }
// ---------------------------------------------------------------------------
function normalizeIncomingItem(raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
    return { ok: false, id: '', reason: 'invalid_item' };
  }
  const id = typeof raw.id === 'string' ? raw.id.trim()
    : (typeof raw._id === 'string' ? raw._id.trim() : '');
  if (!ID_RE.test(id)) return { ok: false, id: id.slice(0, 64), reason: 'invalid_id' };

  let content = typeof raw.content === 'string' ? raw.content.trim() : '';
  if (!content) return { ok: false, id: id, reason: 'empty_content' };
  // 契约 §2.4：content 去空格后非空且 ≤500 字，超长视为非法条目（不静默截断用户内容）
  if (content.length > MAX_CONTENT) return { ok: false, id: id, reason: 'content_too_long' };

  const deadline = toTimestamp(raw.deadline, null);
  const priority = PRIORITIES.indexOf(raw.priority) >= 0 ? raw.priority : 'normal';
  const status = STATUSES.indexOf(raw.status) >= 0 ? raw.status : 'todo';
  const source = SOURCES.indexOf(raw.source) >= 0 ? raw.source : 'manual';
  const rawText = typeof raw.rawText === 'string' ? raw.rawText.slice(0, MAX_RAWTEXT) : '';
  const createTime = toTimestamp(raw.createTime, null);
  // 入参 updateTime 只用于 LWW 比较；缺失视为 0（现存文档一定 >= 0 → 判 stale，服务端不被旧数据覆盖）
  const incomingUpdateTime = toTimestamp(raw.updateTime, 0) || 0;

  return {
    ok: true,
    value: {
      id: id,
      content: content,
      deadline: deadline,
      priority: priority,
      status: status,
      source: source,
      rawText: rawText,
      deleted: raw.deleted === true, // 只认严格 true，避免 "false"/"0" 之类脏值
      createTime: createTime,
      incomingUpdateTime: incomingUpdateTime
    }
  };
}

/**
 * 单条 upsert（LWW）
 * 返回 { kind:'applied', item } | { kind:'stale', item } | { kind:'rejected', entry }
 */
async function upsertOne(openid, raw) {
  const norm = normalizeIncomingItem(raw);
  if (!norm.ok) return { kind: 'rejected', entry: { id: norm.id, reason: norm.reason } };
  const v = norm.value;

  const existing = await getTodo(v.id);

  // 归属校验：同 id 已被别的用户占用（UUID 碰撞或恶意构造）→ 拒绝，绝不跨用户覆盖
  if (existing && existing.openid && existing.openid !== openid) {
    return { kind: 'rejected', entry: { id: v.id, reason: 'not_owner' } };
  }

  if (existing) {
    const serverUpdateTime = Number(existing.updateTime) || 0;
    // LWW：现存 updateTime >= 入参 updateTime 判 stale，不覆盖，把服务端当前值回给客户端
    if (serverUpdateTime >= v.incomingUpdateTime) {
      return { kind: 'stale', item: toClientTodo(existing) };
    }
  }

  const now = nextStamp(); // 服务端盖章：严格单调递增，保证游标一定能前进
  const seq = await nextSeq();
  // set() 是整文档覆盖：必须显式带上 openid / createTime，否则会把归属和创建时间抹掉
  const doc = {
    id: v.id,
    openid: openid,
    content: v.content,
    deadline: v.deadline,
    priority: v.priority,
    status: v.status,
    source: v.source,
    rawText: v.rawText,
    deleted: v.deleted,
    createTime: v.createTime || (existing && Number(existing.createTime)) || now,
    updateTime: now, // 服务端盖章，客户端传值一律作废
    seq: seq
  };
  // doc(id).set()：文档 _id 即业务 id，保证跨端一致（契约 §1）
  await db.collection('todos').doc(v.id).set({ data: doc });

  return { kind: 'applied', item: { id: v.id, updateTime: now } };
}

// ---------------------------------------------------------------------------
// actions
// ---------------------------------------------------------------------------
/** §2.6 ping：连通性与会话校验（Mac 设置页「测试连接」） */
async function handlePing(openid) {
  let count = 0;
  try {
    const res = await db.collection('todos').where({ openid: openid, deleted: _.neq(true) }).count();
    count = (res && Number(res.total)) || 0;
  } catch (e) {
    count = 0; // 集合刚创建/索引未建时 count 失败不应影响连通性判定
  }
  return { ok: true, openid: openid, count: count, serverTime: Date.now(), version: VERSION };
}

/** §2.3 list：增量拉取，updateTime >= since 闭区间，升序 */
async function handleList(openid, payload) {
  const since = clampInt(payload.since, 0, Number.MAX_SAFE_INTEGER, 0);
  const limit = clampInt(payload.limit, 1, MAX_LIMIT, MAX_LIMIT);
  const includeDeleted = toBool(payload.includeDeleted, true); // 默认 true：删除也要同步给其他端

  const cond = { openid: openid, updateTime: _.gte(since) };
  if (!includeDeleted) cond.deleted = _.neq(true);

  // 只取一页（limit 已被 clamp 到 100，正好是云开发单次 where().get() 的上限）
  const res = await db.collection('todos')
    .where(cond)
    .orderBy('updateTime', 'asc')
    .limit(limit)
    .get();

  const raw = Array.isArray(res && res.data) ? res.data : [];

  const items = [];
  for (let i = 0; i < raw.length; i++) {
    const it = toClientTodo(raw[i]);
    if (it) items.push(it);
  }

  // cursor = 本次 items 的 max(updateTime)；空结果原样回传 since
  let cursor = since;
  for (let i = 0; i < items.length; i++) {
    if (items[i].updateTime > cursor) cursor = items[i].updateTime;
  }

  // 满页 → 还有更多。因为所有写入都用 nextStamp() 严格递增，
  // 下一轮 since = cursor 一定能拿到新数据（游标必然前进），客户端不会原地打转。
  let hasMore = items.length >= limit;

  // 防御分支：本页所有文档的 updateTime 都等于 since（游标无法前进），
  // 只可能出现在跨容器同毫秒写入的极端情况 → 宁可这轮少给也不能让客户端空转。
  if (hasMore && cursor === since) {
    console.warn('[todo] list 游标无法前进，保守返回 hasMore=false since=' + since + ' items=' + items.length);
    hasMore = false;
  }

  return { ok: true, items: items, cursor: cursor, hasMore: hasMore, serverTime: Date.now() };
}

/** §2.4 upsert：单条写入 */
async function handleUpsert(openid, payload) {
  const raw = payload.item !== undefined ? payload.item : payload.data;
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
    return fail('bad_request', 'item 必须是一个对象');
  }
  const r = await upsertOne(openid, raw);
  const out = {
    ok: true,
    applied: r.kind === 'applied' ? [r.item] : [],
    stale: r.kind === 'stale' ? [r.item] : [],
    rejected: r.kind === 'rejected' ? [r.entry] : [],
    serverTime: Date.now()
  };
  return out;
}

/** §2.4 bulkUpsert：批量写入（离线补同步 / AI 批量导入） */
async function handleBulkUpsert(openid, payload) {
  let list = payload.items;
  if (!Array.isArray(list)) {
    // 兼容单条对象
    if (list && typeof list === 'object') list = [list];
    else return fail('bad_request', 'items 必须是数组');
  }
  if (list.length > MAX_BULK) return fail('bad_request', '单次最多 ' + MAX_BULK + ' 条');

  const applied = [];
  const stale = [];
  const rejected = [];

  // 串行处理：保证同一次请求内对同一 id 的处理顺序确定，也避免瞬时写放大
  for (let i = 0; i < list.length; i++) {
    try {
      const r = await upsertOne(openid, list[i]);
      if (r.kind === 'applied') applied.push(r.item);
      else if (r.kind === 'stale') stale.push(r.item);
      else rejected.push(r.entry);
    } catch (e) {
      // 单条失败不影响其他条目
      const id = list[i] && typeof list[i].id === 'string' ? list[i].id.slice(0, 64) : '';
      rejected.push({ id: id, reason: 'write_failed' });
    }
  }

  return {
    ok: true,
    applied: applied,
    stale: stale,
    rejected: rejected,
    serverTime: Date.now()
  };
}

function normalizeIdList(v) {
  if (!Array.isArray(v)) return [];
  const out = [];
  for (let i = 0; i < v.length && out.length < MAX_IDS; i++) {
    const id = typeof v[i] === 'string' ? v[i].trim() : '';
    if (ID_RE.test(id) && out.indexOf(id) < 0) out.push(id);
  }
  return out;
}

/** §2.5 remove：软删除。删除也必须有新 updateTime，才能增量下发到所有端 */
async function handleRemove(openid, payload) {
  let ids = normalizeIdList(payload.ids);
  if (!ids.length) ids = normalizeIdList(payload.id ? [payload.id] : []);
  if (!ids.length) return fail('bad_request', 'ids 不能为空或格式非法');

  const removed = [];

  const worker = async function (id) {
    const existing = await getTodo(id);
    if (!existing) {
      // 服务端本来就没有这条：目标状态已达成，算删除成功（幂等，避免客户端 outbox 反复重试）
      removed.push(id);
      return;
    }
    if (existing.openid && existing.openid !== openid) return; // 非本人数据，静默跳过
    if (existing.deleted === true) { removed.push(id); return; }
    // 每条各自盖章（不共用同一个时间戳）：保证同一次批量删除里每个文档的
    // updateTime 也严格递增，否则删除超过 100 条时游标同样会卡住。
    await db.collection('todos').doc(id).update({ data: { deleted: true, updateTime: nextStamp() } });
    removed.push(id);
  };

  // 分批并发，避免一次打太多请求
  for (let i = 0; i < ids.length; i += 10) {
    const chunk = ids.slice(i, i + 10);
    await Promise.all(chunk.map(function (id) {
      return worker(id).catch(function () { /* 单条失败不影响其他 */ });
    }));
  }

  removed.sort();
  return { ok: true, removed: removed, serverTime: Date.now() };
}

/** §2.5.1 clearDone：把该用户所有 status==='done' 的待办软删除（给外部脚本/调试用的便捷入口） */
async function handleClearDone(openid, payload) {
  const removed = [];
  for (let page = 0; page < MAX_CLEAR_PAGES; page++) {
    const res = await db.collection('todos')
      .where({ openid: openid, status: 'done', deleted: _.neq(true) })
      .orderBy('updateTime', 'asc')
      .limit(MAX_LIMIT)
      .get();
    const rows = Array.isArray(res && res.data) ? res.data : [];
    if (!rows.length) break;

    await Promise.all(rows.map(function (row) {
      const id = row._id || row.id;
      // 每条各自 nextStamp()：同一次 clearDone 内也保持 updateTime 严格递增
      return db.collection('todos').doc(id)
        .update({ data: { deleted: true, updateTime: nextStamp() } })
        .catch(function () { return null; });
    }));
    for (let i = 0; i < rows.length; i++) removed.push(rows[i]._id || rows[i].id);

    if (rows.length < MAX_LIMIT) break; // 已拉完
  }
  return { ok: true, removed: removed, serverTime: Date.now() };
}

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------
exports.main = async (event, context) => {
  const evt = (event && typeof event === 'object') ? event : {};
  const httpMethod = String(evt.httpMethod || '').toUpperCase();

  // 预检请求：直接 204 + CORS（契约 §2.7）
  if (httpMethod === 'OPTIONS') return preflightResponse();

  const unwrapped = unwrapEvent(evt);
  const payload = unwrapped.payload;
  const action = typeof payload.action === 'string' ? payload.action.trim() : '';

  let result;
  try {
    if (AUTH_ACTIONS.indexOf(action) < 0) {
      result = fail('bad_request', action ? ('不支持的 action：' + action) : '缺少 action');
    } else {
      const ident = await resolveIdentity(evt, payload);
      if (!ident.openid) {
        result = fail('unauthorized', ident.reason === 'expired_token' ? '登录态已失效' : '未登录或登录态无效');
      } else if (action === 'ping') {
        result = await handlePing(ident.openid);
      } else if (action === 'list') {
        result = await handleList(ident.openid, payload);
      } else if (action === 'upsert') {
        result = await handleUpsert(ident.openid, payload);
      } else if (action === 'bulkUpsert') {
        result = await handleBulkUpsert(ident.openid, payload);
      } else if (action === 'remove') {
        result = await handleRemove(ident.openid, payload);
      } else if (action === 'clearDone') {
        result = await handleClearDone(ident.openid, payload);
      } else {
        result = fail('bad_request', '不支持的 action：' + action);
      }
    }
  } catch (err) {
    // 任何异常都要变成协议里的错误结构，绝不抛给调用方
    console.error('[todo] action 执行失败 action=' + action, err && (err.stack || err.message || err));
    result = fail('internal', '服务内部错误');
  }

  if (unwrapped.isHttp) return httpResponse(result);
  return result;
};
