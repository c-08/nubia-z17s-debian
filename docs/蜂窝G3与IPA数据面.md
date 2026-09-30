# 蜂窝 G3 与 IPA 数据面（09-30 实测）

> 前篇：[`蜂窝G1G2实测.md`](蜂窝G1G2实测.md)（G1 IPA 加载通过 / G2 modem 侧全通）
> 配置：NX595J，Debian 13 arm64 + 主线 6.12.95，`ipa.ko` 从 `/root/` `insmod`

---

## 0 一句话结论

| 层 | 结果 |
|---|---|
| **G1** IPA 驱动加载 | ✅ 通过（09-26） |
| **G2** modem 侧（SIM/射频/注册） | ✅ 通过（09-26，中国联通 460-01） |
| **G3** QMI 建数据传输通道 | ✅ **通过（09-30）** —— 拿到真实运营商 IP |
| **G4** 数据面（网卡 up + ping 通） | ❌ **`ip link set rmnet_ipa0 up` 瞬时冻死整机**，零日志，看门狗约 35s 后复位 |

**里程碑**：09-26 把 G3 判成 `InvalidOperation(70)` 时归因错了。真正的障碍不是参数、不是 DPM，而是
**qmicli 无法在同一个 QMI 连接里连做 DPM-open + WDS-bind + WDS-start 三步**。用单进程 libqmi 客户端
（Python + GI）解决后，`start_network` 一次就过。

---

## 1 G3 通关：单进程 QMI 客户端

### 1.1 为什么必须单进程

| 做法 | 结果 |
|---|---|
| `qmicli --dpm-open-port` 然后 `--wds-bind-mux-data-port` 然后 `--wds-start-network`（三次进程） | `start_network` → **QMI error(70) InvalidOperation**；且 `bind`+`start` 在同一个 qmicli 里会报 "too many WDS actions" |
| 复用 CID（`--client-cid`）跨进程 | `Unknown client 1` |
| `qmi-proxy` | CID 保住了，但**代理不保底层 QRTR 端口** → modem 回包打到已死的端口 → `Operation was cancelled` / `Transaction timed out` |
| **单进程 libqmi（Python GI）** | ✅ 三步共用同一个 `QmiDevice` + 同一条连接 → 直接成功 |

`bind_mux_data_port` 是**绑定在 client 上的**，client 一换就白干 —— 这是关键。

### 1.2 脚本

`scripts/cellular/qmi_up.py`（部署到设备 `/root/qmi_up.py`）

```
QRTR bus → node 0 → QmiDevice.open(NONE)
  [2] DPM  allocate_client + open_port(hw: EMBEDDED, iface=1, rx=16, tx=3)
  [3] WDS  allocate_client + bind_mux_data_port(mux_id=0, EMBEDDED, iface=1)
  [4] WDS  start_network(apn=3gnet, ipv4)
  [5] WDS  get_current_settings  → IP / 网关 / DNS / MTU
  [6] hold N 秒（进程一死，CID 释放，呼叫即被 modem 拆掉）
```

用法：`python3 /root/qmi_up.py [apn] [tx] [rx] [iface] [mux] [hold_sec]`
默认 `3gnet 3 16 1 0 5`。

### 1.3 实测输出（09-30）

```
[2] DPM open_port OK
[3] bind_mux_data_port OK
========== [4] START_NETWORK OK ==========
        wds.start.packet_data_handle = 1819485840
[5] get_current_settings OK
        apn_name                 = '3gnet'
        ip_family                = IPV4
        ipv4_address             = 175522073       → 10.118.65.25
        ipv4_gateway_address     = 175522074       → 10.118.65.26
        ipv4_gateway_subnet_mask = 4294967292      → 255.255.255.252  (/30)
        primary_ipv4_dns_address = 2018529360      → 120.80.80.80
        secondary_ipv4_dns ...   = 3708115032      → 221.5.88.88
        mtu                      = 1500
        pdp_type                 = IPV4_OR_IPV6
        profile_id               = 3GPP idx 7  名称 'modem_def_prof'
```

DNS 是**中国联通**的（120.80.80.80 / 221.5.88.88）⇒ 分配是真的、不是本地伪造。

**注意**：`get_ipv4_*` 返回的是 `guint32`，**不是**点分十进制；换算见下。

```python
def ip4(v):  # v = 175522073
    return "%d.%d.%d.%d" % ((v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff)
```

