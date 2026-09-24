#!/usr/bin/env node
/**
 * miniprogram-tests.js —— QuickTodo 小程序端「核心逻辑」回归自检
 *
 * 这是什么
 *   一个纯 Node.js 的可复跑自检脚本：直接 require 真实的小程序模块
 *   （../miniprogram/utils/{store,sync,api,format,config}.js 与 pages/index/index.js），
 *   用内存桩替换 `wx`（setStorageSync/getStorageSync/removeStorageSync/showToast/cloud.callFunction）
 *   和 `getApp`，在命令行里把本地仓库、outbox、LWW、同步引擎、逻辑时钟、输入规范化、AI 降级全部跑一遍。
 *
 * 怎么跑
 *   node tools/miniprogram-tests.js
 *   退出码 0 = 全部通过；1 = 有失败（可直接接进 CI / pre-commit）。
 *
 * 为什么需要它
 *   小程序代码无法在命令行编译或运行（依赖微信运行时、基础库、云开发与真机能力），
 *   但项目里最容易出错的恰恰是与契约强相关的纯逻辑：契约 §5.5 的三级排序、
 *   §5.2 的 outbox 合并与指数退避、§5.4 的 LWW 与 stale/rejected 回执、
 *   §1.1 的逻辑时间戳（HLC-lite，防本机时钟偏慢导致改动被反覆盖）、
 *   §1.1 content/rawText 截断、§3.4 默认时刻、§2.2 unauthorized 降级。
 *   这些逻辑改动一次就可能静默丢数据，只能靠这一层回归保护。
 *
 * 它不是真机测试（边界说明）
 *   - 不渲染 WXML/WXSS，不校验布局、交互、动画；
 *   - 不覆盖真实 `wx.cloud.callFunction`（网络/权限/云函数部署）、同声传译插件、录音权限、
 *     `wx.scanCode`、storage 容量与持久化行为；
 *   - 不覆盖真机差异（iOS/Android、深色模式、悬浮球手势手感）。
 *   以上仍需在「微信开发者工具 + 真机预览」里验证。
 *
 * 组织方式
 *   分节执行，每节开始前清空模块缓存与内存存储，保证用例之间互不污染。
 */
const path = require('path');

const MINI_ROOT = path.join(__dirname, '..', 'miniprogram');

/* ============================== 全局桩 ============================== */

const storage = {}; // 模拟 wx.setStorageSync / getStorageSync
const toasts = []; // 记录 wx.showToast
const cloudCalls = []; // 记录 wx.cloud.callFunction 调用（含 name/action/payload）
const appState = { cloudReady: true, localMode: false };
let cloudHandler = function () {
  return Promise.resolve({ result: { ok: true } });
};
let capturedPage = null;

function installGlobals() {
  global.wx = {
    getStorageSync(k) {
      return Object.prototype.hasOwnProperty.call(storage, k) ? storage[k] : '';
    },
    setStorageSync(k, v) {
      storage[k] = JSON.parse(JSON.stringify(v === undefined ? null : v));
    },
    removeStorageSync(k) {
      delete storage[k];
    },
    showToast(o) {
      toasts.push((o && o.title) || '');
    },
    showLoading() {},
    hideLoading() {},
    showModal() {},
    vibrateShort() {},
    getWindowInfo() {
      return { windowWidth: 375, windowHeight: 667, statusBarHeight: 20, platform: 'devtools' };
    },
    getSystemInfoSync() {
      return { windowWidth: 375, windowHeight: 667, statusBarHeight: 20, platform: 'devtools' };
    },
    cloud: {
      callFunction(opts) {
        cloudCalls.push({ name: opts.name, action: opts.data && opts.data.action, payload: opts.data });
        return cloudHandler(opts);
      }
    }
  };
  global.getApp = function () {
    return {
      globalData: {
        cloudReady: appState.cloudReady,
        localMode: appState.localMode,
        openid: '',
        serverCount: 0,
        serverVersion: 'v1',
        windowInfo: { windowWidth: 375, windowHeight: 667, statusBarHeight: 20, platform: 'devtools' }
      }
    };
  };
  global.Page = function (o) {
    capturedPage = o;
  };
  global.Component = function () {};
  global.App = function () {};
}

/** 每个分节前调用：清空内存存储 / 事件记录 / 模块缓存，重置桩的行为 */
function resetEnv() {
  for (const k of Object.keys(storage)) delete storage[k];
  toasts.length = 0;
  cloudCalls.length = 0;
  capturedPage = null;
  cloudHandler = function () {
    return Promise.resolve({ result: { ok: true } });
  };
  appState.cloudReady = true;
  appState.localMode = false;
  Object.keys(require.cache).forEach(function (k) {
    if (k.indexOf(MINI_ROOT) === 0) delete require.cache[k];
  });
  installGlobals();
}

/** 只清模块缓存（用于分节内的「模拟冷启动」），保留 storage */
function reloadModules() {
  Object.keys(require.cache).forEach(function (k) {
    if (k.indexOf(MINI_ROOT) === 0) delete require.cache[k];
  });
}

function loadUtil(name) {
  return require(path.join(MINI_ROOT, 'utils', name + '.js'));
}

function loadPage(rel) {
  return require(path.join(MINI_ROOT, rel));
}

/* ============================== 断言与汇总 ============================== */

let passed = 0;
let failed = 0;
const failedNames = [];

