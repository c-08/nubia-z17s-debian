# 青龙多依赖自检脚本

在青龙容器里把**三层依赖**（NodeJS / Python / Linux 工具链）逐个 `require`/`import` **并真实调用一次**，
再用 canvas 画一张图，最后汇总成表。用来回答一个具体问题：**面板上标的"已安装"，到底能不能用？**

| 文件 | 用途 |
|---|---|
| `z17s_depcheck.js` | 主脚本：11 个 JS 依赖 + g++/make 真编译 + 出网实测 + 设备体检 + canvas 出图 |
| `z17s_depcheck.py` | Python 侧：requests / Crypto(AES-GCM 往返) / 标准库 / 缺失包清单 |
| `z17s_smoke.js` | 轻量冒烟（3 个 require + 一张 320×96 画布，1 秒级），日常验证用 |
| `install-node-deps.sh` | **在设备上跑**：把那三个坏依赖换成可用版（幂等，含 jieba 兼容壳） |
| `jieba-shim/` | `jieba` 兼容壳的参考副本（转发到 `@node-rs/jieba`），与上面脚本保持同步 |

## 部署

```bash
scp z17s_depcheck.js z17s_depcheck.py z17s_smoke.js z17s:/tmp/
ssh z17s 'cp /tmp/z17s_depcheck.* /tmp/z17s_smoke.js /root/qinglong/data/scripts/'
```

装完在青龙面板 → 脚本管理里就能看到。

### 定时任务（2026-09-22 已建好，id=1）

| 项 | 值 |
|---|---|
| 名称 | `Z17S 依赖自检` |
| 命令 | `node z17s_depcheck.js` |
| cron | `0 30 9 * * *`（每天 09:30） |
| 状态 | 启用（`isDisabled=0`、`saved=1`） |
| **`log_name`** | **`z17s_depcheck`（必须显式给）** |
| 日志 | `/ql/data/log/z17s_depcheck/<时间戳>.log` |

手工建也行：面板「定时任务」→ 新建 → 名字随便、命令填 `node z17s_depcheck.js`、
cron 填 `0 30 9 * * *`。当时是走官方 openapi 建的（见 `docs/修复记录.md` §17.14，
含 `POST /open/crons` 的字段白名单 —— 它只收 name/command/schedule/labels/task_before/
task_after/work_dir/log_name/allow_multiple_instances/extra_schedules/sub_id，
传 `status`/`isDisabled`/`isPinned` 之类会被 Joi 拒掉）。

> ⚠️ **`log_name` 一定要显式填。** 不填的话青龙会自己推导 —— 推导规则是
> `getUniqPath(command, id)`：取命令的**第一个 token**（这里是 `node`）去扩展名再拼 `_<id>`，
> 于是日志会跑进 `/ql/data/log/node/` 而不是脚本名目录，日志就散开了。
> 白名单里既然有 `log_name`，就别让它推导。
> 找最新一次日志别写死路径：`find /ql/data/log -name '*.log' -newermt '-5 minutes'`。

## 三个坏依赖已全部换掉（2026-09-22 22:15 起 `PASS 32 / FAIL 0`）

```
run 3  22:15:11   32 项：PASS 32 / FAIL 0   耗时 17.0s   load 0.34 → 0.38   （换完依赖手跑）
run 4  22:31:41   32 项：PASS 32 / FAIL 0   脚本 17.2s / 全程 24s          （面板触发）
run 5  22:53:42   32 项：PASS 32 / FAIL 0   脚本 16.9s / 全程 24s          （openapi 触发）
```

三次都在设备启动后的健康窗口里，全程 `gs_close=0  RCU stall=0  ufshcd 错误=0`。
`run 4` / `run 5` 是真正走 `task.sh` 排程链路的，和 §17.13 手跑结果一致 ——
又一次旁证：脚本本身很轻（17 秒），是设备不健康才会被压垮。

