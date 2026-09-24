'use strict';
/**
 * ai 云函数 —— 降级规则解析器（契约 §3.3 / §3.4）
 *
 * 纯 JS、零依赖：未配置 DEEPSEEK_API_KEY，或 DeepSeek 超时/报错/返回非法 JSON 时，
 * 由本文件负责把一段自由文本拆成多条待办，保证功能永远可用。
 *
 * 能力（启发式，够用即可，不追求 NLP 精度）：
 *   1. 切分：换行 / 分号 / 句号 / 「，然后」/ 「、」/ 序号（1. 2. / ①② / -）
 *   2. 时间：今天 明天 后天 大后天 / 下周X 周X 星期X / X月X日 X月X号 / 月底
 *            上午/下午/晚上 X点（支持中文数字：三点、十点半、两点）X:MM / 截止·之前·前
 *   3. 优先级：紧急/尽快/立刻/立即/马上/务必/必须/asap → high；不急/有空/顺便 → low
 *   4. 去噪：记得 / 帮我 / 麻烦 / 我要 等口语前缀，序号标记，时间词从 content 中剔除
 *   5. 默认值（跨端统一，决策 5）：只给日期→当天 23:59:59.999；晚上→20:00、下午→15:00、
 *      上午→10:00、早上/早晨→08:00、中午→12:00；裸「X点」按字面不猜上下午；
 *      显式「今天/明天」不顺延；只给钟点/时段词且今天已过 → 顺延到明天
 *
 * 导出：parseByRules(text, { now, timezone, maxItems }) -> { todos: [{content, deadline, priority}] }
 */

const DAY_MS = 86400000;
const DEFAULT_TIMEZONE = 'Asia/Shanghai';
const DEFAULT_MAX_ITEMS = 8;
const MAX_ITEMS_CAP = 20;
const MAX_CONTENT = 500;
const MAX_TEXT = 4000;

const WEEKDAY_CN = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];
// 周一=1 … 周六=6，周日/周天=7（与 JS getUTCDay 的 0=周日 错开一位，便于「本周内顺延」计算）
const WEEKDAY_NUM = {
  '一': 1, '二': 2, '三': 3, '四': 4, '五': 5, '六': 6, '日': 7, '天': 7,
  '1': 1, '2': 2, '3': 3, '4': 4, '5': 5, '6': 6, '7': 7
};

// 中文数字：支持 一~十、十一~二十四、两（两点/两天）
const CN_DIGIT = {
  '零': 0, '〇': 0, '一': 1, '两': 2, '二': 2, '三': 3, '四': 4,
  '五': 5, '六': 6, '七': 7, '八': 8, '九': 9, '十': 10
};
const NUM_PAT = '(?:\\d{1,3}|[零〇一两二三四五六七八九十]{1,3})';

/** 中文/阿拉伯数字串 → 整数；无法识别返回 NaN */
function cnNumToInt(input) {
  const s = String(input === undefined || input === null ? '' : input).replace(/\s+/g, '');
  if (!s) return NaN;
  if (/^\d+$/.test(s)) return parseInt(s, 10);
  if (s.length === 1) return CN_DIGIT[s] === undefined ? NaN : CN_DIGIT[s];
  if (s[0] === '十') {                       // 十、十一…十九
    const r = CN_DIGIT[s[1]];
    return (s.length === 2 && r !== undefined) ? 10 + r : NaN;
  }
  if (s[1] === '十') {                       // 二十、二十三、三十
    const a = CN_DIGIT[s[0]];
    if (a === undefined) return NaN;
    if (s.length === 2) return a * 10;
    const b = CN_DIGIT[s[2]];
    return (s.length === 3 && b !== undefined) ? a * 10 + b : NaN;
  }
  return NaN;
}

// ---------------------------------------------------------------------------
// 时区 / 日期工具（与 prompt.js 同源逻辑，各写一份以保持文件自包含）
// ---------------------------------------------------------------------------
function pad2(n) {
  return (n < 10 ? '0' : '') + n;
}

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

