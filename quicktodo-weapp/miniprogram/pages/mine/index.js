/**
 * pages/mine —— 我的 / 设置
 * 内容：
 *  1) 云环境 / 登录态（openid 脱敏）/ 待办统计 / 待上传条数
 *  2) 扫码登录 Mac（wx.scanCode → 正则取 ticket → auth.confirmTicket）
 *  3) 添加到微信浮窗 / 手机桌面：快速唤起指引（微信未开放该 API，只能给操作路径）
 *  4) 清空已完成 / 清空本地缓存 / 关于
 */
const config = require('../../config');
const store = require('../../utils/store');
const sync = require('../../utils/sync');
const format = require('../../utils/format');
const api = require('../../utils/api');

/** 从扫码结果里提取 32 位十六进制 ticket（契约 §4.2） */
function extractTicket(raw) {
  const s = String(raw || '');
  let m = s.match(/quicktodo:\/\/login\?ticket=([0-9a-fA-F]{32})/);
  if (m) return m[1].toLowerCase();
  m = s.match(/[?&]ticket=([0-9a-fA-F]{32})/);
  if (m) return m[1].toLowerCase();
  // 纯 hex（Mac 端可能只渲染了 ticket 本身）
  m = s.match(/(^|[^0-9a-fA-F])([0-9a-fA-F]{32})([^0-9a-fA-F]|$)/);
  if (m) return m[2].toLowerCase();
  return '';
}

/** 平台 → 快速唤起指引（微信没有「加到浮窗/桌面」的开放 API，只能引导用户手动操作） */
const GUIDE = {
  ios: [
    { title: '① 添加到微信浮窗', desc: '在当前页面点右上角「⋯」→ 点「浮窗」，之后从微信首页左上角「⋯」或右滑即可快速回到 QuickTodo。' },
    { title: '② 添加到主屏幕（类桌面图标）', desc: '点右上角「⋯」→「在浏览器打开」→ Safari 底部分享按钮 →「添加到主屏幕」。' },
    { title: '③ 用快捷指令一键唤起', desc: '「快捷指令」App → 新建 → 添加操作「打开 App」或「打开 URL」→ 填入小程序链接，可放到桌面或对 Siri 说一句话。' },
    { title: '④ 聊天置顶', desc: '把 QuickTodo 小程序卡片发给「文件传输助手」并置顶，也能实现一眼可见的入口。' }
  ],
  android: [
    { title: '① 添加到桌面', desc: '点右上角「⋯」→「添加到桌面」，桌面上会生成快捷图标，点击直达本小程序。' },
    { title: '② 添加到微信浮窗', desc: '点右上角「⋯」→「浮窗」，微信内可随时从侧边/首页入口回到 QuickTodo。' },
    { title: '③ 最近使用', desc: '微信「发现 → 小程序 → 最近使用」里长按本小程序可置顶，减少查找成本。' }
  ],
  devtools: [
    { title: '开发者工具环境', desc: '模拟器里没有真实的「浮窗 / 添加到桌面」入口。' },
    { title: '请用真机预览', desc: '点工具栏「预览」，用手机微信扫码打开后，再按右上角「⋯」体验浮窗/桌面快捷方式。' }
  ]
};

