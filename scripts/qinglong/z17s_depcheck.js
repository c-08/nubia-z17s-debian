/**
 * Z17S 依赖自检 —— 在青龙容器里把依赖真跑一遍，顺便体检设备
 *
 * 用法（青龙面板 → 脚本管理 → 新建任务 → 任务命令填）：
 *     node z17s_depcheck.js
 * 建议定时：0 30 9 * * *   （每天 09:30）
 *
 * 设计原则：不听面板的"已安装"标签，一律 require + 真实调用一次。
 * 每个依赖都有独立 try/catch，坏掉一个不影响其它；全部输出汇总成一张表。
 */

'use strict';

const fs = require('fs');
const os = require('os');
const { execFileSync } = require('child_process');

const SCRIPT_DIR = '/ql/data/scripts';
const TMP = '/tmp';
const T0 = Date.now();

const results = [];
function rec(kind, name, ok, detail) {
  results.push({ kind, name, ok: !!ok, detail: String(detail).replace(/\s+/g, ' ').slice(0, 96) });
  console.log(`[${ok ? 'PASS' : 'FAIL'}] ${kind.padEnd(8)} ${name.padEnd(14)} ${detail}`);
}
function attempt(kind, name, fn) {
  try {
    const d = fn();
    rec(kind, name, true, d === undefined ? 'ok' : d);
  } catch (e) {
    rec(kind, name, false, (e && e.message) ? e.message : e);
  }
}

// 宽字符感知的表格渲染（中文一个字占两格，prettytable 按字节算会错位）
function dispWidth(s) {
  let w = 0;
  for (const ch of String(s)) {
    const c = ch.codePointAt(0);
    const wide = (
      (c >= 0x1100 && c <= 0x115f) ||
      c === 0x2329 || c === 0x232a ||
      (c >= 0x2e80 && c <= 0xa4cf && c !== 0x303f) ||
      (c >= 0xac00 && c <= 0xd7a3) ||
      (c >= 0xf900 && c <= 0xfaff) ||
      (c >= 0xfe30 && c <= 0xfe6f) ||
      (c >= 0xff00 && c <= 0xff60) ||
      (c >= 0xffe0 && c <= 0xffe6) ||
      (c >= 0x1f300 && c <= 0x1f9ff) ||   // emoji
      (c >= 0x20000 && c <= 0x3fffd)
    );
    w += wide ? 2 : 1;
  }
  return w;
}
function padTo(s, w) { return String(s) + ' '.repeat(Math.max(0, w - dispWidth(s))); }
function renderTable(headers, rows) {
  const all = [headers, ...rows];
  const w = headers.map((_, i) => Math.max(...all.map(r => dispWidth(r[i] === undefined ? '' : r[i]))));
  const line = '+' + w.map(x => '-'.repeat(x + 2)).join('+') + '+';
  const fmt = r => '| ' + r.map((c, i) => padTo(c === undefined ? '' : c, w[i])).join(' | ') + ' |';
  return [line, fmt(headers), line, ...rows.map(fmt), line].join('\n');
}

// 字体扫描：优先看青龙持久卷 /ql/data/fonts（容器重建也不丢），再看系统目录
const FONT_DIRS = ['/ql/data/fonts', '/usr/share/fonts'];
const CJK_RE = /wqy|noto.*(cjk|sc|sans)|source.?han|droid.*fallback|simhei|msyh|hei|song|kai/i;

function walkFonts(dir, depth) {
  if (depth > 4) return [];
  let ents = [];
  try { ents = fs.readdirSync(dir, { withFileTypes: true }); } catch (e) { return []; }
  const out = [];
  for (const e of ents) {
    const p = dir + '/' + e.name;
    if (e.isDirectory()) out.push(...walkFonts(p, depth + 1));
    else if (/\.(ttf|otf|ttc)$/i.test(e.name)) out.push(p);
  }
  return out;
}
function allFonts() {
  const hits = [];
  for (const d of FONT_DIRS) hits.push(...walkFonts(d, 0));
  return hits;
}
function cjkFonts() { return allFonts().filter(f => CJK_RE.test(f)); }

// ---------------------------------------------------------------- 环境信息
console.log('='.repeat(78));
console.log('Z17S 依赖自检  ·  ' + new Date().toLocaleString('zh-CN', { hour12: false }));
console.log('='.repeat(78));
console.log('node      : ' + process.version + '   ' + process.arch + ' / ' + process.platform);
console.log('NODE_PATH : ' + (process.env.NODE_PATH || '(unset)'));
console.log('cwd       : ' + process.cwd());
console.log('');