### 1.4 GI 绑定的坑（一次问清楚，别再踩）

| 坑 | 正解 |
|---|---|
| `Qmi.Device.new(Gio.File.new_for_uri("qrtr://0"))` + `open()` | ❌ `couldn't detect transport type of port` / `No such file or directory`。**QRTR 必须走 node**：`Qrtr.Bus.new(ms, None, cb, None)` → `bus.new_finish(res)` → `bus.get_node(0)` → `Qmi.Device.new_from_node(node, ...)` |
| `Qrtr.Bus.new(...)` 第一个参数 | 是 **`lookup_timeout_ms`（int）**，不是 cancellable |
| 回调签名 | 一律 **3 参** `(src, res, user_data)` |
| `Qrtr.Node.lookup_service()` | **参数是 port，返回 service**！`lookup_port(service)→port` 才是反过来的。所以 `lookup_service(47)` 返回 `-1` **不代表 DPM 不存在** |
| `Qmi.ClientAllocateFlags` | 不存在 → `allocate_client(service, 0, timeout, ...)` 直接传 `0` |
| `cli.get_version()` | 要 3 个 out 参数 → 别调 |
| DPM 硬件端口元素 | GI 里是**纯 struct，没有 setter**。字段直写：`endpoint_type` / `interface_number` / `rx_endpoint_number` / `tx_endpoint_number` |
| `set_requested_settings()` | 需要 `Qmi.WdsRequestedSettings(mask)`；**掩码 0 = 视为未设置** → 报 "Missing mandatory TLV"。用全位掩码 `0x7ffff` |

查服务表：`scripts/cellular/qrtr_services.py`（实测 node 0 上 40 个服务，WDS=1/port 62，DPM=47/port 61）。

---

## 2 G4 失败：`ip link set rmnet_ipa0 up` 瞬时冻死整机

### 2.1 现象（可复现 2/2）

| 时间 | 事件 |
|---|---|
| 23:54:43 | 串口最后心跳 `uptime=2615 load=0.22`（一切正常） |
| 23:54:48 | `g3_linkup.sh` 启动，写 `STEP1  ip link set rmnet_ipa0 up` |
| ~23:54:49 | **进程冻在 `ip link` 内部**（`g3-linkup.log` 里这一行之后**没有 `rc=` 行**） |
| 23:55:09 | PC 侧串口 `port lost (COM15)` |
| ~23:55:20 | 看门狗复位；设备自己回来 |
| 回来时 | `boot_id` `a732bb2a` → `b2b56dfc`（确属复位）；`ipa` 不在（默认安全态 ✓） |

### 2.2 决定性证据：**零内核输出**

串口在死前到断口之间 **没有 panic / oops / call trace / SMMU fault / hung task —— 一行都没有**。
同时 `qmi_up.py` 的 hold 计数（57/600）也被冻住。

⇒ **不是内核崩溃，是 CPU 被同步总线停顿冻死**：访问了一个没上电/没开时钟的寄存器块，
AXI/AHB **永不应答**，CPU 取指都做不到，连 printk 都发不出去，最后靠硬件看门狗复位。
这与 09-26 那次的死法完全一致（当时误判为"复位 or 卡死未定性"，**现在定性为硬挂起**）。

### 2.3 根因定位（源码级）

`drivers/net/ipa/ipa_modem.c`：

```c
static int ipa_open(struct net_device *netdev)
{
	ret = pm_runtime_get_sync(dev);       /* ← 冻结点在此调用树内 */
	if (ret < 0) goto err_power_put;
	ret = ipa_endpoint_enable_one(priv->tx);   /* AP_MODEM_TX = 3 */
	if (ret) goto err_power_put;
	ret = ipa_endpoint_enable_one(priv->rx);   /* AP_MODEM_RX = 16 */
	netif_start_queue(netdev);
	pm_runtime_mark_last_busy(dev);
	(void)pm_runtime_put_autosuspend(dev);
}
```

`drivers/net/ipa/ipa_power.c`：

```c
static int ipa_runtime_resume(struct device *dev)
{
	ret = ipa_power_enable(ipa);          /* icc_bulk_enable + clk_prepare_enable("core") */
	if (WARN_ON(ret < 0)) return ret;     /* ← 若失败会打 WARN，实测没打 ⇒ 这步"成功"了 */
	if (ipa->setup_complete) {            /* 本机 true（probe 时 modem 已把 IPA 拉起来） */
		gsi_resume(&ipa->gsi);            /* 只是 enable_irq()，不碰寄存器 → 已排除 */
		ipa_endpoint_resume(ipa);         /* ← 真凶候选 */
	}
}
```

