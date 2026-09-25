/**
 * pages/index —— 主列表页
 *
 * 职责：
 *  - 渲染列表（分类切换 / 排序 / 空状态），所有展示字段在这里预计算（WXML 只做简单绑定）
 *  - 承载悬浮球与底部面板的交互编排：长按语音 → AI 解析 → 可编辑预览 → 导入
 *  - 手动增删改查（本地优先：先写 store 立即刷新，再异步同步）
 *
 * 数据流：store(缓存+outbox) --subscribe--> 本页 refresh() --setData--> 视图
 *        sync(拉取/上抛) --onStateChange--> 本页顶部状态条 + 一次性 toast
 */
const config = require('../../config');
const store = require('../../utils/store');
const sync = require('../../utils/sync');
const voice = require('../../utils/voice');
const format = require('../../utils/format');
const api = require('../../utils/api');

const EMPTY_ITEM = {}; // 稳定引用：避免无意义的 observer 触发，保住用户正在输入的表单草稿

const FILTERS = [
  { key: 'all', label: '全部' },
  { key: 'todo', label: '待办' },
  { key: 'done', label: '已完成' }
];

/** 单条待办 → 视图行（预计算所有展示文案） */
function rowOf(t, now) {
  const dl = format.formatDeadline(t.deadline, now);
  const done = t.status === 'done';
  const rel = format.formatRelative(done ? t.updateTime : t.createTime, now);
  let relText = rel;
  if (done && rel) relText = '完成于 ' + rel;
  return {
    id: t.id,
    content: t.content,
    done: done,
    priority: t.priority,
    priorityCls: 'p-' + t.priority,
    deadlineText: dl.text,
    deadlineCls: dl.cls,
    sourceIcon: format.sourceIcon(t.source),
    sourceText: format.sourceLabel(t.source),
    sourceCls: format.sourceCls(t.source),
    relText: relText
  };
}

/** 顶部同步状态文案 */
function syncTextOf(s) {
  if (s.localMode) return '本地模式 · 数据仅存本机';
  if (s.syncing) return '同步中…';
  if (s.lastError) return '同步失败：' + s.lastError + (s.pending ? '（' + s.pending + ' 条待上传）' : '');
  if (s.pending > 0) return s.pending + ' 条待上传，正在重试…';
  if (!s.lastSyncAt) return '尚未同步';
  return '已同步 · ' + format.formatRelative(s.lastSyncAt, Date.now());
}

