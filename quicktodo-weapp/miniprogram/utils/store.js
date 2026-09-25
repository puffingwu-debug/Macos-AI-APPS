/**
 * store.js —— 本地数据仓库（缓存 + outbox + LWW 合并 + 契约 §5.5 排序）
 *
 * 设计要点（对应契约 §5）：
 *  1) 本地优先：任何增删改「先写本地」并立即 emit，UI 永不等待网络（§5.1）。
 *  2) outbox：写本地时同一条变更进队列，由 utils/sync.js 按序上抛，失败保留（§5.2）。
 *  3) LWW：updateTime 是唯一权威时钟，但服务端才是盖章方（§1.1/§5.4）。
 *     本地为了让「离线连改」不被自己判成 stale，采用 updateTime = max(now, prev+1) 保证单调递增。
 *  4) 排序严格按契约 §5.5（见 sortTodos）。
 *  5) 云端不认识的字段一律不落库：只保留契约 §1 定义的字段（openid 由服务端填充，客户端永不传）。
 */

const KEYS = {
  TODOS: 'qt_todos_v1',
  OUTBOX: 'qt_outbox_v1',
  CURSOR: 'qt_cursor_v1',
  META: 'qt_meta_v1',
  SERVER_TIME: 'qt_server_time_v1' // 逻辑时钟水位（契约 §1.1），单独存；「清空本地缓存」不重置它
};

const PRIORITY_WEIGHT = { high: 0, normal: 1, low: 2 };
const VALID_PRIORITY = ['high', 'normal', 'low'];
const VALID_SOURCE = ['mac-screenshot', 'mini-voice', 'manual'];
const STATUS = ['todo', 'done'];
const MAX_CONTENT = 500; // 契约 §1.1：最长 500 字
const MAX_RAWTEXT = 4000;
const TOMBSTONE_TTL = 7 * 86400000; // 墓碑本地保留 7 天，避免缓存无限膨胀

const state = {
  inited: false,
  todos: {}, // id -> todo（含已删除墓碑）
  outbox: [], // [{ key, op:'upsert'|'remove', id, item?, at }]
  cursor: 0, // 增量拉取游标 = 上次 list 响应的 cursor
  meta: {}, // { lastSyncAt, lastError, lastRejected, lastStale }
  lastServerTime: 0, // 见过的最大服务端 serverTime（持久化，逻辑时钟水位）
  listeners: [],
  seq: 0 // outbox key 自增计数
};

/** 本机上次发号（逻辑时钟，运行期内存值；冷启动时由缓存里的最大 updateTime 初始化） */
let lastIssued = 0;

/* ============================ 基础工具 ============================ */

function nowMs() {
  return Date.now();
}

/** UUID v4（小写带连字符）。小程序无 crypto，用 Math.random 拼装，够用且满足契约正则 */
function uuid() {
  let s = '';
  for (let i = 0; i < 32; i++) {
    if (i === 12) s += '4';
    else if (i === 16) s += (((Math.random() * 4) | 0) + 8).toString(16);
    else s += ((Math.random() * 16) | 0).toString(16);
  }
  return s.slice(0, 8) + '-' + s.slice(8, 12) + '-' + s.slice(12, 16) + '-' + s.slice(16, 20) + '-' + s.slice(20);
}

function normalizeContent(v) {
  return String(v === null || v === undefined ? '' : v)
    .replace(/[\r\n\t]+/g, ' ')
    .replace(/\s{2,}/g, ' ')
    .trim()
    .slice(0, MAX_CONTENT);
}

function normalizePriority(p) {
  return VALID_PRIORITY.indexOf(p) >= 0 ? p : 'normal';
}

function normalizeSource(s) {
  return VALID_SOURCE.indexOf(s) >= 0 ? s : 'manual';
}

function normalizeStatus(s) {
  return STATUS.indexOf(s) >= 0 ? s : 'todo';
}

/** deadline：null 或 Unix 毫秒（>0），其余一律归一为 null */
function normalizeDeadline(d) {
  if (d === null || d === undefined || d === '') return null;
  const n = Number(d);
  if (!isFinite(n) || n <= 0) return null;
  return Math.round(n);
}

