/**
 * voice.js —— 语音识别封装（微信「同声传译」插件 WechatSI）
 *
 * 插件：app.json → "plugins": { "WechatSI": { "version": "0.3.6", "provider": "wx069ba97219f66d99" } }
 * 用法：requirePlugin('WechatSI').getRecordRecognitionManager()
 *
 * 关键设计（需求 §2 的降级要求）：
 *  - 插件未添加/未授权/基础库不支持 → 不抛异常，走 onError({code:'plugin_unavailable'})，
 *    由页面弹出可手动输入的文本框，功能绝不死掉。
 *  - 录音权限：wx.getSetting → wx.authorize({scope:'scope.record'}) → 被拒则 wx.openSetting 引导。
 *  - stop() 后插件没回调（极少见）→ stopTimeout 兜底报错，同样进入手动输入降级。
 *  - cancel() 直接丢弃回调（用户上滑取消），不会触发 onFinal。
 */
const config = require('../config');

const V = config.voice;

let manager = null;
let pluginFailed = false;
let recording = false;
let stopTimer = null;
let handlers = { onStart: null, onPartial: null, onFinal: null, onError: null };

function clearStopTimer() {
  if (stopTimer) {
    clearTimeout(stopTimer);
    stopTimer = null;
  }
}

function emit(kind, payload) {
  const fn = handlers[kind];
  if (typeof fn === 'function') {
    try {
      fn(payload);
    } catch (e) {
      console.log('[qt:voice] 回调异常：' + (e && e.message ? e.message : e));
    }
  }
}

/** 把插件的 retcode 翻译成本地错误码 */
function mapError(res) {
  const r = res || {};
  const retcode = Number(r.retcode) || 0;
  const msg = String(r.msg || r.errMsg || '');
  if (retcode === -30001 || retcode === -30002 || /permission|auth|授权|denied/i.test(msg)) {
    return { code: 'auth_denied', message: '没有麦克风权限，请授权后重试，或直接手动输入' };
  }
  if (/record|录音|start/i.test(msg)) {
    return { code: 'record_error', message: '录音启动失败，请手动输入' };
  }
  return { code: 'record_error', message: msg || '语音识别失败，请手动输入' };
}

/**
 * 懒加载录音管理器：未配置插件时 requirePlugin 会抛错，这里吞掉并标记不可用
 */
function getManager() {
  if (manager) return manager;
  if (pluginFailed) return null;
  try {
    if (typeof requirePlugin !== 'function') throw new Error('当前基础库不支持插件');
    const plugin = requirePlugin(V.pluginName);
    if (!plugin || typeof plugin.getRecordRecognitionManager !== 'function') {
      throw new Error('插件未正确加载');
    }
    manager = plugin.getRecordRecognitionManager();
  } catch (e) {
    pluginFailed = true;
    console.log('[qt:voice] 同声传译插件不可用：' + (e && e.message ? e.message : e));
    return null;
  }

  manager.onStart = function () {
    emit('onStart', null);
  };
  // 实时中间结果
  manager.onRecognize = function (res) {
    if (!recording) return;
    const text = res && res.result ? String(res.result) : '';
    if (text) emit('onPartial', text);
  };
  // 最终结果（停止录音后回调）
  manager.onStop = function (res) {
    clearStopTimer();
    const wasRecording = recording;
    recording = false;
    const text = res && res.result ? String(res.result).trim() : '';
    if (!wasRecording) return; // cancel() 之后的回调直接丢弃
    emit('onFinal', text);
  };
  manager.onError = function (res) {
    clearStopTimer();
    const wasRecording = recording;
    recording = false;
    if (!wasRecording) return;
    emit('onError', mapError(res));
  };
  return manager;
}

/**
 * 录音权限：已授权直接过；被拒过则 openSetting 引导；首次则 authorize
 * @returns {Promise<{ok:boolean, code?:string, message?:string}>}
 */
function ensureRecordAuth() {
  return new Promise(function (resolve) {
    if (typeof wx.getSetting !== 'function') {
      resolve({ ok: true });
      return;
    }
    wx.getSetting({
      success: function (res) {
        const auth = (res && res.authSetting) || {};
        if (auth['scope.record'] === true) {
          resolve({ ok: true });
          return;
        }
        if (auth['scope.record'] === false) {
          // 曾经拒绝过：authorize 不再弹窗，只能引导去设置页
          resolve(openSettingGuide());
          return;
        }
        wx.authorize({
          scope: 'scope.record',
          success: function () {
            resolve({ ok: true });
          },
          fail: function () {
            resolve(openSettingGuide());
          }
        });
      },
      fail: function () {
        resolve({ ok: true }); // 拿不到设置就直接尝试录音
      }
    });
  });
}