/** 取某时刻在指定时区的墙钟分量；无 Intl 时退化为固定 UTC+8 */
function zonedParts(ms, timeZone) {
  const tz = safeTimeZone(timeZone);
  try {
    const fmt = new Intl.DateTimeFormat('en-US', {
      timeZone: tz,
      hour12: false,
      year: 'numeric', month: '2-digit', day: '2-digit',
      hour: '2-digit', minute: '2-digit', second: '2-digit', weekday: 'short'
    });
    const bag = {};
    const parts = fmt.formatToParts(new Date(ms));
    for (let i = 0; i < parts.length; i++) bag[parts[i].type] = parts[i].value;
    let hour = parseInt(bag.hour, 10);
    if (!Number.isFinite(hour) || hour === 24) hour = 0;
    return {
      year: parseInt(bag.year, 10), month: parseInt(bag.month, 10), day: parseInt(bag.day, 10),
      hour: hour, minute: parseInt(bag.minute, 10) || 0, second: parseInt(bag.second, 10) || 0,
      weekday: bag.weekday || ''
    };
  } catch (e) {
    const d = new Date(ms + 8 * 3600 * 1000);
    return {
      year: d.getUTCFullYear(), month: d.getUTCMonth() + 1, day: d.getUTCDate(),
      hour: d.getUTCHours(), minute: d.getUTCMinutes(), second: d.getUTCSeconds(),
      weekday: WEEKDAY_CN[d.getUTCDay()]
    };
  }
}

/** 某时刻在时区内的 UTC 偏移毫秒 */
function tzOffsetMs(ms, timeZone) {
  const p = zonedParts(ms, timeZone);
  const asUtc = Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second);
  return asUtc - Math.floor(ms / 1000) * 1000;
}

/** 把「时区内的墙钟时间」反解成真实 Unix 毫秒（迭代两次，覆盖夏令时切换） */
function zonedToUtc(year, month, day, hour, minute, timeZone) {
  const guess = Date.UTC(year, month - 1, day, hour, minute, 0, 0);
  const off1 = tzOffsetMs(guess, timeZone);
  let ts = guess - off1;
  const off2 = tzOffsetMs(ts, timeZone);
  if (off2 !== off1) ts = guess - off2;
  return ts;
}

function addDaysToDate(year, month, day, n) {
  const t = new Date(Date.UTC(year, month - 1, day));
  t.setUTCDate(t.getUTCDate() + n);
  return { year: t.getUTCFullYear(), month: t.getUTCMonth() + 1, day: t.getUTCDate() };
}

/** 当月最后一天 */
function lastDayOfMonth(year, month) {
  return new Date(Date.UTC(year, month, 0)).getUTCDate();
}

/** 把 JS getUTCDay（0=周日）换算成周一=1…周日=7 */
function isoWeekday(jsDay) {
  return jsDay === 0 ? 7 : jsDay;
}

// ---------------------------------------------------------------------------
// 切分
// ---------------------------------------------------------------------------
const SEGMENT_SPLITTERS = [
  /\r?\n+/,                                                        // 换行
  /[;；]+/,                                                        // 分号
  /[。]+/,                                                         // 句号
  /[、]+/,                                                         // 顿号
  // 连接词（注意：不含「顺便」，它是优先级关键词，当分隔符会把 low 语义吃掉）
  /[，,]\s*(?:然后|接着|另外|还有|再有|再就是|以及|同时)/,
  /(?:然后|接着|另外|还有|再有|再就是|以及|同时)/,
  /(?:还要|也要|也需要|还得|别忘了还有)/,                            // 「还要买牛奶」这类第二件事
  /(?:^|\s)(?=\d{1,2}\s*[.、)）]\s*)/,                             // 1. / 2、 / 3)
  /(?=[①②③④⑤⑥⑦⑧⑨⑩])/,                                            // ①②③
  /(?:^|\s)[-*•·]\s+/                                              // - 项目符号
];

