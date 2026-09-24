/**
 * float-ball 组件 —— 常驻悬浮球（可拖拽 + 长按语音 + 单击展开面板）
 *
 * 手势判定（三态互斥，避免误触）：
 *   手指按下 → 起 350ms 定时器
 *     ├─ 350ms 内位移 > 8px  → 进入「拖拽」态（取消长按定时器，跟手移动，松手吸附左右边缘）
 *     ├─ 350ms 到且未拖拽     → 进入「录音」态（震动 + 放大 + 波纹 + 实时文字气泡）
 *     │     └─ 录音中手指上滑 > 80px → 「取消」态（气泡显示「松开取消」，松手丢弃）
 *     └─ 未拖拽未录音且快速抬起（< 350ms）→ 「单击」态（展开/收起底部面板）
 *
 * 为什么不用 movable-area/movable-view：movable 组件会在页面上生成一层全屏可移动区域，
 * 挡住底层列表的滚动与点击；这里用 position:fixed + touch 事件自行算坐标，只占球体本身。
 *
 * 位置持久化：storage key = qt_float_pos，{ x, y }（px），松手后写入。
 */
const config = require('../../config');

const UI = config.ui || {};
const POS_KEY = 'qt_float_pos';
const BALL_RPX = UI.ballSizeRpx || 108;
const LONG_PRESS_MS = UI.floatLongPressMs || 350;
const DRAG_PX = UI.floatDragThresholdPx || 8;
const CANCEL_PX = UI.floatCancelOffsetPx || 80;
const EDGE_GAP = UI.edgeGapPx || 8;

