/**
 * todo-sheet 组件 —— 底部弹出面板
 * 三块内容：
 *  1) 语音区：录音状态 / 实时识别文字 / 错误提示 / 手动输入兜底
 *  2) 快捷新增（编辑模式下变成编辑表单）：内容 + 截止日期 + 时间 + 优先级
 *  3) AI 预览导入：可勾选、可改内容/时间/优先级、可删除、一键导入
 *
 * 数据归属：预览数据由页面传给 previewItems + previewToken（token 变化 = 重新初始化一份预览），
 * 组件内部自己维护编辑中的副本，导入时把最终结果通过 import 事件抛给页面 → 页面写 store。
 *
 * setData 粒度：勾选/优先级/日期时间都用「路径更新」（preview[2].checked），
 * 避免整表替换导致 input 的 value 被回写、打断用户输入；只有增删条目才整表替换（替换前先 flush 输入缓冲）。
 */
const format = require('../../utils/format');

const PRIORITIES = [
  { key: 'high', label: '高' },
  { key: 'normal', label: '中' },
  { key: 'low', label: '低' }
];

const STATE_TEXT = {
  idle: '按住悬浮球说话，上滑可取消',
  recording: '正在聆听…松手结束',
  parsing: 'AI 解析中，请稍候…',
  error: '语音不可用'
};