/** 按分隔符把整段文本切成候选片段（逐层切，便于维护） */
function splitSegments(text) {
  let segments = [String(text === undefined || text === null ? '' : text)];
  for (let i = 0; i < SEGMENT_SPLITTERS.length; i++) {
    const re = SEGMENT_SPLITTERS[i];
    const next = [];
    for (let j = 0; j < segments.length; j++) {
      const pieces = segments[j].split(re);
      for (let k = 0; k < pieces.length; k++) next.push(pieces[k]);
    }
    segments = next;
  }
  return segments;
}

// ---------------------------------------------------------------------------
// 时间词解析
// ---------------------------------------------------------------------------
const PERIOD_WORDS = '(上午|早上|早晨|清晨|凌晨|中午|正午|下午|傍晚|晚上|夜里|夜间|今晚|明晚)';
const FRAC_WORDS = '(半|一刻|' + NUM_PAT + '\\s*分)';
// 「一点小问题 / 三点意见」这类不是时间，裸中文数字点数时排除
const NOT_A_TIME = '小|意|建|问|心|评|优|缺|特|重|起|差|儿|地|滴|赞|作用|收获';

/**
 * 从片段中抽取时间信息。
 * 返回 { deadline, matched: [命中的原始子串] }，matched 用于把时间词从 content 里剔除。
 */
