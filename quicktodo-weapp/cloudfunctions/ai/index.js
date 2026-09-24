'use strict';
/**
 * 云函数 ai —— DeepSeek 结构化待办解析（契约 §3）
 *
 * 行为约定：
 *  - `action === 'parse'`：把一段自由文本解析成 [{content, deadline, priority}]
 *  - **必须先有登录态**（决策 4 / 契约 §6「云函数校验登录态后才操作数据」）：
 *    OPENID 优先，其次 HTTP 头 `x-todo-token` / `payload.token` 查 auth_sessions 且未过期；
 *    拿不到身份 → HTTP 401，callFunction 返回 {ok:false,error:{code:'unauthorized'}}。
 *    校验的是**身份存在性**，不做按用户配额（同一 token 可正常解析）。
 *  - 有 DEEPSEEK_API_KEY → 调 `${DEEPSEEK_BASE_URL}/chat/completions`（默认 https://api.deepseek.com），
 *    成功返回 engine:'deepseek'；
 *  - 无 key / 超时 / 非 200 / 上游 JSON 非法 / 模型没给出有效待办 → **一律降级**到
 *    parser.js 规则解析，返回 engine:'rule' + notice + fallbackText，绝不整体失败；
 *  - 只有入参错误（text 为空）才返回 {ok:false, error:{code:'bad_request'}}。
 *  - key 只从环境变量读，绝不写入代码、响应或日志（日志里的 message 也会做脱敏）。
 */

const cloud = require('wx-server-sdk');
const https = require('https');
const http = require('http');
const { URL } = require('url');

const promptLib = require('./prompt');
const parserLib = require('./parser');

cloud.init({ env: cloud.DYNAMIC_CURRENT_ENV });

const db = cloud.database();

// ---------------------------------------------------------------------------
// 常量 / 配置
// ---------------------------------------------------------------------------
const MAX_TEXT = 4000;              // 契约实现值：入参上限
const MAX_RESP_BYTES = 1024 * 1024; // 上游响应体上限 1MB（防异常大包打爆内存）
const DEFAULT_TIMEOUT_MS = 20000;
const MIN_TIMEOUT_MS = 1000;
const MAX_TIMEOUT_MS = 60000;
const DEFAULT_BASE_URL = 'https://api.deepseek.com';
const DEFAULT_MODEL = 'deepseek-flash';
const TOKEN_RE = /^[0-9a-fA-F]{16,128}$/;      // 会话 token（auth 生成 48 位 hex）

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, x-todo-token, Authorization',
  'Access-Control-Max-Age': '86400'
};

const STATUS_BY_CODE = {
  unauthorized: 401,
  bad_request: 400,
  not_found: 404,
  rate_limited: 429,
  upstream_error: 502,
  internal: 500
};

// ---------------------------------------------------------------------------
// 通道解包 / 响应（与 todo 云函数同款精简实现，保持各函数自包含）
// ---------------------------------------------------------------------------
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

function unwrapEvent(event) {
  const evt = (event && typeof event === 'object') ? event : {};
  if (!isHttpEvent(evt)) return { payload: evt, isHttp: false };
  const method = String(evt.httpMethod || '').toUpperCase();
  const query = (evt.queryStringParameters && typeof evt.queryStringParameters === 'object')
    ? evt.queryStringParameters : {};

  let body = {};
  if (method === 'GET' || method === 'HEAD') {
    body = {};
  } else if (typeof evt.body === 'string') {
    let text = evt.body;
    if (evt.isBase64Encoded) {
      try { text = Buffer.from(text, 'base64').toString('utf8'); } catch (e) { text = ''; }
    }
    body = text && text.trim() ? safeJsonParse(text) : {};
  } else if (evt.body && typeof evt.body === 'object') {
    body = evt.body;
  }
  return { payload: Object.assign({}, query, body), isHttp: true };
}

function fail(code, message, extra) {
  const out = { ok: false, error: { code: code, message: String(message || '') } };
  if (extra && typeof extra === 'object') {
    const keys = Object.keys(extra);
    for (let i = 0; i < keys.length; i++) out[keys[i]] = extra[keys[i]];
  }
  return out;
}

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

function preflightResponse() {
  return {
    statusCode: 204,
    headers: Object.assign({ 'Content-Type': 'application/json; charset=utf-8' }, CORS_HEADERS),
    body: ''
  };
}

