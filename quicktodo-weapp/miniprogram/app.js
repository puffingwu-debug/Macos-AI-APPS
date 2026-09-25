/**
 * app.js —— 小程序入口
 * 职责：
 *  1) 云开发初始化（cloudEnv 为空则进入「本地模式」，绝不报错）
 *  2) 冷启动先把本地缓存读进内存（store.init），保证不白屏
 *  3) 缓存 windowInfo 供悬浮球拖拽做边界计算
 *  4) 同步引擎只做初始化；真正的拉取时机由 index 页 onShow / 下拉刷新 / 变更后触发
 */
const config = require('./config');
const store = require('./utils/store');
const sync = require('./utils/sync');

App({
  globalData: {
    cloudReady: false, // wx.cloud 是否可用且已 init
    localMode: true, // 本地模式：不联网，只写缓存
    openid: '', // 云函数上下文返回的 openid（脱敏展示用）
    serverCount: 0, // ping 返回的服务端条数
    serverVersion: '', // ping 返回的契约版本
    windowInfo: null, // { windowWidth, windowHeight, pixelRatio, statusBarHeight, platform }
    version: config.version,
    contractVersion: config.contractVersion
  },

  onLaunch() {
    this.cacheWindowInfo();
    this.initCloud();
    store.init(); // 冷启动：先渲染缓存
    sync.init({ localMode: this.globalData.localMode });
  },

  onShow() {
    // 页面 onShow 会各自触发同步，这里只做一次兜底刷新（切前台）
    sync.trigger('app-show');
  },

  /**
   * 云开发初始化。cloudEnv 为空 = 本地模式（契约 §5.6 离线可读可写）
   */
  initCloud() {
    if (!config.cloudEnv) {
      this.globalData.cloudReady = false;
      this.globalData.localMode = true;
      return;
    }
    if (!wx.cloud) {
      this.globalData.cloudReady = false;
      this.globalData.localMode = true;
      console.log('[qt:app] 当前基础库不支持 wx.cloud，降级为本地模式');
      return;
    }
    try {
      wx.cloud.init({ env: config.cloudEnv, traceUser: true });
      this.globalData.cloudReady = true;
      this.globalData.localMode = false;
    } catch (e) {
      this.globalData.cloudReady = false;
      this.globalData.localMode = true;
      console.log('[qt:app] 云开发初始化失败，降级为本地模式：' + (e && e.errMsg ? e.errMsg : e));
    }
  },

  /**
   * 缓存窗口信息：悬浮球拖拽、边界吸附都要用（wx.getWindowInfo 优先，旧基础库回退）
   */
  cacheWindowInfo() {
    let info = null;
    try {
      if (typeof wx.getWindowInfo === 'function') {
        info = wx.getWindowInfo();
      } else if (typeof wx.getSystemInfoSync === 'function') {
        info = wx.getSystemInfoSync();
      }
    } catch (e) {
      info = null;
    }
    this.globalData.windowInfo = info || { windowWidth: 375, windowHeight: 667, pixelRatio: 2, statusBarHeight: 20, platform: 'devtools' };
  },

  /**
   * 供页面在窗口尺寸变化时刷新缓存
   */
  refreshWindowInfo() {
    this.cacheWindowInfo();
    return this.globalData.windowInfo;
  }
});
