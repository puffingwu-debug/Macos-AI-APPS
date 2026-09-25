'use strict';
/**
 * ai 云函数 —— DeepSeek 提示词构造（契约 §3.3 / §3.4）
 *
 * 只做字符串拼装，不依赖任何第三方库；key 只从云函数环境变量读取，绝不写进代码/日志。
 * 系统提示词必须让模型：只输出固定结构 JSON、按注入的当前时间与时区换算相对时间、
 * 拆分多条任务、丢弃寒暄、优先级收敛到 high/normal/low。
 */

const DEFAULT_TIMEZONE = 'Asia/Shanghai';
const DEFAULT_MAX_ITEMS = 8;
const MAX_ITEMS_CAP = 20;
const MAX_TEXT = 4000;

const WEEKDAY_CN = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];

/** 校验时区串，非法则回落到默认时区（避免把用户输入直接塞进 Intl 抛错） */
function safeTimeZone(tz) {
  if (typeof tz !== 'string') return DEFAULT_TIMEZONE;
  const s = tz.trim();
  if (!s || s.length > 64) return DEFAULT_TIMEZONE;
  if (!/^[A-Za-z][A-Za-z0-9_+-]*(\/[A-Za-z0-9_+-]+)*$/.test(s)) return DEFAULT_TIMEZONE;
  try {
    new Intl.DateTimeFormat('en-US', { timeZone: s });
    return s;
  } catch (e) {
    return DEFAULT_TIMEZONE;
  }
}

function pad2(n) {
  return (n < 10 ? '0' : '') + n;
}

/**
 * 取某一时刻在指定时区的「墙钟」分量。
 * 云函数 Node 16 一般带完整 ICU；万一没有 Intl，退化为固定 UTC+8 算法，保证不抛错。
 */
function zonedParts(ms, timeZone) {
  const tz = safeTimeZone(timeZone);
  try {
    const fmt = new Intl.DateTimeFormat('en-US', {
      timeZone: tz,
      hour12: false,
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
      weekday: 'short'
    });
    const bag = {};
    const parts = fmt.formatToParts(new Date(ms));
    for (let i = 0; i < parts.length; i++) bag[parts[i].type] = parts[i].value;
    let hour = parseInt(bag.hour, 10);
    if (!Number.isFinite(hour) || hour === 24) hour = 0;
    return {
      year: parseInt(bag.year, 10),
      month: parseInt(bag.month, 10),
      day: parseInt(bag.day, 10),
      hour: hour,
      minute: parseInt(bag.minute, 10) || 0,
      second: parseInt(bag.second, 10) || 0,
      weekday: bag.weekday || '',
      tz: tz,
      resolved: tz
    };
  } catch (e) {
    // 无 ICU 兜底：固定 UTC+8
    const d = new Date(ms + 8 * 3600 * 1000);
    return {
      year: d.getUTCFullYear(),
      month: d.getUTCMonth() + 1,
      day: d.getUTCDate(),
      hour: d.getUTCHours(),
      minute: d.getUTCMinutes(),
      second: d.getUTCSeconds(),
      weekday: WEEKDAY_CN[d.getUTCDay()],
      tz: 'UTC+8',
      resolved: 'UTC+8'
    };
  }
}

/** 该时刻在时区内的 UTC 偏移（分钟），用于提示词里展示 UTC+08:00 */
function offsetMinutes(ms, timeZone) {
  const p = zonedParts(ms, timeZone);
  const asUtc = Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second);
  return Math.round((asUtc - Math.floor(ms / 1000) * 1000) / 60000);
}

function formatOffset(minutes) {
  const sign = minutes < 0 ? '-' : '+';
  const abs = Math.abs(minutes);
  return 'UTC' + sign + pad2(Math.floor(abs / 60)) + ':' + pad2(abs % 60);
}

function formatHuman(parts) {
  return parts.year + '-' + pad2(parts.month) + '-' + pad2(parts.day) + ' ' +
    pad2(parts.hour) + ':' + pad2(parts.minute) + ':' + pad2(parts.second);
}

function clampMaxItems(v) {
  const n = Number(v);
  if (!Number.isFinite(n) || n <= 0) return DEFAULT_MAX_ITEMS;
  return Math.min(MAX_ITEMS_CAP, Math.max(1, Math.floor(n)));
}

function normalizeSource(v) {
  const s = typeof v === 'string' ? v.trim() : '';
  return (s === 'mac-screenshot' || s === 'mini-voice' || s === 'manual') ? s : 'manual';
}

/**
 * 构造 system 提示词：注入当前时间/时区 + 相对时间换算表 + 内容与优先级规则
 */