`ipa_endpoint_resume()` → `ipa_endpoint_resume_one(AP_COMMAND_TX)` / `(AP_LAN_RX)`：
`ipa_endpoint_program_suspend(endpoint, false)` + **`gsi_channel_resume()`**（写 IPA/GSI 寄存器）。

**关键对比**：probe 时 `setup_complete == false`，所以 `ipa_runtime_resume` **只做 `ipa_power_enable`**，
`ipa_config()` 写寄存器是**成功的**；而 `ipa_open` 这次 `setup_complete == true`，**多了
`ipa_endpoint_resume()` / `ipa_endpoint_enable_one()` 这两类寄存器写**。冻结就发生在这个增量里。

### 2.4 已排除 / 仍未排除

| 项 | 状态 |
|---|---|
| `gsi_resume()` | ✅ 已排除（只有 `enable_irq()`） |
| `pm_runtime_get_sync` 返回负值提前退出 | ✅ 不是（那样会安全返回，不会死） |
| ICC / `sync_state()` 归属 | ⚠️ 存疑：dmesg 有 5 条 `qnoc-msm8998 N.interconnect: sync_state() pending due to 1e40000.ipa`（这些是 47.58s **加载 ipa 之前**打的） |
| DT 缺 `power-domains` | ⚠️ **确认缺失**：`genpd` 列表里根本没有 ipa_gdsc，IPA 节点也没有 `power-domains` |
| `gcc-msm8998.c` 里的 IPA 资源 | ⚠️ 只有一个 `GCC_IPA_BCR`（block reset，0x89000），**没有任何 IPA 时钟**；主线的 IPA `core` 时钟是 `<&rpmcc RPM_SMD_IPA_CLK>` |
| `ipa_clk` | 加载后已被 `1e40000.ipa` 占用（`con_id=core`），enable_cnt=0 表示当前挂起中 —— **正常** |
| `ipa_a_clk` | ⚠️ **deviceless / no_connection_id** —— 没有任何设备认领（疑似 IPA AXI 时钟） |
| probe 尾部的 `Runtime PM usage count underflow!` | ⚠️ **未定性**，但一定代表 PM 记账有偏差（`pm_runtime` 计数被多减了一次） |

### 2.5 基线快照（`insmod /root/ipa.ko` 之后、不动网卡）

```
ipa.ko 346712 bytes; insmod OK
[ 229.263762] ipa 1e40000.ipa: Adding to iommu group 4
[ 229.268293] ipa 1e40000.ipa: IPA driver initialized
[ 229.301373] ipa 1e40000.ipa: IPA driver setup completed successfully
[ 229.308698] ipa 1e40000.ipa: Runtime PM usage count underflow!

/sys/class/net/rmnet_ipa0/device/power/{runtime_status,runtime_usage,control} = suspended / 0 / auto
autosuspend_delay_ms = 500
```
**推理**：`Runtime PM usage count underflow!` 打在 `setup completed successfully` **之后**，
就是 probe 末尾那句 `pm_runtime_put_autosuspend()`（`ipa_main.c:915`）打的 —— 说明
**它的 get 被别的路径"吃掉"了**（最可能是 `ipa_smp2p` 的 setup-ready 中断路径自己 get+put 了一轮，
而 `ipa_setup()` 又插在 probe 的 get 窗口里）。计数被记账错，是"上了电但以为自己没上电"
这类故障的经典温床。

---

## 3 下一步计划（按性价比排序）

### S1（推荐）仪器化 `ipa.ko` + 活系统热换 —— 一次冻结拿到精确行号

不必刷 boot（`ipa` 是 `=m`，且不在 `/lib/modules`，重启即消失）。
按 `docs/修复记录.md` 的 W1 热换套路：

1. 在 `ipa_open` / `ipa_runtime_resume` / `ipa_power_enable` / `ipa_endpoint_resume_one` /
   `gsi_channel_resume` 每个可疑调用**前**插 `dev_info(dev, "z17s-g4: <tag>\n")`，
   后面跟一个短忙等（`mdelay(30)`）**等 USB ACM 控制台把这一行吐出去**（console 是 `ttyGS0`，
   USB 是主机轮询，给 30ms 才稳）。