function normalizeRawText(v) {
  return String(v === null || v === undefined ? '' : v).slice(0, MAX_RAWTEXT);
}

/**
 * 逻辑时间戳（契约 §1.1 客户端上抛临时值，HLC-lite）：
 *   stamp = max(本机时间, 见过的最大 serverTime + 1, 本机上次发号 + 1, 该条现有版本 + 1)
 *
 * 为什么不能只用本机时钟：若手机时间比服务器慢（例如慢 10 分钟），离线改动上抛时
 * 服务端 existing.updateTime >= 入参 updateTime 会判 stale，并把服务端旧版本回给客户端，
 * 于是用户刚改的内容"自己变回去"（静默数据丢失）。抬到服务端水位之上即可根治。
 * 第 4 项（prev + 1）保留原有性质：同一条待办连改多次，时间戳严格递增。
 */
function nextUpdateTime(prev) {
  const p = Number(prev) || 0;
  const stamp = Math.max(nowMs(), state.lastServerTime + 1, lastIssued + 1, p + 1);
  lastIssued = stamp;
  return stamp;
}

/**
 * 用云函数响应里的 serverTime 抬高本机水位（契约 §2.3/§2.4/§2.5 都带 serverTime）。
 * 只在前进时落盘，避免每次同步都写一次 storage。
 */
function observeServerTime(t) {
  const n = Number(t) || 0;
  if (!isFinite(n) || n <= 0) return state.lastServerTime;
  if (n > state.lastServerTime) {
    state.lastServerTime = n;
    try {
      wx.setStorageSync(KEYS.SERVER_TIME, n);
    } catch (e) {
      console.log('[qt:store] 服务端水位写入失败：' + (e && e.errMsg ? e.errMsg : e));
    }
  }
  return state.lastServerTime;
}

function getLastServerTime() {
  return state.lastServerTime;
}

/** 只保留契约字段的「上行对象」：绝不带 openid / _id / seq。
 *  这里再兜一次长度截断（契约 §1.1：content ≤500、rawText ≤4000），
 *  保证任何进入 outbox 的条目都合法——云函数对超长 content 是直接 rejected，不会替我们截断。 */
function toWire(t) {
  return {
    id: t.id,
    content: normalizeContent(t.content),
    deadline: t.deadline === undefined ? null : t.deadline,
    priority: t.priority,
    status: t.status,
    source: t.source,
    rawText: normalizeRawText(t.rawText),
    createTime: Number(t.createTime) || 0,
    updateTime: Number(t.updateTime) || 0
  };
}

/** 云函数返回的文档 → 本地结构（丢弃 openid / _id / seq 等仅服务端字段） */
function fromServer(raw) {
  const r = raw || {};
  return {
    id: String(r.id || r._id || ''),
    content: normalizeContent(r.content),
    deadline: normalizeDeadline(r.deadline),
    priority: normalizePriority(r.priority),
    status: normalizeStatus(r.status),
    source: normalizeSource(r.source),
    rawText: normalizeRawText(r.rawText),
    deleted: r.deleted === true,
    createTime: Number(r.createTime) || nowMs(),
    updateTime: Number(r.updateTime) || 0
  };
}

/* ============================ 持久化 ============================ */

function persist() {
  try {
    const arr = [];
    const map = state.todos;
    for (const k in map) {
      if (Object.prototype.hasOwnProperty.call(map, k)) arr.push(map[k]);
    }
    wx.setStorageSync(KEYS.TODOS, arr);
    wx.setStorageSync(KEYS.OUTBOX, state.outbox);
    wx.setStorageSync(KEYS.CURSOR, state.cursor);
    wx.setStorageSync(KEYS.META, state.meta);
  } catch (e) {
    console.log('[qt:store] 本地缓存写入失败：' + (e && e.errMsg ? e.errMsg : e));
  }
}

function persistTodosOnly() {
  try {
    const arr = [];
    const map = state.todos;
    for (const k in map) {
      if (Object.prototype.hasOwnProperty.call(map, k)) arr.push(map[k]);
    }
    wx.setStorageSync(KEYS.TODOS, arr);
  } catch (e) {
    console.log('[qt:store] 待办缓存写入失败：' + (e && e.errMsg ? e.errMsg : e));
  }
}