function extractDeadline(text, nowMs, timeZone) {
  const tz = safeTimeZone(timeZone);
  const now = Number.isFinite(Number(nowMs)) && Number(nowMs) > 0 ? Math.floor(Number(nowMs)) : Date.now();
  const p = zonedParts(now, tz);
  const matched = [];

  let hasDay = false;
  let hasTime = false;
  let base = { year: p.year, month: p.month, day: p.day };
  let hour = null;
  let minute = 0;
  let endOfDay = false; // 只给了日期没给时刻 → 取当天 23:59:59.999

  let work = String(text || '');

  function cut(re, handler) {
    const m = work.match(re);
    if (!m) return false;
    matched.push(m[0]);
    work = work.slice(0, m.index) + ' ' + work.slice(m.index + m[0].length);
    if (handler) handler(m);
    return true;
  }

  // --- 日期：带年份 ---
  cut(new RegExp('(\\d{4})\\s*年\\s*(' + NUM_PAT + ')\\s*月\\s*(' + NUM_PAT + ')\\s*[日号]?'), function (m) {
    const y = parseInt(m[1], 10), mo = cnNumToInt(m[2]), d = cnNumToInt(m[3]);
    if (mo >= 1 && mo <= 12 && d >= 1 && d <= 31) { base = { year: y, month: mo, day: d }; hasDay = true; }
  });

  // --- 日期：X月X日/号（无年份，早于当前时间则按明年算）---
  if (!hasDay) {
    cut(new RegExp('(' + NUM_PAT + ')\\s*月\\s*(' + NUM_PAT + ')\\s*[日号]'), function (m) {
      const mo = cnNumToInt(m[1]), d = cnNumToInt(m[2]);
      if (mo >= 1 && mo <= 12 && d >= 1 && d <= 31) {
        base = { year: p.year, month: mo, day: d };
        if (zonedToUtc(base.year, base.month, base.day, 23, 59, tz) < now) base.year = p.year + 1; // 按明年
        hasDay = true;
      }
    });
  }

  // --- 日期：月底/月末 ---
  if (!hasDay) {
    cut(/月底|月末/, function () {
      base = { year: p.year, month: p.month, day: lastDayOfMonth(p.year, p.month) };
      hasDay = true;
    });
  }

  // --- 日期：今天/明天/后天/大后天 ---
  if (!hasDay) {
    if (cut(/大后天/, function () { base = addDaysToDate(p.year, p.month, p.day, 3); hasDay = true; })) { /* +3 */ }
    else if (cut(/后天/, function () { base = addDaysToDate(p.year, p.month, p.day, 2); hasDay = true; })) { /* +2 */ }
    else if (cut(/明天|明日|明儿/, function () { base = addDaysToDate(p.year, p.month, p.day, 1); hasDay = true; })) { /* +1 */ }
    else if (cut(/今天|今日/, function () { hasDay = true; })) { /* +0 */ }
  }

  // --- 日期：下周X（下一个自然周）---
  if (!hasDay) {
    cut(/下(?:个)?(?:周|星期|礼拜)\s*([一二三四五六日天1-7])/, function (m) {
      const target = WEEKDAY_NUM[m[1]];
      const cur = isoWeekday(new Date(Date.UTC(p.year, p.month - 1, p.day)).getUTCDay());
      let delta = (7 - cur) + target; // 先跳到下周一，再到目标星期
      if (delta <= 0) delta += 7;
      base = addDaysToDate(p.year, p.month, p.day, delta);
      hasDay = true;
    });
  }

  // --- 日期：本周X（已过则顺延到下周）---
  if (!hasDay) {
    cut(/(?:这|本)?(?:周|星期|礼拜)\s*([一二三四五六日天1-7])/, function (m) {
      const target = WEEKDAY_NUM[m[1]];
      const cur = isoWeekday(new Date(Date.UTC(p.year, p.month - 1, p.day)).getUTCDay());
      let delta = target - cur;
      if (delta < 0) delta += 7; // 本周已过 → 下周同一天
      base = addDaysToDate(p.year, p.month, p.day, delta);
      hasDay = true;
    });
  }

  // --- 日期：N天后 ---
  if (!hasDay) {
    cut(new RegExp('(' + NUM_PAT + ')\\s*天\\s*(?:后|以后|之后)'), function (m) {
      const n = cnNumToInt(m[1]);
      if (n >= 0 && n <= 365) { base = addDaysToDate(p.year, p.month, p.day, n); hasDay = true; }
    });
  }

  // --- 日期：X号（无月份，已过则顺延到下个月）---
  if (!hasDay) {
    cut(new RegExp('(?:^|[^\\d])(' + NUM_PAT + ')\\s*号'), function (m) {
      const d = cnNumToInt(m[1]);
      if (d >= 1 && d <= 31) {
        base = { year: p.year, month: p.month, day: d };
        if (zonedToUtc(base.year, base.month, base.day, 23, 59, tz) < now) {
          const nm = p.month === 12 ? { y: p.year + 1, m: 1 } : { y: p.year, m: p.month + 1 };
          base = { year: nm.y, month: nm.m, day: d };
        }
        hasDay = true;
      }
    });
  }

  /** 统一处理「时段词 + 点数」 */
  function applyHour(periodStr, hourStr, fracStr) {
    let h = cnNumToInt(hourStr);
    if (!Number.isFinite(h) || h < 0 || h > 24) return;
    let mi = 0;
    const frac = String(fracStr || '').trim();
    if (frac === '半') mi = 30;
    else if (frac === '一刻') mi = 15;
    else if (frac) {
      const mm = cnNumToInt(frac.replace(/\s*分$/, ''));
      if (Number.isFinite(mm)) mi = Math.min(59, mm);
    }
    if (h === 24) h = 0;
    const period = periodStr || '';
    if (period === '下午' || period === '傍晚') h = h < 12 ? h + 12 : h;
    else if (period === '晚上' || period === '夜里' || period === '夜间' || period === '今晚' || period === '明晚') {
      h = h < 12 ? h + 12 : (h === 12 ? 0 : h);
    } else if (period === '凌晨' && h === 12) {
      h = 0;
    }
    hour = h; minute = mi; hasTime = true;
  }

  // --- 时刻：时段词 + X点(半/一刻/X分)，时段词在场时中文数字无歧义 ---
  cut(new RegExp(PERIOD_WORDS + '\\s*(' + NUM_PAT + ')\\s*[点時时]\\s*' + FRAC_WORDS + '?'), function (m) {
    applyHour(m[1], m[2], m[3]);
  });

  // --- 时刻：裸 X点（中文数字需排除「一点小问题/三点意见」这类非时间用法）---
  if (!hasTime) {
    cut(new RegExp('(' + NUM_PAT + ')\\s*[点時时](?!\\s*(?:' + NOT_A_TIME + '))\\s*' + FRAC_WORDS + '?'), function (m) {
      applyHour('', m[1], m[2]);
    });
  }

  // --- 时刻：H:MM ---
  if (!hasTime) {
    cut(new RegExp(PERIOD_WORDS + '?\\s*(\\d{1,2})\\s*[:：]\\s*(\\d{2})'), function (m) {
      const period = /^[上下晚早]|午|晚|晨|夜/.test(m[1] || '') ? m[1] : '';
      const h = parseInt(m[2], 10);
      const mi = Math.min(59, parseInt(m[3], 10) || 0);
      if (h > 23) return;
      applyHour(period, String(h), mi ? String(mi) + '分' : '');
    });
  }

  // --- 时刻：纯时段词，不带具体点数（跨端统一默认值，决策 5）---
  // 中午/正午 → 12:00；晚上 → 20:00；下午 → 15:00；上午 → 10:00；早上/早晨/清晨 → 08:00
  if (!hasTime) {
    cut(/中午|正午/, function () { hour = 12; minute = 0; hasTime = true; });
  }
  if (!hasTime) {
    cut(/(?:今天|明天|明儿)?晚上|今晚|明晚/, function () { hour = 20; minute = 0; hasTime = true; });
  }
  if (!hasTime) {
    cut(/(?:今天|明天)?下午|午后/, function () { hour = 15; minute = 0; hasTime = true; });
  }
  if (!hasTime) {
    cut(/(?:今天|明天)?上午|晌午/, function () { hour = 10; minute = 0; hasTime = true; });
  }
  if (!hasTime) {
    cut(/(?:今天|明天)?(?:早上|早晨|清晨)|明早|一早/, function () { hour = 8; minute = 0; hasTime = true; });
  }

  // --- 截止语义词：只是语义标记，deadline 不加时间，但要从 content 剔除 ---
  cut(/(?:截止到|截止|之前|以前|前)(?![后前后])/);

  if (!hasDay && !hasTime) return { deadline: null, matched: matched };

  // 只给日期没给具体时刻 → 当天 23:59:59.999（有具体时刻则以时刻为准，如「下周一上午十点」）
  if (hasDay && !hasTime) endOfDay = true;
  if (!hasDay) {
    // 只说了时刻没说哪天 → 默认今天；若已过去则顺延到明天
    base = { year: p.year, month: p.month, day: p.day };
  }

  let deadline;
  if (endOfDay) {
    deadline = zonedToUtc(base.year, base.month, base.day, 23, 59, tz) + 59999; // 23:59:59.999
  } else {
    deadline = zonedToUtc(base.year, base.month, base.day, hour === null ? 9 : hour, minute, tz);
  }

  if (!hasDay && deadline <= now) {
    // 「下午3点」在 16 点说出口 → 指的是明天
    const nd = addDaysToDate(base.year, base.month, base.day, 1);
    deadline = endOfDay
      ? zonedToUtc(nd.year, nd.month, nd.day, 23, 59, tz) + 59999
      : zonedToUtc(nd.year, nd.month, nd.day, hour === null ? 9 : hour, minute, tz);
  }

  return { deadline: deadline, matched: matched };
}

