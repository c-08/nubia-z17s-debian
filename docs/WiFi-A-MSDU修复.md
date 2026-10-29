# Wi-Fi「高传输就卡死」修复：A-MSDU 跨指示 + in-order RX 的致命误判

> 2026-10-29 中午。Nubia Z17S / WCN3990 / Linux 6.12.95。
> 结论：**已修复**。只改 `ath10k/htt_rx.c` 一处，`-EAGAIN` 丢一小段而不置 `rx_confused`。
> 实测下行 1–11.5 MB/s、累计 200+ MB 不崩，且不再连带打死 modem。

---

## §0 一句话结论

不是加密问题，也不是「固件坏了」。是驱动**把一次可恢复的 A-MSDU 拆分当成致命错误**，
把整条 RX 通路关死，固件随后饿死 assert，顺带把 ADSP（和跑在 ADSP 上的 modem）一起带走。

---

## §1 最终配置

| 项 | 值 |
|---|---|
| 模块 | `/lib/modules/6.12.95+/kernel/drivers/net/wireless/ath/ath10k/ath10k_core.ko` |
| md5 | `a19ffd2e5de12b43c1cbcf43b58b7796`（549704 B） |
| 源 | `/root/ath10k_core.ko.eagain` |
| 加密 | **硬件加密**（`/etc/modprobe.d/99-z17s-ath10k.conf` 里**不要**写 `cryptmode=1`） |
| 开机安装 | `z17s-ath10k-ko.service`（enabled，见 §5.1） |
| 回滚 | `systemctl disable z17s-ath10k-ko` + `cp /root/ath10k_core.ko.stock` 回 `/lib/modules/...` |

验证加载的是补丁版（`modinfo`/md5 都只能看**文件**，看不了已加载的模块）：

```
dmesg | grep "Z17S ath10k"
# Z17S ath10k: split-A-MSDU tolerance active (in_ord_rx=1)
```

`in_ord_rx` 会打印两次：先 `0`（hw init 时还没定），连接后 `1`（firmware features 已知）。
**`=1` 才说明 in-order 路径启用**，也就是补丁真正生效的那条路径。

---

## §2 死亡链（代码路径）

```
WCN3990 / HL1.0 固件把一个大 A-MSDU 拆到两条 in-order RX 指示里
   │
   ├─ ath10k_htt_rx_extract_amsdu()          htt_rx.c:3151
   │     循环 dequeue 直到 RX_MSDU_END_INFO0_LAST_MSDU
   │     列表走完仍没看到 → skb_queue_splice_init(amsdu, list); return -EAGAIN
   │
   ├─ ath10k_htt_rx_in_ord_ind()             htt_rx.c:3262
   │     case -EAGAIN: fallthrough;          ← 和 default 一起当"不该发生"
   │     default:
   │         ath10k_warn("failed to extract amsdu: %d", -11)
   │         htt->rx_confused = true;        ← ★ 毒药在这里
   │         return -EIO;
   │
   ├─ 之后每一条 RX 指示，函数第一行就被打回：
   │     if (htt->rx_confused) return -EIO;  htt_rx.c:3276
   │
   ├─ ath10k_htt_txrx_compl_task()           htt_rx.c:4383
   │     ret == -EIO ⇒ resched_napi = true ⇒ done = budget
   │     ⇒ NAPI 以满 budget 空转，CPU 烧满
   │
   └─ RX 环不再补 buffer（replenish 追不上）⇒ 固件无缓冲可用 ⇒ assert
         ⇒ ADSP 崩 ⇒ 跑在 ADSP 上的 WCN3990 与 modem 一起崩
```

**为什么看起来"还连着"**：`iw dev wlan0 link` 读的是 mac80211 的 sta 状态，
RX 通路死了它照样显示 `connected / -40dBm / 866.7Mbit`。唯一可信的是 `rx_packets` 是否还在涨。

---

## §3 两个实验

### 实验 A（失败，但很有价值）：`max_num_amsdu = 1`

上游给 RAW 模式用的现成招 —— 通过 H2T `AGGR_CFG` 告诉固件「一个 A-MSDU 最多 1 个子帧」，
`ar->htt.max_num_amsdu = 1`（`core.c:2688`，默认是 `ATH10K_HTT_MAX_NUM_AMSDU_DEFAULT` = 3）。

二进制级验证很干净：对照版与实验版**大小完全相同**，只有 21 字节不同，
其中 `0x12600` 一条指令 `mov w3, #3` → `mov w3, #1`，其余是 build-id。

**结果：无效。** 9 秒传 2.4 MB 后照样 `failed to extract amsdu: -11`
⇒ **这版固件根本不认这个 H2T 限制**。

副产品：崩之前吞吐是好的（3 秒 2.4 MB ≈ 800 KB/s）⇒ 数据面本身没问题，问题纯在错误处理。

