/**
 * sync.js —— 同步引擎（增量拉取 + outbox 上抛 + 指数退避重试）
 *
 * 契约依据 §5：
 *  - 先推后拉：先把 outbox 上抛（bulkUpsert / remove），再 list(since=cursor) 增量拉取
 *  - 拉取：hasMore 为 true 时用新 cursor 继续，直到拉空（§5.3）
 *  - 重试：失败保留 outbox，指数退避 1s→2s→4s…上限 60s（§5.2）
 *  - 冲突：服务端 stale 回执 → 用服务端版本覆盖本地（§5.4）
 *  - 本地模式（cloudEnv 为空）：不发任何请求，outbox 继续累积，UI 顶部提示「本地模式」
 */
const api = require('./api');
const store = require('./store');
const config = require('../config');

const BACKOFF = (config.sync && config.sync.backoff) || [1000, 2000, 4000, 8000, 16000, 32000, 60000];
const BATCH = (config.sync && config.sync.maxOutboxPerRound) || 100;
const MAX_PUSH_LOOP = 50; // 上抛防御性上限：单轮最多 50 批
const MAX_PULL_PAGES = (config.sync && config.sync.maxPullPages) || 20; // 拉取迭代上限（防 hasMore 异常死循环）

const state = {
  inited: false,
  localMode: true,
  syncing: false,
  lastSyncAt: 0,
  lastError: '',
  failCount: 0,
  pending: 0, // outbox 待上抛条数
  lastPushed: 0,
  lastPulled: 0,
  lastStale: 0,
  lastRejected: 0,
  notice: '', // 需要一次性 toast 的提示（被服务端拒收等）
  noticeAt: 0
};

let retryTimer = null;
let running = null; // 正在进行的同步 Promise（用于并发去重）
let listeners = [];
let unsubscribeStore = null;

/* ============================ 对外接口 ============================ */

function init(opts) {
  const o = opts || {};
  if (state.inited) {
    state.localMode = !!o.localMode;
    return state;
  }
  state.localMode = !!o.localMode;
  state.pending = store.outboxSize();
  // 本地新增/删除会改变 outbox 长度，同步状态条要跟着动
  unsubscribeStore = store.subscribe(function () {
    const n = store.outboxSize();
    if (n !== state.pending) {
      state.pending = n;
      publish();
    }
  });
  state.inited = true;
  return state;
}

function getState() {
  return {
    localMode: state.localMode,
    syncing: state.syncing,
    lastSyncAt: state.lastSyncAt,
    lastError: state.lastError,
    failCount: state.failCount,
    pending: state.pending,
    lastPushed: state.lastPushed,
    lastPulled: state.lastPulled,
    lastStale: state.lastStale,
    lastRejected: state.lastRejected,
    notice: state.notice,
    noticeAt: state.noticeAt
  };
}

function onStateChange(fn) {
  if (typeof fn !== 'function') return function () {};
  listeners.push(fn);
  return function off() {
    const i = listeners.indexOf(fn);
    if (i >= 0) listeners.splice(i, 1);
  };
}

function publish() {
  const snapshot = getState();
  for (let i = 0; i < listeners.length; i++) {
    try {
      listeners[i](snapshot);
    } catch (e) {
      console.log('[qt:sync] 状态监听异常：' + (e && e.message ? e.message : e));
    }
  }
}

/**
 * 触发一次同步（去重：同一时刻只有一个同步在跑）
 * @param {string} reason 'onshow' | 'pull' | 'create' | 'edit' | 'delete' | 'retry' ...
 * @returns {Promise<{ok:boolean, skipped?:boolean, pushed:number, pulled:number, error?:string}>}
 */
function trigger(reason) {
  if (state.localMode) {
    publish();
    return Promise.resolve({ ok: true, skipped: true, reason: 'local-mode', pushed: 0, pulled: 0 });
  }
  if (running) return running;
  clearTimer();
  running = run(reason).then(
    function (res) {
      running = null;
      return res;
    },
    function (err) {
      // run 内部已兜底，这里只防御性处理
      running = null;
      return { ok: false, pushed: 0, pulled: 0, error: (err && err.message) || '同步失败' };
    }
  );
  return running;
}

function stop() {
  clearTimer();
}

/* ============================ 内部实现 ============================ */

function clearTimer() {
  if (retryTimer) {
    clearTimeout(retryTimer);
    retryTimer = null;
  }
}

/** 失败后按指数退避安排下一次重试 */
function scheduleRetry() {
  clearTimer();
  const idx = Math.max(0, Math.min(state.failCount - 1, BACKOFF.length - 1));
  const delay = BACKOFF[idx] || 1000;
  retryTimer = setTimeout(function () {
    retryTimer = null;
    trigger('retry');
  }, delay);
}

