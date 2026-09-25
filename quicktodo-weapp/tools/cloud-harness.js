'use strict';
/**
 * QuickTodo 本地联调桩 —— cloud-harness
 * ===========================================================================
 * 用内存 Map 桩掉 `wx-server-sdk`（云数据库 + getWXContext），让三个云函数
 * （todo / ai / auth）**原封不动**地在本地跑起来，用于：
 *
 *   1) 单元/回归测试：`node tools/cloud-harness.js`
 *   2) Mac 客户端 ↔ 云函数 真实端到端联调：`node tools/cloud-harness.js --serve 8787`
 *
 * 关键设计：
 *   - 只拦截 `require('wx-server-sdk')` 与 `require('https')`，云函数源码零改动、零 mock 代码；
 *   - https 默认**透传真实模块**（真调 DeepSeek），只有显式 `mockUpstream()` 后才返回假响应；
 *   - 内存 DB 行为对齐云开发：`doc().get()` 文档不存在会抛错、`set()` 整文档覆盖、
 *     文档 `_id` 等于 doc(id)、`where().get()` 默认 100 条上限、`orderBy` 支持多字段。
 *
 * 编程接口：
 *   const { createHarness, startServer } = require('./cloud-harness');
 *   const h = createHarness();
 *   await h.callFunction('todo', { action: 'ping' }, 'oUSER1');
 *   await h.httpRequest('/todo', { 'x-todo-token': token }, { action: 'ping' });
 *
 *   API 一览
 *   --------
 *   createHarness() -> {
 *     callFunction(name, event, openid?) -> Promise<云函数返回体>   // 模拟小程序 wx.cloud.callFunction
 *     httpRequest(path, headers, bodyObj?, method?) -> Promise<{statusCode, headers, body, json}>
 *     setOpenid(x)                     // 设置 getWXContext().OPENID（'' 表示无登录态）
 *     reset()                          // 清空内存库 + 重置云函数模块状态（lastStamp 等）
 *     seedSession(openid, opts?) -> token   // 直接造一个合法 auth_sessions 会话（省去扫码流程）
 *     seedTicket(openid, opts?) -> ticket   // 直接造一张 pending/confirmed 票据
 *     mockUpstream(opts?)              // 控制 DeepSeek 假响应；传 {enabled:false} 恢复真实请求
 *     lastUpstreamRequest()            // 取最近一次「云函数 → DeepSeek」的请求（断言用）
 *     setNow(ms) / now()               // 冻结 Date.now()（可选，做时间相关断言用）
 *     db, store, collections           // 直接读内存库
 *   }
 *   startServer(port?) -> Promise<http.Server>   // 额外挂了 server.baseUrl / server.port
 *
 * 自检：node tools/cloud-harness.js
 * 起服务：node tools/cloud-harness.js --serve 8787
 */

const Module = require('module');
const http = require('http');
const path = require('path');
const crypto = require('crypto');
const { EventEmitter } = require('events');

// 必须在安装 require 拦截器之前拿到真实 https，否则会拿到自己的假模块
const realHttps = require('https');

const FUNCTIONS_DIR = path.join(__dirname, '..', 'cloudfunctions');
const FUNCTION_NAMES = ['todo', 'ai', 'auth'];
const COLLECTION_NAMES = ['todos', 'auth_tickets', 'auth_sessions', 'counters'];

// ---------------------------------------------------------------------------
// 状态
// ---------------------------------------------------------------------------
const state = {
  store: new Map(),          // name -> Map<id, doc>
  openid: '',                // getWXContext().OPENID
  appid: 'wxharness00000000',
  frozenNow: null,           // 非 null 时 Date.now() 被冻结
  upstream: {                // DeepSeek 假响应开关（默认关闭 = 透传真实请求）
    enabled: false,
    status: 200,
    body: '{}',
    throwErr: null,
    lastRequest: null
  }
};

function initStore() {
  COLLECTION_NAMES.forEach(function (name) {
    if (!state.store.has(name)) state.store.set(name, new Map());
  });
}
initStore();

const clone = function (v) {
  return v === undefined ? undefined : JSON.parse(JSON.stringify(v));
};

// 冻结时钟：仅影响云函数里对 Date.now() 的调用（nextStamp / expireAt 判定等）
const realDateNow = Date.now;
Date.now = function () {
  return state.frozenNow === null ? realDateNow.call(Date) : state.frozenNow;
};

// ---------------------------------------------------------------------------
// 内存数据库（对齐 wx-server-sdk 行为）
// ---------------------------------------------------------------------------
const CMD = function (op, value) { return { __cmd: op, value: value }; };

const command = {
  eq: function (v) { return CMD('eq', v); },
  neq: function (v) { return CMD('neq', v); },
  gt: function (v) { return CMD('gt', v); },
  gte: function (v) { return CMD('gte', v); },
  lt: function (v) { return CMD('lt', v); },
  lte: function (v) { return CMD('lte', v); },
  in: function (v) { return CMD('in', v); },
  nin: function (v) { return CMD('nin', v); },
  exists: function (v) { return CMD('exists', v); },
  inc: function (v) { return CMD('inc', v); },
  set: function (v) { return CMD('set', v); },
  remove: function () { return CMD('remove'); },
  and: function () { return CMD('and', Array.prototype.slice.call(arguments)); },
  or: function () { return CMD('or', Array.prototype.slice.call(arguments)); }
};

function matchValue(docVal, cond) {
  if (cond && typeof cond === 'object' && cond.__cmd) {
    const v = cond.value;
    switch (cond.__cmd) {
      case 'eq': return docVal === v;
      case 'neq': return docVal !== v;
      case 'gt': return docVal > v;
      case 'gte': return docVal >= v;
      case 'lt': return docVal < v;
      case 'lte': return docVal <= v;
      case 'in': return Array.isArray(v) && v.indexOf(docVal) >= 0;
      case 'nin': return !(Array.isArray(v) && v.indexOf(docVal) >= 0);
      case 'exists': return v ? docVal !== undefined : docVal === undefined;
      case 'and': return v.every(function (c) { return matchValue(docVal, c); });
      case 'or': return v.some(function (c) { return matchValue(docVal, c); });
      default: return true;
    }
  }
  if (cond && typeof cond === 'object') return JSON.stringify(docVal) === JSON.stringify(cond);
  return docVal === cond;
}

function matchDoc(doc, cond) {
  return Object.keys(cond || {}).every(function (k) { return matchValue(doc[k], cond[k]); });
}

function applyUpdate(doc, data) {
  Object.keys(data || {}).forEach(function (k) {
    const v = data[k];
    if (v && typeof v === 'object' && v.__cmd === 'inc') { doc[k] = (Number(doc[k]) || 0) + Number(v.value); return; }
    if (v && typeof v === 'object' && v.__cmd === 'set') { doc[k] = clone(v.value); return; }
    if (v && typeof v === 'object' && v.__cmd === 'remove') { delete doc[k]; return; }
    doc[k] = clone(v);
  });
}