console.log('--- 1. NodeJS 依赖（逐个 require + 实际调用）---');

attempt('nodejs', 'axios', () => {
  const ax = require('axios');
  return typeof ax.get === 'function' ? 'module ok（出网测试见第 4 节）' : 'no .get';
});

attempt('nodejs', 'crypto-js', () => {
  const CJ = require('crypto-js');
  const md5 = CJ.MD5('z17s-depcheck').toString();
  const sha = CJ.SHA256('z17s-depcheck').toString().slice(0, 16);
  return `md5=${md5.slice(0, 12)}… sha256=${sha}…`;
});

attempt('nodejs', 'js-base64', () => {
  const { Base64 } = require('js-base64');
  const enc = Base64.encode('青龙依赖自检');
  const dec = Base64.decode(enc);
  if (dec !== '青龙依赖自检') throw new Error('往返不一致');
  return `${enc} → 往返一致`;
});

attempt('nodejs', 'json5', () => {
  const JSON5 = require('json5');
  const o = JSON5.parse("{a:1, b:'x', c:[1,2,],}");
  return JSON.stringify(o);
});

attempt('nodejs', 'moment', () => require('moment')().format('YYYY-MM-DD HH:mm:ss'));

attempt('nodejs', 'date-fns', () => {
  const { format, differenceInYears } = require('date-fns');
  return `format=${format(new Date(), 'yyyy-MM-dd')} diff=${differenceInYears(new Date(), new Date('2026-01-01'))}y`;
});

attempt('nodejs', 'dotenv', () => {
  const dotenv = require('dotenv');
  const p = `${TMP}/z17s-check.env`;
  fs.writeFileSync(p, 'Z17S_PROBE=hello-env\n');
  const r = dotenv.config({ path: p });
  if (r.error) throw r.error;
  if (r.parsed.Z17S_PROBE !== 'hello-env') throw new Error('解析结果不对');
  return '读 .env 成功 ' + JSON.stringify(r.parsed);
});

attempt('nodejs', 'prettytable', () => {
  // ⚠️ 这个版本的 addRow() 是坏的（恒报 "Rows must be an array of arrays"），
  //    必须用 create(fieldNames, rows) 一次性给全部行。
  const PT = require('prettytable');
  const T = PT.PrettyTable || PT;
  const t = new T();
  t.create(['module', 'value'], [['canvas', 'ok'], ['g++', 'ok']]);
  const s = t.toString();
  if (!s.includes('canvas')) throw new Error('输出异常');
  return s.split('\n').filter(Boolean).length + ' 行表格已渲染（create(fields, rows) 形式）';
});

attempt('nodejs', 'canvas', () => {
  const { createCanvas, registerFont } = require('canvas');
  const cv = createCanvas(8, 8);
  const ctx = cv.getContext('2d');
  ctx.fillStyle = '#f00';
  ctx.fillRect(0, 0, 8, 8);
  const b = cv.toBuffer('image/png');
  if (b.length < 50) throw new Error('PNG 太小');
  return `画布可用，8x8 PNG=${b.length}B registerFont=${typeof registerFont}`;
});

attempt('nodejs', 'ws', () => {
  const WebSocket = require('ws');
  const Server = WebSocket.Server || (WebSocket.default && WebSocket.default.Server);
  if (typeof Server !== 'function') throw new Error('no Server');
  return 'Server 构造函数可用（真实握手见第 5 节）';
});

attempt('nodejs', 'node-fetch', () => {
  const nf = require('node-fetch');
  const f = nf.default || nf;
  return typeof f === 'function' ? 'module ok' : 'no callable';
});

console.log('');
console.log('--- 2. 曾经的坏依赖（09-22 已换成可用版，这里真调用一次防退化）---');

// 背景（都写在这，免得以后又忘）：
//   ts-md5@2.0.1 是发布事故 —— package.json 的 exports.require 指向
//     dist/index.cjs.js，可包又声明了 "type":"module"，而 .js 结尾在
//     "type":"module" 下一律按 ESM 解析 → CJS 代码报
//     "exports is not defined in ES module scope"。降到 1.3.1（纯 CJS）即好。
//   jsdom@30 要求 Node ≥ 22，容器是 20.20.2 → 降到 26.1.0（engines: >=18）。
//   npm 上的 jieba@1.0.0 是坏包：main 指向 index.js，但发布的 tarball 里
//     根本没这个文件。已用 /ql/data/scripts/node_modules/jieba 这个壳
//     转发到 @node-rs/jieba（linux-arm64-gnu 预编译，手机上无需编译），
//     所以老写法 require('jieba') 照旧可用。
attempt('fixed', 'ts-md5', () => {
  const { Md5 } = require('ts-md5');
  const got = Md5.hashStr('hello');
  if (got !== '5d41402abc4b2a76b9719d911017c592') throw new Error('md5 结果不对: ' + got);
  return `Md5.hashStr(hello)=${got}  v${require('ts-md5/package.json').version}`;
});