function buildSystemPrompt(options) {
  const opt = options || {};
  const nowMs = Number.isFinite(Number(opt.now)) && Number(opt.now) > 0 ? Math.floor(Number(opt.now)) : Date.now();
  const tz = safeTimeZone(opt.timezone);
  const p = zonedParts(nowMs, tz);
  const maxItems = clampMaxItems(opt.maxItems);
  const off = formatOffset(offsetMinutes(nowMs, tz));

  const lines = [
    '你是「QuickTodo」的待办抽取引擎。你的唯一任务：把用户给出的任意文本（截图 OCR / 语音转写 / 随手记）解析成结构化待办。',
    '',
    '【输出格式（硬性）】',
    '只输出一个 JSON 对象，不要解释、不要 Markdown 代码块、不要多余文字：',
    '{"todos":[{"content":"字符串","deadline":数字或null,"priority":"high"|"normal"|"low"}]}',
    '- content：必填，非空字符串，≤500 字；',
    '- deadline：Unix 毫秒时间戳（数字，13 位），没有明确时间就输出 null；禁止输出字符串日期；',
    '- priority：只能取 high / normal / low 三者之一，默认 normal。',
    '',
    '【当前时间（所有相对时间都必须基于它换算）】',
    '- 客户端本地时间：' + formatHuman(p) + '（' + p.weekday + '）',
    '- 时区：' + tz + '（' + off + '）',
    '- 当前 Unix 毫秒：' + nowMs,
    '',
    '【相对时间 → Unix 毫秒 换算规则】',
    '- 今天/今日 → 当天；明天 → +1 天；后天 → +2 天；大后天 → +3 天；',
    '- 只给日期没给时刻 → 取那天 23:59:59.999；给了时刻 → 用那个时刻；',
    '- 下周一/下周三 → 下一个自然周的周一/周三（本周日为一周最后一天）；',
    '- 周三 / 星期三 / 礼拜三（不带「下」）→ 本周三；若该时刻已经早于当前时间，则顺延到下周同一天；',
    '- 下午3点/下午15点 → 当天 15:00；晚上8点 → 当天 20:00；上午9点/早上9点 → 09:00；中午 → 12:00；',
    '- 3点半 → 该时刻的 30 分（如下午3点半 = 15:30）；晚上7点15分 → 19:15；',
    '- 月底/月末 → 当月最后一天的 23:59:59.999；',
    '- 「X月X日」「X月X号」没写年份：按今年算；若算出来的日期早于当前时间，则按明年算；',
    '- 「截止 / 之前 / 以前 / 前」只是截止语义，deadline 就取那个时间点，不要额外加减时间；',
    '- 完全无法确定时间 → deadline 输出 null，绝不编造。',
    '',
    '【拆分与内容规则】',
    '- 一段文本里的多个任务必须拆成多条 todos：换行、分号、句号、「然后」「还要」「另外」「、」、序号（1. / ① / -）都是分隔符；',
    '- 丢弃纯寒暄与无信息量内容（你好、谢谢、哈哈、在吗、收到 等），不要为它们生成待办；',
    '- content 用简洁的动宾短语（动词开头），去掉「记得 / 帮我 / 麻烦 / 我要 / 请」等口语前缀；',
    '- content 里不要出现时间词（今天/明天/下周三/下午三点/月底…），时间只体现在 deadline；',
    '- 保留原文的人名、数量、地点、专有名词，不要臆造原文没有的任务，也不要合并两个不同任务；',
    '- 最多输出 ' + maxItems + ' 条；超出时保留最重要的 ' + maxItems + ' 条。',
    '',
    '【优先级判定】',
    '- high：出现「紧急 / 加急 / 急 / 尽快 / 立刻 / 立马 / 马上 / asap / 重要 / 优先 / 务必 / 赶紧」，或带有硬性截止且语气紧迫；',
    '- low：出现「不急 / 不着急 / 有空再说 / 顺便 / 低优先级 / 随时」；',
    '- 其余一律 normal。',
    '',
    '【示例】',
    '输入：明天下午三点前把季度报表发给张总 还要买牛奶',
    '输出：{"todos":[{"content":"把季度报表发给张总","deadline":' + (nowMs + 86400000) + ',"priority":"high"},{"content":"买牛奶","deadline":null,"priority":"normal"}]}',
    '（示例中的 deadline 只是示意，真实输出必须按上面的当前时间重新计算）'
  ];
  return lines.join('\n');
}

/** 构造 user 提示词：只带原文 + 少量元信息 */
function buildUserPrompt(options) {
  const opt = options || {};
  const maxItems = clampMaxItems(opt.maxItems);
  const source = normalizeSource(opt.source);
  const raw = typeof opt.text === 'string' ? opt.text : '';
  const text = raw.length > MAX_TEXT ? raw.slice(0, MAX_TEXT) : raw;
  return [
    '待解析文本（来源：' + source + '，最多输出 ' + maxItems + ' 条待办）：',
    '<<<TEXT',
    text,
    'TEXT',
    '请只输出 JSON 对象。'
  ].join('\n');
}

/** 返回 [system, user] 两条消息，可直接喂给 /chat/completions */
function buildMessages(options) {
  const opt = options || {};
  const nowMs = Number.isFinite(Number(opt.now)) && Number(opt.now) > 0 ? Math.floor(Number(opt.now)) : Date.now();
  const opts = {
    now: nowMs,
    timezone: safeTimeZone(opt.timezone),
    maxItems: clampMaxItems(opt.maxItems),
    source: normalizeSource(opt.source),
    text: typeof opt.text === 'string' ? opt.text : ''
  };
  return [
    { role: 'system', content: buildSystemPrompt(opts) },
    { role: 'user', content: buildUserPrompt(opts) }
  ];
}

module.exports = {
  DEFAULT_TIMEZONE: DEFAULT_TIMEZONE,
  DEFAULT_MAX_ITEMS: DEFAULT_MAX_ITEMS,
  MAX_ITEMS_CAP: MAX_ITEMS_CAP,
  MAX_TEXT: MAX_TEXT,
  safeTimeZone: safeTimeZone,
  zonedParts: zonedParts,
  clampMaxItems: clampMaxItems,
  normalizeSource: normalizeSource,
  buildSystemPrompt: buildSystemPrompt,
  buildUserPrompt: buildUserPrompt,
  buildMessages: buildMessages
};
