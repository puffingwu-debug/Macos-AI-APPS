'use strict';
/**
 * 云函数 auth —— Mac 端扫码登录（契约 §4）
 *
 * 流程：Mac createTicket → 渲染二维码 → 小程序 confirmTicket（带微信登录态 openid）
 *       → Mac pollTicket 拿到 token → 之后所有请求带 x-todo-token。
 *
 * 安全要点：
 *  - confirmTicket 的 openid 只来自 cloud.getWXContext().OPENID，绝不接受客户端传入；
 *  - ticket 一票一用（条件更新防并发重复 confirm），5 分钟过期；
 *  - session token 48 位随机 hex，30 天过期，存 auth_sessions（_id = token）。
 */

const cloud = require('wx-server-sdk');
const crypto = require('crypto');

cloud.init({ env: cloud.DYNAMIC_CURRENT_ENV });

const db = cloud.database();
const _ = db.command;

const TICKET_TTL_MS = 5 * 60 * 1000;              // 契约 §4.2：ticket 有效期 5 分钟
const SESSION_TTL_MS = 30 * 24 * 3600 * 1000;     // 契约 §4.2：token 有效期 30 天
const TICKET_RE = /^[0-9a-f]{32}$/;               // crypto.randomBytes(16).toString('hex')
const TOKEN_RE = /^[0-9a-fA-F]{16,128}$/;         // 会话 token（48 位 hex，放宽兼容）
const MAX_DEVICE_NAME = 64;
const MAX_TICKETS_PER_HOUR = 30;                  // 软性防刷：单设备名 1 小时最多建 30 张票

const AUTH_ACTIONS = ['createTicket', 'pollTicket', 'confirmTicket', 'check', 'logout'];

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
// 通道解包 / 响应（自包含实现）
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

/**
 * 失败响应。httpStatus 可选：契约 §4.2 要求「重复 confirm 返回 409 语义的 bad_request」，
 * 用不可枚举属性携带 HTTP 状态，保证 JSON body 仍是 {ok:false,error:{code,message}}。
 */
function fail(code, message, httpStatus) {
  const out = { ok: false, error: { code: code, message: String(message || '') } };
  if (httpStatus) {
    Object.defineProperty(out, '__httpStatus', { value: httpStatus, enumerable: false });
  }
  return out;
}

