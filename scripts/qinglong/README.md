# 青龙多依赖自检脚本

在青龙容器里把**三层依赖**（NodeJS / Python / Linux 工具链）逐个 `require`/`import` **并真实调用一次**，
再用 canvas 画一张图，最后汇总成表。用来回答一个具体问题：**面板上标的"已安装"，到底能不能用？**

| 文件 | 用途 |
|---|---|
| `z17s_depcheck.js` | 主脚本：11 个 JS 依赖 + g++/make 真编译 + 出网实测 + 设备体检 + canvas 出图 |
| `z17s_depcheck.py` | Python 侧：requests / Crypto(AES-GCM 往返) / 标准库 / 缺失包清单 |

## 部署

```bash
scp z17s_depcheck.js z17s_depcheck.py z17s:/tmp/
ssh z17s 'cp /tmp/z17s_depcheck.* /root/qinglong/data/scripts/'
```

装完在青龙面板 → 脚本管理里就能看到。新建任务的**任务命令**填：

```
node z17s_depcheck.js          # 或者：task z17s_depcheck.py
```

想定时（每天 09:30）：cron 填 `0 30 9 * * *`。

## 复跑结果（2026-09-22 21:35，轻量冒烟版 `z17s_smoke.js`）

上面报告里 FAIL 的 5 条中，有 2 条是"我们自己的锅"，改完一直没机会复跑（一跑重 IO 就卡死）。
2026-09-22 改用**零编译、不出网**的 `z17s_smoke.js` 复验，全绿：

```
[PASS] prettytable      create(fields, rows) 渲染 7 行
[PASS] 中文字体             1 个：wqy-microhei.ttc
[PASS] canvas 出图        320x96 PNG=7636B 非白像素=6.16% font=Z17S-CJK
合计 3 项：PASS 3 / FAIL 0   耗时 1.06s   跑前 load=0.40 → 跑后 load=0.45
```

剩下 3 条 FAIL（`ts-md5` / `jsdom@30` / `jieba`）是依赖本身的坑，见上文，不用管。

> `z17s_smoke.js` 就是为"设备经不起重 IO"这个约束写的：3 个 `require` + 一次 320×96 画布，
> 1 秒级完成。**平时验证环境用这个**，`z17s_depcheck.js` 只在需要完整清单（会真跑 `g++`）时用。

## 想不开浏览器手动跑

用**和面板完全相同**的链路：

```bash
docker exec -e QL_DIR=/ql qinglong bash /ql/shell/task.sh z17s_depcheck.js
```

⚠️ **不要** `docker exec qinglong node /tmp/x.js` —— Node 解析 `require` 的基准是**脚本所在目录**（不是 cwd），
放 `/tmp` 下会甩一屏 `Cannot find module`，看起来像"依赖没装"，其实只是位置不对。

## 首次运行结果（2026-09-21 22:46，Nubia Z17S 上的青龙容器）

```
node v20.20.2 arm64/linux    NODE_PATH=…:/ql/data/dep_cache/node/global/5/node_modules
合计 32 项：PASS 27 / FAIL 5（其中 3 项为已知坏依赖）        耗时 10.3s
```

亮点读数：

- **出网**：`registry.npmjs.org` `HTTP 200` 1359ms、`baidu.com` `HTTP 200` 188ms（走 USB RNDIS → PC NAT）
- **Linux 工具链**：`g++ 12.2.0` 编译并运行成功（`harmonic(1e6)=14.392727`）、`make 4.3` 走完 Makefile
- **canvas**：720×400 PNG 出图成功（`canvas@3.2.3` arm64 **预编译二进制**，本就不需要 cairo/pango）
- **设备体检**：内核 `6.12.95+`、内存 5767MB（用 14%）、CPU 温度 44–48℃、磁盘 `/ql/data` 用 12%、
  20 个热区全部在线

当时发现的 5 个 FAIL —— 2 个是脚本自身问题（已修），3 个是**真·坏依赖**：

| 类别 | 项目 | 结论 |
|---|---|---|
| 脚本自身 | `prettytable` | 这版 `addRow()` 恒报 `Rows must be an array of arrays` → 必须 `create(fieldNames, rows)`（已修） |
| 脚本自身 | 中文字体 | 容器无 CJK 字体 → 已放 `wqy-microhei.ttc` 到持久卷并 `registerFont`（已修） |
| 🔴 真坏 | `ts-md5@2.0.1` | 纯 ESM（`"type":"module"`）→ CommonJS `require` 报 `exports is not defined in ES module scope` |
| 🔴 真坏 | `jsdom@30.x` | 需要 Node ≥ 22，容器是 20.20.2 → `Iterator is not defined` |
| 🔴 真坏 | `jieba` | 包损坏，`package.json` 的 `main` 指向不存在的 `index.js` |

> 面板显示这三个"已安装"，是因为它的判定是 `pnpm ls -g | grep <名字>` —— 字符串包含就算。
> **别只信标签，`require` 一次才算数。**

## ⚠️ 跑这个脚本是有代价的

脚本会做编译和绘图（**高 IO / 高负载**），而这台设备在 2026-09-21 22:51 跑这个脚本时
**整机硬卡死（RCU stall）**，只能长按电源 15 秒。详见 [`docs/修复记录.md`](../../docs/修复记录.md) §13。

也就是说：**这不是一个可以随便反复刷的脚本**。要跑的话：

- 一次跑完就停手，别紧接着再 scp / 传大文件
- 想看输出就让它写文件，别用 `ssh … | tail -n 大数字` 拉一长串
- 出现 `load` 单调爬升（脚本心跳会报）就是前兆 —— 停手等它自己降下来