### 实验 B（成功）：容忍 `-EAGAIN`

```c
/* Z17S round 171 */
static unsigned long z17s_amsdu_dropped;          /* file scope */

		case -EAGAIN:
			z17s_amsdu_dropped++;
			if (z17s_amsdu_dropped <= 5 ||
			    !(z17s_amsdu_dropped % 200))
				pr_info("Z17S: dropped partial A-MSDU #%lu (msdus=%u)\n",
					z17s_amsdu_dropped, skb_queue_len(&list));
			__skb_queue_purge(&list);
			return 0;                  /* 不置 rx_confused，不返回 -EIO */
		default:
			ath10k_warn(ar, "failed to extract amsdu: %d\n", ret);
			htt->rx_confused = true;
			__skb_queue_purge(&list);
			return -EIO;
```

代价：丢掉这一小段（几个包，TCP 会重传）。收益：RX 环继续补，固件不会饿死。

**因果闭环（决定性证据）** —— 30 MB 下载期间：

```
[109.322447] Z17S: dropped partial A-MSDU #1 (msdus=3)
[109.332945] Z17S: dropped partial A-MSDU #2 (msdus=3)
[109.412389] Z17S: dropped partial A-MSDU #3 (msdus=3)
[109.534653] Z17S: dropped partial A-MSDU #4 (msdus=3)
[109.619369] Z17S: dropped partial A-MSDU #5 (msdus=3)

failed to extract amsdu = 0        ← 上游那条致命 warn 不再出现
firmware crashed        = 0
rx ring corrupted       = 0
```

同一个故障事件照常发生 5 次，但只丢了这 5 段，剩下的 31 MB 一路跑完。
原来第一次就会把整条通路打死。

★ `-EAGAIN` 是**突发型**：连接 / 拉流刚开始那一秒成簇出现（109.32–109.62 内 5 次），
之后 100+ MB 再没出现 ⇒ 与固件 reorder buffer 的填充阶段有关，不是均匀随机。
所以「丢而不断」的代价几乎为零。

---

## §4 实测数据

| 项目 | 修复前 | 修复后 |
|---|---|---|
| 下行 | 29.8 KB/s，40 秒后归零 | **1.0 – 11.5 MB/s** |
| 峰值 | — | **11.5 MB/s（≈92 Mbit/s）**，30 MB / 2.6 s |
| 累计 | 2.4 MB 即死 | **200+ MB 无一次崩溃** |
| 上行 | — | 20 MB / 10.7 s = 1.87 MB/s（≈15 Mbit/s） |
| ping 公网 | 28 ms 后 unreachable | 20/20，0% loss，28.0 ms |
| 链路 | `connected` 骗人 | `-38 dBm`、866.7 Mbit VHT-MCS9 shortGI NSS2 |
| modem | 连带崩，只能冷启动 | 与 Wi-Fi 同 boot 并存，`default dev rmnet0 metric 50` 优先 |

吞吐波动大（1–11.5 MB/s）**是 AP 上行拥塞**，不是本机问题 —— 同一 boot 内 5 轮里
3.3 / 3.3 / 3.6 / 8.7 MB/s 都出现过。关键指标是「**再也不会归零**」。

---

## §5 踩过的坑（都值得记住）

### 5.1 `/lib/modules` 每次开机被引导镜像还原

往 `/lib/modules/.../ath10k_core.ko` 里 `cp` 新文件，**校验 md5 是对的，重启后变回原厂**
（mtime 回到 `Jan 1 1970`，大小回到 549312）。

正确做法：加一个开机复制单元，形状照抄项目里已有的 `z17s-qmi-helper.service`：

```ini
[Unit]
Description=Z17S install patched ath10k_core.ko (RX A-MSDU tolerance)
DefaultDependencies=no
After=local-fs.target
Before=systemd-modules-load.service systemd-udev-trigger.service z17s-wifi-load.service
ConditionPathExists=/root/ath10k_core.ko.eagain

[Service]
Type=oneshot
ExecStart=/bin/cp -f /root/ath10k_core.ko.eagain /lib/modules/6.12.95+/kernel/drivers/net/wireless/ath/ath10k/ath10k_core.ko
ExecStart=/bin/sh -c 'echo Z17SATH10K unit-copied $(md5sum /lib/modules/6.12.95+/kernel/drivers/net/wireless/ath/ath10k/ath10k_core.ko | cut -c1-16) > /dev/kmsg'
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
```

`Before=` 这三个是必须的：`systemd-modules-load`、`systemd-udev-trigger`、以及本项目的
`z17s-wifi-load.service`（真正 `modprobe ath10k_snoc` 的那个）。

★ `RemainAfterExit=yes` 的 unit，`systemctl start` 是**空操作**，要重新执行必须 `restart`。