2. `O=` 增量编单个模块（~40s），`modprobe -r ipa` / `insmod` 热换。
3. 跑 `ip link set rmnet_ipa0 up` → 冻 → **串口最后一行就是凶手**。
4. 修 → 再编 → 再热换 → 再试。

> ⚠️ 热换前提：模块非启动必需 + usb0/串口退路都在（本机 ✅）。

### S2（零构建成本，先做也行）单变量切分

只 `echo on > /sys/class/net/rmnet_ipa0/device/power/control`（触发 `pm_runtime_get_sync`
→ `ipa_runtime_resume` → icc+clk+`gsi_resume`+`ipa_endpoint_resume`），**不做 `ip link up`**：

- **冻** ⇒ 凶手在 `ipa_power_enable` 或 `ipa_endpoint_resume`（AP 端点）
- **不冻** ⇒ 凶手在 `ipa_open` 的 `ipa_endpoint_enable_one(AP_MODEM_TX/RX)`

做完记得 `echo auto > power/control` 收回。1 次冻结换 50% 的搜索空间。

### S3（更远）DTS / 驱动补资源

若 S1 指向电源域，则为 IPA 节点补 `power-domains` 与 AXI 时钟；**改 DTS 必须重编 +
重签 boot.img**（见 `docs/boot镜像签名与恢复.md`），与"换 .ko"分开做。

---

## 4 复现步骤（含安全闸门）

```bash
# 0) PC 侧先双击 host/windows/serial/start-serial-log.cmd（唯一能扛整机冻死的取证通道）
#    核对 _z17s/serial-log/serial-log.status 的 pc_time 是新的

# 1) 设备侧：加载 ipa（不进 /lib/modules，重启即消失）
ssh z17s 'insmod /root/ipa.ko'

# 2) 确认 modem 在线并已注册（否则先 --dms-set-operating-mode=online）
ssh z17s 'qmicli -d qrtr://0 --dms-get-operating-mode'
ssh z17s 'qmicli -d qrtr://0 --nas-get-serving-system'

# 3) 起单进程 QMI 客户端并长驻（hold 600s）
ssh z17s 'nohup python3 /root/qmi_up.py 3gnet 3 16 1 0 600 >/root/g3-qmi.log 2>&1 &'

# 4) 危险步：分离执行，每步 sync + /dev/kmsg 标记
ssh z17s 'setsid sh /root/g3_linkup.sh >/dev/null 2>&1 </dev/null &'

# 5) 死了就等 ~35s 自动复位；回来后收尸
ssh z17s 'cat /root/g3-linkup.log'          # 最后一行 = 冻结点
ssh z17s 'cat /proc/sys/kernel/random/boot_id'
```

**安全边界**：`ipa` 只在 `/root/` + `insmod` ⇒ 重启即消失、默认安全；从未写
persist/modem/dsp/vendor/system；`boot`/`userdata` 本次全程未动。

---

## 5 顺手纠正的旧结论

| 旧说法 | 新事实 |
|---|---|
| `boot_id` 可判复位 | ❌ **不可靠**：09-26 与 09-30 两次不同开机共用过 `boot_id = a732bb2a`（无 RTC + 熵池重复）。改看 `boots.tsv` + 日志文件 mtime。（本次复位恰好变了 `a732bb2a → b2b56dfc`，是运气） |
| `ip link set rmnet_ipa0 up` = "疑似打死整机，复位/卡死未定性" | ✅ **定性：硬挂起**（CPU 被总线停顿冻死）→ 硬件看门狗约 35s 复位。零日志 = 不是内核崩溃 |
| G3 失败因 `IPA↔modem 数据路径未建` | ⚠️ 半对：路径参数（DPM iface/rx/tx + mux-id=0）都是对的，**真正缺的是"同一个 QMI 连接"** |
| `DPM = QRTR service 2` | ❌ **DPM = service 47（port 61）**；service 1 = WDS（port 62） |
| `lookup_service(47) == -1` ⇒ DPM 不存在 | ❌ `lookup_service()` 的参数是 **port**，语义反了 ⇒ 要用 `lookup_port(47)` |
| `smp2p` 总线未注册 | ❌ `smp2p-lpass/mpss/slpi` 全部 bind 到 `qcom_smp2p`；IPA 的 8 条 device-link 全 `active` |

---

