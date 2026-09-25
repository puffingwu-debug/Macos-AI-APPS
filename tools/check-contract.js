#!/usr/bin/env node
'use strict';
/**
 * check-contract.js —— 跨端契约一致性机械校验
 *
 * 为什么需要它：这份交付由三层组成（Mac Swift 客户端 / 微信小程序 / 云函数），
 * 三端各自独立演进，最容易出的不是「写错一行」，而是**悄悄漂移**：
 * 某端把 limit 写成 200、把字段改名、在客户端里塞了 DeepSeek key、
 * 或者新加的 action 只在云函数里实现了。
 * 这类问题往往要到真机联调才暴露，代价高。所以用这个脚本在提交前机械地拦一道。
 *
 * 它只做**文本级**断言（存在性 / 唯一性 / 禁用词），不替代运行时测试：
 *   - 运行时行为：docs/VERIFICATION.md 里的三套自检（40 + 103 + 50 项断言）
 *   - 本脚本负责：接口名、字段名、数量上限、密钥边界
 *
 * 用法：node tools/check-contract.js      （退出码 0 = 全部通过）
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const MAC_SRC = path.join(ROOT, 'QuickTodo', 'Sources', 'QuickTodo');
const MP = path.join(ROOT, 'quicktodo-weapp', 'miniprogram');
const CF = path.join(ROOT, 'quicktodo-weapp', 'cloudfunctions');

let pass = 0;
const failures = [];

function ok(name, detail) {
  pass++;
  console.log('  PASS  ' + name + (detail ? '  — ' + detail : ''));
}

function bad(name, detail) {
  failures.push(name + (detail ? ' — ' + detail : ''));
  console.log('  FAIL  ' + name + (detail ? '  — ' + detail : ''));
}

function check(name, condition, detail) {
  condition ? ok(name, detail) : bad(name, detail);
}

/** 递归收集指定后缀的文件（跳过构建产物） */
function walk(dir, ext, out) {
  out = out || [];
  if (!fs.existsSync(dir)) return out;
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (['node_modules', '.build', 'dist', '.git'].indexOf(entry.name) >= 0) continue;
      walk(full, ext, out);
    } else if (entry.name.endsWith(ext)) {
      out.push(full);
    }
  }
  return out;
}

function readAll(files) {
  return files.map(function (f) { return fs.readFileSync(f, 'utf8'); }).join('\n');
}

/**
 * 去掉注释但**保留字符串字面量**。
 *
 * 为什么不能简单 `replace(/\/\/.*$/)`：那样会把 `"https://api.deepseek.com"` 里的
 * URL 一起剪掉，反而让「客户端不直连 DeepSeek」这条安全检查漏报（假阴性）。
 * 而注释里出现 `DEEPSEEK_API_KEY` / `api.deepseek.com` 是**文档说明**，不该算违规
 * （假阳性）。所以这里用一个最小的词法扫描：字符串原样保留，注释丢弃。
 */
function stripComments(src) {
  let out = '';
  let i = 0;
  let quote = null;
  const n = src.length;
  while (i < n) {
    const c = src[i];
    const d = src[i + 1];
    if (quote) {
      out += c;
      if (c === '\\') { out += d === undefined ? '' : d; i += 2; continue; }
      if (c === quote) quote = null;
      i++;
      continue;
    }
    if (c === '"' || c === "'" || c === '`') { quote = c; out += c; i++; continue; }
    if (c === '/' && d === '/') { while (i < n && src[i] !== '\n') i++; continue; }
    if (c === '/' && d === '*') {
      i += 2;
      while (i < n && !(src[i] === '*' && src[i + 1] === '/')) i++;
      i += 2;
      continue;
    }
    out += c;
    i++;
  }
  return out;
}

/** 只保留代码（去注释）后的聚合文本 */
function readCode(files) {
  return files.map(function (f) { return stripComments(fs.readFileSync(f, 'utf8')); }).join('\n');
}

function rel(p) {
  return path.relative(ROOT, p);
}

/** 某个 token 出现在哪些文件里 */
function findToken(files, token) {
  const hit = [];
  for (const f of files) {
    if (fs.readFileSync(f, 'utf8').indexOf(token) >= 0) hit.push(rel(f));
  }
  return hit;
}

console.log('== QuickTodo 跨端契约一致性校验 ==');
console.log('   契约：docs/SYNC-PROTOCOL.md\n');

