/**
 * todo-item 组件 —— 单条待办
 * 所有展示文案（截止时间/相对时间/来源/优先级）由页面预计算后传入，
 * 组件内不做任何 WXML 复杂表达式，保证渲染层轻量、可控。
 *
 * 事件：
 *  - toggle  点击左侧复选框（勾选/取消勾选）
 *  - edit    点击卡片主体（进入编辑）
 *  - more    长按卡片（由页面弹操作菜单：编辑/完成/删除）
 */
Component({
  options: {
    addGlobalClass: true
  },

  properties: {
    item: {
      type: Object,
      value: {}
    },
    // 是否禁用交互（同步中不需要禁用，这里留作扩展）
    disabled: {
      type: Boolean,
      value: false
    }
  },

  data: {},

  methods: {
    onToggle() {
      if (this.data.disabled) return;
      // 勾选即时反馈：动画由 wxss transition 完成，触感由页面统一处理
      this.triggerEvent('toggle', { id: this.data.item.id });
    },

    onEdit() {
      if (this.data.disabled) return;
      this.triggerEvent('edit', { id: this.data.item.id });
    },

    onMore() {
      if (this.data.disabled) return;
      this.triggerEvent('more', { id: this.data.item.id });
    }
  }
});