// ---------------------------------------------------------------------------
// 优先级 / 去噪 / 内容清洗
// ---------------------------------------------------------------------------
const LOW_STRONG = ['不急', '不着急', '不紧急', '低优先级', '不忙', '无需着急'];
const LOW_WEAK = ['有空', '闲时', '顺便', '随时', '想起了再'];
const HIGH_WORDS = ['紧急', '加急', '尽快', '立刻', '立即', '立马', '马上', 'asap', '重要', '优先',
  '务必', '赶紧', '赶快', '抓紧', '急', '必须', 'deadline', '第一时间'];

/** 优先级只看原文（清洗会剥掉「紧急：」这类标签，必须在清洗前判定） */
function detectPriority(text) {
  const s = String(text || '').toLowerCase();
  for (let i = 0; i < LOW_STRONG.length; i++) if (s.indexOf(LOW_STRONG[i]) >= 0) return 'low';
  for (let i = 0; i < HIGH_WORDS.length; i++) if (s.indexOf(HIGH_WORDS[i]) >= 0) return 'high';
  for (let i = 0; i < LOW_WEAK.length; i++) if (s.indexOf(LOW_WEAK[i]) >= 0) return 'low';
  return 'normal';
}

// 口语前缀噪声（循环剥离，覆盖「记得帮我」这类叠加前缀）
const NOISE_PREFIX = /^(?:那|嗯|哦|额|诶|好[的吧]?|行|麻烦你|麻烦|请你|请|帮我|帮忙|给我|替我|替我下|记得|记着|别忘了|别忘记|不要忘记|提醒我一下|提醒我|我要|我得|我需要|我想|想要|一定要|务必|千万|please|remind me to|i need to|i want to|todo[:：]?|待办[:：]?)+[\s,，:：、]*/i;
// 「要」单独剥离有歧义（要求/要紧/要点），命中这些词时跳过
const YAO_GUARD = /^要(?:求|紧|点|么|不|是|闻)/;
const NOISE_YAO = /^要[\s,，:：]*/;
// 「有空再/顺便」这类弱语义填充词，从内容里去掉（优先级已在原文里判定过）
const LEADING_FILLER = /^(?:不着急|不急|有空|闲时|顺便|随时)\s*[，,]?\s*(?:再|先)?\s*/;
// 列表序号标记（1. / 2、 / 3) / ① / - / • ）本身不是内容
const LIST_MARKER = /^\s*(?:[①②③④⑤⑥⑦⑧⑨⑩]|\d{1,2}\s*[.、)）]|[-*•·])\s*/;
// 序号后紧跟的优先级标签（「①紧急：修 bug」→「修 bug」），必须带冒号才剥离，避免误伤
const PRIORITY_LABEL = /^(?:紧急|加急|重要|不急|不着急|普通|一般)\s*[:：]\s*/;