attempt('fixed', 'jsdom', () => {
  const { JSDOM } = require('jsdom');
  const d = new JSDOM('<title>t</title><p id=x>中文</p>');
  const txt = d.window.document.querySelector('#x').textContent;
  if (txt !== '中文') throw new Error('DOM 文本不对: ' + txt);
  return `JSDOM 解析 OK <p>=${txt}  v${require('jsdom/package.json').version}`;
});

attempt('fixed', 'jieba', () => {
  const jb = require('jieba');
  const words = jb.cut('我们中出了一个叛徒', true);
  if (!Array.isArray(words) || !words.length) throw new Error('cut() 没返回数组');
  const tags = jb.tag('我爱北京天安门');
  if (!Array.isArray(tags) || !tags.length) throw new Error('tag() 没返回数组');
  return `cut=${JSON.stringify(words)} tag=${tags.length} v${require('jieba/package.json').version}`;
});
// 把"到底解析到哪个文件"打出来 —— 哪天它悄悄退回那个坏包，一眼就能看见
try {
  console.log(`        (jieba 实际解析到 ${require.resolve('jieba')})`);
} catch (e) { /* 上面 attempt 已经报过了 */ }

console.log('');
console.log('--- 3. Linux 依赖（g++ 真编译 + make 真构建）---');

attempt('linux', 'g++ 编译', () => {
  const cpp = `${TMP}/z17s_check.cpp`;
  fs.writeFileSync(cpp, `#include <cstdio>
#include <cmath>
int main() {
  double s = 0;
  for (int i = 1; i <= 1000000; ++i) s += 1.0 / i;
  printf("harmonic(1e6)=%.6f\\n", s);
  return 0;
}
`);
  execFileSync('g++', ['-O2', '-o', `${TMP}/z17s_check`, cpp], { timeout: 60000, stdio: 'pipe' });
  const out = execFileSync(`${TMP}/z17s_check`, { timeout: 10000 }).toString().trim();
  return `编译并运行成功：${out}`;
});

attempt('linux', 'make 构建', () => {
  const dir = `${TMP}/z17s-mk`;
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(`${dir}/main.c`, `#include <stdio.h>
int main(void){ printf("make-ok\\n"); return 0; }
`);
  fs.writeFileSync(`${dir}/Makefile`, `all: app
app: main.c
\tgcc -o app main.c
clean:
\trm -f app
`);
  execFileSync('make', ['-C', dir], { timeout: 60000, stdio: 'pipe' });
  const out = execFileSync(`${dir}/app`, { timeout: 10000 }).toString().trim();
  if (out !== 'make-ok') throw new Error('输出异常 ' + out);
  return '生成 Makefile → make → 运行成功';
});

attempt('linux', 'gcc 版本', () => execFileSync('gcc', ['--version']).toString().split('\n')[0]);
attempt('linux', 'g++ 版本', () => execFileSync('g++', ['--version']).toString().split('\n')[0]);
attempt('linux', 'git', () => execFileSync('git', ['--version']).toString().trim());
attempt('linux', 'curl', () => execFileSync('curl', ['--version']).toString().split('\n')[0].trim());

console.log('');
console.log('--- 4. 出网实测（走 USB RNDIS → PC NAT，结果见文件末尾）---');

console.log('');
console.log('--- 5. 设备体检 ---');