// ---------------------------------------------------------------------------
// 工具
// ---------------------------------------------------------------------------
/** 日志/响应脱敏：万一上游把 key 回显，也不让它出现在 message 里 */
function sanitizeMessage(msg) {
  return String(msg === undefined || msg === null ? '' : msg)
    .replace(/sk-[A-Za-z0-9_\-]{4,}/g, 'sk-***')
    .replace(/Bearer\s+[A-Za-z0-9_\-.]{8,}/gi, 'Bearer ***')
    .slice(0, 300);
}

// ---------------------------------------------------------------------------
// 身份解析（决策 4：ai 也必须校验登录态，避免云接入地址被陌生人刷 DeepSeek 额度）
// 与 todo 云函数同一套规则：OPENID 优先 → x-todo-token / payload.token → auth_sessions
// ---------------------------------------------------------------------------
/** HTTP 下 header key 大小写不固定，遍历并小写化后匹配 */
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
  const fromHeader = readTokenFromHeaders(evt);
  if (fromHeader) return fromHeader;
  const fromPayload = payload && typeof payload.token === 'string' ? payload.token.trim() : '';
  if (TOKEN_RE.test(fromPayload)) return fromPayload;
  const q = (evt && evt.queryStringParameters) || {};
  const fromQuery = typeof q.token === 'string' ? q.token.trim() : '';
  return TOKEN_RE.test(fromQuery) ? fromQuery : '';
}

/**
 * 返回 { openid, via } 或 { openid:'', reason }
 * 命中 token 时顺手刷新 lastSeen（失败忽略）
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
    session = null; // doc 不存在时 SDK 抛错，统一当成无效 token
  }
  if (!session || !session.openid) return { openid: '', via: '', reason: 'invalid_token' };
  if (!(Number(session.expireAt) > Date.now())) return { openid: '', via: '', reason: 'expired_token' };

  db.collection('auth_sessions').doc(token)
    .update({ data: { lastSeen: Date.now() } })
    .catch(function () { /* lastSeen 只是活跃度统计，失败忽略 */ });

  return { openid: session.openid, via: 'token' };
}

function clampNumber(v, min, max, dflt) {
  const n = Number(v);
  if (!Number.isFinite(n)) return dflt;
  return Math.min(max, Math.max(min, Math.floor(n)));
}

function pickString(obj, keys) {
  for (let i = 0; i < keys.length; i++) {
    const v = obj[keys[i]];
    if (typeof v === 'string' && v.trim()) return v;
    if (typeof v === 'number' && Number.isFinite(v)) return String(v);
  }
  return '';
}

/** Promise 化的 JSON POST：Node 内置 http/https，超时用 AbortController + destroy 双保险 */
function postJson(urlStr, bodyObj, options) {
  const opt = options || {};
  return new Promise(function (resolve, reject) {
    let url;
    try {
      url = new URL(urlStr);
    } catch (e) {
      reject(new Error('base_url 非法'));
      return;
    }
    if (url.protocol !== 'https:' && url.protocol !== 'http:') {
      reject(new Error('仅支持 http/https'));
      return;
    }
    const lib = url.protocol === 'https:' ? https : http;
    const payload = Buffer.from(JSON.stringify(bodyObj), 'utf8');
    const headers = Object.assign({
      'Content-Type': 'application/json; charset=utf-8',
      'Content-Length': payload.length,
      'Accept': 'application/json'
    }, opt.headers || {});

    const controller = (typeof AbortController === 'function') ? new AbortController() : null;
    let settled = false;
    let timer = null;
    const timeoutMs = clampNumber(opt.timeoutMs, MIN_TIMEOUT_MS, MAX_TIMEOUT_MS, DEFAULT_TIMEOUT_MS);

    const req = lib.request({
      protocol: url.protocol,
      hostname: url.hostname,
      port: url.port || (url.protocol === 'https:' ? 443 : 80),
      path: url.pathname + url.search,
      method: 'POST',
      headers: headers,
      timeout: timeoutMs,
      signal: controller ? controller.signal : undefined // Node 16+ 支持
    }, function (res) {
      const chunks = [];
      let size = 0;
      res.on('data', function (chunk) {
        size += chunk.length;
        if (size > MAX_RESP_BYTES) {
          req.destroy(new Error('上游响应过大'));
          return;
        }
        chunks.push(chunk);
      });
      res.on('end', function () {
        if (timer) clearTimeout(timer);
        if (settled) return;
        settled = true;
        resolve({
          statusCode: res.statusCode || 0,
          text: Buffer.concat(chunks).toString('utf8')
        });
      });
      res.on('error', function (err) {
        if (timer) clearTimeout(timer);
        if (settled) return;
        settled = true;
        reject(err);
      });
    });

    req.on('timeout', function () {
      req.destroy(new Error('请求超时'));
    });
    req.on('error', function (err) {
      if (timer) clearTimeout(timer);
      if (settled) return;
      settled = true;
      reject(err);
    });

    timer = setTimeout(function () {
      try { if (controller) controller.abort(); } catch (e) { /* ignore */ }
      req.destroy(new Error('请求超时'));
    }, timeoutMs);

    req.write(payload);
    req.end();
  });
}