# 6 S1 实测：冻结点 = `icc_bulk_disable()`（10-01）

## 6.1 做法

`ipa_instr.py` 给 17 个函数插 84 条 `Z17SIPA` `pr_info`（每条后跟 `mdelay(300)` 等 ACM 控制台吐字），
`O=` 增量编单模块 → **活系统热换**（`ipa` 是 `=m` 且不在 `/lib/modules`，重启即消失）。

## 6.2 实测（串口 + `z17s-logwatch` 一致）

死前**最后一行**：

```
Z17SIPA ipa_power_disable:134 pwroff: -> icc_bulk_disable(n=3)
```

之前每一级都被证明健康：`icc_bulk_enable ret=0`、`clk_prepare_enable ret=0`、
两个 `ep_enable ret=0`（id=3 ch=5 / id=16 ch=8）、`gsi_channel_start` 内部全 `ret=0`、
`ipa_endpoint_suspend` / `gsi_channel_suspend` `ret=0`、`clk_disable_unprepare` 正常返回。

## 6.3 结论

冻结点**不在** `ipa_open` / `ipa_runtime_resume`，而在
**autosuspend → `ipa_runtime_suspend` → `ipa_power_disable` → `icc_bulk_disable()`**。
该平台 interconnect 关断时同步总线停顿（零内核输出 + 看门狗 ~35s 复位）。

## 6.4 ✅ 绕过法（已验证）

```sh
echo -1 > /sys/bus/platform/devices/1e40000.ipa/power/autosuspend_delay_ms   # 任何 link up 之前
```

永不 autosuspend ⇒ `ipa_power_disable` 永不执行 ⇒ `ip link set rmnet_ipa0 up` **rc=0**，
接口起来、端点 3/16 使能、无冻结。实测 `runtime_status=active`、
`runtime_active_time=1123250ms` / `runtime_suspended_time=1ms`（几乎从未挂起）。

---

# 7 G4 数据面：链式定位（10-01）

## 7.1 正确的数据面模型（长期被忽略的一环）

`ipa_modem.c ipa_modem_netdev_setup()`：

```c
netdev->header_ops = NULL;
netdev->type       = ARPHRD_RAWIP;
netdev->needed_headroom = sizeof(struct rmnet_map_header);
/* endpoint is configured for QMAP */
```

且 msm8998 用的是 `data/ipa_data-v3.1.c`（`ipa_main.c:649` 把 `qcom,msm8998-ipa` 映射到
`ipa_data_v3_1`，**不是 v3.5.1**），其中 `AP_MODEM_TX = ch5/ep3`、`.qmap = true`。

⇒ `rmnet_ipa0` 只是 **QMAP 中间层**，L3 必须叠 `rmnet0`：

```sh
ip link add link rmnet_ipa0 name rmnet0 type rmnet mux_id 0
```

## 7.2 `ETH_P_MAP` 闸门 —— 解释了"dropped 54"

`ipa_start_xmit()` 里：

```c
	endpoint = ipa->name_map[IPA_ENDPOINT_AP_MODEM_TX];
	if (endpoint->config.qmap && skb->protocol != htons(ETH_P_MAP))
		goto err_drop_skb;        /* stats->tx_dropped++ */
```

`rmnet` 驱动的 `rmnet_egress_handler()` 会把 `skb->protocol` 改成 `ETH_P_MAP`；
直接把 IP 配在 `rmnet_ipa0` 上（早期的 `ipa_ping_now.sh`）**必然全丢**。

## 7.3 现象（叠好 rmnet0 之后）

| 项 | 值 |
|---|---|
| `rmnet0` | `inet 10.100.58.37/30`，`UP`，TX 75 pkt / 0 dropped |
| `rmnet_ipa0` | **TX packets=2 bytes=168 dropped=54**，**RX=0** |
| `tc -s qdisc show dev rmnet_ipa0` | **backlog 6760b 93p**（队列被停、93 个包卡在 qdisc） |
| `/proc/interrupts` | `gsi` = **15**（ping 前后**完全不变**）、`ipa` = **1** |

⇒ **IPA 从不上报 TX 完成**（没有 IEOB 中断）⇒ 包发不出去。

## 7.4 为什么"停"了就再也起不来