// 纯寒暄：整句只由寒暄词/语气词/标点组成才算（「你好，谢谢啦！」→ 丢弃）
const GREETING_WORD = '(?:你好|您好|大家好|hi|hello|hey|谢谢|多谢|感谢|辛苦了|早上好|下午好|晚上好|在吗|在么|收到|好的|好嘞|ok|okk|哈哈+|嘻嘻+|么么|测试|test|啦|了|呀|啊|吧|呢|哈+)';
const GREETING_ONLY = new RegExp('^(?:' + GREETING_WORD + '|[\\s!！。,.，、~～]+)+$', 'i');

function cleanContent(text) {
  let s = String(text === undefined || text === null ? '' : text);
  s = s.replace(LIST_MARKER, '');
  for (let i = 0; i < 5; i++) {
    const before = s;
    s = s.replace(NOISE_PREFIX, '');
    if (!YAO_GUARD.test(s)) s = s.replace(NOISE_YAO, '');
    s = s.replace(LEADING_FILLER, '');
    if (s === before) break;
  }
  s = s.replace(LIST_MARKER, '').replace(PRIORITY_LABEL, '').replace(LEADING_FILLER, '');
  // 去掉首尾标点与空白，压缩连续空白
  s = s.replace(/[\s\u3000]+/g, ' ').trim();
  s = s.replace(/^[,，、。.；;：:!！?？~～\-—*•·]+/, '').replace(/[,，、。.；;：:!！?？~～\-—\s]+$/, '');
  return s.trim();
}

