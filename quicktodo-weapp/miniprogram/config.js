/**
 * config.js —— QuickTodo 小程序端唯一配置入口
 *
 * 说明：
 * 1) 这里只放「非敏感」配置。任何密钥（例如 DEEPSEEK_API_KEY）都只能存在于云函数环境变量，
 *    小程序端永远不出现 key，也不直连 api.deepseek.com（契约 §3.3）。
 * 2) cloudEnv 为空字符串时，小程序进入「本地模式」：不初始化云开发、不发网络请求，
 *    数据只写本机缓存，UI 顶部显示本地模式提示条。
 */
const config = {
  // 云开发环境 ID，例如 'quicktodo-1g2h3i4j5k6l'。留空 = 本地模式。
  // 填写位置：微信开发者工具 → 云开发 → 设置 → 环境 ID。
  cloudEnv: '',

  // 契约版本（只用于展示/排查，不要随意改动；改动必须同步 docs/SYNC-PROTOCOL.md）
  contractVersion: 'v1',

  // 云函数名（契约 §2/§3/§4）
  cloudFunctions: {
    todo: 'todo',
    ai: 'ai',
    auth: 'auth'
  },

  // AI 解析（契约 §3.1）
  ai: {
    maxItems: 8,
    // 时区：用于云函数解析「明天/下周一」这类相对时间
    timezone: 'Asia/Shanghai'
  },

  // 同声传译插件（app.json 中 plugins 必须与这里保持一致）
  voice: {
    pluginName: 'WechatSI',
    pluginVersion: '0.3.6',
    pluginProvider: 'wx069ba97219f66d99',
    duration: 60000, // 单次录音上限，插件最大 60000ms
    lang: 'zh_CN',
    stopTimeout: 4000 // stop() 后等待 onStop 回调的兜底超时（毫秒）
  },

  // 同步策略（契约 §5）
  sync: {
    pageLimit: 100, // list 单页条数（云端固定上限 100，客户端跟随）
    maxOutboxPerRound: 100, // 单轮上抛的最大条数（bulkUpsert 批量）
    maxPullPages: 20, // 单轮最多拉取页数（防 hasMore 异常导致死循环；未拉完的下一轮从游标继续，不丢数据）
    backoff: [1000, 2000, 4000, 8000, 16000, 32000, 60000] // 指数退避，上限 60s
  },

  // 视觉/交互常量
  ui: {
    floatLongPressMs: 350, // 长按判定阈值
    floatDragThresholdPx: 8, // 位移超过 8px 进入拖拽
    floatCancelOffsetPx: 80, // 上滑超过 80px 松手 = 取消录音
    ballSizeRpx: 108,
    edgeGapPx: 8
  },

  version: '1.0.0'
};

module.exports = config;