function ok(name, cond, actual) {
  if (cond) {
    passed++;
    console.log('  PASS  ' + name);
  } else {
    failed++;
    failedNames.push(name);
    console.log('  FAIL  ' + name + (actual === undefined ? '' : '   实际=' + JSON.stringify(actual)));
  }
}

function section(title) {
  console.log('\n=== ' + title + ' ===');
}

const sleep = function (ms) {
  return new Promise(function (r) {
    setTimeout(r, ms);
  });
};

/* ============================== 1. 存储与排序 ============================== */

async function s1_storage_and_sort() {
  section('1. 存储与排序（契约 §1.1 字段规则 / §5.5 排序）');
  resetEnv();
  const store = loadUtil('store');
  store.init();

  const T = function (o) {
    return store.makeTodo(o);
  };
  store.putMany([
    T({ id: 'a-low', content: 'low 无截止', priority: 'low', deadline: null, createTime: 100 }),
    T({ id: 'b-high-late', content: 'high 晚截止', priority: 'high', deadline: 9000, createTime: 200 }),
    T({ id: 'c-normal', content: 'normal 有截止', priority: 'normal', deadline: 5000, createTime: 300 }),
    T({ id: 'd-high-null', content: 'high 无截止', priority: 'high', deadline: null, createTime: 400 }),
    T({ id: 'e-high-soon', content: 'high 早截止', priority: 'high', deadline: 1000, createTime: 500 }),
    T({ id: 'f-high-soon2', content: 'high 同截止更新', priority: 'high', deadline: 1000, createTime: 600 })
  ]);
  store.updateTodo('c-normal', { status: 'done' });
  store.updateTodo('a-low', { status: 'done' });
  const list = store.getList('all', 'smart').map(function (x) {
    return x.id;
  });

  ok('未完成组排在已完成组之前（§5.5 分组）', list.length === 6 && list.slice(4).sort().join(',') === 'a-low,c-normal', list);
  ok('已完成组按 updateTime 降序（a-low 后改 → 排前）', list[4] === 'a-low' && list[5] === 'c-normal', list);
  ok(
    '未完成组：priority 权重升序 → deadline 升序（null 最后）',
    list.slice(0, 4).join(',') === 'f-high-soon2,e-high-soon,b-high-late,d-high-null',
    list.slice(0, 4)
  );
  ok('标记完成后已移出未完成组（未完成组恰好 4 条）', list.slice(0, 4).length === 4 && list.indexOf('c-normal') > 3 && list.indexOf('a-low') > 3, list);

  // §5.5 兜底：两条已完成待办 updateTime 完全相同时，按 createTime 降序，避免列表跳动
  store.mergeServer([
    { id: 'tie-old', content: '同版本-早创建', updateTime: 300000, createTime: 1000, deleted: false, priority: 'normal', status: 'done', source: 'manual', rawText: '' },
    { id: 'tie-new', content: '同版本-晚创建', updateTime: 300000, createTime: 2000, deleted: false, priority: 'normal', status: 'done', source: 'manual', rawText: '' }
  ]);
  const tie = store
    .getList('done')
    .filter(function (x) {
      return x.id.indexOf('tie-') === 0;
    })
    .map(function (x) {
      return x.id;
    });
  ok('已完成组内 updateTime 相同 → createTime 降序兜底（§5.5）', tie.join(',') === 'tie-new,tie-old', tie);

  ok(
    'filter=todo 只返回未完成',
    store.getList('todo').every(function (x) {
      return x.status !== 'done';
    })
  );
  ok(
    'filter=done 只返回已完成',
    store.getList('done').every(function (x) {
      return x.status === 'done';
    })
  );
  const c = store.counts();
  ok('计数与列表一致（8 全部 / 4 待办 / 4 已完成）', c.all === 8 && c.todo === 4 && c.done === 4, c);

  const gen = store.makeTodo({ content: 'uuid 形态' });
  ok('uuid() 生成的 id 符合契约正则 ^[0-9a-fA-F-]{8,64}$', /^[0-9a-fA-F-]{8,64}$/.test(gen.id), gen.id);
  ok(
    'uuid() 是标准 v4（小写带连字符）',
    /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(gen.id),
    gen.id
  );

  store.setCursor(1712345678999);
  ok('增量游标读写一致（契约 §2.3）', store.getCursor() === 1712345678999, store.getCursor());
  store.clearAll();
  ok(
    'clearAll 后待办 / outbox / 游标全部归零',
    store.getList('all').length === 0 && store.outboxSize() === 0 && store.getCursor() === 0,
    store.snapshot()
  );
}

/* ============================== 2. outbox 与 LWW ============================== */