function init() {
  if (state.inited) return state;
  try {
    const todos = wx.getStorageSync(KEYS.TODOS);
    if (todos && todos.length) {
      for (let i = 0; i < todos.length; i++) {
        const t = fromServer(todos[i]);
        if (t.id) state.todos[t.id] = t;
      }
    }
    const outbox = wx.getStorageSync(KEYS.OUTBOX);
    if (outbox && outbox.length) {
      state.outbox = outbox;
      for (let i = 0; i < outbox.length; i++) {
        const k = Number(outbox[i].key) || 0;
        if (k > state.seq) state.seq = k;
      }
    }
    state.cursor = Number(wx.getStorageSync(KEYS.CURSOR)) || 0;
    const meta = wx.getStorageSync(KEYS.META);
    state.meta = meta && typeof meta === 'object' ? meta : {};
    // 逻辑时钟水位：持久化的服务端水位 + 缓存里已有的最大版本（含 outbox 里待上抛的），
    // 保证冷启动后第一次发号也不会低于任何已知版本
    state.lastServerTime = Number(wx.getStorageSync(KEYS.SERVER_TIME)) || 0;
    lastIssued = state.lastServerTime;
    for (const k in state.todos) {
      if (!Object.prototype.hasOwnProperty.call(state.todos, k)) continue;
      const u = Number(state.todos[k].updateTime) || 0;
      if (u > lastIssued) lastIssued = u;
    }
    for (let i = 0; i < state.outbox.length; i++) {
      const it = state.outbox[i].item;
      const u = it ? Number(it.updateTime) || 0 : 0;
      if (u > lastIssued) lastIssued = u;
    }
  } catch (e) {
    console.log('[qt:store] 缓存读取失败，按空数据启动：' + (e && e.errMsg ? e.errMsg : e));
  }
  state.inited = true;
  return state;
}

/* ============================ 订阅/事件 ============================ */

function subscribe(fn) {
  if (typeof fn !== 'function') return function () {};
  state.listeners.push(fn);
  return function unsubscribe() {
    const i = state.listeners.indexOf(fn);
    if (i >= 0) state.listeners.splice(i, 1);
  };
}

function emit() {
  for (let i = 0; i < state.listeners.length; i++) {
    try {
      state.listeners[i]();
    } catch (e) {
      console.log('[qt:store] 监听回调异常：' + (e && e.message ? e.message : e));
    }
  }
}

/* ============================ 读取 ============================ */

function get(id) {
  return state.todos[id] || null;
}

/** 全部未删除待办 */
function all() {
  const out = [];
  const map = state.todos;
  for (const k in map) {
    if (!Object.prototype.hasOwnProperty.call(map, k)) continue;
    const t = map[k];
    if (t && !t.deleted) out.push(t);
  }
  return out;
}

function weight(p) {
  const w = PRIORITY_WEIGHT[p];
  return w === undefined ? 1 : w;
}

function cmpDeadline(a, b) {
  const da = a === null || a === undefined ? null : Number(a);
  const db = b === null || b === undefined ? null : Number(b);
  if (da === null && db === null) return 0;
  if (da === null) return 1; // null 排最后
  if (db === null) return -1;
  return da - db;
}

/**
 * 契约 §5.5 排序（两端必须一致）
 *  - 分组：status === 'done' 归已完成，其余归未完成；未完成在前
 *  - 未完成：priority 权重(high0/normal1/low2) 升序 → deadline 升序(null 最后) → createTime 降序
 *  - 已完成：updateTime 降序 → 同毫秒时 createTime 降序兜底（避免列表跳动）
 *  - order='createTime' 时未完成组改为 createTime 降序（Mac 端可切换的那套规则，这里保留能力）
 */