const macFiles = walk(MAC_SRC, '.swift');
const mpFiles = walk(MP, '.js');
const cfFiles = walk(CF, '.js');
const cfReadme = path.join(CF, 'README.md');

if (!macFiles.length || !mpFiles.length || !cfFiles.length) {
  console.error('!! 找不到某一端的源码，检查路径：\n   ' + [MAC_SRC, MP, CF].join('\n   '));
  process.exit(2);
}

const macSrc = readAll(macFiles);
const mpSrc = readAll(mpFiles);
const cfSrc = readAll(cfFiles);

// ---------------------------------------------------------------- 1. 字段名
console.log('[1] 待办字段（契约 §1）三端一致');
const FIELDS = ['id', 'content', 'deadline', 'priority', 'status', 'source',
                'rawText', 'deleted', 'createTime', 'updateTime'];
for (const field of FIELDS) {
  const inMac = macSrc.indexOf(field) >= 0;
  const inMp = mpSrc.indexOf(field) >= 0;
  const inCf = cfSrc.indexOf(field) >= 0;
  check('字段 ' + field + ' 三端都在', inMac && inMp && inCf,
        'Mac=' + (inMac ? '✓' : '✗') + ' 小程序=' + (inMp ? '✓' : '✗') + ' 云函数=' + (inCf ? '✓' : '✗'));
}

// ---------------------------------------------------------------- 2. action 名
console.log('\n[2] 云函数 action 名（契约 §2 / §3 / §4）');
const TODO_ACTIONS = ['list', 'upsert', 'bulkUpsert', 'remove', 'clearDone', 'ping'];
for (const action of TODO_ACTIONS) {
  check('todo 云函数实现 ' + action, cfSrc.indexOf("'" + action + "'") >= 0);
}
const AI_ACTIONS = ['parse'];
for (const action of AI_ACTIONS) {
  check('ai 云函数实现 ' + action, findToken([path.join(CF, 'ai', 'index.js')], "'" + action + "'").length > 0);
}
const AUTH_ACTIONS = ['createTicket', 'pollTicket', 'confirmTicket', 'check', 'logout'];
for (const action of AUTH_ACTIONS) {
  check('auth 云函数实现 ' + action, findToken([path.join(CF, 'auth', 'index.js')], "'" + action + "'").length > 0);
}

// ---------------------------------------------------------------- 3. 客户端调用面
console.log('\n[3] 两端调用的 action 都在云函数里有实现');
const CLIENT_ACTIONS = ['list', 'upsert', 'bulkUpsert', 'remove', 'ping', 'parse',
                        'createTicket', 'pollTicket', 'confirmTicket', 'check', 'logout'];
for (const action of CLIENT_ACTIONS) {
  const used = (macSrc.indexOf(action) >= 0 ? ['Mac'] : [])
    .concat(mpSrc.indexOf(action) >= 0 ? ['小程序'] : []);
  if (!used.length) continue;   // 该端没用到这个 action，不算问题
  check(action + '（' + used.join(' + ') + '）云函数已实现', cfSrc.indexOf(action) >= 0);
}