async function s2_outbox_and_lww() {
  section('2. outbox 与 LWW（契约 §2.4 / §5.2 / §5.4）');
  resetEnv();
  const store = loadUtil('store');
  store.init();

  const before = store.outboxSize();
  const t1 = store.createTodo({ content: '要删掉的', priority: 'normal' });
  store.updateTodo(t1.id, { content: '改一下' });
  ok('同一 id 多次写入只占 1 条 outbox（同 id 合并）', store.outboxSize() === before + 1, store.outboxSize() - before);
  const pending = store.peekOutbox(999).filter(function (e) {
    return e.id === t1.id;
  });
  ok('outbox 里保留的是最后版本', pending.length === 1 && pending[0].item.content === '改一下', pending);

  store.softRemove(t1.id); // 故意传字符串（而非数组），同时验证参数兼容性
  const afterDel = store.peekOutbox(999).filter(function (e) {
    return e.id === t1.id;
  });
  ok('先建后删 → 合并为单条 remove（不再上抛无意义的 upsert）', afterDel.length === 1 && afterDel[0].op === 'remove', afterDel);
  ok(
    '本地打上 deleted 墓碑且不再出现在列表',
    store.get(t1.id).deleted === true &&
      store.getList('all').every(function (x) {
        return x.id !== t1.id;
      })
  );

  store.mergeServer([
    { id: 'srv-1', content: '服务端新版本', updateTime: 100000, createTime: 1, deleted: false, priority: 'low', status: 'todo', source: 'mac-screenshot', rawText: 'OCR 原文' }
  ]);
  ok('拉取到的新条目被并入本地', !!store.get('srv-1') && store.get('srv-1').content === '服务端新版本');

  store.updateTodo('srv-1', { content: '本地更新' });
  store.mergeServer([
    { id: 'srv-1', content: '服务端旧版本', updateTime: 99999, createTime: 1, deleted: false, priority: 'low', status: 'todo', source: 'mac-screenshot', rawText: '' }
  ]);
  ok('服务端版本更旧 → 本地胜出（不被旧版本回滚）', store.get('srv-1').content === '本地更新', store.get('srv-1').content);

  const localTs = store.get('srv-1').updateTime;
  store.mergeServer([
    { id: 'srv-1', content: '服务端更新版本', updateTime: localTs + 5, createTime: 1, deleted: false, priority: 'high', status: 'done', source: 'mac-screenshot', rawText: '' }
  ]);
  ok('服务端版本更新 → 覆盖本地（服务端为权威时钟）', store.get('srv-1').content === '服务端更新版本' && store.get('srv-1').priority === 'high');

  store.applyWriteResult({ applied: [{ id: 'srv-1', updateTime: 200000 }] });
  ok('applied → 本地 updateTime 严格对齐服务端盖章值', store.get('srv-1').updateTime === 200000, store.get('srv-1').updateTime);
  store.updateTodo('srv-1', { content: '再改一次' });
  ok('本地发号严格递增（自己的连续编辑不会被判 stale）', store.get('srv-1').updateTime > 200000, store.get('srv-1').updateTime);

  store.applyWriteResult({ stale: [{ id: 'srv-1', updateTime: 300000, content: '服务端为准' }] });
  ok('stale → 服务端版本覆盖本地', store.get('srv-1').content === '服务端为准' && store.get('srv-1').updateTime === 300000);

  const t2 = store.createTodo({ content: '会被拒收' });
  store.applyWriteResult({ rejected: [{ id: t2.id, reason: 'empty_content' }] });
  ok('rejected → 本地丢弃，避免 outbox 死循环', store.get(t2.id) === null);

  const w = store.createTodo({ content: 'wire 检查', priority: 'high' });
  const wire = store.peekOutbox(999).filter(function (e) {
    return e.id === w.id;
  })[0].item;
  ok(
    '上行对象只含契约 upsert 字段（无 openid / _id / seq / deleted）',
    JSON.stringify(Object.keys(wire).sort()) ===
      JSON.stringify(['content', 'createTime', 'deadline', 'id', 'priority', 'rawText', 'source', 'status', 'updateTime']),
    Object.keys(wire).sort()
  );
}

/* ============================== 3. 同步引擎 ============================== */