function httpResponse(result) {
  let statusCode;
  if (result && result.ok) {
    statusCode = 200;
  } else if (result && result.__httpStatus) {
    statusCode = result.__httpStatus;
  } else {
    statusCode = STATUS_BY_CODE[(result && result.error && result.error.code) || 'internal'] || 500;
  }
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
function getOpenid() {
  try {
    const ctx = cloud.getWXContext() || {};
    return ctx.OPENID || '';
  } catch (e) {
    return '';
  }
}

function normalizeTicket(v) {
  const s = typeof v === 'string' ? v.trim().toLowerCase() : '';
  return TICKET_RE.test(s) ? s : '';
}

function normalizeToken(v) {
  const s = typeof v === 'string' ? v.trim() : '';
  return TOKEN_RE.test(s) ? s : '';
}

function normalizeDeviceName(v) {
  let s = typeof v === 'string' ? v.replace(/\s+/g, ' ').trim() : '';
  if (s.length > MAX_DEVICE_NAME) s = s.slice(0, MAX_DEVICE_NAME);
  return s || 'Mac';
}

/** 读 ticket；不存在返回 null */
async function getTicket(ticket) {
  try {
    const res = await db.collection('auth_tickets').doc(ticket).get();
    return (res && res.data) || null;
  } catch (e) {
    return null;
  }
}

/** 读 session；不存在返回 null */
async function getSession(token) {
  try {
    const res = await db.collection('auth_sessions').doc(token).get();
    return (res && res.data) || null;
  } catch (e) {
    return null;
  }
}

// ---------------------------------------------------------------------------
// actions（契约 §4.2）
// ---------------------------------------------------------------------------
/** createTicket：Mac 生成登录二维码，返回 ticket / qrPayload / 有效期 */
async function handleCreateTicket(payload) {
  const deviceName = normalizeDeviceName(payload.deviceName);
  const now = Date.now();

  // 软性防刷：同一 deviceName 1 小时内建票过多则拒绝（避免被刷爆集合）
  try {
    const cnt = await db.collection('auth_tickets')
      .where({ deviceName: deviceName, createTime: _.gte(now - 3600 * 1000) })
      .count();
    if (cnt && Number(cnt.total) >= MAX_TICKETS_PER_HOUR) {
      return fail('rate_limited', '操作过于频繁，请稍后再试');
    }
  } catch (e) {
    // 计数失败（集合刚建/无索引）不阻断主流程
  }

  const ticket = crypto.randomBytes(16).toString('hex'); // 32 位 hex
  const expireAt = now + TICKET_TTL_MS;
  await db.collection('auth_tickets').doc(ticket).set({
    data: {
      openid: '',
      status: 'pending',
      token: '',
      deviceName: deviceName,
      createTime: now,
      expireAt: expireAt
    }
  });

  return {
    ok: true,
    ticket: ticket,
    qrPayload: 'quicktodo://login?ticket=' + ticket, // Mac 直接把它编码成二维码
    expiresIn: Math.floor(TICKET_TTL_MS / 1000),     // 300 秒
    expireAt: expireAt
  };
}

/** pollTicket：Mac 轮询；先判过期，再回 pending/scanned/confirmed */
async function handlePollTicket(payload) {
  const ticket = normalizeTicket(payload.ticket);
  if (!ticket) return fail('bad_request', 'ticket 格式非法');

  const doc = await getTicket(ticket);
  // 查不到（已被清理或环境不对）→ 视为失效，让 Mac 停止轮询并重新出码
  if (!doc) return { ok: true, status: 'expired' };

  const now = Date.now();
  if (!(Number(doc.expireAt) > now)) {
    if (doc.status !== 'expired') {
      db.collection('auth_tickets').doc(ticket)
        .update({ data: { status: 'expired' } })
        .catch(function () { /* 过期标记失败不重要 */ });
    }
    return { ok: true, status: 'expired' };
  }

  if (doc.status === 'confirmed' && doc.token) {
    return { ok: true, status: 'confirmed', token: doc.token, openid: doc.openid || '' };
  }
  return { ok: true, status: doc.status || 'pending' };
}

/** confirmTicket：小程序扫码后调用；openid 只认微信上下文 */
async function handleConfirmTicket(payload) {
  const openid = getOpenid();
  if (!openid) return fail('unauthorized', '未获取到微信登录态，请在小程序内操作');

  const ticket = normalizeTicket(payload.ticket);
  if (!ticket) return fail('bad_request', 'ticket 格式非法');

  const doc = await getTicket(ticket);
  if (!doc) return fail('not_found', '登录二维码不存在，请在 Mac 端重新生成');

  const now = Date.now();
  if (!(Number(doc.expireAt) > now)) {
    db.collection('auth_tickets').doc(ticket)
      .update({ data: { status: 'expired' } })
      .catch(function () { /* ignore */ });
    return fail('bad_request', '登录二维码已过期，请在 Mac 端重新生成');
  }
  // 一票一用：已被确认过 → 409 语义的 bad_request
  if (doc.status === 'confirmed') {
    return fail('bad_request', '该二维码已被使用，请在 Mac 端重新生成', 409);
  }

  const token = crypto.randomBytes(24).toString('hex'); // 48 位 hex
  await db.collection('auth_sessions').doc(token).set({
    data: {
      openid: openid,
      createTime: now,
      lastSeen: now,
      expireAt: now + SESSION_TTL_MS
    }
  });

  // 条件更新兜住并发：只有仍是「未确认」状态才能写入 token
  let updated = 0;
  try {
    const upd = await db.collection('auth_tickets')
      .where({ _id: ticket, status: _.neq('confirmed') })
      .update({ data: { openid: openid, status: 'confirmed', token: token, confirmTime: now } });
    updated = (upd && upd.stats && Number(upd.stats.updated)) || 0;
  } catch (e) {
    // 个别环境不支持 where 条件更新：退化为普通更新（前面已判过状态）
    await db.collection('auth_tickets').doc(ticket)
      .update({ data: { openid: openid, status: 'confirmed', token: token, confirmTime: now } });
    updated = 1;
  }

  if (!updated) {
    // 竞态失败：回收刚建的无用会话，保持一票一用
    try { await db.collection('auth_sessions').doc(token).remove(); } catch (e) { /* ignore */ }
    return fail('bad_request', '该二维码已被使用，请在 Mac 端重新生成', 409);
  }

  return { ok: true, openid: openid };
}

/** check：校验会话 token（Mac 启动时验证登录态） */
async function handleCheck(payload) {
  const token = normalizeToken(payload.token);
  if (!token) return fail('unauthorized', '缺少或非法的 token');

  const session = await getSession(token);
  if (!session || !session.openid) return fail('unauthorized', '登录态已失效，请重新扫码登录');
  const now = Date.now();
  if (!(Number(session.expireAt) > now)) {
    try { await db.collection('auth_sessions').doc(token).remove(); } catch (e) { /* ignore */ }
    return fail('unauthorized', '登录态已过期，请重新扫码登录');
  }

  db.collection('auth_sessions').doc(token)
    .update({ data: { lastSeen: now } })
    .catch(function () { /* ignore */ });

  return { ok: true, openid: session.openid, expireAt: Number(session.expireAt) };
}

/** logout：删除会话（幂等） */
async function handleLogout(payload) {
  const token = normalizeToken(payload.token);
  if (token) {
    try { await db.collection('auth_sessions').doc(token).remove(); } catch (e) { /* ignore */ }
  }
  return { ok: true };
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
    if (AUTH_ACTIONS.indexOf(action) < 0) {
      result = fail('bad_request', action ? ('不支持的 action：' + action) : '缺少 action');
    } else if (action === 'createTicket') {
      result = await handleCreateTicket(payload);
    } else if (action === 'pollTicket') {
      result = await handlePollTicket(payload);
    } else if (action === 'confirmTicket') {
      result = await handleConfirmTicket(payload);
    } else if (action === 'check') {
      result = await handleCheck(payload);
    } else {
      result = await handleLogout(payload);
    }
  } catch (err) {
    console.error('[auth] action 执行失败 action=' + action, err && (err.stack || err.message || err));
    result = fail('internal', '服务内部错误');
  }

  if (unwrapped.isHttp) return httpResponse(result);
  return result;
};