| 原名/版本 | 问题 | 换成 | 说明 |
|---|---|---|---|
| `ts-md5@2.0.1` | **发布事故**：`exports.require` 指向 `dist/index.cjs.js`，可包又声明了 `"type":"module"`，而 `.js` 结尾在 `"type":"module"` 下一律按 ESM 解析 → CJS 代码报 `exports is not defined in ES module scope` | `ts-md5@1.3.1` | 纯 CJS（`main = dist/cjs/index.js`） |
| `jsdom@30.1.1` | 要求 Node ≥ 22，容器是 **20.20.2** | `jsdom@26.1.0` | `engines: >=18`，`new JSDOM(...)` 实测通过 |
| `jieba@1.0.0` | 坏包：`main` 指向的 `index.js` 根本不在发布的 tarball 里 | `@node-rs/jieba@1.10.4` + 一个叫 `jieba` 的壳 | 有 **linux-arm64-gnu 预编译**，手机上不编译任何东西 |

一键装/修（幂等）：

```bash
ssh z17s 'bash -s' < scripts/qinglong/install-node-deps.sh
```

关于 `jieba` 那个壳，两条踩过的坑：

1. **壳放在 `/ql/data/scripts/node_modules/jieba`，不放 pnpm 管的全局树。**
   试过把壳塞进全局 `node_modules`（有被 pnpm 当 extraneous 清掉的风险），
   也试过 `pnpm add -g file:...`（pnpm 8 直接判 `Already up to date`，**不肯落地**，
   只留一个断链）。放脚本目录反而最稳 —— 青龙跑脚本时 `require` 的解析基准
   就是脚本所在目录，`/ql/data/scripts/node_modules` 天然在搜索路径上。
2. **软链目标必须写容器内路径**（`/ql/data/...`）。在宿主机上按
   `/root/qinglong/data/...` 建链，进容器就是断链（同一个目录，两种视角）。

> 🔴 **别在面板里给这三个点"重装"**：面板按名字拉最新版 → `ts-md5`/`jsdom` 会退回坏版本、
> `jieba` 会装回那个坏包。面板的"已安装"判定本来就是 `pnpm ls -g | grep 名字`，
> 字符串包含就算，**别只信标签，`require` 一次才算数**。
> （已在 `Dependences` 表给这三行写了 `remark` 说明，`@node-rs/jieba` 也补了一行。）

## 复跑结果（2026-09-22 21:42 / 21:44，完整版 `z17s_depcheck.js` 连跑两次）

设备侧加固（`z17s-usbnet.sh` 快速路径、`z17s-logwatch.py` 新版、`z17s-ufs-quiet`）全部就位后，
在启动 20 分钟的健康窗口里把**完整版**连跑两次，都干净通过：

```
run 1  21:42:34   32 项：PASS 29 / FAIL 3   耗时 11.9s   load 0.72 → 峰值 0.77 → 0.53
run 2  21:44:22   32 项：PASS 29 / FAIL 3   耗时 11.1s   load 0.52 → 0.46
两次全程：gs_close=0  RCU stall=0  ufshcd 错误=0  dwc3 消息=0  串口心跳无一次中断
```

`g++ -O2` 真编译（`harmonic(1e6)=14.392727`）与 `make` 真构建都跑了且通过。
两次 FAIL 的都是同样 3 项真·坏依赖 —— **这 3 项已在 22:15 换掉，见上一节**。
对比首跑的 `PASS 27 / FAIL 5`，`prettytable` 与 中文字体 两项也确认转 PASS
（§17.12 冒烟 + 完整版双重确认）。

### 冒烟版复跑（2026-09-22 21:35，`z17s_smoke.js`）

零编译、不出网，1 秒级完成，用来日常验证那两处修复：