async function s3_sync_engine() {
  section('3. 同步引擎（契约 §2.3 / §2.5 / §5.1–5.3 / §5.7）');
  resetEnv();

  let mode = 'ok'; // ok | failPush | hasMore | alwaysMore
  let page = 0;
  cloudHandler = function (opts) {
    const data = opts.data || {};
    if (mode === 'failPush' && (data.action === 'bulkUpsert' || data.action === 'remove')) {
      return Promise.reject({ errMsg: 'cloud.callFunction:fail Error: ESOCKETTIMEDOUT' });
    }
    if (data.action === 'bulkUpsert') {
      return Promise.resolve({
        result: {
          ok: true,
          applied: data.items.map(function (i) {
            return { id: i.id, updateTime: 1900000000000 };
          }),
          stale: [],
          rejected: [],
          serverTime: 1900000000000
        }
      });
    }
    if (data.action === 'remove') {
      return Promise.resolve({ result: { ok: true, removed: data.ids, serverTime: 1900000000000 } });
    }
    if (data.action === 'list') {
      if (mode === 'alwaysMore') {
        return Promise.resolve({
          result: {
            ok: true,
            items: [
              { id: 'pg' + cloudCalls.length, content: '分页数据', updateTime: 1900000000000 + cloudCalls.length, createTime: 1, deleted: false, priority: 'normal', status: 'todo', source: 'manual', rawText: '' }
            ],
            cursor: data.since + 1,
            hasMore: true,
            serverTime: 1900000000000
          }
        });
      }
      if (mode === 'hasMore' && page === 0) {
        page = 1;
        return Promise.resolve({
          result: {
            ok: true,
            items: [{ id: 'r1', content: '远端1', updateTime: 1900000000001, createTime: 1, deleted: false, priority: 'normal', status: 'todo', source: 'mac-screenshot', rawText: '' }],
            cursor: 1900000000001,
            hasMore: true,
            serverTime: 1900000000001
          }
        });
      }
      if (mode === 'hasMore' && page === 1) {
        page = 2;
        return Promise.resolve({
          result: {
            ok: true,
            items: [{ id: 'r2', content: '远端2', updateTime: 1900000000002, createTime: 2, deleted: false, priority: 'high', status: 'todo', source: 'mac-screenshot', rawText: '' }],
            cursor: 1900000000002,
            hasMore: false,
            serverTime: 1900000000002
          }
        });
      }
      return Promise.resolve({ result: { ok: true, items: [], cursor: data.since, hasMore: false, serverTime: 1900000000003 } });
    }
    return Promise.resolve({ result: { ok: true } });
  };

  const store = loadUtil('store');
  const sync = loadUtil('sync');
  store.init();
  sync.init({ localMode: false });

  // ---- 本地优先 + outbox 上抛 ----
  const a = store.createTodo({ content: '买牛奶', priority: 'high', source: 'manual' });
  store.createTodo({ content: '交报表', priority: 'normal', source: 'mini-voice', rawText: '明天交报表' });
  ok(
    '写入后立即可读（UI 永不等待网络，§5.1）',
    store.getList('all').length === 2
  );
  ok('变更同时进入 outbox 待上抛（§5.2）', store.outboxSize() === 2, store.outboxSize());
  let res = await sync.trigger('test');
  ok('一次同步完成推送', res.ok === true && res.pushed === 2, res);
  ok('上抛成功后 outbox 清空', store.outboxSize() === 0, store.outboxSize());
  const push = cloudCalls.filter(function (c) {
    return c.action === 'bulkUpsert';
  })[0];
  ok('写入走 bulkUpsert 且批量携带 2 条', !!push && push.payload.items.length === 2);
  ok(
    'items 字段与契约 upsert 入参一致',
    JSON.stringify(Object.keys(push.payload.items[0]).sort()) ===
      JSON.stringify(['content', 'createTime', 'deadline', 'id', 'priority', 'rawText', 'source', 'status', 'updateTime'])
  );
  ok('applied 回执后本地 updateTime 对齐服务端盖章值', store.get(a.id).updateTime === 1900000000000, store.get(a.id).updateTime);
  ok('空结果时 cursor 原样回传 since（§2.3）', store.getCursor() === 0, store.getCursor());
  const listCall = cloudCalls.filter(function (c) {
    return c.action === 'list';
  })[0];
  ok(
    'list 请求带 since / limit(100，对齐云端上限) / includeDeleted',
    listCall.payload.since === 0 && listCall.payload.limit === 100 && listCall.payload.includeDeleted === true,
    listCall.payload
  );

  // ---- 顺序：remove 批与 upsert 批都上抛 ----
  cloudCalls.length = 0;
  const c1 = store.createTodo({ content: '待删除项' });
  store.softRemove([c1.id]);
  ok('先建后删被合并成 1 条 remove', store.outboxSize() === 1 && store.peekOutbox(1)[0].op === 'remove');
  store.createTodo({ content: '新项' });
  await sync.trigger('test2');
  const order = cloudCalls
    .filter(function (c) {
      return c.action !== 'list';
    })
    .map(function (c) {
      return c.action;
    });
  ok('outbox 里的 remove 与 upsert 都会上抛', order.indexOf('remove') >= 0 && order.indexOf('bulkUpsert') >= 0, order);

  // ---- 失败：数据不丢 + 指数退避 ----
  mode = 'failPush';
  store.createTodo({ content: '离线期间新增' });
  const f1 = await sync.trigger('fail');
  ok('同步失败时返回 ok:false（不抛出，UI 不崩）', f1.ok === false, f1);
  ok('失败后 outbox 保留，绝不丢数据（§5.2）', store.outboxSize() === 1, store.outboxSize());
  ok('失败计数 +1（决定退避时长 1s→2s→…→60s）', sync.getState().failCount === 1, sync.getState().failCount);
  ok('失败原因记录给人看', /超时|网络/.test(sync.getState().lastError), sync.getState().lastError);
  const f2 = await sync.trigger('fail2');
  ok('再次失败 failCount=2（下次退避 2s）', sync.getState().failCount === 2 && f2.ok === false, sync.getState().failCount);
  mode = 'ok';
  const f3 = await sync.trigger('recover');
  ok('恢复后成功清空 outbox 且计数归零', f3.ok === true && store.outboxSize() === 0 && sync.getState().failCount === 0);

  // ---- hasMore 循环 ----
  mode = 'hasMore';
  page = 0;
  cloudCalls.length = 0;
  const p = await sync.trigger('pull');
  ok('hasMore 为真时继续拉取，两页都并入本地（§5.3）', !!store.get('r1') && !!store.get('r2'));
  ok('本轮共拉取 2 条', p.pulled === 2, p);
  ok('cursor 前进到最后一页的 cursor', store.getCursor() === 1900000000002, store.getCursor());
  const listCalls = cloudCalls.filter(function (c) {
    return c.action === 'list';
  });
  ok('第二页用的是第一页回传的新 cursor（不是旧值）', listCalls[listCalls.length - 1].payload.since === 1900000000001, listCalls.map(function (c) { return c.payload.since; }));

  // ---- 拉取迭代上限（防 hasMore 异常导致死循环）----
  mode = 'alwaysMore';
  cloudCalls.length = 0;
  const t0 = Date.now();
  const capRes = await sync.trigger('cap-test');
  const listCount = cloudCalls.filter(function (c) {
    return c.action === 'list';
  }).length;
  ok('hasMore 恒为 true 时同步仍能正常结束（不死循环）', capRes.ok === true && Date.now() - t0 < 5000);
  ok('list 调用次数正好等于上限 maxPullPages = 20', listCount === 20, listCount);
  ok('游标已推进（未拉完的部分下一轮继续，不丢数据）', store.getCursor() > 0, store.getCursor());
  const cfg = require(path.join(MINI_ROOT, 'config.js'));
  ok('config：pageLimit=100（对齐云端）、maxPullPages=20', cfg.sync.pageLimit === 100 && cfg.sync.maxPullPages === 20, cfg.sync);

  // ---- 本地模式：零请求 ----
  sync.stop();
  resetEnv();
  const store2 = loadUtil('store');
  const sync2 = loadUtil('sync');
  store2.init();
  sync2.init({ localMode: true });
  cloudCalls.length = 0;
  const localRes = await sync2.trigger('local');
  ok('本地模式（cloudEnv 为空）不发任何请求', localRes.skipped === true && cloudCalls.length === 0, cloudCalls.length);
  store2.createTodo({ content: '本地模式新增' });
  ok('本地模式仍可读写，改动留在 outbox 等联网补传（§5.6）', store2.getList('all').length > 0 && store2.outboxSize() > 0);
  sync2.stop();
}