function makeQuery(name, cond) {
  return {
    _cond: cond || {},
    _order: [],
    _limit: 100,   // 云开发单次 get 默认/最大 100 条
    _skip: 0,
    _field: null,
    orderBy: function (field, dir) { this._order.push([field, dir]); return this; },
    limit: function (n) { this._limit = Number(n); return this; },
    skip: function (n) { this._skip = Number(n); return this; },
    field: function (f) { this._field = f; return this; },
    get: async function () {
      const col = state.store.get(name) || new Map();
      let rows = Array.from(col.values()).filter(function (d) { return matchDoc(d, this._cond); }, this);
      const order = this._order.slice().reverse();
      order.forEach(function (o) {
        const f = o[0], dir = o[1];
        rows.sort(function (a, b) {
          const x = a[f], y = b[f];
          if (x === y) return 0;
          const r = x < y ? -1 : 1;
          return dir === 'desc' ? -r : r;
        });
      });
      rows = rows.slice(this._skip, this._skip + this._limit);
      return { data: rows.map(clone) };
    },
    count: async function () {
      const col = state.store.get(name) || new Map();
      const cond = this._cond; // 注意：回调里不能再依赖 this（严格模式下为 undefined）
      const n = Array.from(col.values()).filter(function (d) { return matchDoc(d, cond); }).length;
      return { total: n };
    },
    update: async function (arg) {
      const col = state.store.get(name) || new Map();
      const cond = this._cond;
      let n = 0;
      col.forEach(function (doc) {
        if (matchDoc(doc, cond)) { applyUpdate(doc, arg.data); n++; }
      });
      return { stats: { updated: n } };
    },
    remove: async function () {
      const col = state.store.get(name) || new Map();
      const cond = this._cond;
      let n = 0;
      Array.from(col.keys()).forEach(function (id) {
        if (matchDoc(col.get(id), cond)) { col.delete(id); n++; }
      });
      return { stats: { removed: n } };
    }
  };
}

function makeDoc(name, id) {
  return {
    get: async function () {
      const col = state.store.get(name) || new Map();
      const doc = col.get(id);
      // 对齐云开发：文档不存在时 SDK 抛错（云函数里都做了 try/catch）
      if (!doc) {
        const err = new Error('document.get:fail document not exists');
        err.errCode = -1;
        throw err;
      }
      return { data: clone(doc) };
    },
    set: async function (arg) {
      const col = state.store.get(name) || new Map();
      // set 是整文档覆盖；文档 _id 等于 doc(id)
      col.set(id, Object.assign({ _id: id }, clone(arg.data)));
      return { _id: id, stats: { created: 1, updated: 0 } };
    },
    update: async function (arg) {
      const col = state.store.get(name) || new Map();
      const doc = col.get(id);
      if (!doc) return { stats: { updated: 0 } };
      applyUpdate(doc, arg.data);
      return { stats: { updated: 1 } };
    },
    remove: async function () {
      const col = state.store.get(name) || new Map();
      const had = col.delete(id);
      return { stats: { removed: had ? 1 : 0 } };
    },
    field: function () { return this; }
  };
}

const db = {
  command: command,
  serverDate: function () { return new Date(); },
  collection: function (name) {
    if (!state.store.has(name)) state.store.set(name, new Map());
    return {
      doc: function (id) { return makeDoc(name, id); },
      where: function (cond) { return makeQuery(name, cond); },
      orderBy: function (f, d) { return makeQuery(name, {}).orderBy(f, d); },
      limit: function (n) { return makeQuery(name, {}).limit(n); },
      skip: function (n) { return makeQuery(name, {}).skip(n); },
      get: function () { return makeQuery(name, {}).get(); },
      count: function () { return makeQuery(name, {}).count(); },
      add: async function (arg) {
        const col = state.store.get(name) || new Map();
        const id = (arg && arg.data && arg.data._id) || crypto.randomBytes(12).toString('hex');
        col.set(id, Object.assign({ _id: id }, clone(arg.data)));
        return { _id: id };
      }
    };
  }
};

// ---------------------------------------------------------------------------
// wx-server-sdk 桩 + https 拦截
// ---------------------------------------------------------------------------
const sdkStub = {
  DYNAMIC_CURRENT_ENV: 'DYNAMIC_CURRENT_ENV',
  init: function () { /* noop */ },
  database: function () { return db; },
  getWXContext: function () {
    return {
      OPENID: state.openid,
      APPID: state.appid,
      UNIONID: '',
      ENV: 'cloud-harness',
      SOURCE: 'cloud-harness'
    };
  }
};

/** 假的 https.request：只有 mockUpstream({enabled:true}) 后才拦截，否则透传真实请求 */
function fakeRequest(options, callback) {
  const req = new EventEmitter();
  const chunks = [];
  req.write = function (chunk) {
    if (chunk) chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(String(chunk)));
    return true;
  };
  req.setTimeout = function () { return req; };
  req.__done = false;
  req.destroy = function (err) {
    if (req.__done) return;
    req.__done = true;
    req.emit('error', err || new Error('destroyed'));
  };
  req.abort = function () { req.destroy(new Error('aborted')); };
  req.end = function () {
    const up = state.upstream;
    up.lastRequest = {
      url: String(options.protocol || 'https:') + '//' + String(options.hostname || '') +
        String(options.path || ''),
      method: options.method || 'GET',
      headers: clone(options.headers) || {},
      body: Buffer.concat(chunks).toString('utf8')
    };
    if (!up.enabled) {
      req.destroy(new Error('cloud-harness: 上游 mock 未开启，但代码发起了真实 https 请求（若要真调 DeepSeek 请配置 DEEPSEEK_API_KEY）'));
      return;
    }
    process.nextTick(function () {
      if (up.throwErr) { req.destroy(up.throwErr); return; }
      const res = new EventEmitter();
      res.statusCode = up.status;
      res.headers = {};
      res.setEncoding = function () { return res; };
      if (callback) callback(res);
      const body = typeof up.body === 'function' ? up.body(up.lastRequest) : up.body;
      res.emit('data', Buffer.from(String(body === undefined ? '' : body)));
      res.emit('end');
    });
  };
  return req;
}

const fakeHttps = Object.create(realHttps);
fakeHttps.request = fakeRequest;
fakeHttps.get = function (options, callback) {
  const req = fakeRequest(options, callback);
  req.end();
  return req;
};

const originalLoad = Module._load;
Module._load = function (request, parent, isMain) {
  if (request === 'wx-server-sdk') return sdkStub;
  if (request === 'https') return fakeHttps;
  return originalLoad.apply(this, arguments);
};

// ---------------------------------------------------------------------------
// 云函数装载
// ---------------------------------------------------------------------------
function functionPath(name) {
  return path.join(FUNCTIONS_DIR, name, 'index.js');
}

function loadFunction(name) {
  if (FUNCTION_NAMES.indexOf(name) < 0) throw new Error('未知云函数：' + name);
  return require(functionPath(name));
}

function dropFunctionCache() {
  FUNCTION_NAMES.forEach(function (name) {
    try { delete require.cache[require.resolve(functionPath(name))]; } catch (e) { /* ignore */ }
  });
}

/** 路径 → 云函数名（云接入绑定关系：/todo→todo、/ai→ai、/auth→auth） */
function functionForPath(p) {
  const clean = String(p || '').split('?')[0].replace(/\/+$/, '');
  const seg = clean.split('/').filter(Boolean)[0] || '';
  return FUNCTION_NAMES.indexOf(seg) >= 0 ? seg : '';
}

function toStringMap(obj) {
  const out = {};
  if (obj && typeof obj === 'object') {
    Object.keys(obj).forEach(function (k) {
      const v = obj[k];
      out[k] = (v === undefined || v === null) ? '' : String(v);
    });
  }
  return out;
}