async function run(reason) {
  state.syncing = true;
  state.lastError = '';
  publish();

  const result = { ok: true, pushed: 0, pulled: 0, reason: reason || '' };
  try {
    result.pushed = await flushOutbox();
    result.pulled = await pullAll();
    state.failCount = 0;
    state.lastSyncAt = Date.now();
    store.setMeta({ lastSyncAt: state.lastSyncAt, lastError: '' });
    if (result.pushed || result.pulled) {
      console.log('[qt:sync] 同步完成 push=' + result.pushed + ' pull=' + result.pulled + ' reason=' + result.reason);
    }
  } catch (err) {
    state.failCount += 1;
    state.lastError = (err && err.message) || '同步失败';
    result.ok = false;
    result.error = state.lastError;
    // 失败路径才打印，避免刷屏；outbox 数据保留，等退避重试
    console.log('[qt:sync] 失败第 ' + state.failCount + ' 次：' + state.lastError + '（' + state.pending + ' 条待上抛）');
    store.setMeta({ lastError: state.lastError });
    scheduleRetry();
  } finally {
    state.syncing = false;
    state.pending = store.outboxSize();
    publish();
  }
  return result;
}

/**
 * 上抛 outbox。按入队顺序处理，连续同类操作合批：
 *  - 连续 upsert → bulkUpsert(items)
 *  - 连续 remove → remove(ids)
 * 保持顺序是为了让「先建后删」这类本地操作在服务端也按序生效（本地已做同 id 合并，顺序主要影响不同 id 的批量语义）。
 */
async function flushOutbox() {
  let processed = 0;
  let loop = 0;
  let staleCount = 0;
  let rejectedCount = 0;

  while (loop++ < MAX_PUSH_LOOP) {
    const batch = store.peekOutbox(BATCH);
    if (!batch.length) break;

    if (batch[0].op === 'upsert') {
      const group = [];
      for (let i = 0; i < batch.length; i++) {
        if (batch[i].op !== 'upsert') break;
        group.push(batch[i]);
      }
      const items = group.map(function (e) {
        return e.item;
      });
      // 本次上抛每条用的 updateTime 快照：用于「推送期间被改过则跳过覆盖」的保护（契约 §1.1 逻辑时间戳）
      const sentVersions = {};
      for (let i = 0; i < group.length; i++) {
        sentVersions[group[i].id] = group[i].item.updateTime;
      }
      const res = await api.todo.bulkUpsert(items); // 网络/云函数异常会抛出 → 交给退避重试
      store.observeServerTime(res.serverTime); // 抬高逻辑时钟水位（契约 §2.4 响应带 serverTime）
      const stat = store.applyWriteResult(res, sentVersions);
      staleCount += stat.stale;
      rejectedCount += stat.rejected;
      store.dropOutbox(
        group.map(function (e) {
          return e.key;
        })
      );
      processed += group.length;
    } else {
      const group = [];
      for (let i = 0; i < batch.length; i++) {
        if (batch[i].op !== 'remove') break;
        group.push(batch[i]);
      }
      const ids = group.map(function (e) {
        return e.id;
      });
      const res = await api.todo.remove(ids);
      store.observeServerTime(res.serverTime); // 契约 §2.5 响应带 serverTime
      store.dropOutbox(
        group.map(function (e) {
          return e.key;
        })
      );
      processed += group.length;
    }
  }

  state.lastStale = staleCount;
  state.lastRejected = rejectedCount;
  if (rejectedCount > 0) {
    state.notice = '有 ' + rejectedCount + ' 条待办被服务端拒收（内容为空或超长），已从本地移除';
    state.noticeAt = Date.now();
    console.log('[qt:sync] 服务端拒收 ' + rejectedCount + ' 条');
  } else if (staleCount > 0) {
    state.notice = '有 ' + staleCount + ' 条待办在其它端更新过，已采用云端版本';
    state.noticeAt = Date.now();
  } else {
    state.notice = '';
  }
  return processed;
}

/**
 * 增量拉取：list(since=cursor) → merge → cursor=响应.cursor，hasMore 则继续。
 * 迭代上限 MAX_PULL_PAGES（默认 20 页 × 100 条 = 2000 条/轮）：
 * 即使云端 hasMore 异常返回 true 也不会死循环；没拉完的部分下一轮从已持久化的游标继续，不会丢数据。
 */
async function pullAll() {
  let total = 0;
  let loop = 0;

  while (loop++ < MAX_PULL_PAGES) {
    const since = store.getCursor();
    const res = await api.todo.list({
      since: since,
      limit: (config.sync && config.sync.pageLimit) || 100,
      includeDeleted: true
    });
    const items = res.items || [];
    store.observeServerTime(res.serverTime); // 抬高逻辑时钟水位（契约 §2.3 响应带 serverTime）
    if (items.length) {
      store.mergeServer(items);
      total += items.length;
    }
    const cursor = Number(res.cursor);
    if (isFinite(cursor) && cursor >= since) store.setCursor(cursor);

    if (!res.hasMore) break;
    if (!items.length) break; // 防御：声明还有更多却没给数据，避免死循环
  }
  return total;
}

module.exports = {
  init: init,
  trigger: trigger,
  stop: stop,
  getState: getState,
  onStateChange: onStateChange
};