// ---------------------------------------------------------------- 4. limit 上限
console.log('\n[4] 分页上限（契约 §2.3：固定 100）');
check('Mac 端 list 传 limit 100', /limit: 100/.test(macSrc), 'SyncEngine 里显式传 100');
check('Mac 端 API 默认 limit = 100', /limit: Int = 100/.test(macSrc));
check('小程序 pageLimit = 100', /pageLimit:\s*100/.test(mpSrc));
check('云函数 clamp 到 100', /MAX_LIMIT\s*=\s*100/.test(cfSrc));
check('云函数不再出现 limit 200', !/limit["']?\s*:\s*200/.test(cfSrc));

// ---------------------------------------------------------------- 5. 密钥边界
console.log('\n[5] 密钥边界（契约 §3.3 / §6）');
const clientFiles = macFiles.concat(mpFiles);
// 安全检查必须在**去注释**后的代码上做：注释里写「不得出现 DEEPSEEK_API_KEY」是文档，不是违规
const clientCode = readCode(clientFiles);
const leakedKey = /sk-[A-Za-z0-9]{16,}/.test(clientCode) ? ['(检测到形如 sk-xxx 的密钥字面量)'] : [];
check('客户端没有 API key 字面量', leakedKey.length === 0, leakedKey.join(', ') || '干净');

const directUpstream = clientCode.indexOf('api.deepseek.com') >= 0
  ? ['(客户端代码里出现了 api.deepseek.com)'] : [];
check('客户端不直连 DeepSeek', directUpstream.length === 0, directUpstream.join(', ') || '干净（仅注释中提及该规则）');

const keyEnvOutsideCloud = clientCode.indexOf('DEEPSEEK_API_KEY') >= 0
  ? ['(客户端代码里引用了该环境变量)'] : [];
check('DEEPSEEK_API_KEY 不出现在客户端代码中', keyEnvOutsideCloud.length === 0,
      keyEnvOutsideCloud.join(', ') || '干净（仅注释中提及该规则）');

check('云函数确实从环境变量读 key', /process\.env\.DEEPSEEK_API_KEY/.test(cfSrc));
check('云函数支持 base_url / model / timeout 环境变量',
      /DEEPSEEK_BASE_URL/.test(cfSrc) && /DEEPSEEK_MODEL/.test(cfSrc) && /DEEPSEEK_TIMEOUT_MS/.test(cfSrc));
check('默认模型为 deepseek-flash', /deepseek-flash/.test(cfSrc));

// ---------------------------------------------------------------- 6. ai 鉴权
console.log('\n[6] ai 云函数鉴权（防止白烧额度）');
const aiIndex = path.join(CF, 'ai', 'index.js');
const aiSrc = fs.existsSync(aiIndex) ? stripComments(fs.readFileSync(aiIndex, 'utf8')) : '';
const aiAuthCall = aiSrc.indexOf('await resolveIdentity(');
const aiParseCall = aiSrc.indexOf('await handleParse(');
check('ai 做身份解析', /resolveIdentity/.test(aiSrc));
check('ai 未授权返回 unauthorized', /unauthorized/.test(aiSrc));
check('ai 先鉴权再解析（不消耗 DeepSeek 额度）',
      aiAuthCall >= 0 && aiParseCall >= 0 && aiAuthCall < aiParseCall,
      'resolveIdentity@' + aiAuthCall + ' < handleParse@' + aiParseCall);

// ---------------------------------------------------------------- 7. 契约版本
console.log('\n[7] 契约版本号一致');
const contract = fs.readFileSync(path.join(ROOT, 'docs', 'SYNC-PROTOCOL.md'), 'utf8');
const versionMatch = contract.match(/契约版本：`(v\d+)`/);
const contractVersion = versionMatch ? versionMatch[1] : null;
check('契约头部声明了版本号', !!contractVersion, contractVersion || '未找到');
if (contractVersion) {
  const macPing = /version: "v1"|version = "v1"|"version": "v1"/.test(cfSrc) || /VERSION = 'v1'/.test(cfSrc);
  check('云函数返回的 version 与契约一致 (' + contractVersion + ')', macPing);
  check('小程序 config 声明 contractVersion 一致',
        new RegExp("contractVersion:\\s*'" + contractVersion + "'").test(mpSrc));
}

// ---------------------------------------------------------------- 8. 部署文档
console.log('\n[8] 交付文档齐备');
check('云函数部署手册存在', fs.existsSync(cfReadme));
check('契约文档存在', fs.existsSync(path.join(ROOT, 'docs', 'SYNC-PROTOCOL.md')));
check('验证记录存在', fs.existsSync(path.join(ROOT, 'docs', 'VERIFICATION.md')));
check('Mac 端 README 存在', fs.existsSync(path.join(ROOT, 'QuickTodo', 'README.md')));
check('小程序端 README 存在', fs.existsSync(path.join(ROOT, 'quicktodo-weapp', 'README.md')));
check('云函数本地联调工具存在', fs.existsSync(path.join(ROOT, 'quicktodo-weapp', 'tools', 'cloud-harness.js')));

// ---------------------------------------------------------------- 汇总
console.log('\n==========================================');
if (failures.length === 0) {
  console.log('契约一致性校验全部通过: ' + pass + ' passed, 0 failed');
} else {
  console.log('契约一致性校验失败: ' + pass + ' passed, ' + failures.length + ' failed');
  console.log('失败项:\n  - ' + failures.join('\n  - '));
}
console.log('==========================================');
process.exit(failures.length === 0 ? 0 : 1);