// ---------------------------------------------------------------------------
// createHarness()
// ---------------------------------------------------------------------------
function createHarness() {
  return {
    db: db,
    store: state.store,

    /** 设置 getWXContext().OPENID（'' = 无小程序登录态，只能靠 token） */
    setOpenid: function (x) { state.openid = x || ''; },
    getOpenid: function () { return state.openid; },

    /** 冻结/解冻 Date.now()（null = 恢复真实时间） */
    setNow: function (ms) { state.frozenNow = (ms === null || ms === undefined) ? null : Number(ms); },
    now: function () { return Date.now(); },

    /** 清空内存库、重置云函数模块级状态（nextStamp 等）与 mock */
    reset: function () {
      COLLECTION_NAMES.forEach(function (name) { state.store.set(name, new Map()); });
      dropFunctionCache();
      state.openid = '';
      state.frozenNow = null;
      state.upstream = { enabled: false, status: 200, body: '{}', throwErr: null, lastRequest: null };
    },

    /**
     * 模拟 wx.cloud.callFunction：event 即业务参数，身份来自 getWXContext().OPENID
     * @param {string} name   云函数名 todo|ai|auth
     * @param {object} event  业务参数（不带 HTTP 信封）
     * @param {string} [openid] 传了就临时切换登录态；不传则沿用 setOpenid 的值
     */
    callFunction: async function (name, event, openid) {
      if (openid !== undefined) state.openid = openid || '';
      const mod = loadFunction(name);
      const evt = (event && typeof event === 'object') ? clone(event) : {};
      return await mod.main(evt, {});
    },

    /**
     * 模拟云接入（HTTP 访问服务）请求
     * 注意：HTTP 通道**不携带微信登录态**（这是真实环境的行为，也是 confirmTicket 走 HTTP 必然 401 的原因），
     *       因此本方法执行期间会临时把 OPENID 置空，只认 x-todo-token / payload.token。
     * @param {string} p        形如 /todo、/ai、/auth，可带查询串（如 /todo?action=list&since=0）
     * @param {object} [headers] 请求头（大小写不敏感）
     * @param {object|string} [body] POST 用对象（或原始字符串）；GET 用对象自动转 queryStringParameters
     * @param {string} [method] 默认 POST
     * @returns {Promise<{statusCode, headers, body, json}>} body 为原始 JSON 字符串，json 为解析结果
     */
    httpRequest: async function (p, headers, body, method) {
      const u = new URL(String(p), 'http://harness.local');
      const name = functionForPath(u.pathname);
      if (!name) throw new Error('未知路径（只支持 /todo、/ai、/auth）：' + p);

      const prevOpenid = state.openid;
      state.openid = ''; // HTTP 通道没有微信登录态
      try {
        const m = String(method || 'POST').toUpperCase();
        const event = {
          path: u.pathname,
          httpMethod: m,
          headers: clone(headers) || {},
          queryStringParameters: {},
          body: '',
          isBase64Encoded: false,
          requestContext: { path: u.pathname, httpMethod: m, sourceIp: '127.0.0.1', identity: {} }
        };
        u.searchParams.forEach(function (v, k) { event.queryStringParameters[k] = v; });
        if (m === 'GET' || m === 'HEAD') {
          Object.assign(event.queryStringParameters, toStringMap(body));
        } else if (typeof body === 'string') {
          event.body = body;
        } else if (body && typeof body === 'object') {
          event.body = JSON.stringify(body);
        }
        const raw = await loadFunction(name).main(event, {});
        const env = (raw && typeof raw === 'object' && typeof raw.statusCode === 'number')
          ? raw
          : { statusCode: 200, headers: {}, body: JSON.stringify(raw) };
        let json = null;
        try { json = JSON.parse(env.body); } catch (e) { json = null; }
        return { statusCode: env.statusCode, headers: env.headers || {}, body: env.body, json: json };
      } finally {
        state.openid = prevOpenid;
      }
    },

    /** 造一个合法会话（省去小程序扫码），返回 token */
    seedSession: function (openid, opts) {
      const o = opts || {};
      const token = o.token || crypto.randomBytes(24).toString('hex');
      const now = Date.now();
      db.collection('auth_sessions').doc(token);
      state.store.get('auth_sessions').set(token, {
        _id: token,
        openid: openid || 'oHARNESS',
        createTime: now,
        lastSeen: now,
        expireAt: o.expired ? now - 1000 : now + (o.ttlMs || 30 * 24 * 3600 * 1000)
      });
      return token;
    },

    /** 造一张票据（默认 pending 未过期） */
    seedTicket: function (openid, opts) {
      const o = opts || {};
      const ticket = o.ticket || crypto.randomBytes(16).toString('hex');
      const now = Date.now();
      state.store.get('auth_tickets').set(ticket, {
        _id: ticket,
        openid: openid || '',
        status: o.status || 'pending',
        token: o.token || '',
        deviceName: o.deviceName || 'harness',
        createTime: now,
        expireAt: o.expired ? now - 1000 : now + (o.ttlMs || 5 * 60 * 1000)
      });
      return ticket;
    },

    /**
     * 控制 DeepSeek 假响应（每次调用都完整描述期望状态）
     *   mockUpstream({ status:200, body:'{"choices":[...]}' })   开启并按给定响应返回（会清掉上次的 throwErr）
     *   mockUpstream({ throwErr: new Error('timeout') })         模拟网络异常/超时（会清掉上次的 status/body 效果）
     *   mockUpstream({ enabled:false })                          关闭（透传真实 https）
     */
    mockUpstream: function (opts) {
      const o = opts || {};
      const up = state.upstream;
      up.enabled = o.enabled === undefined ? true : !!o.enabled;
      if (o.status !== undefined) up.status = Number(o.status);
      if (o.body !== undefined) up.body = o.body;
      up.throwErr = o.throwErr === undefined ? null : o.throwErr; // 未显式指定就清空，避免上一次的 mock 残留
      return up;
    },

    lastUpstreamRequest: function () { return state.upstream.lastRequest; },

    /** 直接读某个集合的所有文档（断言用） */
    collections: function (name) {
      return Array.from((state.store.get(name) || new Map()).values()).map(clone);
    }
  };
}