### 5.2 ★ 运行期 `rmmod ath10k_snoc` 会崩 modem

在连着 AP 的状态下卸载：

```
[1378] sta_state 4->3 + set_key cmd=1              ← modprobe -r 触发断连
[1381] failed to install key -110
[1384] wmi command 16387 timeout, restarting hardware
[1415] could not suspend target (-108)              ← wcn3990 挂不掉
[1420] ipa: received modem crashed event            ← ADSP 崩 → modem 崩
[1421] remoteproc0: stopped → MBA booted → 重启
```

后果：`rmnet_ipa0` 整个 netdev 消失、wlan0 也回不来（`failed to assign msa map permissions: -22`），
本 boot 双废，**只能冷启动**。

⇒ **换 ath10k 模块只能「开机前装好、开机自动加载」，绝不能运行期卸载重载。**
（开机加载本身安全：modem 完全在线时首次 `modprobe` 成功，wlan0 正常起来并自动连上。）

### 5.3 已加载模块没法用 md5 判断是哪个二进制

- `modinfo` 读的是**文件**，不是已加载的模块
- `/sys/module/ath10k_core/coresize` 是页对齐的（原厂 339968），加的代码太小跨不过页边界，
  **不能当指纹**
- ⇒ 补丁里必须自带一条**加载时** `pr_info`

### 5.4 `dmesg -c` 造成的假象

`z17s-up.sh` 的 `[10] 自检` 会 `dmesg -c`，之后 `grep -c "dropped partial A-MSDU"` 变 0
**是清环假象**，不是计数器归零（模块内静态变量只在 #1–5 和每 200 次打印）。
判「有没有崩」要看 `firmware crashed` 的累计次数，或者自己定期把 dmesg 落盘。

### 5.5 `cryptmode=1` 与当前 ko 的关系

`cryptmode > 0` 要求固件报 `RAW_MODE_SUPPORT`，这版固件没有 ⇒ `could not probe fw (-22)`
⇒ **wlan0 根本不出现**。所以：

- 想用硬件加密（推荐）⇒ `modprobe.d` 里**不要**有 `cryptmode`
- 想走软解 ⇒ 需要额外补丁绕过 `RAW_MODE_SUPPORT` 门槛（W1 那套），而且软解本身发不出加密帧

**本项目最终选择硬件加密**，`hwcrypto 1`，一切正常。

---

## §6 复现步骤

```bash
# 0. 环境（WSL / Linux，已装 aarch64-linux-gnu-）
SRC=/root/z17s-kbuild/linux-6.12.95
OUT=/root/z17s-debian/build/kernel-out
ATH=$SRC/drivers/net/wireless/ath/ath10k

# 1. 打补丁（scripts/wifi/z17s-ath10k-eagain.patch，只改 htt_rx.c）
cd $SRC && git apply /path/to/z17s-ath10k-eagain.patch

# 2. 编译（约 30 秒）
make -C $SRC O=$OUT ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- M=$ATH modules

# 3. 上机
scp $ATH/ath10k_core.ko z17s:/root/ath10k_core.ko.eagain
scp scripts/wifi/z17s-ath10k-ko.service z17s:/etc/systemd/system/
scp scripts/wifi/99-z17s-ath10k.conf   z17s:/etc/modprobe.d/
ssh z17s 'systemctl daemon-reload && systemctl enable --now z17s-ath10k-ko.service'

# 4. 物理断电（长按电源 10–15 s），开机
# 5. 确认
ssh z17s 'dmesg | grep "Z17S ath10k"'      # in_ord_rx=1
```

---

## §7 红线

1. **绝不运行期 `rmmod ath10k_snoc` / `ath10k_core`**（§5.2，会崩 modem）
2. 崩一次就要**冷启动**（长按电源 10–15 s，不要 `reboot`）；断电前 `sync ×3` 等 5 s
3. Wi-Fi 崩 = ADSP 崩 = **modem 崩**，蜂窝同 boot 一起废
4. 判活看 `rx_packets` / `firmware crashed` 计数，**不要信 `iw link` 的 connected**
5. 改 `/lib/modules` 里的任何 ko 都必须配开机复制单元（§5.1）

---

## §8 还没做

- 吞吐波动（1–11.5 MB/s）没定位到本机还是 AP 上行；换一个 AP 复核即可分辨
- 没试 `in_ord_rx = false`（走传统 RX 路径）。**不建议**：固件既然报 `RX_FULL_REORDER`，
  环是按乱序填充的，传统路径顺序遍历会读错
- 没做 A-MSDU 的「跨指示拼接」（保留部分并在下一条指示前接上）。理论上能连那几个包也不丢，
  但要维护跨指示状态，收益远小于风险 —— 现在丢的那几段 TCP 自己就补回来了