Component({
  options: {
    addGlobalClass: true
  },

  properties: {
    visible: { type: Boolean, value: false },
    // 'create' | 'edit'
    mode: { type: String, value: 'create' },
    // 编辑对象：{ id, content, date, time, priority }
    item: { type: Object, value: {} },
    // 语音状态：idle | recording | parsing | error
    voiceState: { type: String, value: 'idle' },
    voiceText: { type: String, value: '' },
    voiceError: { type: String, value: '' },
    aiLoading: { type: Boolean, value: false },
    aiEngine: { type: String, value: '' },
    aiNote: { type: String, value: '' },
    previewItems: { type: Array, value: [] },
    // 每次 +1 表示「这是一批新的 AI 结果」，组件据此重置预览
    previewToken: { type: Number, value: 0 }
  },

  data: {
    priorities: PRIORITIES,
    stateText: STATE_TEXT.idle,
    form: {
      content: '',
      date: '',
      time: format.DEFAULT_TIME, // 契约 §3.4：只给日期不给时间 → 当天 23:59:59.999
      priority: 'normal',
      hasDeadline: false
    },
    preview: [],
    checkedCount: 0,
    allChecked: false,
    today: '',
    manualText: ''
  },

  lifetimes: {
    attached() {
      this._keySeq = 0;
      this._pvContent = []; // 预览条目输入缓冲（不参与渲染，避免打断输入）
      this._formContent = '';
      this.setData({ today: format.todayStr() });
    }
  },

  observers: {
    voiceState(v) {
      this.setData({ stateText: STATE_TEXT[v] || STATE_TEXT.idle });
    },
    previewToken() {
      this.initPreview();
    },
    'mode, item'(mode, item) {
      this.fillForm(mode, item);
    }
  },

  methods: {
    /* ======================= 表单（新增/编辑） ======================= */

    fillForm(mode, item) {
      const it = item || {};
      if (mode === 'edit' && it.id) {
        this._formContent = it.content || '';
        this.setData({
          form: {
            content: it.content || '',
            date: it.date || '',
            time: it.time || format.DEFAULT_TIME,
            priority: it.priority || 'normal',
            hasDeadline: !!it.date
          }
        });
      } else if (mode === 'create') {
        this.resetForm();
      }
    },

    resetForm() {
      this._formContent = '';
      this.setData({
        form: { content: '', date: '', time: format.DEFAULT_TIME, priority: 'normal', hasDeadline: false }
      });
    },

    // 输入框不 setData（保持非受控），只在提交时读缓冲
    onContentInput(e) {
      this._formContent = e.detail.value;
    },

    onToggleDeadline(e) {
      const on = !!(e.detail && e.detail.value);
      if (on && !this.data.form.date) {
        // 打开开关但没选日期 → 默认今天 + 当天结束（契约 §3.4），避免出现空截止
        this.setData({ 'form.hasDeadline': true, 'form.date': this.data.today, 'form.time': this.data.form.time || format.DEFAULT_TIME });
        return;
      }
      this.setData({ 'form.hasDeadline': on });
    },

    onDateChange(e) {
      this.setData({ 'form.date': e.detail.value, 'form.hasDeadline': true });
    },

    onTimeChange(e) {
      this.setData({ 'form.time': e.detail.value, 'form.hasDeadline': true });
    },

    onPriority(e) {
      const p = e.currentTarget.dataset.p;
      this.setData({ 'form.priority': p });
    },

    onSubmit() {
      const content = String(this._formContent || this.data.form.content || '').trim();
      if (!content) {
        wx.showToast({ title: '请输入待办内容', icon: 'none' });
        return;
      }
      const f = this.data.form;
      const deadline = f.hasDeadline ? format.combineDateTime(f.date, f.time) : null;
      this.triggerEvent('submit', {
        mode: this.data.mode,
        id: this.data.mode === 'edit' ? (this.data.item && this.data.item.id) || '' : '',
        content: content,
        deadline: deadline,
        priority: f.priority
      });
      if (this.data.mode !== 'edit') this.resetForm();
    },

    /* ======================= 语音区 ======================= */

    onManualInput(e) {
      this._manualText = e.detail.value;
    },

    onManualParse() {
      const text = String(this._manualText || '').trim();
      if (!text) {
        wx.showToast({ title: '请先输入文字', icon: 'none' });
        return;
      }
      this.triggerEvent('manualtext', { text: text });
    },

    onVoiceToggle() {
      this.triggerEvent('voicetoggle', {});
    },

    /* ======================= AI 预览 ======================= */

    initPreview() {
      const raw = this.data.previewItems || [];
      const list = [];
      for (let i = 0; i < raw.length; i++) {
        const it = raw[i] || {};
        const deadline = Number(it.deadline) || 0;
        this._keySeq += 1;
        list.push({
          key: 'pv' + this._keySeq,
          content: String(it.content || ''),
          checked: it.checked !== false,
          priority: it.priority || 'normal',
          date: deadline ? format.toDateStr(deadline) : '',
          time: deadline ? format.toTimeStr(deadline) : format.DEFAULT_TIME
        });
      }
      this._pvContent = list.map(function (x) {
        return x.content;
      });
      this.setData({ preview: list });
      this.recount();
    },

    /** 把输入缓冲里的最新文本写回数组（整表 setData 之前必须调用） */
    flushPreview() {
      const list = this.data.preview || [];
      const buf = this._pvContent || [];
      for (let i = 0; i < list.length; i++) {
        if (typeof buf[i] === 'string') list[i].content = buf[i];
      }
      return list;
    },

    recount() {
      const list = this.data.preview || [];
      let checked = 0;
      for (let i = 0; i < list.length; i++) {
        if (list[i].checked) checked++;
      }
      this.setData({
        checkedCount: checked,
        allChecked: list.length > 0 && checked === list.length
      });
    },

    onPreviewInput(e) {
      const i = Number(e.currentTarget.dataset.index);
      if (isNaN(i)) return;
      this._pvContent[i] = e.detail.value;
    },

    onToggleCheck(e) {
      const i = Number(e.currentTarget.dataset.index);
      const key = 'preview[' + i + '].checked';
      const next = !this.data.preview[i].checked;
      const d = {};
      d[key] = next;
      this.setData(d);
      this.recount();
    },

    onToggleAll() {
      const list = this.flushPreview();
      const target = !this.data.allChecked;
      for (let i = 0; i < list.length; i++) list[i].checked = target;
      this.setData({ preview: list.slice() }); // 传新引用，确保渲染层一定重算
      this.recount();
    },

    onPreviewPriority(e) {
      const i = Number(e.currentTarget.dataset.index);
      const p = e.currentTarget.dataset.p;
      const d = {};
      d['preview[' + i + '].priority'] = p;
      this.setData(d);
    },

    onPreviewDate(e) {
      const i = Number(e.currentTarget.dataset.index);
      const d = {};
      d['preview[' + i + '].date'] = e.detail.value;
      this.setData(d);
    },

    onPreviewTime(e) {
      const i = Number(e.currentTarget.dataset.index);
      const d = {};
      d['preview[' + i + '].time'] = e.detail.value;
      this.setData(d);
    },

    onPreviewDelete(e) {
      const i = Number(e.currentTarget.dataset.index);
      const list = this.flushPreview();
      list.splice(i, 1);
      const buf = this._pvContent || [];
      buf.splice(i, 1);
      this.setData({ preview: list.slice() });
      this.recount();
    },

    /** 组装最终导入数据（含勾选过滤由页面再做一次保险） */
    collectPreview() {
      const list = this.flushPreview();
      const out = [];
      for (let i = 0; i < list.length; i++) {
        const it = list[i];
        const content = String(it.content || '').trim();
        const deadline = it.date ? format.combineDateTime(it.date, it.time) : null;
        out.push({
          content: content,
          deadline: deadline,
          priority: it.priority || 'normal',
          checked: !!it.checked
        });
      }
      return out;
    },

    onImport() {
      const items = this.collectPreview();
      let n = 0;
      for (let i = 0; i < items.length; i++) {
        if (items[i].checked && items[i].content) n++;
      }
      if (!n) {
        wx.showToast({ title: '请至少勾选一条', icon: 'none' });
        return;
      }
      this.triggerEvent('import', { items: items });
    },

    onDiscardPreview() {
      this.triggerEvent('discardpreview', {});
    },

    onPreviewPriorityTapAll() {
      // 预留：批量改优先级（当前版本不需要）
    },

    /* ======================= 关闭 ======================= */

    onClose() {
      this.triggerEvent('close', {});
    },

    onMaskTap() {
      this.triggerEvent('close', {});
    },

    noop() {}
  }
});