/* ============================== 4. 时钟保护 ============================== */

async function s4_clock_protection() {
  section('4. 时钟保护（契约 §1.1 逻辑时间戳 HLC-lite）');
  resetEnv();

  // 假服务端时钟基准（严格递增推进器，见下方各断言）
  const T0 = Date.now() + 7200000;
  // 桩里的 serverTime 默认取 0（falsy），observeServerTime 会忽略，避免"假水位"盖住后面的断言
  let pushServerTime = 0;
  let listServerTime = 0;
  cloudHandler = function (opts) {
    const data = opts.data || {};
    if (data.action === 'bulkUpsert') {
      return Promise.resolve({
        result: {
          ok: true,
          applied: data.items.map(function (i) {
            return { id: i.id, updateTime: pushServerTime };
          }),
          stale: [],
          rejected: [],
          serverTime: pushServerTime
        }
      });
    }
    if (data.action === 'remove') return Promise.resolve({ result: { ok: true, removed: data.ids, serverTime: pushServerTime } });
    if (data.action === 'list') return Promise.resolve({ result: { ok: true, items: [], cursor: data.since, hasMore: false, serverTime: listServerTime } });
    return Promise.resolve({ result: { ok: true } });
  };

  let store = loadUtil('store');
  let sync = loadUtil('sync');
  store.init();
  sync.init({ localMode: false });

  // ---- 本机时钟偏慢：新改动必须高于服务端水位 ----
  const now = Date.now();
  const watermark = now + 3600000; // 模拟服务端比本机快 1 小时
  store.observeServerTime(watermark);
  ok('observeServerTime 记录服务端水位', store.getLastServerTime() === watermark, store.getLastServerTime());
  ok('前提成立：本机 now 小于水位（旧实现必然被判 stale）', now < watermark);
  const a = store.createTodo({ content: '本机时钟偏慢时新建' });
  ok('createTodo 的 updateTime 高于服务端水位', a.updateTime > watermark, { updateTime: a.updateTime, watermark: watermark });
  const b = store.createTodo({ content: '第二条' });
  const c3 = store.createTodo({ content: '第三条' });
  ok('连续新建严格递增', a.updateTime < b.updateTime && b.updateTime < c3.updateTime, [a.updateTime, b.updateTime, c3.updateTime]);
  const serverDoc = { updateTime: watermark };
  ok(
    '按服务端 stale 规则判定：不会被判 stale（改动不会自己变回去）',
    [a, b, c3].every(function (x) {
      return x.updateTime > serverDoc.updateTime;
    })
  );
  ok('对照：旧的 Date.now() 版本会被判 stale（说明该用例有效）', !(now > serverDoc.updateTime));

  // ---- 同一条连续编辑 + 墓碑 ----
  let cur = a.updateTime;
  let mono = true;
  for (let i = 0; i < 5; i++) {
    const n = store.updateTodo(a.id, { content: '第' + (i + 2) + '次修改' });
    if (!(n.updateTime > cur && n.updateTime > watermark)) mono = false;
    cur = n.updateTime;
  }
  ok('同一条连续编辑 5 次：严格递增且始终高于水位', mono, cur);
  store.softRemove([b.id]);
  ok('软删除墓碑也使用水位之上的时间戳', store.get(b.id).updateTime > watermark, store.get(b.id).updateTime);

  // ---- applied：推送期间被改过则跳过覆盖 ----
  const t1 = store.get(a.id).updateTime;
  const sent1 = {};
  sent1[a.id] = t1;
  const edited = store.updateTodo(a.id, { content: '推送期间用户又改了' });
  const t2 = edited.updateTime;
  ok('并发改动后本地时间戳变大', t2 > t1, { t1: t1, t2: t2 });
  store.applyWriteResult({ applied: [{ id: a.id, updateTime: t1 + 10 }] }, sent1);
  ok('applied：被改过 → 跳过覆盖，保留本地新版本', store.get(a.id).updateTime === t2, { got: store.get(a.id).updateTime, want: t2 });
  ok('applied：被改过 → 内容也没被改回', store.get(a.id).content === '推送期间用户又改了', store.get(a.id).content);
  const t3 = store.get(a.id).updateTime;
  const sent2 = {};
  sent2[a.id] = t3;
  store.applyWriteResult({ applied: [{ id: a.id, updateTime: t3 + 50 }] }, sent2);
  ok('applied：没被改过 → 正常对齐服务端盖章值', store.get(a.id).updateTime === t3 + 50, store.get(a.id).updateTime);

  // ---- stale：同样受并发保护 ----
  const x = store.createTodo({ content: '本地原始' });
  const st1 = {};
  st1[x.id] = x.updateTime;
  const xEdited = store.updateTodo(x.id, { content: '并发编辑后的内容' });
  store.applyWriteResult({ stale: [{ id: x.id, updateTime: x.updateTime + 5, content: '服务端旧版本' }] }, st1);
  ok('stale：被改过 → 跳过覆盖，保住并发编辑', store.get(x.id).content === '并发编辑后的内容', store.get(x.id).content);
  const xEditedTs = xEdited.updateTime; // 注意：xEdited 与 state 内是同一引用，必须先快照
  const st2 = {};
  st2[x.id] = xEditedTs;
  store.applyWriteResult({ stale: [{ id: x.id, updateTime: xEditedTs + 9, content: '服务端更新版本' }] }, st2);
  ok(
    'stale：没被改过 → 服务端为准覆盖（§5.4）',
    store.get(x.id).content === '服务端更新版本' && store.get(x.id).updateTime === xEditedTs + 9,
    store.get(x.id)
  );

  // ---- §2.4 注：content 为空的 stale 直接忽略 ----
  const y = store.createTodo({ content: '本地内容不能丢' });
  const sv = {};
  sv[y.id] = y.updateTime;
  store.applyWriteResult({ stale: [{ id: y.id, updateTime: y.updateTime + 3, content: '   ' }] }, sv);
  ok(
    '空 content 的 stale 被忽略（残缺数据不覆盖本地，§2.4 注）',
    store.get(y.id).content === '本地内容不能丢' && store.get(y.id).updateTime === y.updateTime,
    store.get(y.id)
  );
  store.applyWriteResult({ stale: [{ id: y.id, updateTime: y.updateTime + 4, content: '服务端完整文档' }] }, sv);
  ok('完整文档的 stale 仍照常覆盖', store.get(y.id).content === '服务端完整文档', store.get(y.id).content);
  const z = store.createTodo({ content: '待删除项' });
  const sv2 = {};
  sv2[z.id] = z.updateTime;
  store.applyWriteResult({ stale: [{ id: z.id, updateTime: z.updateTime + 5, content: '', deleted: true }] }, sv2);
  ok('墓碑 stale（deleted=true）允许生效', store.get(z.id).deleted === true, store.get(z.id));

  // ---- 三个响应的 serverTime 都接上水位 + 持久化 + 冷启动 ----
  // 用一个「单调递增的假服务端时钟」推进：T0+1000(list) → T0+2000(bulkUpsert) → T0+3000(remove)。
  // 注意不能随手写一个很大的绝对时间（例如 2031 年）当假水位：水位只增不减，
  // 之后再拿 Date.now()+2h 这种更小的值去比，会被正确地拒绝下调，断言就会假失败。
  listServerTime = T0 + 1000;
  await sync.trigger('t-list');
  ok('list 响应的 serverTime 抬高水位', store.getLastServerTime() === listServerTime, store.getLastServerTime());
  pushServerTime = T0 + 2000;
  cloudCalls.length = 0;
  store.createTodo({ content: '触发一次上抛' });
  await sync.trigger('t-push');
  const upserts = cloudCalls.filter(function (x2) {
    return x2.action === 'bulkUpsert';
  });
  const lastPush = upserts[upserts.length - 1];
  ok(
    'bulkUpsert 入参的 updateTime 全部高于服务端水位（不会被判 stale）',
    lastPush.payload.items.every(function (i) {
      return i.updateTime > listServerTime;
    }),
    lastPush.payload.items.map(function (i) {
      return i.updateTime;
    })
  );
  ok('水位已持久化到 storage', storage['qt_server_time_v1'] === pushServerTime, storage['qt_server_time_v1']);

  // 模拟冷启动：清掉模块缓存后重新 init（storage 保留）
  const wm = pushServerTime; // 当前水位 = 两个响应里更大的那个
  reloadModules();
  store = loadUtil('store');
  sync = loadUtil('sync');
  store.init();
  ok('冷启动后水位从缓存恢复', store.getLastServerTime() === wm, store.getLastServerTime());
  const afterReload = store.createTodo({ content: '冷启动后新建' });
  ok('冷启动后新建仍高于水位', afterReload.updateTime > wm, { got: afterReload.updateTime, watermark: wm });
  store.clearAll();
  ok('clearAll 刻意不重置水位（否则清缓存后又暴露在时钟偏慢风险下）', store.getLastServerTime() === wm, store.getLastServerTime());
  const afterClear = store.createTodo({ content: '清缓存后新建' });
  ok('清缓存后新建仍高于水位', afterClear.updateTime > wm, afterClear.updateTime);
  sync.stop();

  // ---- remove 响应的 serverTime 也要接入水位；且水位只增不减 ----
  // 独立环境隔离：bulkUpsert / list 都回传 0（被 observeServerTime 忽略），只有 remove 带真实水位
  resetEnv();
  const removeWm = T0 + 3000;
  cloudHandler = function (opts) {
    const data = opts.data || {};
    if (data.action === 'remove') return Promise.resolve({ result: { ok: true, removed: data.ids, serverTime: removeWm } });
    if (data.action === 'bulkUpsert') return Promise.resolve({ result: { ok: true, applied: [], stale: [], rejected: [], serverTime: 0 } });
    if (data.action === 'list') return Promise.resolve({ result: { ok: true, items: [], cursor: data.since, hasMore: false, serverTime: 0 } });
    return Promise.resolve({ result: { ok: true } });
  };
  const store4 = loadUtil('store');
  const sync4 = loadUtil('sync');
  store4.init();
  sync4.init({ localMode: false });
  const rmi = store4.createTodo({ content: '触发 remove 响应' });
  store4.softRemove([rmi.id]);
  await sync4.trigger('t-remove');
  sync4.stop();
  ok(
    'remove 响应的 serverTime 接入水位，且更小的 serverTime 不会下调水位（§2.5 / 只增不减）',
    store4.getLastServerTime() === removeWm &&
      store4.observeServerTime(removeWm - 999999) === removeWm &&
      store4.getLastServerTime() === removeWm,
    store4.getLastServerTime()
  );

  // ---- 本地模式同样使用逻辑时间戳 ----
  resetEnv();
  const store3 = loadUtil('store');
  const sync3 = loadUtil('sync');
  store3.init();
  sync3.init({ localMode: true });
  cloudCalls.length = 0;
  const skipped = await sync3.trigger('local');
  store3.observeServerTime(Date.now() + 3600000);
  const localTodo = store3.createTodo({ content: '本地模式新建' });
  ok('本地模式零请求（不因逻辑时钟改动而联网）', skipped.skipped === true && cloudCalls.length === 0, cloudCalls.length);
  ok('本地模式新建同样使用逻辑时间戳', localTodo.updateTime > Date.now(), localTodo.updateTime);
  sync3.stop();
}