1. `ipa_endpoint_skb_tx()`：`trans = ipa_endpoint_trans_alloc(...)` 返回 NULL ⇒ `-EBUSY`
2. `trans_alloc` 的失败点在 `gsi_trans.c`：
   ```c
   if (!gsi_trans_tre_reserve(trans_info, tre_count)) return NULL;
   ```
   `tre_avail` 只在**事务完成**时归还；没有完成 ⇒ 迟早耗尽。
3. `ipa_start_xmit()` 拿到 `-EBUSY`（≠`-E2BIG`）⇒ `return NETDEV_TX_BUSY`，
   **队列停在 `netif_stop_queue()` 之后没被唤醒**。
4. 唯一的唤醒路径是 `ipa_modem_resume()` → `queue_pm_work()` → `ipa_modem_wake_queue_work()`
   → `netif_wake_queue()`。而设备因 autosuspend=−1 **永远 active、永不 resume**
   ⇒ **队列永久停摆**（qdisc 越积越多）。

## 7.5 为什么这次连 `down` 都锁死整机（新）

`gsi.c`：

```c
static void gsi_channel_trans_quiesce(struct gsi_channel *channel)
{
	trans = gsi_channel_trans_last(channel);
	if (trans) {
		wait_for_completion(&trans->completion);   /* ← 无超时 */
		gsi_trans_free(trans);
	}
}
```

而它被 `__gsi_channel_stop()` 在**最开头**调用：

```c
	/* Wait for any underway transactions to complete before stopping. */
	gsi_channel_trans_quiesce(channel);
```

`ip link set rmnet_ipa0 down` → `ipa_stop` → `ipa_endpoint_disable_one(tx)`
→ `gsi_channel_stop` → `__gsi_channel_stop` → **在 `rtnl` 下无限等那两个永不完成的事务**。

实测时间线（10-01，串口）：

| t (uptime) | 事件 |
|---|---|
| 1515.8 | `Z17SI2 I2 begin A=10.100.58.37/30 GW=10.100.58.38` |
| 1515.9 | `Z17SI2 I2 del rmnet0 rc=0` |
| — | 执行 `ip link set rmnet_ipa0 down` ⇒ **再无任何标记** |
| 1543 → 1704 | `load` 从 **1.63 线性涨到 16.76**（≈ +1/10s） |
| 全程 | `z17s-hb` 心跳继续 ⇒ **CPU0 活着 ⇒ 看门狗不跳 ⇒ 只能断电重启** |
| — | ssh `banner exchange` 超时 ⇒ rtnl 被占，网络相关任务全部堆死 |

## 7.6 上游从来没验证过 msm8998 的 IPA 数据面

原始补丁（AngeloGioacchino Del Regno, 2021, `linux-netdevbpf`）作者自述：

> "Since the userspace isn't entirely ready ... for data connection ... it was possible to
> **only partially test** this series. Specifically, **loading the IPA firmware and setting up
> the interface went just fine** ..."

⇒ "接口能起来 + modem 不崩"就是上游的全部结论，**G4 属于无人区**。

### 与原始补丁的实质差异（候选修因）

| 字段 | 原始 msm8998 补丁 | 现在 6.12.95 的 v3.1 数据 |
|---|---|---|
| `AP_COMMAND_TX.seq_type` | `IPA_SEQ_DMA_ONLY` | `IPA_SEQ_DMA`（等价改名，✅ 无碍） |
| **`AP_MODEM_TX.seq_type`** | **`IPA_SEQ_2ND_PKT_PROCESS_PASS_NO_DEC_UCP`** | **`IPA_SEQ_2_PASS_SKIP_LAST_UC`** |
| `AP_MODEM_TX.seq_rep_type` | （当时字段不存在） | **缺失**；sdm845 的 v3.5.1 有 `IPA_SEQ_REP_DMA_PARSER` |

⚠️ 现在的 v3.1 数据还多了 `rx.buffer_size=8192` / `aggr_time_limit=500`（原补丁没有），
像是**从 sdm845 的 v3.5.1 表抄过来的**，`seq_type` 很可能是被一起抄错了。

---

# 8 🔴 新红线（务必记牢）

1. 🔴 **`ip link set rmnet_ipa0 down` 与 `rmmod ipa` 现在都会锁死整机**（只要 TX 通道有未完成事务）。
   一旦要换模块：**先干净重启**（`ipa` 不在 `/lib/modules`，重启即无），再直接 `insmod` 新模块，
   **不要 down、不要 rmmod**。
