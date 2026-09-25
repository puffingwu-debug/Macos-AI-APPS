/**
 * api.js —— 云函数调用统一封装
 *
 * 契约依据：docs/SYNC-PROTOCOL.md
 *  - 小程序通道 payload = event（直接把业务参数作为 data 传给 callFunction）
 *  - 通用响应 { ok:true, ... } / { ok:false, error:{ code, message } }
 *  - 错误码：unauthorized / bad_request / not_found / rate_limited / upstream_error / internal
 *
 * 本文件只负责「发请求 + 统一错误处理 + 统一 loading 态」，不做任何本地状态管理。
 * 注意：ai.parse 的失败是「正常降级路径」，所以用 allowFail 返回原始对象而不是抛错。
 */
const config = require('../config');

const FN = config.cloudFunctions;

/** 构造带 code 的错误对象 */
function mkError(code, message, extra) {
  const err = new Error(message || code || '请求失败');
  err.code = code || 'internal';
  err.extra = extra || null;
  return err;
}

/** 云开发是否已就绪（本地模式下永远是 false，调用方据此走本地分支） */
function cloudReady() {
  try {
    const app = getApp();
    return !!(app && app.globalData && app.globalData.cloudReady && wx.cloud && typeof wx.cloud.callFunction === 'function');
  } catch (e) {
    return false;
  }
}

/** 把 wx.cloud 的底层错误翻译成契约错误码 + 人话 */
function friendlyError(err, name) {
  const msg = String((err && (err.errMsg || err.message)) || '');
  if (/timeout|超时|TIME_LIMIT/i.test(msg)) {
    return { code: 'upstream_error', message: '网络超时，请稍后重试' };
  }
  if (/-404011|-501000|-604100|FUNCTION_NOT_FOUND|not found/i.test(msg)) {
    return { code: 'internal', message: '云函数「' + name + '」未部署，或未选择云环境' };
  }
  if (/cloud init|not initialized|未初始化|env/i.test(msg) && /cloud/i.test(msg)) {
    return { code: 'cloud_unavailable', message: '云开发未初始化（本地模式）' };
  }
  if (/network|ERR_|fail/i.test(msg)) {
    return { code: 'upstream_error', message: '网络异常，请检查网络后重试' };
  }
  return { code: 'internal', message: msg || '调用失败' };
}

/**
 * 调用云函数
 * @param {string} name 云函数名
 * @param {object} payload 业务参数（含 action）
 * @param {object} [opts] { loading:boolean|string, allowFail:boolean, loadingText }
 * @returns {Promise<object>} 云函数返回的 result 对象
 */
async function call(name, payload, opts) {
  const options = opts || {};
  if (!cloudReady()) {
    throw mkError('cloud_unavailable', '云开发未初始化（本地模式）');
  }
  if (options.loading) {
    wx.showLoading({ title: typeof options.loading === 'string' ? options.loading : '处理中', mask: true });
  }

  let res = null;
  let netErr = null;
  try {
    res = await wx.cloud.callFunction({ name: name, data: payload || {} });
  } catch (err) {
    netErr = err;
  } finally {
    if (options.loading) {
      wx.hideLoading();
    }
  }

  if (netErr) {
    const f = friendlyError(netErr, name);
    // 只在错误路径打印，避免刷屏
    console.log('[qt:api] ' + name + ' 调用失败：' + f.code + ' ' + f.message);
    throw mkError(f.code, f.message, netErr);
  }

  const result = res && res.result;
  if (!result || typeof result !== 'object') {
    throw mkError('internal', '云函数「' + name + '」返回为空');
  }
  if (result.ok === false && !options.allowFail) {
    const e = result.error || {};
    throw mkError(e.code || 'internal', e.message || '请求失败', result);
  }
  return result;
}

/* ============================ 云函数 todo（契约 §2） ============================ */
const todo = {
  /** 增量拉取：语义 updateTime >= since（闭区间） */
  list(payload) {
    const p = payload || {};
    return call(FN.todo, {
      action: 'list',
      since: Number(p.since) || 0,
      limit: Number(p.limit) || config.sync.pageLimit,
      includeDeleted: p.includeDeleted !== false
    });
  },
  /** 单条写入 */
  upsert(item) {
    return call(FN.todo, { action: 'upsert', item: item });
  },
  /** 批量写入（离线补同步 / AI 批量导入） */
  bulkUpsert(items) {
    return call(FN.todo, { action: 'bulkUpsert', items: items || [] });
  },
  /** 软删除（服务端置 deleted=true + 盖 updateTime） */
  remove(ids) {
    return call(FN.todo, { action: 'remove', ids: ids || [] });
  },
  /** 连通性/会话校验，同时拿到 openid 用于「我的」页展示 */
  async ping() {
    const res = await call(FN.todo, { action: 'ping' });
    try {
      const app = getApp();
      if (app && app.globalData) {
        app.globalData.openid = res.openid || '';
        app.globalData.serverCount = Number(res.count) || 0;
        app.globalData.serverVersion = res.version || '';
      }
    } catch (e) {
      // getApp 不可用时忽略（例如测试环境）
    }
    return res;
  }
};

/* ============================ 云函数 ai（契约 §3） ============================ */
const ai = {
  /**
   * 结构化解析。失败（含 fallbackText）不抛错，交给页面降级为可编辑纯文本预览。
   */
  parse(payload) {
    const p = payload || {};
    return call(
      FN.ai,
      {
        action: 'parse',
        text: String(p.text || ''),
        source: p.source || 'mini-voice',
        now: Number(p.now) || Date.now(),
        timezone: p.timezone || config.ai.timezone,
        maxItems: Number(p.maxItems) || config.ai.maxItems
      },
      { allowFail: true }
    );
  }
};

/* ============================ 云函数 auth（契约 §4） ============================ */
const auth = {
  /** 小程序扫码后确认票据，把 openid 绑到 Mac 会话上 */
  confirmTicket(ticket) {
    return call(FN.auth, { action: 'confirmTicket', ticket: String(ticket || '') });
  },
  check(token) {
    return call(FN.auth, { action: 'check', token: String(token || '') });
  },
  createTicket(deviceName) {
    return call(FN.auth, { action: 'createTicket', deviceName: deviceName || 'Mac' });
  },
  pollTicket(ticket) {
    return call(FN.auth, { action: 'pollTicket', ticket: String(ticket || '') });
  },
  logout(token) {
    return call(FN.auth, { action: 'logout', token: String(token || '') });
  }
};

module.exports = {
  mkError: mkError,
  cloudReady: cloudReady,
  call: call,
  todo: todo,
  ai: ai,
  auth: auth
};