Component({
  options: {
    addGlobalClass: true
  },

  properties: {
    // 面板是否展开：展开时球体显示「关闭」态（×）
    expanded: {
      type: Boolean,
      value: false
    },
    // AI 解析中：球体显示忙碌转圈
    busy: {
      type: Boolean,
      value: false
    },
    // 录音实时识别文字（气泡展示）
    hint: {
      type: String,
      value: ''
    }
  },

  data: {
    x: 0,
    y: 0,
    ready: false, // 位置算好前不渲染，避免闪一下 (0,0)
    recording: false, // 录音态
    canceling: false, // 上滑取消态
    bubbleBelow: false // 球太靠上时气泡显示在下方
  },

  lifetimes: {
    attached() {
      this.initGeometry();
      this.restorePos();
      this.bindResize();
    },
    detached() {
      this.clearLongPress();
      this.unbindResize();
    }
  },

  methods: {
    /* ======================= 几何与位置 ======================= */

    initGeometry() {
      let info = null;
      try {
        if (typeof wx.getWindowInfo === 'function') info = wx.getWindowInfo();
        else info = wx.getSystemInfoSync();
      } catch (e) {
        info = null;
      }
      if (!info) {
        try {
          info = getApp().globalData.windowInfo;
        } catch (e) {
          info = null;
        }
      }
      info = info || { windowWidth: 375, windowHeight: 667, statusBarHeight: 20 };
      const w = Number(info.windowWidth) || 375;
      const h = Number(info.windowHeight) || 667;
      const ballPx = Math.round((BALL_RPX * w) / 750);
      this._win = { windowWidth: w, windowHeight: h };
      this._ballPx = ballPx;
      this._bounds = {
        minX: EDGE_GAP,
        maxX: Math.max(EDGE_GAP, w - ballPx - EDGE_GAP),
        minY: Math.round((Number(info.statusBarHeight) || 20) + 8),
        maxY: Math.max(EDGE_GAP, h - ballPx - 20)
      };
    },

    bindResize() {
      if (typeof wx.onWindowResize !== 'function') return;
      const self = this;
      this._onResize = function () {
        self.initGeometry();
        self.setData({
          x: self.clamp(self.data.x, self._bounds.minX, self._bounds.maxX),
          y: self.clamp(self.data.y, self._bounds.minY, self._bounds.maxY)
        });
      };
      wx.onWindowResize(this._onResize);
    },

    unbindResize() {
      if (this._onResize && typeof wx.offWindowResize === 'function') {
        wx.offWindowResize(this._onResize);
      }
      this._onResize = null;
    },

    clamp(v, min, max) {
      const n = Number(v) || 0;
      if (n < min) return min;
      if (n > max) return max;
      return n;
    },

    /** 读取上次位置；没有则默认贴在右侧 62% 高度处 */
    restorePos() {
      let pos = null;
      try {
        pos = wx.getStorageSync(POS_KEY);
      } catch (e) {
        pos = null;
      }
      const b = this._bounds;
      let x;
      let y;
      if (pos && typeof pos.x === 'number' && typeof pos.y === 'number') {
        x = this.clamp(pos.x, b.minX, b.maxX);
        y = this.clamp(pos.y, b.minY, b.maxY);
      } else {
        x = b.maxX;
        y = Math.round(b.minY + (b.maxY - b.minY) * 0.62);
      }
      this.setData({ x: x, y: y, ready: true, bubbleBelow: y < 140 });
    },

    savePos(x, y) {
      try {
        wx.setStorageSync(POS_KEY, { x: Math.round(x), y: Math.round(y) });
      } catch (e) {
        // 忽略：位置存不上不影响使用
      }
    },

    /* ======================= 手势 ======================= */

    clearLongPress() {
      if (this._lpTimer) {
        clearTimeout(this._lpTimer);
        this._lpTimer = null;
      }
    },

    onTouchStart(e) {
      const t = (e.touches && e.touches[0]) || (e.changedTouches && e.changedTouches[0]);
      if (!t) return;
      this._startX = t.clientX;
      this._startY = t.clientY;
      this._startLeft = this.data.x;
      this._startTop = this.data.y;
      this._startAt = Date.now();
      this._dragging = false;
      this._recording = false;
      this._canceling = false;
      this._moved = false;

      const self = this;
      this.clearLongPress();
      this._lpTimer = setTimeout(function () {
        self._lpTimer = null;
        self.beginRecord();
      }, LONG_PRESS_MS);
    },

    onTouchMove(e) {
      const t = (e.touches && e.touches[0]) || (e.changedTouches && e.changedTouches[0]);
      if (!t) return;
      const dx = t.clientX - this._startX;
      const dy = t.clientY - this._startY;

      // 1) 录音中：只判断「上滑取消」，不再进入拖拽（录音优先级更高）
      if (this._recording) {
        const canceling = dy <= -CANCEL_PX;
        if (canceling !== this._canceling) {
          this._canceling = canceling;
          this.setData({ canceling: canceling });
        }
        return;
      }

      // 2) 位移超过阈值 → 进入拖拽（同时取消长按定时器，避免拖到一半开始录音）
      if (!this._dragging && (Math.abs(dx) > DRAG_PX || Math.abs(dy) > DRAG_PX)) {
        this._dragging = true;
        this._moved = true;
        this.clearLongPress();
      }
      if (!this._dragging) return;

      const b = this._bounds;
      const x = this.clamp(this._startLeft + dx, b.minX, b.maxX);
      const y = this.clamp(this._startTop + dy, b.minY, b.maxY);
      if (x === this.data.x && y === this.data.y) return;
      this.setData({ x: x, y: y, bubbleBelow: y < 140 });
    },

    onTouchEnd() {
      this.clearLongPress();

      // A. 录音结束（正常结束 or 上滑取消）
      if (this._recording) {
        const canceled = this._canceling;
        this._recording = false;
        this._canceling = false;
        this.setData({ recording: false, canceling: false });
        this.triggerEvent('recordend', {
          cancelled: canceled,
          duration: Math.max(0, Date.now() - this._startAt)
        });
        return;
      }

      // B. 拖拽结束 → 吸附到最近的左/右边缘并记住位置
      if (this._dragging) {
        this._dragging = false;
        const b = this._bounds;
        const center = this.data.x + this._ballPx / 2;
        const x = center < this._win.windowWidth / 2 ? b.minX : b.maxX;
        this.setData({ x: x });
        this.savePos(x, this.data.y);
        return;
      }

      // C. 快速单击 → 展开/收起面板
      if (!this._moved && Date.now() - this._startAt < LONG_PRESS_MS + 80) {
        this.triggerEvent('balltap', {});
      }
    },

    onTouchCancel() {
      this.clearLongPress();
      if (this._recording) {
        this._recording = false;
        this._canceling = false;
        this.setData({ recording: false, canceling: false });
        // 系统打断（来电等）→ 按取消处理，避免录音状态悬挂
        this.triggerEvent('recordend', { cancelled: true, duration: Math.max(0, Date.now() - this._startAt) });
        return;
      }
      if (this._dragging) {
        this._dragging = false;
        this.savePos(this.data.x, this.data.y);
      }
    },

    /** 长按达成：震动 + 进入录音态，交给页面去真正启动录音 */
    beginRecord() {
      if (this._dragging || this._recording) return;
      this._recording = true;
      try {
        if (typeof wx.vibrateShort === 'function') {
          wx.vibrateShort({ type: 'medium', fail: function () {} });
        }
      } catch (e) {
        // 忽略：部分基础库不支持 type 参数
      }
      this.setData({ recording: true, canceling: false });
      this.triggerEvent('recordstart', {});
    },

    /** 供页面在外部状态变化时强制复位（例如录音被系统中断） */
    resetGesture() {
      this.clearLongPress();
      this._recording = false;
      this._dragging = false;
      this._canceling = false;
      this.setData({ recording: false, canceling: false });
    }
  }
});