function sortTodos(list, order) {
  const undone = [];
  const done = [];
  for (let i = 0; i < list.length; i++) {
    if (list[i].status === 'done') done.push(list[i]);
    else undone.push(list[i]);
  }
  if (order === 'createTime') {
    undone.sort(function (a, b) {
      return (Number(b.createTime) || 0) - (Number(a.createTime) || 0);
    });
  } else {
    undone.sort(function (a, b) {
      const w = weight(a.priority) - weight(b.priority);
      if (w !== 0) return w;
      const d = cmpDeadline(a.deadline, b.deadline);
      if (d !== 0) return d;
      return (Number(b.createTime) || 0) - (Number(a.createTime) || 0);
    });
  }
  done.sort(function (a, b) {
    const u = (Number(b.updateTime) || 0) - (Number(a.updateTime) || 0);
    if (u !== 0) return u;
    return (Number(b.createTime) || 0) - (Number(a.createTime) || 0);
  });
  return undone.concat(done);
}

/**
 * @param {string} filter 'all' | 'todo' | 'done'
 * @param {string} [order] 'smart'(默认,契约 §5.5) | 'createTime'
 */
function getList(filter, order) {
  const arr = all().filter(function (t) {
    if (filter === 'todo') return t.status !== 'done';
    if (filter === 'done') return t.status === 'done';
    return true;
  });
  return sortTodos(arr, order);
}

function counts() {
  let a = 0;
  let todo = 0;
  let done = 0;
  const arr = all();
  for (let i = 0; i < arr.length; i++) {
    a++;
    if (arr[i].status === 'done') done++;
    else todo++;
  }
  return { all: a, todo: todo, done: done };
}

/* ============================ outbox ============================ */

let outboxKey = 0;

function nextKey() {
  state.seq += 1;
  outboxKey = state.seq;
  return outboxKey;
}

function findOutboxIndex(id) {
  for (let i = 0; i < state.outbox.length; i++) {
    if (state.outbox[i].id === id) return i;
  }
  return -1;
}

/**
 * 入队 upsert。同一 id 的旧条目被「替换」（新的 key），
 * 这样即使旧条目正在上抛，落库回执也不会误删新条目（新 key 不在丢弃列表里）。
 */
function enqueueUpsert(item) {
  const entry = { key: nextKey(), op: 'upsert', id: item.id, item: toWire(item), at: nowMs() };
  const idx = findOutboxIndex(item.id);
  if (idx >= 0) state.outbox[idx] = entry;
  else state.outbox.push(entry);
}

/** 入队 remove；若同一 id 还有未上抛的 upsert，直接替换为 remove（本地已删，无需再创建） */
function enqueueRemove(id) {
  const entry = { key: nextKey(), op: 'remove', id: id, at: nowMs() };
  const idx = findOutboxIndex(id);
  if (idx >= 0) state.outbox[idx] = entry;
  else state.outbox.push(entry);
}

function outboxSize() {
  return state.outbox.length;
}

function peekOutbox(limit) {
  const n = Number(limit) || state.outbox.length;
  return state.outbox.slice(0, Math.max(0, n));
}

/** 按 key 丢弃已成功上抛的条目（不按下标，避免并发写入错位） */
function dropOutbox(keys) {
  if (!keys || !keys.length) return 0;
  const set = {};
  for (let i = 0; i < keys.length; i++) set[keys[i]] = true;
  const before = state.outbox.length;
  state.outbox = state.outbox.filter(function (e) {
    return !set[e.key];
  });
  const removed = before - state.outbox.length;
  if (removed > 0) {
    persist();
    emit();
  }
  return removed;
}

/** 读取 outbox 条目当前对应的本地待办（不存在则说明已被删除） */
function outboxItem(entry) {
  if (!entry) return null;
  return state.todos[entry.id] || null;
}

/* ============================ 写入（本地优先） ============================ */

/** 构造一条新待办（不落库，供批量导入时先组数据） */
function makeTodo(input) {
  const src = input || {};
  const t = nowMs();
  return {
    id: src.id || uuid(),
    content: normalizeContent(src.content),
    deadline: normalizeDeadline(src.deadline),
    priority: normalizePriority(src.priority),
    status: normalizeStatus(src.status),
    source: normalizeSource(src.source),
    rawText: normalizeRawText(src.rawText),
    deleted: false,
    // createTime 用本机时钟（契约 §1.1：客户端生成，用于展示与排序）
    createTime: Number(src.createTime) || t,
    // updateTime 用逻辑时间戳（契约 §1.1）：新建也必须在服务端水位之上，
    // 批量导入时每条依次 +1 保证严格递增
    updateTime: Number(src.updateTime) || nextUpdateTime(0)
  };
}

