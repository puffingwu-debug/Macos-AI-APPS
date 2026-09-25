/**
 * format.js —— 展示层格式化（时间 / 优先级 / 来源）
 * 纯函数，无副作用，方便在两个页面和多个组件里复用。
 * 重要：小程序 WXML 里不能写复杂表达式，所有展示文案都在这里算好后 setData 进列表。
 */

const PRIORITY_LABEL = { high: '高', normal: '中', low: '低' };
const PRIORITY_TEXT = { high: '高优先级', normal: '普通', low: '低优先级' };
const SOURCE_LABEL = { 'mac-screenshot': '截图', 'mini-voice': '语音', manual: '手动' };
const SOURCE_ICON = { 'mac-screenshot': '📷', 'mini-voice': '🎤', manual: '✍️' };
const SOURCE_CLS = { 'mac-screenshot': 'src-shot', 'mini-voice': 'src-voice', manual: 'src-manual' };

function pad2(n) {
  const v = Number(n) || 0;
  return v < 10 ? '0' + v : '' + v;
}

/** 当天 00:00 的时间戳（本地时区） */
function startOfDay(ts) {
  const d = new Date(Number(ts) || Date.now());
  d.setHours(0, 0, 0, 0);
  return d.getTime();
}

/** 短日期：3月5日 / 2024年3月5日 */
function shortDate(ts, base) {
  const d = new Date(Number(ts) || Date.now());
  const b = new Date(Number(base) || Date.now());
  if (d.getFullYear() === b.getFullYear()) {
    return d.getMonth() + 1 + '月' + d.getDate() + '日';
  }
  return d.getFullYear() + '年' + (d.getMonth() + 1) + '月' + d.getDate() + '日';
}

/**
 * 截止时间展示（需求 §4：含「今天 18:00」「已逾期」红色高亮）
 * @returns {{text:string, cls:string, overdue:boolean, has:boolean}}
 */
function formatDeadline(deadline, now) {
  const t = Number(deadline);
  if (deadline === null || deadline === undefined || deadline === '' || !isFinite(t) || t <= 0) {
    return { text: '', cls: '', overdue: false, has: false };
  }
  const base = Number(now) || Date.now();
  const d = new Date(t);
  const hm = pad2(d.getHours()) + ':' + pad2(d.getMinutes());
  const dayDiff = Math.round((startOfDay(t) - startOfDay(base)) / 86400000);

  let dayText;
  if (dayDiff === 0) dayText = '今天';
  else if (dayDiff === 1) dayText = '明天';
  else if (dayDiff === 2) dayText = '后天';
  else if (dayDiff === -1) dayText = '昨天';
  else dayText = shortDate(t, base);

  const overdue = t < base;
  if (overdue) {
    return { text: '已逾期 · ' + dayText + ' ' + hm, cls: 'overdue', overdue: true, has: true };
  }
  return { text: dayText + ' ' + hm, cls: dayDiff === 0 ? 'today' : '', overdue: false, has: true };
}

/**
 * 相对时间（刚刚 / 5 分钟前 / 3 小时前 / 昨天 / 3 天前 / 3月5日）
 */
function formatRelative(ts, now) {
  const t = Number(ts);
  if (!t || !isFinite(t)) return '';
  const base = Number(now) || Date.now();
  const diff = base - t;
  // updateTime 是逻辑时间戳（契约 §1.1），本机时钟偏慢时可能略大于本机当前时间，
  // 小幅「未来」按「刚刚」显示，避免出现「9月24日」这种突兀文案
  if (diff < 0) {
    return diff > -300000 ? '刚刚' : shortDate(t, base);
  }
  const min = Math.floor(diff / 60000);
  if (min < 1) return '刚刚';
  if (min < 60) return min + ' 分钟前';
  const hour = Math.floor(min / 60);
  if (hour < 24) return hour + ' 小时前';
  const day = Math.round((startOfDay(base) - startOfDay(t)) / 86400000);
  if (day <= 1) return '昨天';
  if (day < 7) return day + ' 天前';
  return shortDate(t, base);
}

/** 时间戳 → 'YYYY-MM-DD'（picker mode="date" 需要） */
function toDateStr(ts) {
  const t = Number(ts);
  if (!t || !isFinite(t) || t <= 0) return '';
  const d = new Date(t);
  return d.getFullYear() + '-' + pad2(d.getMonth() + 1) + '-' + pad2(d.getDate());
}

