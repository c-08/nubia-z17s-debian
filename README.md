# z17s-debian-ops

把一台 **努比亚 Z17S（NX595J / MSM8998）** 变成可长期运行的 Debian 13 小服务器 —— 这里放的是**让它真正能用起来**的那一层：USB 有线网络、容器运行时修复、Web 面板、以及一路踩出来的故障修复方案。

底层移植（内核 + rootfs）来自 [huanhuangyun/z17s-debian](https://github.com/huanhuangyun/z17s-debian)，本仓库不重复造轮子，只补上"跑起来之后"的那部分。

---

## 这台机器现在能干什么

| 能力 | 状态 | 说明 |
|---|---|---|
| **USB 有线网络** | ✅ 主力 | 手机通过 USB 变成一块 RNDIS 网卡（`192.168.137.2`），开机自启，PC 侧 ping 延迟 **0ms** |
| **USB 串口控制台** | ✅ | 同一根线提供 ttyGS0 控制台，root 自动登录；**系统卡死时唯一救命通道** |
| Docker / 容器 | ✅ | 需内核开启 `CONFIG_CGROUP_BPF`（见下文，原版缺这项） |
| 1Panel 面板 | ✅ | `http://192.168.137.2:28888/z17s_panel` |
| 青龙面板 | ✅ | `http://192.168.137.2:5700` |
| 蓝牙 | ✅ | 设备树硬编码的 NV 与 persist 一致，无需改动 |
| 音频 | ✅ | `card 0: Nubia-Z17S` 已注册 |
| Wi-Fi | ✅ **可用（10-29 修复）** | 能连 5GHz、硬件加密、下行实测 **15–18.5 MB/s**（10-29 复测；192 MB 持续 13.7 MB/s 零抖动），累计 200+ MB 不崩。之前"高传输就卡死"的真凶**不是加密**，而是 `ath10k` 的 in-order RX 路径把「A-MSDU 跨两条指示」当成致命错误（`rx_confused`）⇒ RX 环枯竭 ⇒ 固件饿死崩 ⇒ ADSP 崩 ⇒ **modem 一起崩**。补丁只改 `htt_rx.c` 一处：`-EAGAIN` 丢这一小段而不置 `rx_confused`。见 [docs/WiFi-A-MSDU修复.md](docs/WiFi-A-MSDU修复.md) |
| **蜂窝（手机卡）** | ✅ **可用（10-29 打通）** | **数据面已通，能真正上网**：下行 **2.85–3.0 Mbit/s**（= 这张卡的套餐限速，已打满）、`ping` 零丢包、DNS / HTTP / HTTPS 全通、**开机 172 秒全自动上线**（`TARGET=90`）。两个决定性修复：① **`insmod` 必须在 modem 注册之后**（早加载会让 modem 侧 GSI 通道不启动 ⇒ 假连接）；② **ep16 聚合旁路** —— IPA 硬件把下行多包聚合成一帧却只写第一个包的 QMAP 长度，`rmnet_map_ingress_handler()` 只 trim 到该长度就上送，**其余整段丢弃（下行只上送 38%）**，关掉聚合后 2.3 KB/s → 332–374 KB/s。见 [docs/蜂窝G5-数据面打通.md](docs/蜂窝G5-数据面打通.md) |
| **短信** | ✅ **可用（10-29 打通）** | 收、发、转发全通。QMI WMS（service 5）在，ModemManager 1.24 完整接管。已装 **DbusSmsForwardCPlus**（`dbussms.service`）：网页 + HTTP API 在 **1102** 端口，`GET /api?telnum=…&smstext=…` 即可发短信，收到短信实时转发到 **企业微信群机器人**（key 单独存 `/root/sms/webhook.conf`，600 权限，不进仓库）。转发失败会重试 3 次并落待补发队列，`z17s-sms-replay.timer` 每 5 min 自动补发 —— **刚开机没网时不丢消息**。**原版在 MM 1.24 上完全不可用**（modem 路径写死 `Modem/0`、match 规则同样写死、收发共用一条 D-Bus 连接会挂死），已修 3 个 bug。见 [docs/短信转发与发送.md](docs/短信转发与发送.md) |
| 摄像头 / NFC / 指纹 / 传感器 | ❓ | 未验证 |
| 显示 | ⚠️ | 下半屏重叠（上游已知缺陷） |
| **息屏运行** | ✅ **可用（10-29）** | `z17s-screen off` 关背光息屏、`on` 恢复，开机由 `z17s-screen.service` 自动执行。**只动背光，绝不用 `fb0/blank`** —— 本机 DPU 原子提交扛不住 `blank=4`，写下去立刻报 `vblank timeout` / `commit done -110`。见 [docs/息屏与背光.md](docs/息屏与背光.md) |

**结论：这是一台"USB 为主，蜂窝 + Wi-Fi 都可用"的机器。** 日常网络走 USB（0ms 延迟、稳定），
出门 / 没 PC 时切蜂窝（2.85–3.0 Mbit/s，卡限速 3M，开机 172 秒自动上线），同一 AP 下走 Wi-Fi（15–18.5 MB/s）。
手机卡还能收发短信（1102 端口网页 / API + 实时转发）。
**两个无线通路都踩过"看起来连着、其实已经死了"的坑**，判活请看计数器而不是链路状态。

> 🔴 **刷机唯一通道 = TWRP（音量上+电源）+ `adb push` + `dd`**。
> 本机 fastboot **不能刷分区**（实测 `flash`/`download` 全是 `unknown command`，且 `reboot recovery` 回 `OKAY` 是假信号）。

---

## 📖 文档导航

| 我想… | 看这里 |
|---|---|
| **先看个全景** —— 项目地址、设备信息、能力清单、两条无线通路各自踩过什么坑 | [docs/项目总览.md](docs/项目总览.md) |
| **第一次上手** —— 连上设备、日常操作、命令速查 | [docs/使用说明.md](docs/使用说明.md) |
| **出问题了** —— 17 个故障的现象 / 判据 / 根因 / 修法 + 诊断方法论 | [docs/修复记录.md](docs/修复记录.md) |
| **备份与恢复** —— 四层备份策略、恢复步骤、哪些操作会变砖 | [docs/备份与恢复.md](docs/备份与恢复.md) |
| **🔴 要动 boot 镜像** —— 签名规则、本地验签、三重闸门、黑屏后三条恢复通道 | [docs/boot镜像签名与恢复.md](docs/boot镜像签名与恢复.md) |
| **卡死时怎么留证据** —— 三层日志与取证体系 | [docs/日志与取证.md](docs/日志与取证.md) |
| **硬件到底能用什么** —— Wi-Fi / 蜂窝 / 蓝牙 / 音频的定量结论 | [docs/硬件现状.md](docs/硬件现状.md) |
| **Wi-Fi / 手机卡还有没有办法** —— 可选方案的评审、三条零成本前置实验、成本与风险重估 | [docs/WiFi与蜂窝修复方案.md](docs/WiFi与蜂窝修复方案.md) |
| **⭐⭐ Wi-Fi 到底卡在哪 / 怎么修的** —— A-MSDU 跨指示 + in-order RX 误判，代码路径 + 因果闭环 + 踩过的坑 | [docs/WiFi-A-MSDU修复.md](docs/WiFi-A-MSDU修复.md) |
| **Wi-Fi 历史实验** —— W1（软解）上机实测全过程。**方向本身是错的，结论已更正** | [docs/W1实验结果.md](docs/W1实验结果.md) |
| **⭐ 手机卡到底能不能救** —— 可行性评估：证据链、三道门、逐日计划、风险止损 | [docs/蜂窝可行性评估.md](docs/蜂窝可行性评估.md) |
| **⭐ 手机卡实测到哪一步了** —— G1/G2 上机全过程：IPA 满分通过、modem 拉回 online、LTE 注册成功、G3 卡点与死前现场 | [docs/蜂窝G1G2实测.md](docs/蜂窝G1G2实测.md) |
| **⭐⭐ 手机卡最新进展（G3 已通）** —— 单进程 libqmi 三步连做拿到联通真实 IP；`ip link set rmnet_ipa0 up` 硬挂起的零日志尸检与源码级根因；下一步仪器化热换方案 | [docs/蜂窝G3与IPA数据面.md](docs/蜂窝G3与IPA数据面.md) |
| **⭐⭐⭐ 手机卡已经能上网了（10-29）** —— 数据面打通全过程：`insmod` 时序、**ep16 聚合导致下行只上送 38%** 的定量证据与修复、332–374 KB/s 实测、开机自动上线、SIM 卡兼容性结论、全套红线 | [docs/蜂窝G5-数据面打通.md](docs/蜂窝G5-数据面打通.md) |
| **⭐ 短信收发与转发（10-29）** —— 收 / 发 / 转发全通，1102 端口 API，原版 3 个 bug 的定位与修法 | [docs/短信转发与发送.md](docs/短信转发与发送.md) |
| **⭐ 息屏运行（10-29）** —— 关背光而不是 blank；DPU commit 超时的实测证据与开关脚本 | [docs/息屏与背光.md](docs/息屏与背光.md) |
| **重编内核** —— 必改的配置项、编译产物校验 | [kernel/README.md](kernel/README.md) |

> 全部文档为中文，按"**症状 → 判据 → 根因 → 修法**"组织，每个结论都带实测数据。

---

## 为什么需要这个仓库

上游的移植包能让你开机进 Debian，但会撞上四个**不看文档绝对想不到**的坑，每一个都能耗掉你一整天：

1. **容器全都起不来** —— 内核缺 `CONFIG_CGROUP_BPF`，`runc` 报 `bpf_prog_query(BPF_CGROUP_DEVICE) failed: invalid argument`。**任何镜像都起不来**（连 `alpine` 都不行），跟容器配置无关。→ [修复记录 §1](docs/修复记录.md)

2. **开机随机卡死几十分钟** —— `console=ttyGS0` 是 USB 串口，PC 侧没人读时 tty 缓冲写满，systemd PID1 恰好卡在 `write()` 里，**整个开机停摆，连 90 秒超时都不触发**。急救法：打开串口读一下，当场解卡。→ [修复记录 §3](docs/修复记录.md)

3. **USB 网卡每次开机都不受管** —— NetworkManager 上游规则 `85-nm-unmanaged.rules` 对**所有 `DEVTYPE=gadget` 的网卡**置 `NM_UNMANAGED=1`，所以配置写得再对也不会自动激活，DNS 全废。→ [修复记录 §4](docs/修复记录.md)

4. **`g_multi` 永久不可用** —— 本内核树的 `legacy/multi.c` 无条件调用 `can_support_ecm()`，而 `gadget_is_altset_supported()` 恒为 false，报 `failed to start g_multi: -22`。只能用 configfs 手工搭复合 gadget。→ [修复记录 §2](docs/修复记录.md)

---

## 目录结构

```
.
├── device/                     要部署到手机上的文件（保留了目标绝对路径）
│   ├── etc/systemd/system/     z17s-* 服务与定时器
│   ├── etc/systemd/system.conf.d/10-z17s-quiet.conf      ← 修复"开机卡死"
│   ├── etc/udev/rules.d/99-z17s-usb0-managed.rules       ← 修复"usb0 不受管"
│   ├── etc/NetworkManager/system-connections/z17s-usb0.nmconnection
│   ├── etc/modprobe.d/10-z17s-unsafe-modules.conf        ← 黑名单 ipa.ko
│   ├── etc/sysctl.d/10-z17s-console.conf                 ← 串口日志降噪
│   └── usr/local/sbin/         z17s-* 脚本
│       ├── z17s-logwatch.py    ⭐ 日志守护：0.25s 落盘 + 每 10s 串口心跳
│       └── z17s-screendump     远程读手机屏幕内容（/dev/vcsa1，不用拍照）
├── host/                       PC（宿主机）侧脚本
│   ├── pull-chunks.sh          ⭐ **推荐**：分块 + 限速拉取数据归档（可续传、失败即停）
│   ├── net-throttle.py         ⭐ PC 侧管道限速器（纯 stdlib；靠 TCP 反压让设备端 tar 也慢下来）
│   ├── pull-rootfs.sh          一把拉全盘（**实测 966 MB 就会把设备跑死**，默认别用）
│   └── windows/
│       ├── setup-rndis.ps1/.cmd    ICS 透明 NAT 一键配置（自提权）
│       ├── z17s-proxy.py           ／降级方案：用户态 HTTP+DNS 代理
│       ├── start-proxy.cmd
│       ├── pull-backup.cmd         拉取 T1 关键分区备份
│       ├── pull-rootfs.cmd         拉取整盘（双击版，自动找 Git Bash）
│       ├── env.cmd / env.ps1       终端环境自检（PATH / adb）
│       └── serial/                 串口控制台工具
├── scripts/
│   ├── install-on-device.sh    把 device/ 一键部署到手机
│   ├── install-logwatch.sh     部署三层日志与取证体系（幂等，可重复跑）
│   ├── backup-system.sh        设备侧备份 T1（boot + persist + 配置 + 包列表，20 秒）
│   ├── flash-boot-cgroupbpf.sh 安全刷 boot 分区（备份 → 写入 → 回读校验 → 装模块）
│   ├── cellular/               手机卡数据通路工具（见 docs/蜂窝G5-数据面打通.md）
│       ├── qmi_up.py           ⭐ 单进程 libqmi：DPM-open + WDS-bind + WDS-start 一次连通
│       ├── qrtr_services.py    枚举 modem 上全部 QRTR 服务（只读）
│       ├── g3_linkup.sh        ⚠️ 危险：`ip link set rmnet_ipa0 up` 单变量实验（每步 sync + kmsg 标记）
│       └── probe_qrtr.py       QRTR 设备打开方式的探针（GI 绑定避坑用）
│   └── wifi/                   Wi-Fi A-MSDU 修复（见 docs/WiFi-A-MSDU修复.md）
│       ├── z17s-ath10k-eagain.patch  ⭐ 唯一改动：htt_rx.c 里 -EAGAIN 不再置 rx_confused
│       ├── build-ath10k-eagain.sh    编译脚本（WSL + aarch64-linux-gnu-）
│       ├── z17s-ath10k-ko.service    ⭐ 开机复制单元（/lib/modules 每次开机会被还原）
│       └── 99-z17s-ath10k.conf       硬件加密，**不要**写 cryptmode=1
│   └── sms/                    短信收发与转发（见 docs/短信转发与发送.md）
│       ├── install-dbussms.sh        一键装：依赖 → 源码 → 补丁 → 编译 → 部署 → 自启
│       ├── z17s-dbussms.patch        ⭐ 修原版 3 个 bug（modem 路径 / match 规则 / 共享连接）
│       ├── dbussms.service           systemd 单元（-fS --sendsmsapi=enable）
│       ├── config.txt                配置模板（apiPort = 1102）
│       ├── forward.sh                Shell 转发钩子（落盘 + 调 wecom.py）
│       ├── wecom.py                  ⭐ 企业微信群机器人推送（json.dumps 构造，中文安全）
│       └── webhook.conf.example      机器人 key 模板（真 key 只存设备上，600）
│   └── screen/                 息屏与背光（见 docs/息屏与背光.md）
│       ├── z17s-screen               ⭐ on/off/status（只动背光，不碰 fb0/blank）
│       └── z17s-screen.service       开机自动息屏（sleep 8 等显示栈就绪）
├── kernel/
│   ├── README.md               内核重编要点（必改项 + 产物校验）
│   ├── build-*.sh              上游构建脚本
│   └── config-6.12.95-running.txt   设备实跑内核的完整 .config（改动实证）
└── docs/
    ├── 项目总览.md             ⭐ 一页看完：项目地址 + 设备信息 + Wi-Fi/蜂窝为什么修不好
    ├── 蜂窝可行性评估.md       ⭐ 手机卡上网：从"无解"改判为"值得一试"（证据 + 三道门 + 逐日计划）
    ├── 蜂窝G1G2实测.md         ⭐ 手机卡上机实测：IPA 满分通过、modem 拉回 online、LTE 注册成功、G3 卡点
    ├── 蜂窝G3与IPA数据面.md    ⭐⭐ G3 通关（单进程 libqmi 拿到联通真实 IP）+ `rmnet_ipa0 up` 硬挂起尸检与根因
    ├── 蜂窝G5-数据面打通.md    ⭐⭐⭐ 10-29 数据面打通，能真正上网（3 Mbit/s 套餐上限、开机自动）+ ep16 聚合根因
    ├── WiFi-A-MSDU修复.md      ⭐⭐⭐ 10-29 Wi-Fi 修好了：A-MSDU 跨指示 + in-order RX 误判（代码路径 + 因果闭环）
    ├── boot镜像签名与恢复.md   🔴 改 boot 前必读：改了就必须重签，否则黑屏；含本地验签与恢复通道
    ├── W1实验结果.md           Wi-Fi 软解上机实测（⚠️ 方向错了，顶部有更正横幅，§4 实验清单作废）
    ├── WiFi与蜂窝修复方案.md   Wi-Fi 软解 / 蜂窝绕行的方案评审与实施清单（含"只换 .ko，不刷 boot"）
    ├── 使用说明.md             日常怎么用、怎么连、命令速查
    ├── 修复记录.md             17 个故障的现象/判据/根因/修法 + 诊断方法论
    ├── 日志与取证.md           三层日志体系：卡死时怎么留下最后一条证据
    ├── 备份与恢复.md           四层备份策略与恢复步骤（含"RNDIS 不能搬整盘"的实测结论）
    └── 硬件现状.md             Wi-Fi / 蜂窝 / 蓝牙 / 音频的定性与结论
```

---

## ⚠️ 一条必须先知道的硬件级限制

**不要把上 GB 的数据压到 USB/RNDIS 上搬。** 实测：

| 实验 | 通道 | 结果 |
|---|---|---|
| 设备端读满 3.4 GB 磁盘（不走网络） | 纯磁盘 | ✅ 正常 |
| 同一份数据经 SSH/RNDIS 传出 | RNDIS | ❌ **传出 966 MB 时整机硬卡死**（RCU stall，需断电重启） |

触发条件是「大量存储读」+「USB 持续满载」的叠加。所以：

- 搬数据请用 `host/pull-chunks.sh`（**分块 + 限速**，最要紧的排前面，失败即停）
- 整盘镜像走 **TWRP + adb**
- 关键分区只有几十 MB（`host/windows/pull-backup.cmd`），走 RNDIS 完全没问题

---

## 快速开始

### 前置条件

- 手机已刷入上游的 Debian 13 移植包，能开机、能用串口进系统
- PC 有 Windows 与一根数据线

### 第 1 步：让 USB 网络起来

```bash
# 在手机上（串口或任意终端）执行
git clone https://github.com/c-08/nubia-z17s-debian.git /root/z17s-debian-ops
cd /root/z17s-debian-ops
sudo bash scripts/install-on-device.sh
```

脚本会：复制所有配置到正确路径 → 重载 udev / NM → 启用 `z17s-usbnet.timer` → 做一次自检。

### 第 2 步：PC 侧给手机共享网络

双击 `host/windows/setup-rndis.cmd`（会弹 UAC 提权）。它配置 Windows ICS，让手机能出公网。

> ✅ **每台 PC 只需要配一次。** 真正生效的是持久化的 `192.168.137.1`（宿主侧 ICS 网卡）
> 加一条 WinNAT（`z17s-usb`），两者都不随 USB 重新枚举消失 —— 判据是 `Get-NetNat` 里还列着它。
> 只有当「手机能 ping 通 PC、却出不了公网」时才需要重跑，**先查 `Get-NetNat` 再动手**。
> Windows 显示「未识别的网络」是正常现象，不是故障。

### 第 3 步：登录

```bash
ssh z17s          # 需要先在 ~/.ssh/config 里配别名，或者：
ssh -i <你的密钥> root@192.168.137.2
```

---

## 内核要求

上游默认的 `z17s_defconfig` 有两个必须改的地方，否则会分别导致"容器全崩"和"卡死在 UFS 等待循环"：

| 配置项 | 改成 | 不改的后果 |
|---|---|---|
| `CONFIG_CGROUP_BPF` | `=y` | 所有容器起不来（`runc` 报 BPF 错误） |
| `CONFIG_RPMSG_QCOM_SMD` | `=y` | 它是 `depends on` 的上游，改成 `=m` 会把 UFS 的整套 supplier 驱动压成模块 → **开机卡死在 UFS 等待循环** |

详细步骤与校验方法见 [kernel/README.md](kernel/README.md)。

---

## 已知问题

Wi-Fi 与蜂窝**都已打通**（蜂窝 2026-10-29 上午，Wi-Fi 2026-10-29 中午）；关机语义已定性，别再重复投入。
（蜂窝见 [docs/蜂窝G5-数据面打通.md](docs/蜂窝G5-数据面打通.md)，Wi-Fi 见
[docs/WiFi-A-MSDU修复.md](docs/WiFi-A-MSDU修复.md)）。完整分析见 [docs/项目总览.md](docs/项目总览.md)。

- ~~**Wi-Fi 每次开机活不过约 7 分钟**~~ → **✅ 2026-10-29 已修复，能正常大流量传输**。
  历史误判（已推翻）：曾认为根因是 `mac80211.ko` 的 `key_hw_accel` 强制硬件解密、以及"固件不肯发软解帧"。
  **实测都不成立** —— 硬件加密（`hwcrypto 1`）本身完全正常，能连、能传、ping 28ms。
  真凶在 `drivers/net/wireless/ath/ath10k/htt_rx.c`：WCN3990/HL1.0 固件会把一个 A-MSDU 拆到
  **两条** in-order RX 指示里，`ath10k_htt_rx_extract_amsdu()` 找不到 `LAST_MSDU` 标志就返回 `-EAGAIN`，
  而 `ath10k_htt_rx_in_ord_ind()` 把它当致命错误置 `rx_confused = true` —— 之后**每一条** RX 指示
  在函数第一行就被 `return -EIO` 打回，NAPI 空转、RX 环不再补 buffer，固件约 160 秒后 assert，
  **连带把 ADSP 和 modem 一起打死**（WCN3990 固件跑在 ADSP 上）。
  这就是"链路显示 connected / -40dBm / 866Mbit，但 `rx_packets` 不动"的原因。
  修法：把 `-EAGAIN` 从 `fallthrough` 里拆出来，只 `__skb_queue_purge()` 这一小段并 `return 0`，
  不置 `rx_confused`。实测同一次故障（每次 3 个 MSDU）照常发生，丢 5 段之后 31 MB 照跑。
  详见 [docs/WiFi-A-MSDU修复.md](docs/WiFi-A-MSDU修复.md)。
- ~~**蜂窝（手机卡）上不了网**~~ → **✅ 2026-10-29 已解决，能真正上网**（下行 2.85–3.0 Mbit/s，已是套餐上限；开机自动上线）。
  历史脉络：MSM8998 的 modem 数据**必须经过 IPA 加速器**，早期 `ipa.ko` 一加载就把本机重启
  （`# IPA resets this NX595J with the current 6.12 device tree`），因此进了黑名单；09-25 改判"值得一试"
  （主线原生支持 `qcom,msm8998-ipa`、设备树接线完整、Android 下成功过）；09-30 **G3 通关**
  （单进程 libqmi 拿到联通真实 IP）；10-29 **G5 打通数据面**。
  ⇒ 卡住的从来不是"主线不支持蜂窝"，而是两个很具体的坑：**`insmod` 时机** 和 **ep16 聚合**。
  详见 [docs/蜂窝G5-数据面打通.md](docs/蜂窝G5-数据面打通.md)。
- **关机"慢"的真相**：一次干净关机其实只要 **约 11 秒**，其中 **10.7 秒在等 `docker.service` 停** ——
  关机前 `systemctl stop docker` 能压到 1~2 秒。另外按电源键 **点一下就该松手**
  （logind 实测 `HandlePowerKeyLongPress=ignore`，"按多久"软件层完全不管；
  按住等于白送时间给 PMIC 的 10~12 秒长按复位逻辑，会出现"关完 3 秒又自己开机"）。

---

## 致谢与许可

- 底层移植：[huanhuangyun/z17s-debian](https://github.com/huanhuangyun/z17s-debian)
- 本仓库新增的修复与脚本：MIT（见 [LICENSE](LICENSE)）
- `device/etc/NetworkManager/system-connections/*.nmconnection` 中的 Wi-Fi 连接文件**已从仓库排除**（含 WPA 密钥），请自行创建。

---

## 免责声明

本仓库涉及**直接写入手机分区**的操作。刷机有变砖风险，请务必备份（见 [docs/备份与恢复.md](docs/备份与恢复.md)）后再动手。作者不对任何数据丢失或设备损坏负责。