/* ============================== 5. 输入规范化与默认时间 ============================== */

async function s5_normalize_and_default_time() {
  section('5. 输入规范化与默认时间（契约 §1.1 截断 / §3.4 默认时刻）');
  resetEnv();
  const store = loadUtil('store');
  const format = loadUtil('format');
  store.init();

  const long = '很长的内容'.repeat(200); // 1000 字
  const longRaw = '转写原文'.repeat(1250); // 5000 字
  ok('测试文本确实超过 500 字', long.length > 500, long.length);
  ok('测试 rawText 确实超过 4000 字', longRaw.length > 4000, longRaw.length);

  const a = store.createTodo({ content: long, source: 'manual' }); // 路径①：手动新增
  ok('手动新增：本地先截断到 500 字', a.content.length === 500, a.content.length);
  const wire1 = store.peekOutbox(999).filter(function (e) {
    return e.id === a.id;
  })[0].item;
  ok('手动新增：上抛内容同样是 500 字（不会被云端 rejected）', wire1.content.length === 500, wire1.content.length);

  store.updateTodo(a.id, { content: long + long }); // 路径②：编辑
  ok('编辑：同样截断到 500 字', store.get(a.id).content.length === 500, store.get(a.id).content.length);

  const imp = [store.makeTodo({ content: long, source: 'mini-voice', rawText: longRaw })]; // 路径③④：AI / 语音导入
  store.putMany(imp);
  ok('导入：正文截断到 500 字', store.get(imp[0].id).content.length === 500, store.get(imp[0].id).content.length);
  const wireImp = store.peekOutbox(999).filter(function (e) {
    return e.id === imp[0].id;
  })[0].item;
  ok('导入：rawText 截断到 4000 字（§1.1）', wireImp.rawText.length === 4000, wireImp.rawText.length);
  ok(
    'outbox 中所有正文均不超过 500 字',
    store.peekOutbox(999).every(function (e) {
      return !e.item || e.item.content.length <= 500;
    })
  );
  ok('首尾空格被去掉', store.createTodo({ content: '   买牛奶   ' }).content === '买牛奶');

  const empty = store.putMany([store.makeTodo({ content: '   ' })]);
  ok(
    '空内容在本地就被挡下（不产生"写进去又被云端删掉"的假成功）',
    empty.length === 0 &&
      store.getList('all').every(function (t) {
        return !!t.content;
      }),
    empty.length
  );
  const keep = store.get(a.id).content;
  ok('编辑成空内容被忽略，保留原值', store.updateTodo(a.id, { content: '  ' }) === null && store.get(a.id).content === keep);
  ok(
    '被挡下的空条目没有进入 outbox',
    store.peekOutbox(999).every(function (e) {
      return e.op !== 'upsert' || !!e.item.content;
    })
  );

  // ---- §3.4 默认时刻：只给日期不给时间 → 当天 23:59:59.999 ----
  const d = '2026-03-05';
  const eod = format.combineDateTime(d, '');
  const dt = new Date(eod);
  ok(
    '只给日期（时间为空）→ 当天 23:59:59.999（§3.4）',
    dt.getHours() === 23 && dt.getMinutes() === 59 && dt.getSeconds() === 59 && dt.getMilliseconds() === 999,
    dt.toString()
  );
  ok("选择器默认值 '23:59' → 同样解析为 23:59:59.999", format.combineDateTime(d, format.DEFAULT_TIME) === eod);
  ok("DEFAULT_TIME 已导出且为 '23:59'", format.DEFAULT_TIME === '23:59', format.DEFAULT_TIME);
  const explicit = format.combineDateTime(d, '15:00');
  const et = new Date(explicit);
  ok('用户显式选了 15:00 → 精确 15:00:00.000（不被改写）', et.getHours() === 15 && et.getMinutes() === 0 && et.getSeconds() === 0 && et.getMilliseconds() === 0);
  ok('往返无损：23:59:59.999 → 展示 → 再解析仍是同一毫秒', format.combineDateTime(format.toDateStr(eod), format.toTimeStr(eod)) === eod);
  ok('没有日期 → null（不臆造截止时间）', format.combineDateTime('', '10:00') === null);
  ok('endOfDay() 对非法输入返回 null', format.endOfDay('bad') === null);
}