// ---------------------------------------------------------------------------
// 模型返回的容错解析
// ---------------------------------------------------------------------------
/** 去 ```json 包裹 → 直接 JSON.parse → 截取第一个 { 到最后一个 } → 退一步取数组 */
function extractJsonObject(text) {
  if (typeof text !== 'string' || !text.trim()) return null;
  let s = text.trim();
  s = s.replace(/^\uFEFF/, '');
  s = s.replace(/^```(?:json|JSON)?\s*/, '').replace(/```\s*$/, '').trim();
  try {
    const v = JSON.parse(s);
    if (v && typeof v === 'object') return v;
  } catch (e) { /* 继续容错 */ }

  const start = s.indexOf('{');
  const end = s.lastIndexOf('}');
  if (start >= 0 && end > start) {
    try {
      const v = JSON.parse(s.slice(start, end + 1));
      if (v && typeof v === 'object') return v;
    } catch (e) { /* 继续容错 */ }
  }

  const as = s.indexOf('[');
  const ae = s.lastIndexOf(']');
  if (as >= 0 && ae > as) {
    try {
      const arr = JSON.parse(s.slice(as, ae + 1));
      if (Array.isArray(arr)) return { todos: arr };
    } catch (e) { /* 放弃 */ }
  }
  return null;
}

/** deadline 支持 数字（秒/毫秒）、ISO 字符串、null；非法一律 null */
function normalizeDeadlineValue(v) {
  if (v === null || v === undefined || v === '') return null;
  if (typeof v === 'number' && Number.isFinite(v)) {
    if (v <= 0) return null;
    // 10 位秒级时间戳（< 1e11）自动升为毫秒
    return v < 1e11 ? Math.floor(v * 1000) : Math.floor(v);
  }
  if (typeof v === 'string') {
    const s = v.trim();
    if (!s) return null;
    if (/^\d+$/.test(s)) return normalizeDeadlineValue(Number(s));
    const t = Date.parse(s); // ISO / "2024-05-01 15:00" 等
    if (Number.isFinite(t) && t > 0) return Math.floor(t);
    return null; // 「明天」这类纯中文时间词交给 deadline=null，不猜
  }
  return null;
}

const PRIORITY_ALIAS = {
  high: 'high', normal: 'normal', low: 'low',
  urgent: 'high', important: 'high', medium: 'normal', mid: 'normal',
  '高': 'high', '中': 'normal', '低': 'low',
  '紧急': 'high', '普通': 'normal', '一般': 'normal'
};

function normalizePriorityValue(v) {
  if (typeof v !== 'string') return 'normal';
  const k = v.trim().toLowerCase();
  return PRIORITY_ALIAS[k] || PRIORITY_ALIAS[v.trim()] || 'normal'; // 非法值回退 normal
}