2. 🔴 `autosuspend_delay_ms = -1` 必须在**任何 link up 之前**写（每次 insmod 后都要重写）。
3. 🔴 只要 TX 队列被停过（`tc` 显示 backlog>0），这机器就只能断电重启 —— **没有软复位通道**。

---

# 9 下一步（重启后照做，零 rmmod）

```sh
# PC 侧：确认串口记录器在录（serial-log.status 的 pc_time 是新的）
# 设备：干净重启后 ipa 未加载 —— 直接上第二遍仪器化模块
insmod /root/ipa-instr2.ko                                     # 已推送，sha256 fc396b2f...
echo -1 > /sys/bus/platform/devices/1e40000.ipa/power/autosuspend_delay_ms
dmesg | grep -E "ipa 1e40000|Z17SIPA" | tail -30               # 记下 isr_ieob 是否出现
python3 /root/qmi_up.py 3gnet 3 16 1 0 3600 &                  # G3：保持 PDP
ip link set rmnet_ipa0 up
ip link add link rmnet_ipa0 name rmnet0 type rmnet mux_id 0
ip link set rmnet0 up; ip addr add 10.100.58.37/30 dev rmnet0
ip route add 10.100.58.38/32 dev rmnet0
ping -c 4 -W 2 -I rmnet0 10.100.58.38
dmesg | grep Z17SIPA2 | tail -40                               # ★ 关键读数
```

判读：

- `isr_ieob` **总共只在 setup 阶段出现、ping 时一条没有** ⇒ 坐实"IPA 不完成 AP_MODEM_TX 事务"
  ⇒ 下一步改 `AP_MODEM_TX.seq_type` / 补 `seq_rep_type`
- 出现 `tre_reserve FAIL need=1 avail=0` ⇒ 坐实 §7.4 的 TRE 耗尽
- 出现 `xmit pm_get ret=...` ⇒ 另有一条 `pm_runtime_get()<1` 的独立问题

**收工：直接断电重启（不要 down / 不要 rmmod）。**

## 9.1 仪器化产物与还原

| 文件 | 说明 |
|---|---|
| `_g3/build/ipa-instr2.ko` | 第二遍（TX/完成路径）模块，sha256 `fc396b2f…`，已推送 `/root/ipa-instr2.ko` |
| `_g3/build/ipa-instr.ko` | 第一遍（S1）模块 |
| `_g3/build/ipa-pristine.ko` | 干净对照 |
| `_g3/ipa_instr.py` / `ipa_instr2.py` / `fix_gsi_macro.py` | 打桩脚本 |
| WSL 源码树 `drivers/net/ipa/*.c.orig` / `*.orig2` | 还原备份（`.orig` 才是原始） |

⚠️ **编译 arm64 模块必须带 `ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-`**；
补丁里有 `\n` 时**不要用 shell heredoc 写 Python**（转义会被吃掉），写成脚本文件再跑。

---

# 10 🔴🔴 G4 真正根因（10-01 二次上机）：`insmod ipa` 把 modem 固件逼崩

## 10.1 决定性日志（`/var/log/z17s-kmsg/kmsg-cbc45795.log`）

```
[512.26] qcom-q6v5-mss 4080000.remoteproc: MBA booted without debug policy, loading mpss
[514.18] ipa 1e40000.ipa: received modem running event
[514.19] remoteproc remoteproc0: remote processor 4080000.remoteproc is now up
[468.99] qcom-q6v5-mss: fatal error received:
         ipa_sio.c:2107: IPA Assert: ipa_ipfltr.init_done == TRUE failed: Init message f
[510.68] 同上（crash #2）
[554.19] 同上（crash #3）
```

modem 固件在 **IPA 断言**上崩了 **3 次（crash loop）**：**IP filter 表没有初始化**
（`ipa_ipfltr.init_done != TRUE`，在处理 "Init message" 时失败）。后果：

- `modem_ready` / `uc_ready` 永不同时为真 ⇒ **`rmnet_ipa0` 根本不会被创建**
- QMI 客户端全部 `QMI protocol error (3): 'Internal'`；QRTR **node 0 从 40 个服务掉到 2 个**
- `--wds-start-network` 报 `endpoint hangup`

## 10.2 🔑 `rmnet_ipa0` 是"握手完成"的指示灯（源码级）