attempt('host', '内核', () => os.release() + ' ' + os.arch());
attempt('host', 'CPU', () => {
  const txt = fs.readFileSync('/proc/cpuinfo', 'utf8');
  // x86 有 model name；arm64 没有，只有 implementer + part 号
  const model = txt.match(/^model name\s*:\s*(.+)$/m);
  if (model) return model[1].trim() + ` ×${os.cpus().length}核`;
  const impl = (txt.match(/^CPU implementer\s*:\s*(\S+)/m) || [])[1] || '?';
  const part = (txt.match(/^CPU part\s*:\s*(\S+)/m) || [])[1] || '?';
  const KNOWN = {
    '0x51:0x801': 'Qualcomm Kryo (A73 系)',
    '0x51:0x802': 'Qualcomm Kryo 385 (A75 系)',
    '0x51:0x800': 'Qualcomm Kryo (A57 系)',
    '0x41:0xd03': 'ARM Cortex-A53',
    '0x41:0xd05': 'ARM Cortex-A55',
    '0x41:0xd07': 'ARM Cortex-A57',
    '0x41:0xd08': 'ARM Cortex-A72',
    '0x41:0xd09': 'ARM Cortex-A73',
    '0x41:0xd0d': 'ARM Cortex-A77',
  };
  const name = KNOWN[`${impl}:${part}`] || `impl ${impl} part ${part}`;
  return `${name} ×${os.cpus().length}核`;
});
attempt('host', '内存', () => {
  const t = os.totalmem() / 1048576, f = os.freemem() / 1048576;
  return `总 ${t.toFixed(0)}MB，空闲 ${f.toFixed(0)}MB（已用 ${(100 - f / t * 100).toFixed(0)}%）`;
});
attempt('host', '负载', () => os.loadavg().map(x => x.toFixed(2)).join(' / '));
attempt('host', '运行时长', () => (os.uptime() / 60).toFixed(0) + ' 分钟');
attempt('host', 'CPU 温度', () => {
  const base = '/sys/class/thermal';
  const zones = fs.readdirSync(base).filter(z => z.startsWith('thermal_zone'));
  const out = [];
  for (const z of zones) {
    try {
      const t = parseInt(fs.readFileSync(`${base}/${z}/temp`, 'utf8').trim(), 10);
      const type = fs.readFileSync(`${base}/${z}/type`, 'utf8').trim();
      if (t > 0) out.push(`${type}=${(t / 1000).toFixed(1)}℃`);
    } catch (e) { /* 忽略读不到的温度域 */ }
  }
  return out.length ? out.join(' ') : '(无温度域)';
});
attempt('host', '磁盘', () => execFileSync('df', ['-h', '/ql/data']).toString().split('\n')[1]);
attempt('host', '中文字体', () => {
  const fonts = allFonts();
  const cjk = cjkFonts();
  if (!cjk.length) throw new Error(`无中文字体（共 ${fonts.length} 个西文字体）→ canvas 画中文会变方框`);
  return `${cjk.length} 个：${cjk.map(f => f.split('/').pop()).slice(0, 3).join(', ')}`;
});