```
[PASS] prettytable      create(fields, rows) 渲染 7 行
[PASS] 中文字体             1 个：wqy-microhei.ttc
[PASS] canvas 出图        320x96 PNG=7636B 非白像素=6.16% font=Z17S-CJK
合计 3 项：PASS 3 / FAIL 0   耗时 1.06s   跑前 load=0.40 → 跑后 load=0.45
```

> 平时日常验证优先用 `z17s_smoke.js`（3 个 `require` + 一次 320×96 画布）；
> 需要完整清单（会真跑 `g++`/`make`/出网）再用 `z17s_depcheck.js`。

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

| 类别 | 项目 | 当时的结论 | 现状 |
|---|---|---|---|
| 脚本自身 | `prettytable` | 这版 `addRow()` 恒报 `Rows must be an array of arrays` → 必须 `create(fieldNames, rows)` | ✅ 已修（09-21 当晚） |
| 脚本自身 | 中文字体 | 容器无 CJK 字体 → 已放 `wqy-microhei.ttc` 到持久卷并 `registerFont` | ✅ 已修（09-21 当晚） |
| 🔴 真坏 | `ts-md5@2.0.1` | 纯 ESM（`"type":"module"`）→ CommonJS `require` 报 `exports is not defined in ES module scope` | ✅ 换成 `1.3.1`（09-22 22:15） |
| 🔴 真坏 | `jsdom@30.x` | 需要 Node ≥ 22，容器是 20.20.2 → `Iterator is not defined` | ✅ 换成 `26.1.0`（09-22 22:15） |
| 🔴 真坏 | `jieba` | 包损坏，`package.json` 的 `main` 指向不存在的 `index.js` | ✅ 换成 `@node-rs/jieba@1.10.4` + 壳（09-22 22:15） |

> 上表是**历史快照**（09-21 首跑）。这三个"真坏"现在全部换掉了，复跑 `PASS 32 / FAIL 0`，
> 详见上文「三个坏依赖已全部换掉」一节。
>
> 它们当时显示"已安装"，是因为面板的判定是 `pnpm ls -g | grep <名字>` —— 字符串包含就算。
> **别只信标签，`require` 一次才算数。**

## 关于"跑这个脚本会不会把设备跑挂"（2026-09-22 更正）

2026-09-21 22:51 跑这个脚本时设备**整机硬卡死（RCU stall）**，只能长按电源 15 秒
（详见 [`docs/修复记录.md`](../../docs/修复记录.md) §13）。当时因此写下了"这不是一个可以
随便反复刷的脚本"。**这条结论现在要降级** —— 09-22 连跑两次都正常（见上文），因为：

- 脚本本身很轻：**总共只跑 11 秒**，负载峰值 0.77。而那次卡死时是
  `load 0.27 → 3.72 单调爬升 + 3 次 RCU stall + ufshcd_config_vreg_load err=-110`，
  **完全不是一个量级**。
- 那次真正的推动力，是设备当时已处在"**开机 +45 秒重建 gadget 挂住 PID1**"的状态里
  （半死态，§17.4 / §17.10 / §17.11），脚本只是压上去的最后一根稻草。

所以现在的建议是：

- **设备健康时随便跑**，连跑两次都没问题。
- 🔴 **真正的禁忌**：别在设备**刚经历 gadget 重建**、或**已经进半死态**（SSH 建不起会话、
  串口不再吐心跳）时再去压它 —— 那时什么脚本都会成为最后一根稻草。
- 跑重 IO 时仍然建议：让它**写文件**而不是用 `ssh … | tail -n 大数字` 拉长串；出现
  `load` 单调爬升（串口心跳里有）就停手等它降下来。

> ⚠️ 也**不要**反过来把 09-22 这次"没卡死"全算到 `z17s-ufs-quiet` 头上：它实际只关掉了
> `power/control` 与 `auto_hibern8` 两个开关（§17.11.4），而 11 秒的短峰值可能压根没触发
> UFS 的 runtime 调压路径。要判定它有没有用，得跑更长的高 IO。
