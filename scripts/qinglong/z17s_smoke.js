/**
 * Z17S 轻量冒烟检查 —— 只验证「不重 IO」的那几个依赖
 *
 * 为什么单独有这个脚本（2026-09-21 教训）：
 *   完整 z17s_depcheck.js 的第 3 节会 `g++ -O2` 真编译 + `make` 真构建 —— cc1plus 要拉
 *   几百个头文件，这是打在 UFS 上的高 IO 尖峰；随后就会看到
 *       l26: failed to set load 560000: -ETIMEDOUT
 *       ufshcd-qcom 1da4000.ufshc: ufshcd_config_vreg_load: vccq set load (ua=560000) failed, err=-110
 *   紧接着 RCU stall 级联、整机停摆（只能长按电源 15 秒）。
 *   所以「验证 canvas / 中文字体 / prettytable」不要顺带跑编译器。
 *
 * 本脚本只做：3 个 require + 1 次 320x96 小画布渲染 + 1 张 PNG 落盘。秒级完成。
 *
 * 用法（青龙容器内）：
 *   NODE_PATH=/ql/data/dep_cache/node/global/5/node_modules node z17s_smoke.js
 */

'use strict';

const fs = require('fs');
const os = require('os');

const T0 = Date.now();
const FONT_DIRS = ['/ql/data/fonts', '/usr/share/fonts'];
const CJK_RE = /wqy|noto.*(cjk|sc|sans)|source.?han|droid.*fallback|simhei|msyh|hei|song|kai/i;
const OUT = '/ql/data/scripts/z17s-smoke.png';

const rows = [];
function rec(name, ok, detail) {
  rows.push({ name, ok: !!ok, detail: String(detail).replace(/\s+/g, ' ').slice(0, 90) });
  console.log(`[${ok ? 'PASS' : 'FAIL'}] ${name.padEnd(16)} ${detail}`);
}

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
function cjkFonts() {
  const all = [];
  for (const d of FONT_DIRS) all.push(...walkFonts(d, 0));
  return { all, cjk: all.filter(f => CJK_RE.test(f)) };
}

function loadavg() { return os.loadavg().map(x => x.toFixed(2)).join('/'); }
function ufsPm() {
  const p = '/sys/bus/platform/devices/1da4000.ufshc/power';
  try {
    return `control=${fs.readFileSync(p + '/control', 'utf8').trim()} runtime=${fs.readFileSync(p + '/runtime_status', 'utf8').trim()}`;
  } catch (e) { return '(不可读)'; }
}

console.log('Z17S 冒烟检查  ' + new Date().toLocaleString('zh-CN', { hour12: false }));
console.log(`node ${process.version} ${process.arch}   load=${loadavg()}   UFS ${ufsPm()}`);
console.log('');

// 1. prettytable —— 这个版本的 addRow() 是坏的，必须 create(fields, rows)
try {
  const PT = require('prettytable');
  const T = PT.PrettyTable || PT;
  const t = new T();
  t.create(['模块', '状态'], [['canvas', 'ok'], ['prettytable', 'ok'], ['中文字体', 'ok']]);
  const s = t.toString();
  if (!s.includes('canvas')) throw new Error('输出里没有 canvas，渲染异常');
  const lines = s.split('\n').filter(Boolean);
  rec('prettytable', true, `create(fields, rows) 渲染 ${lines.length} 行`);
  console.log(s.split('\n').map(l => '    ' + l).join('\n'));
} catch (e) {
  rec('prettytable', false, e.message || e);
}

// 2. 中文字体（直接扫目录，不看 fontconfig —— 容器里 fc-list 看不到是正常的）
const { all, cjk } = cjkFonts();
rec('中文字体', cjk.length > 0,
  cjk.length ? `${cjk.length} 个：${cjk.map(f => f.split('/').pop()).join(', ')}` :
    `无（扫描到 ${all.length} 个字体文件）`);

// 3. canvas + 中文真渲染
try {
  const { createCanvas, registerFont } = require('canvas');
  let family = 'sans-serif';
  const tried = [];
  for (const f of cjk) {
    try { registerFont(f, { family: 'Z17S-CJK' }); family = 'Z17S-CJK'; break; }
    catch (e) { tried.push(`${f.split('/').pop()}: ${e.message}`); }
  }

  const W = 320, H = 96;
  const cv = createCanvas(W, H);
  const ctx = cv.getContext('2d');
  ctx.fillStyle = '#ffffff';
  ctx.fillRect(0, 0, W, H);
  ctx.fillStyle = '#111111';
  ctx.font = `bold 26px "${family}"`;
  ctx.fillText('中文渲染 测试', 16, 40);
  ctx.font = `14px "${family}"`;
  ctx.fillStyle = '#2f6f3e';
  ctx.fillText(`font=${family}  ${new Date().toLocaleTimeString('zh-CN', { hour12: false })}`, 16, 68);

  const buf = cv.toBuffer('image/png');
  fs.writeFileSync(OUT, buf);

  // 粗糙的「有没有画出东西」判据：统计非白像素占比
  const raw = ctx.getImageData(0, 0, W, H).data;
  let ink = 0;
  for (let i = 0; i < raw.length; i += 4) if (raw[i] < 200) ink++;
  const ratio = ink / (W * H);

  rec('canvas 出图', true,
    `${W}x${H} PNG=${buf.length}B 非白像素=${(ratio * 100).toFixed(2)}% font=${family} → ${OUT}`);
  if (tried.length) console.log('    （registerFont 失败过：' + tried.join(' | ') + '）');
  if (ratio < 0.01) console.log('    ⚠️ 非白像素过少，中文可能没画出来');
} catch (e) {
  rec('canvas 出图', false, e.message || e);
}

// 4. 收尾
const pass = rows.filter(r => r.ok).length;
console.log('');
console.log(`合计 ${rows.length} 项：PASS ${pass} / FAIL ${rows.length - pass}   耗时 ${((Date.now() - T0) / 1000).toFixed(2)}s   load=${loadavg()}`);
console.log(`UFS PM 事后：${ufsPm()}`);