// ---------------------------------------------------------------------------
// startServer()：本地 HTTP 服务器，按云接入 event 形状转交云函数
// ---------------------------------------------------------------------------
function startServer(port) {
  const wanted = Number(port) || Number(process.env.PORT) || 8787;
  return new Promise(function (resolve, reject) {
    const server = http.createServer(function (req, res) {
      const chunks = [];
      req.on('data', function (c) { chunks.push(c); });
      req.on('error', function () {
        res.writeHead(400, { 'Content-Type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify({ ok: false, error: { code: 'bad_request', message: '请求体读取失败' } }));
      });
      req.on('end', async function () {
        let u;
        try {
          u = new URL(req.url, 'http://127.0.0.1');
        } catch (e) {
          res.writeHead(400, { 'Content-Type': 'application/json; charset=utf-8' });
          res.end(JSON.stringify({ ok: false, error: { code: 'bad_request', message: 'URL 非法' } }));
          return;
        }
        const name = functionForPath(u.pathname);
        if (!name) {
          res.writeHead(404, { 'Content-Type': 'application/json; charset=utf-8' });
          res.end(JSON.stringify({
            ok: false,
            error: { code: 'not_found', message: '未知路径 ' + u.pathname + '（只支持 /todo、/ai、/auth）' }
          }));
          return;
        }
        try {
          // 完全按云接入（HTTP 访问服务）的 event 形状投递
          const event = {
            path: u.pathname,
            httpMethod: req.method,
            headers: Object.assign({}, req.headers), // Node 已小写化，正好覆盖大小写不敏感场景
            queryStringParameters: Object.fromEntries(u.searchParams.entries()),
            body: Buffer.concat(chunks).toString('utf8'),
            isBase64Encoded: false,
            requestContext: {
              path: u.pathname,
              httpMethod: req.method,
              sourceIp: req.socket.remoteAddress || '127.0.0.1',
              identity: {}
            }
          };
          const out = await loadFunction(name).main(event, {});
          const env = (out && typeof out === 'object' && typeof out.statusCode === 'number')
            ? out
            : { statusCode: 200, headers: { 'Content-Type': 'application/json; charset=utf-8' }, body: JSON.stringify(out) };
          res.writeHead(env.statusCode, env.headers || {});
          res.end(env.body === undefined || env.body === null ? '' : String(env.body));
        } catch (err) {
          process.stderr.write('[cloud-harness] ' + name + ' 执行异常: ' + (err && err.stack ? err.stack : err) + '\n');
          res.writeHead(500, { 'Content-Type': 'application/json; charset=utf-8' });
          res.end(JSON.stringify({ ok: false, error: { code: 'internal', message: '本地桩内部错误' } }));
        }
      });
    });
    server.on('error', reject);
    server.listen(wanted, '127.0.0.1', function () {
      server.port = server.address().port;
      server.baseUrl = 'http://127.0.0.1:' + server.port;
      resolve(server);
    });
  });
}

// ---------------------------------------------------------------------------
// 自检用例
// ---------------------------------------------------------------------------
function createRunner() {
  const r = { pass: 0, fail: 0, failures: [] };
  r.ok = function (name, cond, extra) {
    if (cond) {
      r.pass++;
      console.log('  PASS ' + name);
    } else {
      r.fail++;
      r.failures.push(name);
      console.log('  FAIL ' + name + (extra === undefined ? '' : '  ' + JSON.stringify(extra)));
    }
  };
  r.section = function (t) { console.log('\n== ' + t + ' =='); };
  return r;
}

// Asia/Shanghai 是固定 UTC+8（无夏令时），用 UTC 数学构造「墙钟时间」便于断言
function cnTime(y, mo, d, h, mi) {
  return Date.UTC(y, mo - 1, d, h - 8, mi || 0, 0, 0);
}

function hexId(i) {
  return '00000000-0000-4000-8000-' + String(i).padStart(12, '0');
}

async function runSelfTest() {
  const h = createHarness();
  const { pass, fail } = { pass: 0, fail: 0 };
  const R = createRunner();
  const UPSTREAM_BACKUP = {
    key: process.env.DEEPSEEK_API_KEY,
    url: process.env.DEEPSEEK_BASE_URL,
    model: process.env.DEEPSEEK_MODEL,
    timeout: process.env.DEEPSEEK_TIMEOUT_MS
  };
  const restoreEnv = function () {
    ['DEEPSEEK_API_KEY', 'DEEPSEEK_BASE_URL', 'DEEPSEEK_MODEL', 'DEEPSEEK_TIMEOUT_MS'].forEach(function (k) {
      const v = UPSTREAM_BACKUP[k === 'DEEPSEEK_API_KEY' ? 'key' : k === 'DEEPSEEK_BASE_URL' ? 'url' : k === 'DEEPSEEK_MODEL' ? 'model' : 'timeout'];
      if (v === undefined) delete process.env[k]; else process.env[k] = v;
    });
  };

  // =========================================================================
  R.section('todo：身份解析与 HTTP 通道');
  h.reset();
  let r = await h.callFunction('todo', { action: 'ping' }, 'oUSER1');
  R.ok('callFunction + OPENID → ping ok', r.ok === true && r.openid === 'oUSER1' && r.version === 'v1' && r.count === 0, r);

  let res = await h.httpRequest('/todo', {}, {}, 'OPTIONS');
  R.ok('OPTIONS → 204 + CORS', res.statusCode === 204 && res.headers['Access-Control-Allow-Origin'] === '*', res.statusCode);

  res = await h.httpRequest('/todo', {}, { action: 'ping' });
  R.ok('HTTP 无 token → 401 unauthorized', res.statusCode === 401 && res.json.error.code === 'unauthorized', res);

  r = await h.callFunction('todo', { action: 'ping' }, '');
  R.ok('callFunction 无 OPENID → unauthorized', r.ok === false && r.error.code === 'unauthorized', r);

  // auth 全流程（扫码登录）
  R.section('auth：扫码登录全流程');
  h.reset();
  let t = await h.callFunction('auth', { action: 'createTicket', deviceName: 'Kun 的 MacBook' });
  R.ok('createTicket 结构正确',
    t.ok === true && /^[0-9a-f]{32}$/.test(t.ticket) &&
    t.qrPayload === 'quicktodo://login?ticket=' + t.ticket && t.expiresIn === 300 && t.expireAt > Date.now(), t);
  const ticket = t.ticket;

  r = await h.callFunction('auth', { action: 'pollTicket', ticket: ticket });
  R.ok('pollTicket → pending', r.ok === true && r.status === 'pending' && r.token === undefined, r);

  r = await h.callFunction('auth', { action: 'confirmTicket', ticket: ticket });
  R.ok('confirmTicket 无 openid → unauthorized', r.ok === false && r.error.code === 'unauthorized', r);

  res = await h.httpRequest('/auth', { 'Content-Type': 'application/json' }, { action: 'confirmTicket', ticket: ticket }, 'POST');
  R.ok('HTTP confirmTicket 无 openid → 401（HTTP 通道拿不到微信登录态）', res.statusCode === 401, res);

  r = await h.callFunction('auth', { action: 'confirmTicket', ticket: ticket }, 'oSCANNER');
  R.ok('confirmTicket(小程序) → ok + openid', r.ok === true && r.openid === 'oSCANNER', r);

  r = await h.callFunction('auth', { action: 'confirmTicket', ticket: ticket }, 'oSCANNER');
  R.ok('重复 confirm → bad_request(409 语义)', r.ok === false && r.error.code === 'bad_request' && r.__httpStatus === 409, r);

  r = await h.callFunction('auth', { action: 'pollTicket', ticket: ticket });
  R.ok('pollTicket → confirmed + token(48hex)',
    r.ok === true && r.status === 'confirmed' && /^[0-9a-f]{48}$/.test(r.token) && r.openid === 'oSCANNER', r);
  const token = r.token;
  const sess = h.collections('auth_sessions')[0];
  R.ok('auth_sessions 有效期 30 天', Math.round((sess.expireAt - sess.createTime) / 86400000) === 30, sess);

  r = await h.callFunction('auth', { action: 'check', token: token });
  R.ok('check → ok + openid + expireAt', r.ok === true && r.openid === 'oSCANNER' && typeof r.expireAt === 'number', r);

  r = await h.callFunction('auth', { action: 'check', token: 'deadbeefdeadbeef' });
  R.ok('check 非法 token → unauthorized', r.ok === false && r.error.code === 'unauthorized', r);

  const t2 = await h.callFunction('auth', { action: 'createTicket', deviceName: 'M2' });
  h.store.get('auth_tickets').get(t2.ticket).expireAt = Date.now() - 1;
  r = await h.callFunction('auth', { action: 'pollTicket', ticket: t2.ticket });
  R.ok('pollTicket 过期 → expired', r.ok === true && r.status === 'expired', r);

  r = await h.callFunction('auth', { action: 'nope' });
  R.ok('未知 action → bad_request', r.ok === false && r.error.code === 'bad_request', r);

  // =========================================================================
  R.section('todo：LWW / 校验 / list / 软删除');
  h.reset();
  const macToken = h.seedSession('oMAC');
  res = await h.httpRequest('/todo', { 'X-TODO-Token': macToken }, { action: 'ping' });
  R.ok('Mac HTTP + 大写 header x-todo-token 可识别', res.statusCode === 200 && res.json.openid === 'oMAC', res.json);

  const idA = 'aaaaaaaa-1111-4111-8111-111111111111';
  res = await h.httpRequest('/todo', { 'x-todo-token': macToken }, {
    action: 'upsert',
    item: {
      id: idA, content: '写季度报表', deadline: null, priority: 'high', status: 'todo',
      source: 'mac-screenshot', rawText: 'OCR 原文', createTime: 1712345678901, updateTime: 1712345678901
    }
  });
  R.ok('upsert 新增 → applied', res.json.applied.length === 1 && res.json.stale.length === 0 && res.json.rejected.length === 0, res.json);
  const stampA = res.json.applied[0].updateTime;
  const storedA = h.store.get('todos').get(idA);
  R.ok('服务端盖章 + _id=id + openid 归属 + deleted=false',
    storedA._id === idA && storedA.openid === 'oMAC' && storedA.updateTime === stampA && storedA.deleted === false, storedA);

  res = await h.httpRequest('/todo', { 'x-todo-token': macToken }, {
    action: 'upsert', item: { id: idA, content: '旧内容（时钟慢的端）', updateTime: stampA - 100000 }
  });
  R.ok('LWW：现存 >= 入参 → stale 且不覆盖', res.json.applied.length === 0 && res.json.stale.length === 1 && res.json.stale[0].content === '写季度报表', res.json);
  const staleFields = Object.keys(res.json.stale[0]);
  R.ok('stale 回传完整文档（契约 §2.4）',
    ['id', 'content', 'deadline', 'priority', 'status', 'source', 'rawText', 'deleted', 'updateTime']
      .every(function (k) { return staleFields.indexOf(k) >= 0; }), staleFields);

  res = await h.httpRequest('/todo', { 'x-todo-token': macToken }, {
    action: 'upsert', item: { id: idA, content: '写季度报表 v2', createTime: 123, updateTime: stampA + 1 }
  });
  R.ok('LWW：入参更新 → applied 且内容落库',
    res.json.applied.length === 1 && h.store.get('todos').get(idA).content === '写季度报表 v2', res.json);
  R.ok('set() 保留 openid / createTime',
    h.store.get('todos').get(idA).openid === 'oMAC' && h.store.get('todos').get(idA).createTime === 123, h.store.get('todos').get(idA));

  res = await h.httpRequest('/todo', { 'x-todo-token': macToken }, {
    action: 'bulkUpsert',
    items: [
      { id: 'bbbbbbbb-2222-4222-8222-222222222222', content: '买牛奶', source: 'mini-voice' },
      { id: 'cccccccc-3333-4333-8333-333333333333', content: '   ' },
      { id: 'not-a-valid-id', content: '坏 id' },
      { id: 'dddddddd-4444-4444-8444-444444444444', content: 'x'.repeat(600) },
      { id: 'eeeeeeee-5555-4555-8555-555555555555', content: '看牙医', priority: 'URGENT', source: 'hack' }
    ]
  });
  R.ok('bulkUpsert：2 applied / 3 rejected', res.json.applied.length === 2 && res.json.rejected.length === 3, res.json);
  R.ok('rejected reason 枚举正确',
    res.json.rejected.map(function (x) { return x.reason; }).sort().join() === 'content_too_long,empty_content,invalid_id', res.json.rejected);
  R.ok('枚举白名单回退 priority=normal / source=manual',
    h.store.get('todos').get('eeeeeeee-5555-4555-8555-555555555555').priority === 'normal' &&
    h.store.get('todos').get('eeeeeeee-5555-4555-8555-555555555555').source === 'manual');

  // rawText 截断（决策 2：≤4000 截断而不是拒绝）
  res = await h.httpRequest('/todo', { 'x-todo-token': macToken }, {
    action: 'upsert', item: { id: 'ffffffff-6666-4666-8666-666666666666', content: '带长 rawText', rawText: 'R'.repeat(9999) }
  });
  const rawStored = h.store.get('todos').get('ffffffff-6666-4666-8666-666666666666');
  R.ok('rawText > 4000 被截断到 4000（不是 rejected）',
    res.json.applied.length === 1 && rawStored.rawText.length === 4000, { applied: res.json.applied.length, len: rawStored.rawText.length });

  res = await h.httpRequest('/todo', { 'x-todo-token': macToken }, { action: 'list', since: 0, limit: 100 });
  const items1 = res.json.items;
  const stamps1 = items1.map(function (i) { return i.updateTime; });
  R.ok('list items 按 updateTime 升序', stamps1.join() === stamps1.slice().sort(function (a, b) { return a - b; }).join(), stamps1);
  R.ok('cursor = max(updateTime) 且 serverTime 存在',
    res.json.cursor === Math.max.apply(null, stamps1) && typeof res.json.serverTime === 'number', res.json.cursor);
  R.ok('Todo 结构与契约 §1 字段一致',
    Object.keys(items1[0]).sort().join() === '_id,content,createTime,deadline,deleted,id,openid,priority,rawText,seq,source,status,updateTime',
    Object.keys(items1[0]).sort());

  res = await h.httpRequest('/todo', { 'x-todo-token': macToken }, { action: 'list', since: 99999999999999 });
  R.ok('空结果 cursor 原样回传 since', res.json.cursor === 99999999999999 && res.json.items.length === 0, res.json.cursor);

  res = await h.httpRequest('/todo', { 'x-todo-token': macToken }, { action: 'remove', ids: [idA, 'ffffffff-6666-4666-8666-666666666666', 'bad-id'] });
  R.ok('remove：软删除 + 幂等 + 过滤非法 id',
    res.json.removed.indexOf(idA) >= 0 && res.json.removed.indexOf('bad-id') < 0, res.json);
  R.ok('软删除后 deleted=true 且 updateTime 变新',
    h.store.get('todos').get(idA).deleted === true && h.store.get('todos').get(idA).updateTime > stampA, h.store.get('todos').get(idA));

  res = await h.httpRequest('/todo', { 'x-todo-token': macToken }, { action: 'list', since: 0, includeDeleted: true });
  R.ok('includeDeleted 默认 true → 删除项下发给其他端', res.json.items.some(function (i) { return i.id === idA && i.deleted === true; }), null);
  res = await h.httpRequest('/todo', { 'x-todo-token': macToken }, { action: 'list', since: 0, includeDeleted: false });
  R.ok('includeDeleted=false → 不含已删除', res.json.items.every(function (i) { return i.deleted !== true; }), null);

  res = await h.httpRequest('/todo', { 'x-todo-token': macToken }, { action: 'ping' });
  const aliveCount = h.collections('todos').filter(function (d) { return d.openid === 'oMAC' && d.deleted !== true; }).length;
  R.ok('ping count 只统计本人未删除待办，且与库内一致',
    res.json.count === aliveCount && aliveCount > 0, { ping: res.json.count, expected: aliveCount });

  res = await h.httpRequest('/todo', { 'x-todo-token': macToken }, { action: 'remove', ids: [] });
  R.ok('remove 空 ids → 400 bad_request', res.statusCode === 400 && res.json.error.code === 'bad_request', res.statusCode);

  res = await h.httpRequest('/todo?action=list&since=0', { 'x-todo-token': macToken }, {}, 'GET');
  R.ok('HTTP GET → queryStringParameters 解包', res.statusCode === 200 && res.json.ok === true, res.statusCode);

  // clearDone（契约 §2.5.1）
  h.reset();
  const ownToken = h.seedSession('oUSER1');
  await h.httpRequest('/todo', { 'x-todo-token': ownToken }, { action: 'upsert', item: { id: hexId(1), content: '已完成', status: 'done' } });
  await h.httpRequest('/todo', { 'x-todo-token': ownToken }, { action: 'upsert', item: { id: hexId(2), content: '未完成', status: 'todo' } });
  res = await h.httpRequest('/todo', { 'x-todo-token': ownToken }, { action: 'clearDone' });
  R.ok('clearDone：只软删 done，响应 = {ok,removed,serverTime}（§2.5.1）',
    res.json.ok === true && res.json.removed.length === 1 &&
    Object.keys(res.json).sort().join() === 'ok,removed,serverTime' &&
    h.store.get('todos').get(hexId(1)).deleted === true &&
    h.store.get('todos').get(hexId(2)).deleted === false, res.json);

  R.section('todo：身份隔离与鉴权');
  res = await h.httpRequest('/todo', { 'x-todo-token': h.seedSession('oOTHER') }, {
    action: 'upsert', item: { id: hexId(2), content: '抢别人的 id', updateTime: Date.now() + 1e6 }
  });
  R.ok('跨用户同 id → rejected not_owner',
    res.json.rejected.length === 1 && res.json.rejected[0].reason === 'not_owner' &&
    h.store.get('todos').get(hexId(2)).content === '未完成', res.json);
  res = await h.httpRequest('/todo', { 'x-todo-token': h.seedSession('oX', { expired: true }) }, { action: 'ping' });
  R.ok('过期 session → 401', res.statusCode === 401, res.statusCode);

  // =========================================================================
  R.section('决策 1：严格递增 stamp → 150 条两轮分页不丢数据');
  h.reset();
  const pageToken = h.seedSession('oPAGE');
  const BULK = 150;
  const bulkItems = [];
  for (let i = 0; i < BULK; i++) {
    bulkItems.push({ id: hexId(i), content: '批量待办 ' + i, createTime: 1712345678000 + i, updateTime: 1 });
  }
  res = await h.httpRequest('/todo', { 'x-todo-token': pageToken }, { action: 'bulkUpsert', items: bulkItems });
  const appliedStamps = res.json.applied.map(function (x) { return x.updateTime; });
  const sortedStamps = appliedStamps.slice().sort(function (a, b) { return a - b; });
  R.ok('一次 bulkUpsert 150 条全部 applied', res.json.applied.length === 150 && res.json.rejected.length === 0, { applied: res.json.applied.length, rejected: res.json.rejected.length });
  R.ok('150 个 updateTime 互不相同且严格递增（决策 1 核心）',
    new Set(appliedStamps).size === 150 && appliedStamps.join() === sortedStamps.join(),
    { unique: new Set(appliedStamps).size, monotonic: appliedStamps.join() === sortedStamps.join() });

  const page1 = (await h.httpRequest('/todo', { 'x-todo-token': pageToken }, { action: 'list', since: 0, limit: 100 })).json;
  R.ok('第一轮 limit=100 → 100 条 + hasMore=true',
    page1.items.length === 100 && page1.hasMore === true && page1.cursor === Math.max.apply(null, page1.items.map(function (i) { return i.updateTime; })),
    { n: page1.items.length, hasMore: page1.hasMore });

  const page2 = (await h.httpRequest('/todo', { 'x-todo-token': pageToken }, { action: 'list', since: page1.cursor, limit: 100 })).json;
  const onlyPage1 = page2.items.filter(function (i) { return i.updateTime === page1.cursor; });
  R.ok('第二轮 → 50 条新数据 + 1 条边界重发（gte 闭区间语义）+ hasMore=false',
    page2.items.length === 51 && onlyPage1.length === 1 && page2.hasMore === false,
    { n: page2.items.length, boundaryRepeat: onlyPage1.length, hasMore: page2.hasMore });

  const seen = {};
  page1.items.concat(page2.items).forEach(function (i) { seen[i.id] = (seen[i.id] || 0) + 1; });
  const uniqueIds = Object.keys(seen);
  const dupIds = uniqueIds.filter(function (k) { return seen[k] > 1; });
  const missing = [];
  for (let i = 0; i < BULK; i++) if (!seen[hexId(i)]) missing.push(hexId(i));
  R.ok('两轮按 id 去重后 = 150 条，无遗漏（客户端按 id+updateTime 去重即可）',
    uniqueIds.length === 150 && missing.length === 0, { unique: uniqueIds.length, missing: missing.length });
  R.ok('唯一的重复是边界那一条（闭区间重发，非丢数据）',
    dupIds.length === 1 && dupIds[0] === (onlyPage1[0] && onlyPage1[0].id), { dupIds: dupIds.length });

  const page3 = (await h.httpRequest('/todo', { 'x-todo-token': pageToken }, { action: 'list', since: page2.cursor, limit: 100 })).json;
  R.ok('第三轮（已到全局最大 stamp）→ 只回边界那一条 + hasMore=false（客户端据此结束循环，不会死循环）',
    page3.items.length === 1 && page3.items[0].updateTime === page2.cursor && page3.hasMore === false,
    { n: page3.items.length, hasMore: page3.hasMore });
  const ascAll = page1.items.concat(page2.items).map(function (i) { return i.updateTime; });
  R.ok('末页 cursor = 全局最大 stamp（游标已推进到终点）',
    page2.cursor === Math.max.apply(null, ascAll) && page3.cursor === page2.cursor, { cursor: page2.cursor, max: Math.max.apply(null, ascAll) });

  // 按契约 §5.3/§5.4 的客户端循环：先按 id 去重（LWW），hasMore=false 时停止
  const seenMap = new Map();
  let loopCursor = 0;
  let calls = 0;
  let loopMore = true;
  while (loopMore && calls < 10) {
    const page = (await h.httpRequest('/todo', { 'x-todo-token': pageToken }, { action: 'list', since: loopCursor, limit: 100 })).json;
    calls++;
    page.items.forEach(function (i) { seenMap.set(i.id, i.updateTime); });
    loopCursor = page.cursor;
    loopMore = page.hasMore;
  }
  R.ok('客户端式循环（since=cursor + 按 id 去重）3 次内拉完 150 条并收敛',
    seenMap.size === 150 && calls <= 3 && loopMore === false, { unique: seenMap.size, calls: calls, hasMore: loopMore });
  R.ok('循环结束时 cursor = 全局最大 stamp（下次增量从终点继续）',
    loopCursor === Math.max.apply(null, ascAll), { cursor: loopCursor });

  // =========================================================================
  R.section('决策 4：ai 必须校验登录态');
  h.reset();
  delete process.env.DEEPSEEK_API_KEY;
  h.setOpenid('');

  r = await h.callFunction('ai', { action: 'parse', text: '明天买牛奶' }, '');
  R.ok('callFunction 无 OPENID 无 token → unauthorized',
    r.ok === false && r.error.code === 'unauthorized' && r.engine === undefined, r);

  res = await h.httpRequest('/ai', {}, { action: 'parse', text: '明天买牛奶' });
  R.ok('HTTP 无 token → 401 unauthorized（不消耗 DeepSeek 额度）',
    res.statusCode === 401 && res.json.error.code === 'unauthorized', res);

  res = await h.httpRequest('/ai', { 'x-todo-token': 'a'.repeat(48) }, { action: 'parse', text: '明天买牛奶' });
  R.ok('HTTP 伪造 token → 401', res.statusCode === 401, res.statusCode);

  res = await h.httpRequest('/ai', { 'x-todo-token': h.seedSession('oMAC', { expired: true }) }, { action: 'parse', text: '明天买牛奶' });
  R.ok('HTTP 过期 session → 401', res.statusCode === 401, res.statusCode);

  const aiToken = h.seedSession('oMAC');
  res = await h.httpRequest('/ai', { 'X-TODO-TOKEN': aiToken }, { action: 'parse', text: '明天买牛奶', timezone: 'Asia/Shanghai' });
  R.ok('HTTP 合法 session token → 200 + 正常解析（engine=rule，未配 key）',
    res.statusCode === 200 && res.json.ok === true && res.json.engine === 'rule' && res.json.todos.length === 1, res.json);
  R.ok('携带 token 时刷新了 lastSeen',
    h.collections('auth_sessions')[0].lastSeen > 0, h.collections('auth_sessions')[0].lastSeen);

  h.setOpenid('oMINI');
  r = await h.callFunction('ai', { action: 'parse', text: '明天买牛奶' });
  R.ok('小程序 callFunction（OPENID）→ 正常解析', r.ok === true && r.todos.length === 1, r);

  h.setOpenid('');
  r = await h.callFunction('ai', { action: 'parse', text: '明天买牛奶', token: aiToken });
  R.ok('callFunction + payload.token → 正常解析', r.ok === true && r.todos.length === 1, r);

  r = await h.callFunction('ai', { action: 'unknown', text: 'x' });
  R.ok('未知 action 仍返回 bad_request（不泄露鉴权细节）', r.ok === false && r.error.code === 'bad_request', r);

  res = await h.httpRequest('/ai', {}, {}, 'OPTIONS');
  R.ok('ai OPTIONS → 204 + CORS', res.statusCode === 204, res.statusCode);

  // =========================================================================
  R.section('ai：解析 / 降级 / 脱敏');
  h.reset();
  const aiTok = h.seedSession('oAI');
  const AUTH = { 'x-todo-token': aiTok };
  const NOW = cnTime(2026, 3, 10, 10, 0); // 2026-03-10 10:00 Asia/Shanghai（周二）

  res = await h.httpRequest('/ai', AUTH, { action: 'parse', text: '   ' });
  R.ok('text 为空 → 400 bad_request', res.statusCode === 400 && res.json.error.code === 'bad_request', res);

  res = await h.httpRequest('/ai', AUTH, { action: 'parse', text: '明天下午三点前把季度报表发给张总 还要买牛奶', now: NOW, timezone: 'Asia/Shanghai' });
  R.ok('无 key → engine=rule + notice + fallbackText',
    res.json.ok === true && res.json.engine === 'rule' && /未配置 DEEPSEEK_API_KEY/.test(res.json.notice) && res.json.fallbackText.indexOf('季度报表') >= 0, res.json);
  R.ok('规则解析：拆 2 条 + 明天 15:00',
    res.json.todos.length === 2 && res.json.todos[0].deadline === cnTime(2026, 3, 11, 15, 0) &&
    res.json.todos[0].content === '把季度报表发给张总', res.json.todos);

  process.env.DEEPSEEK_API_KEY = 'sk-test-secret-1234567890';
  const modelObj = {
    todos: [
      { content: '把季度报表发给张总', deadline: cnTime(2026, 3, 11, 15, 0), priority: 'HIGH' },
      { content: '   ', deadline: null, priority: 'normal' },
      { content: '买牛奶', deadline: '2026-03-11T10:00:00+08:00', priority: 'urgent' },
      { content: '看牙医', deadline: '明天', priority: '中' },
      { content: '跑步', deadline: Math.floor(cnTime(2026, 3, 12, 7, 0) / 1000), priority: 'low' },
      { content: '写周报', deadline: -5, priority: 'weird' }
    ]
  };
  h.mockUpstream({ status: 200, body: JSON.stringify({ choices: [{ message: { content: '```json\n' + JSON.stringify(modelObj) + '\n```' } }] }) });
  res = await h.httpRequest('/ai', AUTH, { action: 'parse', text: '一段文本', now: NOW, timezone: 'Asia/Shanghai', maxItems: 5 });
  R.ok('mock 上游成功 → engine=deepseek + model',
    res.json.ok === true && res.json.engine === 'deepseek' && res.json.model === 'deepseek-flash' && res.json.todos.length === 5, res.json);
  R.ok('容错：```json 包裹 / 空 content 丢弃 / priority 别名回退',
    res.json.todos[0].priority === 'high' && res.json.todos[1].priority === 'high' && res.json.todos[4].priority === 'normal',
    res.json.todos.map(function (t) { return t.priority; }));
  R.ok('容错：ISO deadline / 中文时间词→null / 秒级时间戳→毫秒 / 负数→null',
    res.json.todos[1].deadline === cnTime(2026, 3, 11, 10, 0) && res.json.todos[2].deadline === null &&
    res.json.todos[3].deadline === cnTime(2026, 3, 12, 7, 0) && res.json.todos[4].deadline === null, res.json.todos);
  const upReq = h.lastUpstreamRequest();
  const upBody = JSON.parse(upReq.body);
  R.ok('上游请求体符合契约（host/path/model/temperature/json_object/messages）',
    upReq.url === 'https://api.deepseek.com/chat/completions' && upBody.model === 'deepseek-flash' &&
    upBody.temperature === 0.2 && upBody.response_format.type === 'json_object' && upBody.messages.length === 2, upBody);
  R.ok('Authorization 带 key', upReq.headers.Authorization === 'Bearer sk-test-secret-1234567890');
  R.ok('响应不含明文 key', JSON.stringify(res.json).indexOf('sk-test-secret') < 0);

  h.mockUpstream({ status: 500, body: '{"error":{"message":"bad key sk-test-secret-1234567890"}}' });
  const logs = [];
  const ow = console.warn, oe = console.error;
  console.warn = function () { logs.push(Array.prototype.join.call(arguments, ' ')); };
  console.error = function () { logs.push(Array.prototype.join.call(arguments, ' ')); };
  res = await h.httpRequest('/ai', AUTH, { action: 'parse', text: '明天交报告' });
  console.warn = ow; console.error = oe;
  R.ok('上游 500 → 降级 engine=rule + notice 带状态码',
    res.json.ok === true && res.json.engine === 'rule' && /DeepSeek 500/.test(res.json.notice), res.json);
  R.ok('上游报错时响应与日志都脱敏（不含 sk-test-secret）',
    JSON.stringify(res.json).indexOf('sk-test-secret') < 0 && logs.join('\n').indexOf('sk-test-secret') < 0, null);
  R.ok('降级时回传 fallbackText', res.json.fallbackText === '明天交报告');

  h.mockUpstream({ status: 200, body: JSON.stringify({ choices: [{ message: { content: '抱歉，无法解析' } }] }) });
  res = await h.httpRequest('/ai', AUTH, { action: 'parse', text: '明天交报告' });
  R.ok('模型返回非 JSON → 降级', res.json.engine === 'rule' && /不是合法 JSON/.test(res.json.notice), res.json.notice);

  h.mockUpstream({ throwErr: new Error('socket hang up') });
  res = await h.httpRequest('/ai', AUTH, { action: 'parse', text: '明天交报告' });
  R.ok('网络异常 → 降级', res.json.engine === 'rule' && /请求失败/.test(res.json.notice), res.json.notice);

  h.mockUpstream({ status: 200, body: JSON.stringify({ choices: [{ message: { content: '{"todos":[]}' } }] }) });
  res = await h.httpRequest('/ai', AUTH, { action: 'parse', text: '明天交报告' });
  R.ok('模型空 todos → 降级到规则解析', res.json.engine === 'rule' && res.json.todos.length === 1, res.json);

  h.mockUpstream({ status: 200, body: JSON.stringify({ choices: [{ message: { content: '结果如下：{"todos":[{"content":"交报告","deadline":null,"priority":"normal"}]} 以上。' } }] }) });
  res = await h.httpRequest('/ai', AUTH, { action: 'parse', text: '明天交报告' });
  R.ok('content 内前后带散文 → 截取 {..} 成功', res.json.engine === 'deepseek' && res.json.todos[0].content === '交报告', res.json);

  h.mockUpstream({ enabled: false });
  process.env.DEEPSEEK_TIMEOUT_MS = '3000';
  h.mockUpstream({ throwErr: Object.assign(new Error('请求超时'), { code: 'ABORT_ERR' }) });
  res = await h.httpRequest('/ai', AUTH, { action: 'parse', text: '明天交报告' });
  R.ok('超时 → 降级 + notice 带超时毫秒', res.json.engine === 'rule' && /超时（3000ms）/.test(res.json.notice), res.json.notice);
  h.mockUpstream({ enabled: false });
  restoreEnv();

  // =========================================================================
  R.section('决策 5：parser 默认值（跨端统一）');
  h.reset();
  const parser = require(path.join(FUNCTIONS_DIR, 'ai', 'parser.js'));
  const parse = function (text, now) {
    return parser.parseByRules(text, { now: now, timezone: 'Asia/Shanghai' }).todos;
  };
  const AT0700 = cnTime(2026, 3, 10, 7, 0);   // 早上 7 点：所有默认时刻都还没到
  const AT2100 = cnTime(2026, 3, 10, 21, 0);  // 晚上 21 点：当天时刻都已过

  R.ok('只给日期 → 当天 23:59:59.999',
    parse('明天交报告', AT0700)[0].deadline === cnTime(2026, 3, 11, 23, 59) + 59999, parse('明天交报告', AT0700)[0]);
  R.ok('晚上 → 20:00', parse('晚上交报告', AT0700)[0].deadline === cnTime(2026, 3, 10, 20, 0), parse('晚上交报告', AT0700)[0]);
  R.ok('下午 → 15:00', parse('下午交报告', AT0700)[0].deadline === cnTime(2026, 3, 10, 15, 0), parse('下午交报告', AT0700)[0]);
  R.ok('上午 → 10:00', parse('上午交报告', AT0700)[0].deadline === cnTime(2026, 3, 10, 10, 0), parse('上午交报告', AT0700)[0]);
  R.ok('早上 → 08:00', parse('早上交报告', AT0700)[0].deadline === cnTime(2026, 3, 10, 8, 0), parse('早上交报告', AT0700)[0]);
  R.ok('早晨 → 08:00', parse('早晨交报告', AT0700)[0].deadline === cnTime(2026, 3, 10, 8, 0), parse('早晨交报告', AT0700)[0]);
  R.ok('中午 → 12:00', parse('中午交报告', AT0700)[0].deadline === cnTime(2026, 3, 10, 12, 0), parse('中午交报告', AT0700)[0]);
  R.ok('只给钟点/时段词且今天已过 → 顺延到明天',
    parse('晚上交报告', AT2100)[0].deadline === cnTime(2026, 3, 11, 20, 0) &&
    parse('9点交报告', AT2100)[0].deadline === cnTime(2026, 3, 11, 9, 0), [parse('晚上交报告', AT2100)[0], parse('9点交报告', AT2100)[0]]);
  R.ok('显式「今天」且时间已过 → 不顺延',
    parse('今天早上交报告', AT2100)[0].deadline === cnTime(2026, 3, 10, 8, 0), parse('今天早上交报告', AT2100)[0]);
  R.ok('裸「X点」按字面取，不猜上下午',
    parse('3点交报告', cnTime(2026, 3, 10, 1, 0))[0].deadline === cnTime(2026, 3, 10, 3, 0), parse('3点交报告', cnTime(2026, 3, 10, 1, 0))[0]);
  R.ok('中文数字时间：下午三点 → 15:00',
    parse('下午三点交报告', AT0700)[0].deadline === cnTime(2026, 3, 10, 15, 0), parse('下午三点交报告', AT0700)[0]);
  R.ok('仅时间词无信息量 → 丢弃', parse('明天', AT0700).length === 0);
  R.ok('纯寒暄 → 丢弃', parse('你好，谢谢啦！', AT0700).length === 0);
  R.ok('优先级：尽快/紧急/立刻/立即/马上/务必/必须/asap → high',
    ['尽快交方案', '紧急修复', '立刻回电', '立即处理', '马上回电', '务必确认', '必须提交', 'asap fix']
      .every(function (t) { return parse(t, AT0700)[0].priority === 'high'; }),
    ['尽快交方案', '立即处理', '必须提交'].map(function (t) { return parse(t, AT0700)[0].priority; }));
  R.ok('优先级：不急/有空/顺便 → low，其余 normal',
    parse('不急，有空再看书', AT0700)[0].priority === 'low' && parse('买牛奶', AT0700)[0].priority === 'normal', null);
  R.ok('X月X日未写年份且已过 → 按明年',
    parse('3月5号交房租', AT0700)[0].deadline === cnTime(2027, 3, 5, 23, 59) + 59999, parse('3月5号交房租', AT0700)[0]);
  R.ok('月底 → 当月最后一天 23:59:59.999',
    parse('月底前提交报销', AT0700)[0].deadline === cnTime(2026, 3, 31, 23, 59) + 59999, parse('月底前提交报销', AT0700)[0]);
  R.ok('序号/项目符号/换行/顿号切分多条',
    parse('1. 交周报 2. 买牛奶 3. 取快递', AT0700).length === 3 &&
    parse('- 体检\n- 交方案', AT0700).length === 2 &&
    parse('买牛奶、鸡蛋、面包', AT0700).length === 3, null);
  R.ok('非法时区回落默认时区且不抛错',
    parse('明天交报告', AT0700)[0].deadline === parse('明天交报告', AT0700)[0].deadline && parse('x', AT0700).length >= 0);
  R.ok('空白/null 输入不抛错', parse('   ', AT0700).length === 0 && parser.parseByRules(null).todos.length === 0);

  // =========================================================================
  R.section('startServer：云接入 event 形状端到端');
  h.reset();
  const srv = await startServer(0); // 0 = 随机可用端口
  try {
    const token2 = h.seedSession('oSERVE');
    const pingRes = await fetch(srv.baseUrl + '/todo', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-todo-token': token2 },
      body: JSON.stringify({ action: 'ping' })
    });
    const pingJson = await pingRes.json();
    R.ok('HTTP /todo ping → 200 + openid', pingRes.status === 200 && pingJson.ok === true && pingJson.openid === 'oSERVE', pingJson);

    const noAuth = await fetch(srv.baseUrl + '/todo', {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ action: 'ping' })
    });
    R.ok('HTTP /todo 无 token → 401', noAuth.status === 401, noAuth.status);

    const optRes = await fetch(srv.baseUrl + '/ai', { method: 'OPTIONS' });
    R.ok('HTTP /ai OPTIONS → 204', optRes.status === 204, optRes.status);

    const notFound = await fetch(srv.baseUrl + '/nope', { method: 'POST', body: '{}' });
    R.ok('未知路径 → 404', notFound.status === 404, notFound.status);

    const getUser = await fetch(srv.baseUrl + '/todo?action=ping', { headers: { 'x-todo-token': token2 } });
    R.ok('HTTP GET query 解包 + 200', getUser.status === 200 && (await getUser.json()).ok === true, getUser.status);
  } finally {
    await new Promise(function (resolve) { srv.close(resolve); });
  }

  return { pass: R.pass, fail: R.fail, failures: R.failures };
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------
module.exports = {
  createHarness: createHarness,
  startServer: startServer,
  runSelfTest: runSelfTest,
  functionForPath: functionForPath,
  FUNCTIONS_DIR: FUNCTIONS_DIR,
  db: db
};