/** 把命中的时间词从内容里剔除；若剔除后没剩什么有效内容，则返回 null 表示「只有时间」 */
function stripTimeWords(content, matched) {
  let s = content;
  for (let i = 0; i < matched.length; i++) {
    const idx = s.indexOf(matched[i]);
    if (idx >= 0) s = s.slice(0, idx) + ' ' + s.slice(idx + matched[i].length);
  }
  s = s.replace(/^[,，、。.；;：:!！?？~～\-—\s]+/, '').replace(/[,，、。.；;：:!！?？~～\-—\s]+$/, '');
  s = s.replace(/^(?:在|于)\s*/, '');       // 「在明天…」→「…」
  s = s.replace(/\s*(?:之前|以前|截止|完成)$/, '');
  s = s.replace(/[（(]\s*[)）]/g, '').trim();
  return s.length >= 2 ? s : null;
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------
function parseSegment(segment, nowMs, timeZone) {
  const raw = String(segment === undefined || segment === null ? '' : segment);
  const cleaned = cleanContent(raw);
  if (!cleaned || cleaned.length < 2) return null;
  if (GREETING_ONLY.test(cleaned)) return null;
  if (!/[\u4e00-\u9fa5a-zA-Z0-9]/.test(cleaned)) return null; // 只剩表情/标点

  const priority = detectPriority(raw); // 用原文判优先级，避免清洗把「紧急」标签删掉
  const timeInfo = extractDeadline(cleaned, nowMs, timeZone);
  const noTime = stripTimeWords(cleaned, timeInfo.matched);
  // 只有时间词的片段（「明天」「下午三点前」）没有信息量，丢弃
  if (!noTime) return null;

  const content = (noTime || cleaned).slice(0, MAX_CONTENT).trim();
  if (!content) return null;

  return {
    content: content,
    deadline: timeInfo.deadline === undefined ? null : timeInfo.deadline,
    priority: priority
  };
}

/**
 * 规则解析入口
 * @param {string} text 原始文本
 * @param {{now?:number, timezone?:string, maxItems?:number}} options
 * @returns {{todos: Array<{content:string, deadline:(number|null), priority:string}>}}
 */
function parseByRules(text, options) {
  const opt = options || {};
  const tz = safeTimeZone(opt.timezone);
  const now = Number.isFinite(Number(opt.now)) && Number(opt.now) > 0 ? Math.floor(Number(opt.now)) : Date.now();
  let maxItems = Number(opt.maxItems);
  if (!Number.isFinite(maxItems) || maxItems <= 0) maxItems = DEFAULT_MAX_ITEMS;
  maxItems = Math.min(MAX_ITEMS_CAP, Math.floor(maxItems));

  const source = typeof text === 'string' ? text : (text === undefined || text === null ? '' : String(text));
  const segments = splitSegments(source.slice(0, MAX_TEXT));

  const todos = [];
  const seen = {};
  for (let i = 0; i < segments.length && todos.length < maxItems; i++) {
    const item = parseSegment(segments[i], now, tz);
    if (!item) continue;
    const key = item.content + '|' + (item.deadline || '');
    if (seen[key]) continue; // 同一段文本里重复出现的任务只保留一条
    seen[key] = true;
    todos.push(item);
  }
  return { todos: todos };
}

module.exports = {
  parseByRules: parseByRules,
  splitSegments: splitSegments,
  parseSegment: parseSegment,
  extractDeadline: extractDeadline,
  detectPriority: detectPriority,
  cleanContent: cleanContent,
  stripTimeWords: stripTimeWords,
  cnNumToInt: cnNumToInt,
  safeTimeZone: safeTimeZone,
  zonedParts: zonedParts,
  zonedToUtc: zonedToUtc,
  DAY_MS: DAY_MS
};