Page({
  data: {
    filter: 'all',
    tabs: [],
    list: [],
    counts: { all: 0, todo: 0, done: 0 },
    // 同步状态
    localMode: false,
    syncing: false,
    syncText: '',
    syncError: '',
    pending: 0,
    // 面板与表单
    sheetVisible: false,
    sheetMode: 'create',
    sheetItem: EMPTY_ITEM,
    // 语音
    voiceState: 'idle',
    voiceText: '',
    voiceError: '',
    ballHint: '',
    ballBusy: false,
    // AI 预览
    previewItems: [],
    previewToken: 0,
    aiLoading: false,
    aiEngine: '',
    aiNote: '',
    lastVoiceText: '',
    // 空状态
    emptyTitle: '还没有待办',
    emptyDesc: '长按右下角悬浮球说一句话，或点它手动添加'
  },

  /* ======================= 生命周期 ======================= */

  onLoad() {
    const self = this;
    this._lastNoticeAt = 0;
    this._unsubStore = store.subscribe(function () {
      self.refresh();
    });
    this._unsubSync = sync.onStateChange(function (s) {
      self.applySyncState(s);
    });
    this.setData({ localMode: sync.getState().localMode });
    this.applySyncState(sync.getState());
    this.refresh();
    this.startTicker();
  },

  onShow() {
    this.setData({ localMode: sync.getState().localMode });
    this.refresh();
    this.startTicker();
    // 契约 §5.7：小程序 onShow 拉一次
    sync.trigger('onshow');
  },

  onHide() {
    this.stopTicker();
  },

  onUnload() {
    this.stopTicker();
    if (this._unsubStore) this._unsubStore();
    if (this._unsubSync) this._unsubSync();
    voice.cancel();
  },

  onPullDownRefresh() {
    const self = this;
    if (this.data.localMode) {
      wx.stopPullDownRefresh();
      wx.showToast({ title: '本地模式：未配置云环境', icon: 'none' });
      return;
    }
    sync.trigger('pull').then(function () {
      self.refresh();
      wx.stopPullDownRefresh();
    }, function () {
      wx.stopPullDownRefresh();
    });
  },

  /** 相对时间/逾期状态需要随时间推移刷新，60s 一次（仅页面可见时） */
  startTicker() {
    const self = this;
    if (this._ticker) return;
    this._ticker = setInterval(function () {
      self.refresh();
    }, 60000);
  },

  stopTicker() {
    if (this._ticker) {
      clearInterval(this._ticker);
      this._ticker = null;
    }
  },

  /* ======================= 渲染 ======================= */

  refresh() {
    const now = Date.now();
    const filter = this.data.filter;
    const rows = store.getList(filter, 'smart').map(function (t) {
      return rowOf(t, now);
    });
    const c = store.counts();

    const tabs = FILTERS.map(function (f) {
      return { key: f.key, label: f.label, count: c[f.key] || 0 };
    });

    let emptyTitle = '还没有待办';
    let emptyDesc = '长按右下角悬浮球说一句话，或点它手动添加';
    if (filter === 'todo') {
      emptyTitle = '待办都清空了';
      emptyDesc = '点右下角悬浮球，随时记一条';
    } else if (filter === 'done') {
      emptyTitle = '还没有完成的待办';
      emptyDesc = '点击左侧圆圈即可标记完成';
    }

    this.setData({
      list: rows,
      counts: c,
      tabs: tabs,
      emptyTitle: emptyTitle,
      emptyDesc: emptyDesc
    });
  },

  applySyncState(s) {
    if (!s) return;
    this.setData({
      localMode: s.localMode,
      syncing: s.syncing,
      syncError: s.lastError || '',
      pending: s.pending,
      syncText: syncTextOf(s)
    });
    // 服务端拒收/stale 提示只弹一次
    if (s.notice && s.noticeAt && s.noticeAt !== this._lastNoticeAt) {
      this._lastNoticeAt = s.noticeAt;
      wx.showToast({ title: s.notice, icon: 'none', duration: 2800 });
    }
  },

  /* ======================= 分类 / 同步交互 ======================= */

  onFilter(e) {
    const f = e.currentTarget.dataset.filter;
    if (!f || f === this.data.filter) return;
    this.setData({ filter: f });
    this.refresh();
  },

  onSyncTap() {
    if (this.data.localMode) {
      wx.showToast({ title: '本地模式：填写 config.js 的 cloudEnv 后可用', icon: 'none', duration: 2600 });
      return;
    }
    const self = this;
    wx.showLoading({ title: '同步中', mask: true });
    sync.trigger('manual').then(function (res) {
      wx.hideLoading();
      self.refresh();
      if (res && res.ok) {
        wx.showToast({ title: res.pushed || res.pulled ? '同步完成' : '已是最新', icon: 'none' });
      } else {
        wx.showToast({ title: (res && res.error) || '同步失败', icon: 'none' });
      }
    });
  },

  /* ======================= 列表项交互 ======================= */

  onToggle(e) {
    const id = e.detail && e.detail.id;
    if (!id) return;
    const next = store.toggleTodo(id);
    if (!next) return;
    try {
      if (typeof wx.vibrateShort === 'function') wx.vibrateShort({ type: 'light', fail: function () {} });
    } catch (err) {
      // 忽略：部分机型/基础库不支持
    }
    sync.trigger('toggle');
  },

  onEdit(e) {
    const id = e.detail && e.detail.id;
    const t = store.get(id);
    if (!t) return;
    this.setData({
      sheetVisible: true,
      sheetMode: 'edit',
      sheetItem: {
        id: t.id,
        content: t.content,
        date: format.toDateStr(t.deadline),
        time: format.toTimeStr(t.deadline) || format.DEFAULT_TIME,
        priority: t.priority
      }
    });
  },

  onMore(e) {
    const self = this;
    const id = e.detail && e.detail.id;
    const t = store.get(id);
    if (!t) return;
    const doneLabel = t.status === 'done' ? '标记为未完成' : '标记为已完成';
    wx.showActionSheet({
      itemList: ['编辑', doneLabel, '删除'],
      success(res) {
        if (res.tapIndex === 0) {
          self.onEdit({ detail: { id: id } });
        } else if (res.tapIndex === 1) {
          store.toggleTodo(id);
          sync.trigger('toggle');
        } else if (res.tapIndex === 2) {
          self.confirmRemove(id);
        }
      },
      fail() {
        // 用户取消菜单，静默
      }
    });
  },

  /** 删除二次确认（需求 §3） */
  confirmRemove(id) {
    wx.showModal({
      title: '删除待办',
      content: '删除后会同步到 Mac 端，确定删除？',
      confirmText: '删除',
      confirmColor: '#fa5151',
      success(r) {
        if (!r.confirm) return;
        const n = store.softRemove([id]);
        if (n > 0) {
          sync.trigger('delete');
          wx.showToast({ title: '已删除', icon: 'none' });
        }
      }
    });
  },

  /* ======================= 悬浮球 ======================= */

  onBallTap() {
    this.setData({
      sheetVisible: !this.data.sheetVisible,
      sheetMode: 'create',
      sheetItem: EMPTY_ITEM
    });
  },

  onRecordStart() {
    const self = this;
    this.setData({
      sheetVisible: true,
      voiceState: 'recording',
      voiceText: '',
      voiceError: '',
      ballHint: '正在聆听…'
    });
    voice.start(this.voiceHandlers());
  },

  onRecordEnd(e) {
    const cancelled = !!(e.detail && e.detail.cancelled);
    if (cancelled) {
      // 上滑取消：丢弃结果，不调用 AI
      voice.cancel();
      this.setData({ voiceState: 'idle', voiceText: '', ballHint: '', ballBusy: false });
      wx.showToast({ title: '已取消', icon: 'none' });
      return;
    }
    this.setData({ voiceState: 'parsing', ballHint: '识别中…' });
    voice.stop(); // 最终结果在 onFinal / onError 回调里处理
  },

  /** 语音回调集合（悬浮球长按 与 面板按钮 共用） */
  voiceHandlers() {
    const self = this;
    return {
      onPartial(text) {
        self.setData({ voiceText: text, ballHint: text });
      },
      onFinal(text) {
        self.onVoiceFinal(text);
      },
      onError(err) {
        self.onVoiceError(err);
      }
    };
  },

  /** 面板里的「开始录音/结束录音」按钮（不方便长按球时的替代入口） */
  onVoiceToggle() {
    if (voice.isRecording()) {
      this.setData({ voiceState: 'parsing', ballHint: '识别中…' });
      voice.stop();
      return;
    }
    this.setData({ voiceState: 'recording', voiceText: '', voiceError: '', ballHint: '正在聆听…' });
    voice.start(this.voiceHandlers());
  },

  onVoiceFinal(text) {
    const t = String(text || '').trim();
    if (!t) {
      this.onVoiceError({ code: 'empty_result', message: '没有识别到内容，请手动输入' });
      return;
    }
    this.setData({
      voiceText: t,
      lastVoiceText: t,
      voiceState: 'parsing',
      ballHint: 'AI 解析中…',
      ballBusy: true
    });
    this.parseText(t);
  },

  /**
   * 语音异常统一降级入口（需求 §2 硬性要求：功能绝不死掉）
   * 插件不可用 / 识别为空 / 超时 / 录音失败 → 弹可编辑文本框手动补充
   */
  onVoiceError(err) {
    const e = err || {};
    this.setData({
      voiceState: 'error',
      voiceError: e.message || '语音识别失败，请手动输入',
      ballHint: '',
      ballBusy: false
    });
    if (e.code === 'auth_denied') {
      // 权限弹窗已经弹过；若用户选的是「手动输入」，直接进降级输入框
      if (e.wantManual) this.manualFallback();
      return;
    }
    if (
      e.code === 'plugin_unavailable' ||
      e.code === 'empty_result' ||
      e.code === 'timeout' ||
      e.code === 'record_error'
    ) {
      this.manualFallback();
    }
  },

  async manualFallback() {
    const text = await voice.promptManualText({
      title: '手动输入待办',
      placeholder: '例如：明天下午三点前把季度报表发给张总'
    });
    if (!text) {
      this.setData({ voiceState: 'idle', ballBusy: false });
      return;
    }
    this.setData({
      voiceText: text,
      lastVoiceText: text,
      voiceError: '',
      voiceState: 'parsing',
      ballHint: 'AI 解析中…',
      ballBusy: true
    });
    this.parseText(text);
  },

  /** 面板里直接输入文字 → 同样走 AI 解析 */
  onManualText(e) {
    const text = String((e.detail && e.detail.text) || '').trim();
    if (!text) return;
    this.setData({ lastVoiceText: text, voiceState: 'parsing', ballBusy: true });
    this.parseText(text);
  },

  /**
   * 调 ai 云函数解析（契约 §3）。
   * 任何失败都不阻断：拿不到结构化结果就用原文生成一条可编辑预览。
   */
  async parseText(text) {
    let res = null;
    try {
      // 契约 §3.1：小程序通道 payload = event，source 固定 mini-voice
      res = await api.ai.parse({
        text: text,
        source: 'mini-voice',
        now: Date.now(),
        timezone: config.ai.timezone,
        maxItems: config.ai.maxItems
      });
    } catch (e) {
      res = { ok: false, error: { code: (e && e.code) || 'internal', message: (e && e.message) || '解析失败' }, fallbackText: text };
    }

    const ok = !!(res && res.ok);
    const errCode = (res && res.error && res.error.code) || '';
    const errMsg = (res && res.error && res.error.message) || '未知错误';
    // 无论解析成功与否，都把「原始转写」保留成 1 条可编辑预览：登录态失效/云函数异常时也不会丢文本
    const todos = ok && res.todos && res.todos.length ? res.todos : [{ content: text, deadline: null, priority: 'normal' }];

    let note = '';
    if (!ok) {
      if (errCode === 'unauthorized') {
        // 契约 §2.2：ai 也会校验登录态。此时保留原文，让用户手动编辑/勾选后照常导入，
        // 导入走的是本地+outbox，不依赖 ai，因此不会白屏也不会丢文本。
        note = '登录态已失效，AI 解析暂不可用。原始转写已保留在下面，可直接编辑/勾选后导入（稍后下拉刷新即可恢复 AI 解析）';
        wx.showToast({ title: '登录态失效，已保留原文', icon: 'none', duration: 2600 });
      } else {
        note = 'AI 解析不可用（' + errMsg + '），已按原文生成 1 条，可手动编辑后导入';
      }
    } else if (res.engine === 'rule') {
      note = '云端未配置 DeepSeek key，已使用内置规则解析，请确认时间/优先级';
    }

    this.setData({
      previewItems: todos.map(function (t) {
        return {
          content: String((t && t.content) || '').slice(0, 500),
          deadline: Number(t && t.deadline) || 0,
          priority: (t && t.priority) || 'normal',
          checked: true
        };
      }),
      previewToken: this.data.previewToken + 1,
      aiEngine: (res && res.engine) || '',
      aiNote: note,
      aiLoading: false,
      ballBusy: false,
      voiceState: 'idle',
      ballHint: ''
    });
  },

  /* ======================= 面板事件 ======================= */

  onSheetClose() {
    if (voice.isRecording()) voice.cancel();
    this.setData({ sheetVisible: false, voiceState: 'idle', ballHint: '', ballBusy: false });
  },

  /** 手动新增 / 编辑保存（面板 submit 事件） */
  onSheetSubmit(e) {
    const d = e.detail || {};
    const content = String(d.content || '').trim();
    if (!content) {
      wx.showToast({ title: '请输入待办内容', icon: 'none' });
      return;
    }
    const deadline = d.deadline ? Number(d.deadline) : null;

    if (d.mode === 'edit' && d.id) {
      const next = store.updateTodo(d.id, { content: content, deadline: deadline, priority: d.priority });
      if (!next) {
        wx.showToast({ title: '待办不存在', icon: 'none' });
        return;
      }
      sync.trigger('edit');
      this.setData({ sheetVisible: false });
      wx.showToast({ title: '已保存', icon: 'success' });
      return;
    }

    store.createTodo({
      content: content,
      deadline: deadline,
      priority: d.priority,
      source: 'manual',
      rawText: ''
    });
    sync.trigger('create');
    this.setData({ sheetVisible: false });
    wx.showToast({ title: '已添加', icon: 'success' });
  },

  /** AI 预览 → 一键导入（source: mini-voice，rawText 存原始转写文本） */
  onImport(e) {
    const items = (e.detail && e.detail.items) || [];
    const picked = items.filter(function (it) {
      return it.checked && String(it.content || '').trim();
    });
    if (!picked.length) {
      wx.showToast({ title: '请至少勾选一条', icon: 'none' });
      return;
    }
    const raw = this.data.lastVoiceText || '';
    const rows = picked.map(function (it) {
      return store.makeTodo({
        content: it.content,
        deadline: it.deadline,
        priority: it.priority,
        source: 'mini-voice',
        rawText: raw
      });
    });
    store.putMany(rows); // 先写本地（立即刷新 UI）+ 入 outbox
    sync.trigger('import');

    this.setData({
      sheetVisible: false,
      previewItems: [],
      previewToken: this.data.previewToken + 1,
      aiNote: '',
      aiEngine: '',
      voiceText: '',
      voiceState: 'idle',
      lastVoiceText: '',
      ballHint: ''
    });
    wx.showToast({ title: '已导入 ' + rows.length + ' 条', icon: 'none' });
  },

  onDiscardPreview() {
    this.setData({
      previewItems: [],
      previewToken: this.data.previewToken + 1,
      aiNote: '',
      aiEngine: ''
    });
    wx.showToast({ title: '已放弃本批解析', icon: 'none' });
  }
});