// ---------------------------------------------------------------- main
(async () => {
  // 4. 出网实测（异步部分）
  const ax = require('axios');
  const targets = [
    ['registry.npmjs.org', 'https://registry.npmjs.org/'],
    ['baidu.com', 'https://www.baidu.com/'],
  ];
  for (const [label, url] of targets) {
    const t = Date.now();
    try {
      const r = await ax.get(url, { timeout: 12000, validateStatus: () => true });
      rec('network', label, r.status === 200, `HTTP ${r.status}  ${Date.now() - t}ms`);
    } catch (e) {
      rec('network', label, false, (e.message || e) + '');
    }
  }

  // node-fetch 也真拉一次，别只看 require 成功
  try {
    const nf = require('node-fetch');
    const f = nf.default || nf;
    const r = await f('https://registry.npmjs.org/', { timeout: 12000 });
    rec('network', 'node-fetch', r.status === 200, `HTTP ${r.status}`);
  } catch (e) {
    rec('network', 'node-fetch', false, (e.message || e) + '');
  }

  // 5b. canvas 真画一张图（含中文渲染；中文字体从持久卷自动注册）
  let pngPath = '';
  try {
    const { createCanvas, registerFont } = require('canvas');
    let family = 'DejaVu Sans';
    const cjk = cjkFonts();
    for (const f of cjk) {
      try { registerFont(f, { family: 'Z17S-CJK' }); family = 'Z17S-CJK'; break; }
      catch (e) { /* 这个字体不可用就换下一个 */ }
    }

    const W = 760, H = 440;
    const cv = createCanvas(W, H);
    const ctx = cv.getContext('2d');
    const grad = ctx.createLinearGradient(0, 0, W, H);
    grad.addColorStop(0, '#12224a');
    grad.addColorStop(1, '#1c4d3a');
    ctx.fillStyle = grad;
    ctx.fillRect(0, 0, W, H);

    ctx.fillStyle = 'rgba(255,255,255,0.08)';
    ctx.fillRect(0, 0, W, 96);

    ctx.fillStyle = '#ffffff';
    ctx.font = `bold 32px "${family}"`;
    ctx.fillText('Z17S 依赖自检', 32, 58);
    ctx.font = `16px "${family}"`;
    ctx.fillStyle = 'rgba(255,255,255,0.72)';
    ctx.fillText('Nubia Z17S · MSM8998 · Debian 13 trixie · Qinglong container', 32, 82);

    // 卡片上的计数必须和后面的汇总表对得上。注意"出图"这一项要等 PNG 存盘后
    // 才会 rec()，而卡片在这之前就画好了 —— 直接数 results 会少数 1 项，
    // 进度条分母也会少 1。能走到这里就说明 canvas 可用、"出图"必然 PASS，
    // 所以这里把它自己预算进去（+1）。
    const pass = results.filter(r => r.ok).length + 1;
    const fail = results.filter(r => !r.ok).length;
    const totalN = results.length + 1;
    const lines = [
      `内核   ${os.release()}  ${os.arch()}`,
      `内存   ${(os.totalmem() / 1048576).toFixed(0)} MB（空闲 ${(os.freemem() / 1048576).toFixed(0)} MB）`,
      `负载   ${os.loadavg().map(x => x.toFixed(2)).join(' / ')}   运行 ${(os.uptime() / 60).toFixed(0)} 分钟`,
      `Node   ${process.version}`,
      `检查项 ${pass} 通过 / ${fail} 失败`,
    ];
    ctx.font = `18px "${family}"`;
    ctx.fillStyle = '#ffffff';
    lines.forEach((l, i) => ctx.fillText(l, 32, 140 + i * 34));

    // 进度条
    const barW = W - 64, barH = 16, barY = 330;
    ctx.fillStyle = 'rgba(255,255,255,0.18)';
    ctx.fillRect(32, barY, barW, barH);
    ctx.fillStyle = '#3fb950';
    ctx.fillRect(32, barY, barW * (pass / totalN), barH);

    ctx.font = `14px "${family}"`;
    ctx.fillStyle = 'rgba(255,255,255,0.65)';
    ctx.fillText(`生成于 ${new Date().toLocaleString('zh-CN', { hour12: false })}  ·  z17s_depcheck.js`, 32, 385);
    ctx.fillText(`中文字体：${family === 'Z17S-CJK' ? '文泉驿微米黑（已注册）' : '缺失，中文已降级为方框'}`, 32, 408);

    pngPath = `${SCRIPT_DIR}/z17s-depcheck.png`;
    const png = cv.toBuffer('image/png');
    fs.writeFileSync(pngPath, png);
    rec('nodejs', 'canvas 出图', true, `${W}x${H} PNG 已存 ${pngPath} (${png.length}B) 字体=${family}`);
  } catch (e) {
    rec('nodejs', 'canvas 出图', false, e.message);
  }

  // 6. 汇总表
  console.log('');
  console.log('--- 6. 汇总 ---');
  // 说明：这里不用 prettytable —— 它按字节数算列宽，中文表头会错位。
  console.log(renderTable(['类别', '项目', '结果', '说明'],
    results.map(r => [r.kind, r.name, r.ok ? 'PASS' : 'FAIL', r.detail])));

  const pass = results.filter(r => r.ok).length;
  const fail = results.filter(r => !r.ok).length;

  console.log('');
  console.log('='.repeat(78));
  console.log(`合计 ${results.length} 项：PASS ${pass}  /  FAIL ${fail}`);
  console.log(`耗时 ${((Date.now() - T0) / 1000).toFixed(1)}s`);
  if (pngPath) console.log(`示意图：${pngPath}`);
  console.log('='.repeat(78));

  // 报告落盘（便于事后翻查 / 外部取回）
  const report = [
    `Z17S 依赖自检报告  ${new Date().toISOString()}`,
    `node ${process.version} ${process.arch}  load=${os.loadavg().map(x => x.toFixed(2)).join('/')}`,
    '',
    ...results.map(r => `${r.ok ? 'PASS' : 'FAIL'}\t${r.kind}\t${r.name}\t${r.detail}`),
    '',
    `合计 ${results.length}：PASS ${pass} / FAIL ${fail}`,
  ].join('\n');
  fs.writeFileSync(`${SCRIPT_DIR}/z17s-depcheck-report.txt`, report + '\n');

  process.exit(fail > 0 ? 1 : 0);
})();
