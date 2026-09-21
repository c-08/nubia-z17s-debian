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
| Wi-Fi | ⚠️ 不稳定 | 能连上，但**每次开机约 7 分钟后固件崩溃**，详见 [docs/硬件现状.md](docs/硬件现状.md) |
| 蜂窝（手机卡） | ❌ | `ipa.ko` 会触发 boot loop 已被列入黑名单，本移植设计上就是"仅 Wi-Fi" |
| 摄像头 / NFC / 指纹 / 传感器 | ❓ | 未验证 |
| 显示 | ⚠️ | 下半屏重叠（上游已知缺陷） |

**结论：这是一台"USB 连着用"的机器。** 网络走 USB，屏幕当辅助，服务的稳定性不依赖 Wi-Fi。

---

## 📖 文档导航

| 我想… | 看这里 |
|---|---|
| **第一次上手** —— 连上设备、日常操作、命令速查 | [docs/使用说明.md](docs/使用说明.md) |
| **出问题了** —— 14 个故障的现象 / 判据 / 根因 / 修法 + 诊断方法论 | [docs/修复记录.md](docs/修复记录.md) |
| **备份与恢复** —— 四层备份策略、恢复步骤、哪些操作会变砖 | [docs/备份与恢复.md](docs/备份与恢复.md) |
| **卡死时怎么留证据** —— 三层日志与取证体系 | [docs/日志与取证.md](docs/日志与取证.md) |
| **硬件到底能用什么** —— Wi-Fi / 蜂窝 / 蓝牙 / 音频的定量结论 | [docs/硬件现状.md](docs/硬件现状.md) |
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
│   └── flash-boot-cgroupbpf.sh 安全刷 boot 分区（备份 → 写入 → 回读校验 → 装模块）
├── kernel/
│   ├── README.md               内核重编要点（必改项 + 产物校验）
│   ├── build-*.sh              上游构建脚本
│   └── config-6.12.95-running.txt   设备实跑内核的完整 .config（改动实证）
└── docs/
    ├── 使用说明.md             日常怎么用、怎么连、命令速查
    ├── 修复记录.md             14 个故障的现象/判据/根因/修法 + 诊断方法论
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
git clone https://github.com/<you>/z17s-debian-ops.git /root/z17s-debian-ops
cd /root/z17s-debian-ops
sudo bash scripts/install-on-device.sh
```

脚本会：复制所有配置到正确路径 → 重载 udev / NM → 启用 `z17s-usbnet.timer` → 做一次自检。

### 第 2 步：PC 侧给手机共享网络

双击 `host/windows/setup-rndis.cmd`（会弹 UAC 提权）。它配置 Windows ICS，让手机能出公网。

> ⚠️ **手机每次重启后都要重跑一次** —— Windows 的 ICS 绑定记录会随 USB 重新枚举而消失，症状是「手机能 ping 通 PC，但出不了公网」。这不是手机的问题。

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

- **Wi-Fi 会在开机约 7 分钟后崩溃**，且崩溃后只能重启恢复（上游主线内核同样存在，非本移植引入）。详见 [docs/硬件现状.md](docs/硬件现状.md)。
- **蜂窝不可用**，`ipa.ko` 已进黑名单 —— 加载它会 boot loop。
- **关机很慢**（实测十几分钟），且关机中期会出现"能 ping 通但所有 TCP 端口连不上"，别误判为死机。

---

## 致谢与许可

- 底层移植：[huanhuangyun/z17s-debian](https://github.com/huanhuangyun/z17s-debian)
- 本仓库新增的修复与脚本：MIT（见 [LICENSE](LICENSE)）
- `device/etc/NetworkManager/system-connections/*.nmconnection` 中的 Wi-Fi 连接文件**已从仓库排除**（含 WPA 密钥），请自行创建。

---

## 免责声明

本仓库涉及**直接写入手机分区**的操作。刷机有变砖风险，请务必备份（见 [docs/备份与恢复.md](docs/备份与恢复.md)）后再动手。作者不对任何数据丢失或设备损坏负责。