/* ============================== 6. AI 解析降级 ============================== */

async function s6_ai_degradation() {
  section('6. AI 解析降级（契约 §2.2 unauthorized / §3.2 / §3.3）');
  resetEnv();
  cloudHandler = function (opts) {
    if (opts.name === 'ai') {
      return Promise.resolve({ result: { ok: false, engine: 'deepseek', error: { code: 'unauthorized', message: '登录态已失效' } } });
    }
    return Promise.resolve({ result: { ok: true } });
  };

  const store = loadUtil('store');
  store.init();
  loadPage('pages/index/index.js'); // 真实页面逻辑，Page() 被桩捕获
  const page = capturedPage;
  const ctx = {
    data: JSON.parse(JSON.stringify(page.data)),
    setData(o) {
      Object.assign(this.data, o);
    }
  };
  const raw = '明天下午三点前把季度报表发给张总';
  ctx.data.lastVoiceText = raw;
  await page.parseText.call(ctx, raw);

  ok('未白屏：仍生成 1 条可编辑预览', ctx.data.previewItems.length === 1, ctx.data.previewItems);
  ok('原始转写完整保留在预览里（不丢文本）', ctx.data.previewItems[0].content === raw, ctx.data.previewItems[0].content);
  ok('提示文案点明「登录态已失效」', /登录态已失效/.test(ctx.data.aiNote), ctx.data.aiNote);
  ok('提示文案说明原文已保留并给出恢复路径', /保留/.test(ctx.data.aiNote) && /刷新|重试|导入/.test(ctx.data.aiNote), ctx.data.aiNote);
  ok(
    '有 toast 提示，不是静默失败',
    toasts.some(function (t) {
      return /登录态失效/.test(t);
    }),
    toasts
  );
  ok('状态回到 idle（悬浮球不再转圈）', ctx.data.voiceState === 'idle' && ctx.data.ballBusy === false, { voiceState: ctx.data.voiceState, ballBusy: ctx.data.ballBusy });
  ok('原文可用于后续导入的 rawText', ctx.data.lastVoiceText === raw);

  page.onImport.call(ctx, {
    detail: { items: [{ content: ctx.data.previewItems[0].content, deadline: null, priority: 'normal', checked: true }] }
  });
  const imported = store.getList('all').filter(function (t) {
    return t.source === 'mini-voice';
  });
  ok(
    '未授权状态下仍能导入（导入走本地 + outbox，不依赖 ai）',
    imported.length === 1 && imported[0].rawText.indexOf('季度报表') >= 0,
    imported.length
  );
}