/**
 * 批量写入本地 + 入队（手动新增 / 编辑 / AI 导入 / 语音导入四条路径共用），只 persist/emit 一次。
 * 契约 §1.1：content 去空格后必须 1–500 字，空内容云函数会拒收（rejected），
 * 所以在入口就把空内容的条目挡掉，避免「写进去又被云端删掉」的假成功。
 */
function putMany(items) {
  const list = items || [];
  if (!list.length) return [];
  const accepted = [];
  for (let i = 0; i < list.length; i++) {
    const it = list[i];
    if (!it || !it.id) continue;
    // makeTodo/updateTodo 已做 slice(0,500)，这里再确认一次非空
    if (!it.content) {
      console.log('[qt:store] 丢弃空内容待办 id=' + it.id);
      continue;
    }
    state.todos[it.id] = it;
    enqueueUpsert(it);
    accepted.push(it);
  }
  if (!accepted.length) return accepted;
  persist();
  emit();
  return accepted;
}

function put(item) {
  return putMany([item])[0];
}

function createTodo(input) {
  return put(makeTodo(input));
}

/** 局部更新（编辑/勾选）：保留 id/createTime/source，盖本地新 updateTime */
function updateTodo(id, patch) {
  const prev = state.todos[id];
  if (!prev) return null;
  const p = patch || {};
  const next = {
    id: prev.id,
    content: p.content !== undefined ? normalizeContent(p.content) : prev.content,
    deadline: p.deadline !== undefined ? normalizeDeadline(p.deadline) : prev.deadline,
    priority: p.priority !== undefined ? normalizePriority(p.priority) : prev.priority,
    status: p.status !== undefined ? normalizeStatus(p.status) : prev.status,
    source: prev.source,
    rawText: p.rawText !== undefined ? normalizeRawText(p.rawText) : prev.rawText,
    deleted: false,
    createTime: prev.createTime,
    updateTime: nextUpdateTime(prev.updateTime)
  };
  // 契约 §1.1：content 不允许为空（云端会 rejected）。空内容视为无效编辑，保持原值。
  if (!next.content) {
    console.log('[qt:store] 编辑内容为空，已忽略 id=' + id);
    return null;
  }
  state.todos[id] = next;
  enqueueUpsert(next);
  persist();
  emit();
  return next;
}

/** 勾选完成/取消完成 */
function toggleTodo(id) {
  const prev = state.todos[id];
  if (!prev) return null;
  return updateTodo(id, { status: prev.status === 'done' ? 'todo' : 'done' });
}

/**
 * 软删除（契约 §2.5：本地先置 deleted=true，同步时走 remove）
 * 本地保留墓碑，保证「云端拉回旧版本」时不会被复活。
 */
function softRemove(ids) {
  // 兼容传单个 id 字符串的写法，避免误把字符串当数组遍历
  const list = Array.isArray(ids) ? ids : ids ? [ids] : [];
  let n = 0;
  for (let i = 0; i < list.length; i++) {
    const id = list[i];
    const prev = state.todos[id];
    if (!prev) continue;
    state.todos[id] = {
      id: prev.id,
      content: prev.content,
      deadline: prev.deadline,
      priority: prev.priority,
      status: prev.status,
      source: prev.source,
      rawText: prev.rawText,
      deleted: true,
      createTime: prev.createTime,
      updateTime: nextUpdateTime(prev.updateTime)
    };
    enqueueRemove(id);
    n++;
  }
  if (n > 0) {
    persist();
    emit();
  }
  return n;
}

function softRemoveDone() {
  const ids = all()
    .filter(function (t) {
      return t.status === 'done';
    })
    .map(function (t) {
      return t.id;
    });
  return softRemove(ids);
}

/* ============================ 云端合并（LWW） ============================ */

function isDifferent(a, b) {
  return (
    (Number(a.updateTime) || 0) !== (Number(b.updateTime) || 0) ||
    a.deleted !== b.deleted ||
    a.content !== b.content ||
    a.status !== b.status ||
    a.priority !== b.priority ||
    (a.deadline === null ? null : Number(a.deadline)) !== (b.deadline === null ? null : Number(b.deadline))
  );
}