Page({
  data: {
    // 环境
    cloudEnvText: '未配置（本地模式）',
    localMode: true,
    cloudReady: false,
    openidMasked: '未获取',
    openidRaw: '',
    serverCount: 0,
    // 统计
    counts: { all: 0, todo: 0, done: 0 },
    pending: 0,
    lastSyncText: '尚未同步',
    syncing: false,
    // 版本
    version: config.version,
    contractVersion: config.contractVersion,
    // 指引面板
    guideVisible: false,
    guideSteps: [],
    platform: 'devtools'
  },

  onLoad() {
    const self = this;
    this._unsubStore = store.subscribe(function () {
      self.refreshStats();
    });
    this._unsubSync = sync.onStateChange(function (s) {
      self.applySyncState(s);
    });
    this.detectPlatform();
    this.setData({
      cloudEnvText: config.cloudEnv ? config.cloudEnv : '未配置（本地模式）',
      localMode: sync.getState().localMode,
      cloudReady: api.cloudReady()
    });
    this.refreshStats();
    this.applySyncState(sync.getState());
  },

  onShow() {
    this.setData({ cloudReady: api.cloudReady(), localMode: sync.getState().localMode });
    this.refreshStats();
    this.applySyncState(sync.getState());
    this.loadIdentity();
  },

  onUnload() {
    if (this._unsubStore) this._unsubStore();
    if (this._unsubSync) this._unsubSync();
  },

  detectPlatform() {
    let platform = 'devtools';
    try {
      const info = getApp().globalData.windowInfo || wx.getSystemInfoSync();
      const p = String((info && info.platform) || '').toLowerCase();
      if (p === 'android') platform = 'android';
      else if (p === 'ios') platform = 'ios';
      else platform = 'devtools';
    } catch (e) {
      platform = 'devtools';
    }
    this.setData({ platform: platform });
  },

  refreshStats() {
    this.setData({ counts: store.counts(), pending: store.outboxSize() });
  },

  applySyncState(s) {
    if (!s) return;
    let lastSyncText = '尚未同步';
    if (s.localMode) lastSyncText = '本地模式：不联网';
    else if (s.syncing) lastSyncText = '同步中…';
    else if (s.lastError) lastSyncText = '上次同步失败：' + s.lastError;
    else if (s.lastSyncAt) lastSyncText = '上次同步：' + format.formatRelative(s.lastSyncAt, Date.now());
    this.setData({ syncing: s.syncing, pending: s.pending, lastSyncText: lastSyncText, localMode: s.localMode });
  },

  /** ping 云函数拿 openid（契约 §2.6），失败不打扰用户 */
  async loadIdentity() {
    if (!this.data.cloudReady) {
      this.setData({ openidMasked: '本地模式未登录', openidRaw: '' });
      return;
    }
    try {
      const res = await api.todo.ping();
      // ping 响应也带 serverTime（契约 §2.6）：顺手抬高逻辑时钟水位
      store.observeServerTime(res && res.serverTime);
      const openid = String((res && res.openid) || '');
      this.setData({
        openidRaw: openid,
        openidMasked: format.maskOpenid(openid),
        serverCount: Number((res && res.count) || 0)
      });
    } catch (e) {
      this.setData({ openidMasked: '获取失败：' + ((e && e.message) || '未知错误') });
    }
  },

  /* ======================= 同步 ======================= */

  onSyncTap() {
    if (this.data.localMode) {
      wx.showToast({ title: '本地模式：请先配置 cloudEnv', icon: 'none' });
      return;
    }
    const self = this;
    wx.showLoading({ title: '同步中', mask: true });
    sync.trigger('mine-manual').then(function (res) {
      wx.hideLoading();
      self.refreshStats();
      wx.showToast({ title: res && res.ok ? '同步完成' : (res && res.error) || '同步失败', icon: 'none' });
    });
  },

  /* ======================= 扫码登录 Mac（契约 §4） ======================= */

  onScanLogin() {
    const self = this;
    if (!this.data.cloudReady) {
      wx.showModal({
        title: '需要云环境',
        content: '扫码登录依赖云函数 auth。请在 config.js 里填写 cloudEnv，并部署 auth 云函数后再试。',
        showCancel: false
      });
      return;
    }
    wx.scanCode({
      onlyFromCamera: false, // 允许从相册选二维码
      scanType: ['qrCode'],
      success(res) {
        const raw = String((res && res.result) || '');
        const ticket = extractTicket(raw);
        if (!ticket) {
          wx.showModal({
            title: '二维码无法识别',
            content: '没有从二维码里解析出 ticket。内容：' + format.truncate(raw, 80),
            showCancel: false
          });
          return;
        }
        self.confirmTicket(ticket);
      },
      fail(err) {
        const msg = String((err && err.errMsg) || '');
        if (/cancel/i.test(msg)) return; // 用户主动取消：静默返回，不报错
        wx.showToast({ title: '扫码失败，请重试', icon: 'none' });
      }
    });
  },

  async confirmTicket(ticket) {
    wx.showLoading({ title: '确认中', mask: true });
    let okMsg = '';
    let errMsg = '';
    try {
      // 契约 §4.2：confirmTicket 的 openid 由云函数上下文提供，小程序不传
      const res = await api.auth.confirmTicket(ticket);
      okMsg = 'Mac 端已登录成功' + (res && res.openid ? '（' + format.maskOpenid(res.openid) + '）' : '');
    } catch (e) {
      if (e && e.code === 'bad_request') {
        errMsg = '二维码已过期或已被使用，请在 Mac 端重新生成后扫码。';
      } else if (e && e.code === 'cloud_unavailable') {
        errMsg = '云环境不可用，请检查 config.js 的 cloudEnv。';
      } else {
        errMsg = (e && e.message) || '确认失败，请重试。';
      }
    }
    wx.hideLoading();
    if (okMsg) {
      wx.showModal({ title: '登录成功', content: okMsg + '，现在可以在 Mac 上查看待办了。', showCancel: false, confirmText: '好' });
      this.loadIdentity();
    } else {
      wx.showModal({ title: '登录失败', content: errMsg, showCancel: false });
    }
  },

  /* ======================= 浮窗 / 桌面指引 ======================= */

  onGuide() {
    this.detectPlatform();
    this.setData({ guideVisible: true, guideSteps: GUIDE[this.data.platform] || GUIDE.devtools });
  },

  onGuideClose() {
    this.setData({ guideVisible: false });
  },

  onGuideMaskTap() {
    this.setData({ guideVisible: false });
  },

  noop() {},

  /* ======================= 危险操作 ======================= */

  /**
   * 清空已完成。
   * 契约 §2.5.1：clearDone 是**可选**便捷动作，两端统一实现为
   * 「本地软删除 + outbox 批量 remove 上抛」，语义与 clearDone 完全等价，因此这里不调 clearDone。
   */
  onClearDone() {
    const n = this.data.counts.done;
    if (!n) {
      wx.showToast({ title: '没有已完成的待办', icon: 'none' });
      return;
    }
    const self = this;
    wx.showModal({
      title: '清空已完成',
      content: '将删除 ' + n + ' 条已完成的待办，并同步到 Mac 端。此操作不可撤销，确定继续？',
      confirmText: '清空',
      confirmColor: '#fa5151',
      success(r) {
        if (!r.confirm) return;
        const c = store.softRemoveDone();
        sync.trigger('clear-done');
        self.refreshStats();
        wx.showToast({ title: '已清空 ' + c + ' 条', icon: 'none' });
      }
    });
  },

  onClearCache() {
    const self = this;
    const pending = store.outboxSize();
    const content = pending
      ? '本机有 ' + pending + ' 条改动还没同步到云端，清空后会丢失这些改动，并从云端重新拉取。确定清空？'
      : '将清空本机缓存（云端数据不受影响），随后重新从云端拉取。确定清空？';
    wx.showModal({
      title: '清空本地缓存',
      content: content,
      confirmText: '清空',
      confirmColor: '#fa5151',
      success(r) {
        if (!r.confirm) return;
        store.clearAll();
        self.refreshStats();
        sync.trigger('clear-cache');
        wx.showToast({ title: '本地缓存已清空', icon: 'none' });
      }
    });
  },

  onAbout() {
    wx.showModal({
      title: '关于 QuickTodo',
      content:
        '版本：' + config.version + '\n' +
        '契约版本：' + config.contractVersion + '（docs/SYNC-PROTOCOL.md）\n' +
        '云函数：todo / ai / auth\n' +
        '同步策略：本地优先 + outbox 上抛 + LWW(updateTime)\n' +
        '排序：优先级 → 截止时间 → 创建时间（契约 §5.5）',
      showCancel: false,
      confirmText: '好'
    });
  },

  /** 复制 openid（便于 Mac 端排查同一个账号） */
  onCopyOpenid() {
    if (!this.data.openidRaw) {
      wx.showToast({ title: '暂未取得 openid', icon: 'none' });
      return;
    }
    wx.setClipboardData({
      data: this.data.openidRaw,
      success() {
        wx.showToast({ title: '已复制', icon: 'none' });
      }
    });
  }
});