/* ============================== 入口 ============================== */

const SECTIONS = [
  { name: '存储与排序', run: s1_storage_and_sort },
  { name: 'outbox 与 LWW', run: s2_outbox_and_lww },
  { name: '同步引擎', run: s3_sync_engine },
  { name: '时钟保护', run: s4_clock_protection },
  { name: '输入规范化与默认时间', run: s5_normalize_and_default_time },
  { name: 'AI 解析降级', run: s6_ai_degradation }
];

async function run() {
  console.log('QuickTodo 小程序端自检（契约 v1 · docs/SYNC-PROTOCOL.md）');
  console.log('说明：纯逻辑回归，不渲染 UI、不连真机、不调真实云函数。');
  for (let i = 0; i < SECTIONS.length; i++) {
    try {
      await SECTIONS[i].run();
    } catch (e) {
      failed++;
      failedNames.push(SECTIONS[i].name + '（分节异常）');
      console.log('  FAIL  [' + SECTIONS[i].name + '] 抛出异常：' + ((e && e.stack) || e));
    }
  }
  console.log('');
  if (failed === 0) {
    console.log('小程序端自检全部通过: ' + passed + ' passed, 0 failed');
  } else {
    console.log('小程序端自检未通过: ' + passed + ' passed, ' + failed + ' failed');
    console.log('失败用例：');
    failedNames.forEach(function (n) {
      console.log('  - ' + n);
    });
  }
  return failed === 0 ? 0 : 1;
}

if (require.main === module) {
  run().then(
    function (code) {
      process.exit(code);
    },
    function (e) {
      console.log('自检脚本自身异常：' + ((e && e.stack) || e));
      process.exit(1);
    }
  );
}

module.exports = {
  run: run,
  SECTIONS: SECTIONS,
  stats: function () {
    return { passed: passed, failed: failed, failedNames: failedNames.slice() };
  },
  resetEnv: resetEnv,
  loadUtil: loadUtil,
  sleep: sleep
};