/** 把模型输出规整成契约 §3.2 的 todos；content 为空则丢弃该条 */
function normalizeModelTodos(parsed, maxItems) {
  let list = null;
  if (Array.isArray(parsed)) {
    list = parsed;
  } else if (parsed && typeof parsed === 'object') {
    const keys = ['todos', 'items', 'tasks', 'list', 'data', 'result'];
    for (let i = 0; i < keys.length; i++) {
      if (Array.isArray(parsed[keys[i]])) { list = parsed[keys[i]]; break; }
    }
  }
  if (!list) return [];

  const out = [];
  for (let i = 0; i < list.length && out.length < maxItems; i++) {
    const raw = list[i];
    if (raw === null || raw === undefined) continue;

    let content = '';
    let deadlineRaw = null;
    let priorityRaw = '';
    if (typeof raw === 'string') {
      content = raw;
    } else if (typeof raw === 'object') {
      content = pickString(raw, ['content', 'text', 'title', 'task', 'name', 'description', 'desc']);
      if (raw.deadline !== undefined) deadlineRaw = raw.deadline;
      else if (raw.dueDate !== undefined) deadlineRaw = raw.dueDate;
      else if (raw.due !== undefined) deadlineRaw = raw.due;
      else if (raw.time !== undefined) deadlineRaw = raw.time;
      else if (raw.deadlineAt !== undefined) deadlineRaw = raw.deadlineAt;
      if (raw.priority !== undefined) priorityRaw = raw.priority;
      else if (raw.level !== undefined) priorityRaw = raw.level;
    } else {
      continue;
    }

    content = String(content).replace(/\s+/g, ' ').trim();
    if (!content) continue;                     // content 空 → 丢弃
    if (content.length > 500) content = content.slice(0, 500);

    out.push({
      content: content,
      deadline: normalizeDeadlineValue(deadlineRaw),
      priority: normalizePriorityValue(priorityRaw)
    });
  }
  return out;
}

// ---------------------------------------------------------------------------
// DeepSeek 调用
// ---------------------------------------------------------------------------
function readConfig() {
  const key = typeof process.env.DEEPSEEK_API_KEY === 'string' ? process.env.DEEPSEEK_API_KEY.trim() : '';
  let base = typeof process.env.DEEPSEEK_BASE_URL === 'string' ? process.env.DEEPSEEK_BASE_URL.trim() : '';
  if (!base) base = DEFAULT_BASE_URL;
  base = base.replace(/\/+$/, '');
  const model = (typeof process.env.DEEPSEEK_MODEL === 'string' && process.env.DEEPSEEK_MODEL.trim())
    ? process.env.DEEPSEEK_MODEL.trim() : DEFAULT_MODEL;
  const timeoutMs = clampNumber(process.env.DEEPSEEK_TIMEOUT_MS, MIN_TIMEOUT_MS, MAX_TIMEOUT_MS, DEFAULT_TIMEOUT_MS);
  return { key: key, baseUrl: base, model: model, timeoutMs: timeoutMs };
}

/**
 * 调 DeepSeek /chat/completions
 * 返回 { ok:true, content } 或 { ok:false, reason }（reason 已脱敏，可直接进 notice）
 */
async function callDeepSeek(cfg, messages) {
  let res;
  try {
    res = await postJson(cfg.baseUrl + '/chat/completions', {
      model: cfg.model,
      messages: messages,
      temperature: 0.2,
      response_format: { type: 'json_object' },
      stream: false,
      max_tokens: 1200
    }, {
      timeoutMs: cfg.timeoutMs,
      headers: { Authorization: 'Bearer ' + cfg.key }
    });
  } catch (e) {
    const msg = sanitizeMessage(e && e.message ? e.message : e);
    if (/超时|timeout|abort/i.test(msg)) return { ok: false, reason: 'DeepSeek 请求超时（' + cfg.timeoutMs + 'ms）' };
    return { ok: false, reason: 'DeepSeek 请求失败：' + msg };
  }

  if (res.statusCode < 200 || res.statusCode >= 300) {
    return { ok: false, reason: 'DeepSeek ' + res.statusCode + ' ' + sanitizeMessage(res.text).slice(0, 120) };
  }

  let data = null;
  try {
    data = JSON.parse(res.text);
  } catch (e) {
    return { ok: false, reason: 'DeepSeek 响应不是合法 JSON' };
  }
  const choice = data && Array.isArray(data.choices) ? data.choices[0] : null;
  const message = choice && choice.message ? choice.message : null;
  let content = message ? message.content : '';
  if (content && typeof content === 'object') content = JSON.stringify(content); // 少数网关直接给对象

  if (typeof content !== 'string' || !content.trim()) {
    return { ok: false, reason: 'DeepSeek 未返回内容' };
  }
  return { ok: true, content: content, usage: data.usage || null };
}