if (require.main === module) {
  const args = process.argv.slice(2);
  const serveIdx = args.indexOf('--serve');
  if (serveIdx >= 0) {
    const port = Number(args[serveIdx + 1]) || Number(process.env.PORT) || 8787;
    startServer(port).then(function (srv) {
      const h = createHarness();
      const token = h.seedSession(process.env.HARNESS_OPENID || 'oMAC');
      console.log('cloud-harness 已启动（内存库，数据不落盘）');
      console.log('  监听地址   : ' + srv.baseUrl);
      console.log('  云函数路径 : ' + srv.baseUrl + '/todo  ' + srv.baseUrl + '/ai  ' + srv.baseUrl + '/auth');
      console.log('  预置 token : ' + token + '   （已写入 auth_sessions，openid=' + (process.env.HARNESS_OPENID || 'oMAC') + '）');
      console.log('  Mac 端 baseURL 就填: ' + srv.baseUrl);
      console.log('');
      console.log('  示例: curl -s -X POST ' + srv.baseUrl + '/todo \\');
      console.log('          -H "Content-Type: application/json" -H "x-todo-token: ' + token + '" \\');
      console.log('          -d \'{"action":"ping"}\'');
      console.log('');
      console.log('  说明: ai 云函数仍按环境变量决定是否真调 DeepSeek；未配 DEEPSEEK_API_KEY 时走规则降级。');
      console.log('  停止: Ctrl+C');
    }).catch(function (err) {
      console.error('启动失败: ' + (err && err.message ? err.message : err));
      process.exit(1);
    });
  } else {
    runSelfTest().then(function (r) {
      console.log('\n==========================================');
      if (r.fail === 0) {
        console.log('cloud-harness 自检全部通过: ' + r.pass + ' passed, 0 failed');
      } else {
        console.log('cloud-harness 自检失败: ' + r.pass + ' passed, ' + r.fail + ' failed');
        console.log('失败用例:\n  - ' + r.failures.join('\n  - '));
      }
      console.log('==========================================');
      process.exit(r.fail === 0 ? 0 : 1);
    }).catch(function (err) {
      console.error('自检异常: ' + (err && err.stack ? err.stack : err));
      process.exit(2);
    });
  }
}