/**
 * 增量拉取结果合并（契约 §5.4：LWW by updateTime，服务端为权威）
 * @returns {number} 实际发生变化的条数
 */
function mergeServer(items) {
  const list = items || [];
  let changed = 0;
  for (let i = 0; i < list.length; i++) {
    const incoming = fromServer(list[i]);
    if (!incoming.id) continue;
    const local = state.todos[incoming.id];
    const localTime = local ? Number(local.updateTime) || 0 : -1;
    // 服务端 updateTime >= 本地 → 服务端胜出（闭区间语义，同毫秒也以服务端为准）
    if (!local || (Number(incoming.updateTime) || 0) >= localTime) {
      if (!local || isDifferent(local, incoming)) changed++;
      state.todos[incoming.id] = incoming;
    }
  }
  if (changed > 0) {
    pruneTombstones();
    persist();
    emit();
  }
  return changed;
}

/**
 * 写回执处理（契约 §2.4）
 *  - applied：把本地 updateTime 对齐服务端盖章值（本地后续编辑靠 nextUpdateTime 保持递增）
 *  - stale：服务端为准，覆盖本地（用户本地改动会被丢弃，属于契约规定的行为）
 *  - rejected：服务端拒收（如内容为空/超长），本地丢弃，避免 outbox 死循环
 *
 * @param {object} res 云函数响应
 * @param {object} [sentVersions] 本次上抛时每条用的 updateTime 快照 { id: updateTime }。
 *        传入后会做「推送期间是否被改过」保护：若本地该条当下的 updateTime 已不等于上抛时的值，
 *        说明用户在上抛过程中又改了这条，此时服务端的 applied/stale 都是针对旧版本的结论，
 *        必须跳过覆盖，否则会把用户的新改动连同时间戳一起改小/改回去。
 */
function applyWriteResult(res, sentVersions) {
  const r = res || {};
  const applied = r.applied || [];
  const stale = r.stale || [];
  const rejected = r.rejected || [];
  const sent = sentVersions && typeof sentVersions === 'object' ? sentVersions : null;

  /** 本地该条是否仍是本次上抛的那个版本（没被并发修改） */
  function unchangedSincePush(local, id) {
    if (!sent) return true; // 未提供快照时保持旧行为
    const pushed = sent[id];
    if (pushed === undefined) return true; // 非本次上抛的条目（例如别人的回执）
    return (Number(local.updateTime) || 0) === (Number(pushed) || 0);
  }

  for (let i = 0; i < applied.length; i++) {
    const a = applied[i];
    const local = state.todos[a.id];
    if (!local || !a.updateTime) continue;
    if (!unchangedSincePush(local, a.id)) continue; // 推送期间用户又改了 → 保留本地新版本
    // 严格采用服务端盖章值：契约 §1.1/§5.4 规定服务端 updateTime 是唯一权威时钟。
    // 若本机时钟快于服务端而保留本地大值，会导致后续拉取时误判「本地更新」而丢掉其它端的修改。
    local.updateTime = Number(a.updateTime) || local.updateTime;
  }
  for (let i = 0; i < stale.length; i++) {
    const s = stale[i];
    const local = state.todos[s.id];
    if (!local) continue;
    // 契约 §2.4 注：stale 应为完整文档；若回传的 content 为空说明数据残缺，直接忽略这条
    // （例外：deleted=true 的墓碑本身可能不带正文，删除语义仍要生效，交给 list 路径兜底也行）
    if (typeof s.content === 'string' && !normalizeContent(s.content) && s.deleted !== true) {
      console.log('[qt:store] 忽略 content 为空的 stale 条目 id=' + s.id);
      continue;
    }
    // 同样保护：stale 是针对「我们上抛的那个版本」的结论；若用户在上抛后又改过，
    // 用服务端旧版本覆盖会丢掉更新的本地改动，此时跳过（该条新的 outbox 条目会在下一轮重新上抛）
    if (!unchangedSincePush(local, s.id)) continue;
    if (s.updateTime) local.updateTime = Number(s.updateTime) || local.updateTime;
    if (typeof s.content === 'string') local.content = normalizeContent(s.content);
    if (s.deadline !== undefined) local.deadline = normalizeDeadline(s.deadline);
    if (s.priority !== undefined) local.priority = normalizePriority(s.priority);
    if (s.status !== undefined) local.status = normalizeStatus(s.status);
    if (s.source !== undefined) local.source = normalizeSource(s.source);
    if (s.rawText !== undefined) local.rawText = normalizeRawText(s.rawText);
    if (typeof s.deleted === 'boolean') local.deleted = s.deleted;
  }
  for (let i = 0; i < rejected.length; i++) {
    const id = rejected[i] && rejected[i].id;
    if (id && state.todos[id]) delete state.todos[id];
  }
  if (applied.length || stale.length || rejected.length) {
    persistTodosOnly();
    emit();
  }
  return { applied: applied.length, stale: stale.length, rejected: rejected.length };
}