// ---------------------------------------------------------------------------
// action: parse
// ---------------------------------------------------------------------------
async function handleParse(payload) {
  const started = Date.now();
  const cfg = readConfig();

  // --- 入参校验（唯一的硬失败分支）---
  const rawText = typeof payload.text === 'string' ? payload.text : '';
  const text = rawText.trim();
  if (!text) {
    return fail('bad_request', 'text 不能为空', {
      engine: cfg.key ? 'deepseek' : 'rule',
      fallbackText: ''
    });
  }

  const truncated = text.length > MAX_TEXT;
  const safeText = truncated ? text.slice(0, MAX_TEXT) : text;
  const now = (function () {
    const n = Number(payload.now);
    return (Number.isFinite(n) && n > 0) ? Math.floor(n) : Date.now();
  })();
  const timezone = promptLib.safeTimeZone(payload.timezone);
  const maxItems = promptLib.clampMaxItems(payload.maxItems);
  const source = promptLib.normalizeSource(payload.source);

  const notices = [];
  if (truncated) notices.push('文本超过 ' + MAX_TEXT + ' 字，已截断');

  // --- 降级：本地规则解析 ---
  function ruleResult(noticeList) {
    const parsed = parserLib.parseByRules(safeText, { now: now, timezone: timezone, maxItems: maxItems });
    const all = notices.concat(noticeList || []);
    return {
      ok: true,
      engine: 'rule',
      model: cfg.model,
      todos: parsed.todos,
      elapsedMs: Date.now() - started,
      notice: all.join('；'),
      fallbackText: safeText // 契约 §3.3：降级时回传原文，客户端可退化为手动编辑导入
    };
  }

  // 未配置 key：直接用规则解析，不算失败
  if (!cfg.key) {
    return ruleResult(['未配置 DEEPSEEK_API_KEY，已使用本地规则解析']);
  }

  // --- 真实模型 ---
  let call;
  try {
    const messages = promptLib.buildMessages({
      text: safeText, now: now, timezone: timezone, maxItems: maxItems, source: source
    });
    call = await callDeepSeek(cfg, messages);
  } catch (e) {
    call = { ok: false, reason: 'DeepSeek 调用异常：' + sanitizeMessage(e && e.message ? e.message : e) };
  }

  if (!call.ok) {
    console.warn('[ai] 降级到规则解析：' + call.reason);
    return ruleResult(['已降级为本地规则解析：' + call.reason]);
  }

  const parsedJson = extractJsonObject(call.content);
  if (!parsedJson) {
    console.warn('[ai] 降级到规则解析：模型返回内容无法解析为 JSON');
    return ruleResult(['已降级为本地规则解析：模型返回内容不是合法 JSON']);
  }

  const todos = normalizeModelTodos(parsedJson, maxItems);
  if (!todos.length) {
    console.warn('[ai] 降级到规则解析：模型未返回有效待办');
    return ruleResult(['已降级为本地规则解析：模型未返回有效待办']);
  }

  const out = {
    ok: true,
    engine: 'deepseek',
    model: cfg.model,
    todos: todos,
    elapsedMs: Date.now() - started
  };
  if (notices.length) out.notice = notices.join('；');
  return out;
}

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------
exports.main = async (event, context) => {
  const evt = (event && typeof event === 'object') ? event : {};
  const httpMethod = String(evt.httpMethod || '').toUpperCase();
  if (httpMethod === 'OPTIONS') return preflightResponse();

  const unwrapped = unwrapEvent(evt);
  const payload = unwrapped.payload;
  const action = typeof payload.action === 'string' ? payload.action.trim() : '';

  let result;
  try {
    if (action !== 'parse') {
      result = fail('bad_request', action ? ('不支持的 action：' + action) : '缺少 action');
    } else {
      // 决策 4：先校验登录态（401 优先于 400），拿不到身份直接拒绝，不消耗 DeepSeek 额度
      const ident = await resolveIdentity(evt, payload);
      if (!ident.openid) {
        result = fail('unauthorized', ident.reason === 'expired_token' ? '登录态已失效' : '未登录或登录态无效');
      } else {
        result = await handleParse(payload);
      }
    }
  } catch (err) {
    // 兜底：规则解析本身也不该失败，但真出异常时仍要返回协议结构
    console.error('[ai] action 执行失败 action=' + action, err && (err.stack || err.message || err));
    const text = typeof payload.text === 'string' ? payload.text.slice(0, MAX_TEXT) : '';
    let todos = [];
    try {
      todos = parserLib.parseByRules(text, {
        now: Number(payload.now) || Date.now(),
        timezone: payload.timezone,
        maxItems: payload.maxItems
      }).todos;
    } catch (e2) { todos = []; }
    result = fail('internal', '服务内部错误', {
      engine: 'rule',
      todos: todos,
      fallbackText: text
    });
  }

  if (unwrapped.isHttp) return httpResponse(result);
  return result;
};