```c
/* ipa_qmi.c:145 */
static void ipa_qmi_ready(struct ipa_qmi *ipa_qmi)
{
	if (!ipa_qmi->modem_ready || !ipa_qmi->uc_ready)   /* INIT_DRIVER 响应 + DRIVER_INIT_COMPLETE */
		return;
	...
	ret = ipa_modem_start(ipa);      /* → alloc_netdev("rmnet_ipa%d") + register_netdev */
}
```

⇒ **网卡在不在，就等于"AP↔modem IPA QMI 握手有没有走完"**。以后先用它判断，比猜快得多。

mainline 的 `ipa_init_modem_driver_req` 报文里**是带** `hdr_tbl_info`、`v4/v6_route_tbl_info`、
`v4/v6_filter_tbl_start` 的 —— 上游"想"告诉 modem 滤波器表的位置，但 **msm8998 的 modem 固件
仍然在处理这条消息时断言**。这与该系列作者自述"数据面未验证"吻合：
**上游对 "IPA v3.1 + msm8998 modem" 这一组合从没跑通过。**

## 10.3 顺序决定成败（**务必记住**）

| 顺序 | 结果 |
|---|---|
| **modem online → insmod → pin autosuspend → 起 PDP → `ip link set rmnet_ipa0 up`** | ✅ 网卡出现、PDP 成功拿到 IP（`10.158.175.64/25`） |
| 起 PDP → insmod（❌ 把 QMI 提到前面"让 modem 服务先就位"） | ❌ `start_network` 报 `endpoint hangup` → modem 崩 → 之后**再也建不出网卡** |

⇒ **IPA 必须先于"数据呼叫"就位**；而且极可能还得**先于 modem 启动**（我们每次 insmod 时 modem
早已在跑，IPA 初始化当着 modem 的面重配硬件 ⇒ modem 断言）。

## 10.4 ❌ modem 一崩，`rmmod` 也别想（SRCU 死锁）

```
pid=6896 rmmod  D  __synchronize_srcu
  ipa_remove → ipa_deconfig → ipa_modem_deconfig → qcom_unregister_ssr_notifier
    → srcu_notifier_chain_unregister → synchronize_srcu        ← 卡死
pid=68   kworker/u33:1+rproc_recovery_wq  D  ipa_cmd_pipeline_clear_wait  ← 未完成的 modem 恢复工作
```

pass-3 给 `gsi_channel_trans_quiesce()` 加的 3s 超时**救不了这一条**（卡在 SRCU，不是 quiesce）。
⇒ **只要 modem 崩过，`rmmod` 就永久阻塞，只能断电重启。**

## 10.5 下一次实验的顺序（已想清楚）

```
1) modem online（--dms-set-operating-mode=online）→ 确认 registered
2) insmod /root/ipa-instr3.ko [z17s_seq=N z17s_rep=M]     ← IPA 先就位
3) 等 probe 走完：dmesg | grep "IPA driver setup completed successfully"
4) echo -1 > .../1e40000.ipa/power/autosuspend_delay_ms   ← 任何 link up 之前
5) ★ 重启 modem：echo stop  > /sys/class/remoteproc/remoteproc0/state
                 echo start > /sys/class/remoteproc/remoteproc0/state
   让 modem 在"IPA 已就位"的世界里启动 —— 本轮新提出的关键单变量
6) 轮询 rmnet_ipa0 出现（≤60s）；dmesg | grep -a "IPA modem start\|Assert" 看握手是否完成
7) 起 PDP（qmi_up2.py）→ 拿 CARRIER
8) link up → 叠 rmnet0 → 配 L3 → ping
```

**判据**：出现 `IPA modem start completed successfully` = 握手走完；若再出现
`IPA Assert: ipa_ipfltr.init_done` = 顺序仍不对，需改 DTS（`qcom,gsi-loader = "modem"`，
要重签 boot，见 `boot镜像签名与恢复.md`）。

## 10.6 本轮脚本 bug（下次别犯）

1. `ping ... | tail -3; PRC=$?` → 取到的是 **`tail` 的状态** ⇒ 假阳性"成功"
   （**必须去掉管道**：`ping ... > f 2>&1; PRC=$?`）
2. `insmod` 后**没等 `rmnet_ipa0` 出现**（probe 走完才 `register_netdev`）⇒ `Cannot find device`
3. `pgrep -f "[q]mi_up2"` **自匹配 ssh 命令行**（命令行里含 `qmi_up2.py`）⇒ PDP 根本没起
   ⇒ 改用 `ps -eo args | grep -c '^python3 /root/qmi_up2.py'`