/** 清理过期墓碑，避免缓存无限增长（只清「已删除且早于游标 7 天」的） */
function pruneTombstones() {
  const limit = state.cursor - TOMBSTONE_TTL;
  if (!limit || limit <= 0) return;
  const map = state.todos;
  for (const k in map) {
    if (!Object.prototype.hasOwnProperty.call(map, k)) continue;
    const t = map[k];
    if (t && t.deleted && (Number(t.updateTime) || 0) < limit) delete map[k];
  }
}

/* ============================ 游标 / 元信息 / 清空 ============================ */

function getCursor() {
  return Number(state.cursor) || 0;
}

function setCursor(v) {
  const n = Number(v) || 0;
  if (n === state.cursor) return;
  state.cursor = n;
  try {
    wx.setStorageSync(KEYS.CURSOR, state.cursor);
  } catch (e) {
    // 忽略：游标写失败只影响下次多拉一点
  }
}

function getMeta() {
  return state.meta;
}

function setMeta(patch) {
  state.meta = Object.assign({}, state.meta, patch || {});
  try {
    wx.setStorageSync(KEYS.META, state.meta);
  } catch (e) {
    // 忽略
  }
  return state.meta;
}

/**
 * 清空本地缓存。
 * @param {object} [opts] { keepOutbox:boolean } 默认连 outbox 一起清（「我的」页会先做二次确认并提示未同步数据会丢失）
 */
function clearAll(opts) {
  const o = opts || {};
  state.todos = {};
  if (!o.keepOutbox) state.outbox = [];
  state.cursor = 0;
  state.meta = {};
  try {
    wx.removeStorageSync(KEYS.TODOS);
    wx.removeStorageSync(KEYS.CURSOR);
    wx.removeStorageSync(KEYS.META);
    if (!o.keepOutbox) wx.removeStorageSync(KEYS.OUTBOX);
  } catch (e) {
    console.log('[qt:store] 清空缓存失败：' + (e && e.errMsg ? e.errMsg : e));
  }
  emit();
  return true;
}

/** 调试用快照（不参与业务） */
function snapshot() {
  return { size: Object.keys(state.todos).length, outbox: state.outbox.length, cursor: state.cursor };
}

module.exports = {
  KEYS: KEYS,
  PRIORITY_WEIGHT: PRIORITY_WEIGHT,
  init: init,
  subscribe: subscribe,
  emit: emit,
  get: get,
  all: all,
  getList: getList,
  sortTodos: sortTodos,
  counts: counts,
  makeTodo: makeTodo,
  put: put,
  putMany: putMany,
  createTodo: createTodo,
  updateTodo: updateTodo,
  toggleTodo: toggleTodo,
  softRemove: softRemove,
  softRemoveDone: softRemoveDone,
  mergeServer: mergeServer,
  applyWriteResult: applyWriteResult,
  observeServerTime: observeServerTime,
  getLastServerTime: getLastServerTime,
  nextUpdateTime: nextUpdateTime,
  outboxSize: outboxSize,
  peekOutbox: peekOutbox,
  dropOutbox: dropOutbox,
  getCursor: getCursor,
  setCursor: setCursor,
  getMeta: getMeta,
  setMeta: setMeta,
  clearAll: clearAll,
  uuid: uuid,
  snapshot: snapshot
};