function openSettingGuide() {
  return new Promise(function (resolve) {
    wx.showModal({
      title: '需要麦克风权限',
      content: '语音记待办需要录音权限，请在设置中打开「麦克风」后重试。也可以直接手动输入文字。',
      confirmText: '去设置',
      cancelText: '手动输入',
      success: function (r) {
        if (!r.confirm) {
          // 用户选了「手动输入」→ 带 wantManual 标记，页面据此直接弹输入框
          resolve({ ok: false, code: 'auth_denied', message: '未授权麦克风，可手动输入', wantManual: true });
          return;
        }
        wx.openSetting({
          success: function (s) {
            const ok = !!(s && s.authSetting && s.authSetting['scope.record']);
            resolve(ok ? { ok: true } : { ok: false, code: 'auth_denied', message: '未授权麦克风，可手动输入' });
          },
          fail: function () {
            resolve({ ok: false, code: 'auth_denied', message: '未授权麦克风，可手动输入' });
          }
        });
      },
      fail: function () {
        resolve({ ok: false, code: 'auth_denied', message: '未授权麦克风，可手动输入' });
      }
    });
  });
}

/**
 * 开始录音
 * @param {object} opts { onStart, onPartial, onFinal, onError }
 * @returns {Promise<boolean>} 是否成功启动
 */
async function start(opts) {
  const o = opts || {};
  handlers = {
    onStart: o.onStart || null,
    onPartial: o.onPartial || null,
    onFinal: o.onFinal || null,
    onError: o.onError || null
  };

  const m = getManager();
  if (!m) {
    emit('onError', { code: 'plugin_unavailable', message: '语音识别插件不可用（未在后台添加同声传译或使用测试号），请手动输入' });
    return false;
  }

  const auth = await ensureRecordAuth();
  if (!auth.ok) {
    emit('onError', auth);
    return false;
  }

  if (recording) {
    // 上一次没收干净，先停掉
    try {
      m.stop();
    } catch (e) {
      // 忽略
    }
    recording = false;
  }

  try {
    m.start({ duration: V.duration, lang: V.lang });
    recording = true;
    return true;
  } catch (e) {
    recording = false;
    emit('onError', { code: 'record_error', message: '录音启动失败，请手动输入' });
    return false;
  }
}

/** 结束录音并等待最终结果（onStop → onFinal） */
function stop() {
  clearStopTimer();
  const m = manager;
  if (!m || !recording) {
    // 没真正录上（例如按得太短）→ 直接以空文本收尾，由页面决定降级
    if (handlers.onFinal) emit('onFinal', '');
    else emit('onError', { code: 'empty_result', message: '没有识别到内容，请手动输入' });
    return;
  }
  recording = false;
  try {
    m.stop();
  } catch (e) {
    emit('onError', { code: 'record_error', message: '停止录音失败，请手动输入' });
    return;
  }
  // 兜底：插件长时间不回调 onStop/onError
  stopTimer = setTimeout(function () {
    stopTimer = null;
    emit('onError', { code: 'timeout', message: '识别超时，请手动输入' });
  }, V.stopTimeout || 4000);
}

/** 取消录音：丢弃所有结果回调（手指上滑松手时调用） */
function cancel() {
  clearStopTimer();
  const m = manager;
  const was = recording;
  recording = false;
  handlers = { onStart: null, onPartial: null, onFinal: null, onError: null };
  if (m && was) {
    try {
      m.stop();
    } catch (e) {
      // 忽略
    }
  }
}

function isRecording() {
  return recording;
}

/** 插件是否可用（页面可用于提前提示，不用也安全） */
function available() {
  return !pluginFailed;
}

/**
 * 降级入口：弹出可编辑的文本框让用户手动补充文字
 * @returns {Promise<string>} 用户确认的文字（取消返回空串）
 */
function promptManualText(opts) {
  const o = opts || {};
  return new Promise(function (resolve) {
    wx.showModal({
      title: o.title || '手动输入待办',
      editable: true,
      placeholderText: o.placeholder || '例如：明天下午三点前把季度报表发给张总',
      content: o.value || '',
      confirmText: '解析',
      cancelText: '取消',
      success: function (r) {
        resolve(r && r.confirm ? String(r.content || '').trim() : '');
      },
      fail: function () {
        resolve('');
      }
    });
  });
}

module.exports = {
  start: start,
  stop: stop,
  cancel: cancel,
  isRecording: isRecording,
  available: available,
  ensureRecordAuth: ensureRecordAuth,
  promptManualText: promptManualText
};
