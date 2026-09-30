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