/** 时间戳 → 'HH:mm'（picker mode="time" 需要） */
function toTimeStr(ts) {
  const t = Number(ts);
  if (!t || !isFinite(t) || t <= 0) return '';
  const d = new Date(t);
  return pad2(d.getHours()) + ':' + pad2(d.getMinutes());
}

/** 时间选择器的默认值 = 「当天结束」。
 *  契约 §3.4：只给日期不给时间时，deadline 取当天 23:59:59.999。
 *  选择器默认值即 '23:59'，combineDateTime 把「空值 / '23:59'」统一按当天最后一毫秒处理，
 *  保证「有日期没时间」的手动录入与 AI 解析出来的结果两端一致。 */
const DEFAULT_TIME = '23:59';

/** 'YYYY-MM-DD' → 当天 23:59:59.999 */
function endOfDay(dateStr) {
  const dp = String(dateStr || '').split('-');
  if (dp.length < 3) return null;
  const y = Number(dp[0]);
  const m = Number(dp[1]);
  const d = Number(dp[2]);
  if (!isFinite(y) || !isFinite(m) || !isFinite(d)) return null;
  const dt = new Date(y, m - 1, d, 23, 59, 59, 999);
  const t = dt.getTime();
  return isFinite(t) ? t : null;
}

/**
 * 'YYYY-MM-DD' + 'HH:mm' → Unix 毫秒；dateStr 为空返回 null。
 * 契约 §3.4：只给日期不给时间（timeStr 为空或等于默认值 '23:59'）→ 当天 23:59:59.999。
 */
function combineDateTime(dateStr, timeStr) {
  if (!dateStr) return null;
  const time = String(timeStr || '');
  if (!time || time === DEFAULT_TIME) return endOfDay(dateStr);
  const dp = String(dateStr).split('-');
  if (dp.length < 3) return null;
  const tp = time.split(':');
  const y = Number(dp[0]);
  const m = Number(dp[1]);
  const d = Number(dp[2]);
  const hh = Number(tp[0]);
  const mm = Number(tp[1]);
  if (!isFinite(y) || !isFinite(m) || !isFinite(d)) return null;
  const dt = new Date(y, m - 1, d, isFinite(hh) ? hh : 0, isFinite(mm) ? mm : 0, 0, 0);
  const t = dt.getTime();
  return isFinite(t) ? t : null;
}

/** 今天（用于 picker 的 start 限制） */
function todayStr() {
  return toDateStr(Date.now());
}

function priorityLabel(p) {
  return PRIORITY_LABEL[p] || PRIORITY_LABEL.normal;
}

function priorityText(p) {
  return PRIORITY_TEXT[p] || PRIORITY_TEXT.normal;
}

function sourceLabel(s) {
  return SOURCE_LABEL[s] || SOURCE_LABEL.manual;
}

function sourceIcon(s) {
  return SOURCE_ICON[s] || SOURCE_ICON.manual;
}

function sourceCls(s) {
  return SOURCE_CLS[s] || SOURCE_CLS.manual;
}

/** openid 脱敏：oX12****cd34 */
function maskOpenid(openid) {
  const s = String(openid || '');
  if (!s) return '未登录';
  if (s.length <= 10) return s.slice(0, 2) + '****';
  return s.slice(0, 4) + '****' + s.slice(-4);
}

/** 来源原始文本摘要（溯源展示） */
function truncate(text, max) {
  const s = String(text || '');
  const n = Number(max) || 60;
  return s.length > n ? s.slice(0, n) + '…' : s;
}

/** 秒 → 秒数展示（语音时长） */
function secondsText(ms) {
  const s = Math.max(0, Math.round((Number(ms) || 0) / 1000));
  return s + '″';
}

module.exports = {
  PRIORITY_LABEL: PRIORITY_LABEL,
  SOURCE_LABEL: SOURCE_LABEL,
  DEFAULT_TIME: DEFAULT_TIME,
  pad2: pad2,
  startOfDay: startOfDay,
  endOfDay: endOfDay,
  shortDate: shortDate,
  formatDeadline: formatDeadline,
  formatRelative: formatRelative,
  toDateStr: toDateStr,
  toTimeStr: toTimeStr,
  combineDateTime: combineDateTime,
  todayStr: todayStr,
  priorityLabel: priorityLabel,
  priorityText: priorityText,
  sourceLabel: sourceLabel,
  sourceIcon: sourceIcon,
  sourceCls: sourceCls,
  maskOpenid: maskOpenid,
  truncate: truncate,
  secondsText: secondsText
};
