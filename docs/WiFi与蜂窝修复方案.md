# Wi-Fi 与蜂窝：还能做什么（方案评审 + 实施清单）

> 2026-09-23。对一份"W1 重编内核 / W2 取证 / C1 蜂窝绕行"方案的逐条核实。
>
> ⚠️ **2026-09-25 修订**：本文 **C 节**把内置蜂窝判为"不建议投入"，依据是"IPA 加载即复位、架构级缺失"。
> 经设备侧取证 + 上游核查，该结论**过强**（详见 [蜂窝可行性评估.md](蜂窝可行性评估.md)）：
> IPA v3.1 主线原生支持、本机 IPA 节点接线完整、本机 Android 下数据面跑通过。
> **C 节结论改为"值得一试"**；C1a / C1b 两条绕行路线依然有效，作为兜底。
> **结论：方向成立，但原方案把 W1 的代价估高了一档、把 C1b 的代价估低了一档。**
>
> ⚠️ **2026-09-25 又一处修订（W1，源码级）**：**`key_hw_accel` 不是钩子，是日志插桩**（`net/mac80211/key.c` 里 6 条
> `pr_info`，外层逻辑与上游一致，上游本就支持"驱动返回 1 → 软解"）⇒ **`mac80211.ko` 不用改**；
> 真正的软解开关在 **`ath10k` 驱动**（`mac.c:6592` 的 `if (arvif->nohwcrypt) return 1;`），
> 编译产物是 **`ath10k_core.ko`**。而 `nohwcrypt` 在 WCN3990 上**目前永远为 false**
> （唯一置位入口 `core.c:2673` 被 `RAW_MODE_SUPPORT` 挡住）—— 这才是"key 照样交给固件、固件照崩"的原因。
> **详见 §2**（已按新结论重写，含确切补丁与 file:line）。
>
> 已穷尽、不要再试的方向见 [硬件现状.md §一](硬件现状.md)；本文只写"还能做什么"与"怎么做最省"。

---

## 0 一页结论

| 原方案 | 原估价 | 核实后 | 判定 |
|---|---|---|---|
| **W1** 改 `key_hw_accel` → 软解，**重编内核 + 刷 boot** | 高风险（刷 boot） | 🔑 **要改的是 `ath10k_core.ko`（不是 `mac80211.ko`）**。⚠️ 2026-09-25 更正：**要持久生效就得换进 boot 的 ramdisk ⇒ 必须重新签名**（换 `/lib/modules` 会被开机覆盖） | ✅ **值得做**；风险点是"签名"，不是"模块"（见 [boot镜像签名与恢复.md](boot镜像签名与恢复.md)） |
| **W1** 的"模块参数开关" | 需要重编才能改 | 🔑 **`key_hw_accel` 不是参数**（源码里没有 `module_param`），但补丁可以挂在**现成的 `cryptmode` 参数**上 | ✅ 默认行为零变化，挂参即切换 |
| **W2** `apt-get --reinstall wireless-regdb` | 零风险，应该能修 | ❌ **大概率无效** —— 内核开了 `REQUIRE_SIGNED_REGDB`，问题在**签名**不在文件损坏 | 🔧 改成"从内核源码树取配套两个文件" |
| **W2** 合并取证开关一起刷 | 顺手做 | ⚠️ 取证开关是**核心选项（非模块）**，**必须刷 boot + 过 AVB 签名** | ⚠️ **建议与 W1 拆开**，见 §4 |
| **C1b** 手机卡经 PC 中转（手机 **USB 共享**给 PC） | 零改动 | ⚠️ **会撞网段** —— Windows ICS 默认就用 `192.168.137.0/24`，和 `z17s-usb` 完全相同 | 🔧 改成"**手机开 Wi-Fi 热点**给 PC"，才真的零改动 |
| **C1a** 4G dongle 直插 Z17S | 先验 `dr_mode`，可能要改 DTS | ✅ 拓扑互斥判断**正确**，但成本比原估**更高**（要改 DTB→刷 boot+签名，且**失去 SSH/串口救援**） | 🔻 降到最低优先级 |
| 新增（原方案没有） | — | ⭐ `power_save off` + ⭐ `dyndbg` 抓 key 路径 + ⭐ regdb 双文件 | ✅ **三条全是零成本**，排在 W1 前面 |

**一句话**：先花 15 分钟做三条不花钱的（§3），再决定要不要动 W1；W1 走"换单文件"而不是"刷 boot"；C1b 换成手机热点形态；C1a 最后再说。

> 📦 **进度（2026-09-25）**：W1 的 A/B 两处补丁**已打好并编译成功**，得到
> `ath10k_core.ko`（549 552 B / md5 `e46e8e82…`），**ABI 预检通过（190/190 符号 CRC 全一致）**，
> 现等"要不要部署"的决定 —— 部署需你在场（串口记录器要双击）。详见 §2.4.1 与工作区 `w1-out/构建说明.md`。

---

## 1 五个必须先知道的事实

全部来自仓库里的 `kernel/config-6.12.95-running.txt`（当前运行内核的真实配置）与 `kernel/build-boot.sh`，**不是推测**。

| # | 事实 | 出处 | 对方案的影响 |
|---|---|---|---|
| 1 | **`CONFIG_MAC80211=m`**（还有 `CFG80211=m`、`ATH10K=m`、`ATH10K_SNOC=m`） | config | ★ **不用重编内核** —— 换的是 `.ko`。⚠️ 但本机 initramfs **每次开机把 `/lib/modules` 覆盖回** boot 内嵌那份 ⇒ **要持久仍须改 boot 镜像并重签**（§2.4） |
| 2 | **没有 `CONFIG_MODULE_SIG*`**，但有 `CONFIG_MODVERSIONS=y` | config | 替换的 `.ko` **本身不需要签名** ✅；但**符号 CRC 必须一致** → 必须同源码 + 同 config + 同工具链。⚠️ **别混淆**：`.ko` 不用签 ≠ 装它的 **boot 镜像**不用签（那个**必须**签，见 [boot镜像签名与恢复.md](boot镜像签名与恢复.md)） |
| 3 | **`CONFIG_CFG80211_REQUIRE_SIGNED_REGDB=y`** + `CONFIG_CFG80211_USE_KERNEL_REGDB_KEYS=y` | config | ★ 解释 `regulatory.db is malformed` —— 内核只认**用自己内置 key 签的** regdb |
| 4 | **`CONFIG_SOFTLOCKUP_DETECTOR` / `DETECT_HUNG_TASK` / `MAGIC_SYSRQ` / `PSTORE` 全部没有**（`KALLSYMS=y`、`DEBUG_FS=y`、`DYNAMIC_DEBUG=y` 有） | config | 取证开关**确实该加**；但它们是核心选项 → **必须刷 boot**；而 dyndbg 已可用，见 §3.2 |
| 5 | boot 镜像要过 **AVB 签名**（`BootSignature.jar` + `verity.pk8` + `verity.x509.der`），且 `abootimg -k` 要求 `Image.gz + DTB×3` | `kernel/build-boot.sh`、`kernel/README.md` | 刷 boot 的**真实成本**比"dd 进去"高得多 → 又一个"W1 别刷 boot"的理由 |

**前置条件**：本仓库 `kernel/` 里**只有构建脚本和一份 config**，`common.sh` 与 `assets/`（`$ASSETS_DIR`、`$BUILD_DIR`、DTB 源、签名材料）都不在仓库里。

> ✅ **2026-09-25 已确认环境齐备**：WSL 里源码树 `/root/z17s-kbuild/linux-6.12.95`（带全部移植补丁）
> 与 `O=` 构建树 `/root/z17s-debian/build/kernel-out` 都在，且后者与 `build/config-6.12.95+` 一致、
> `Module.symvers` 完整 ⇒ **可增量编模块，不需要恢复环境全量重编**。构建脚本在
> `/root/z17s-debian/scripts/build-kernel.sh`（上游包 `z17s-debian`）。

---

## 2 W1：让 `ath10k` 在 WCN3990 上走软件解密

> ⚠️ **2026-09-25 源码级修正（本节此前的前提是错的）**
> 1. **`key_hw_accel` 不是"自研钩子"，是纯日志插桩**：`net/mac80211/key.c` 里那 6 条 `pr_info`
>    （129 / 167 / 189 / 230 / 234 / 237）只是往 `ieee80211_key_enable_hw_accel()` 里加的打印，
>    **外层逻辑与上游 Linux 一字不差**。上游本来就接受"驱动返回 1 → 走软件解密"
>    （`key.c:229-232`：`if (ret == 1) return 0;`，上面注释就是 *all of these we can do in software*）。
>    ⇒ **`mac80211.ko` 不需要改**，不是因为"钩子在别处"，而是因为它从来就原生支持软解。
> 2. **真正的软解开关在 `ath10k` 驱动里**，编译产物是 **`ath10k_core.ko`**（依赖 `cfg80211`）。
>    ⇒ 编译/替换目标从 `mac80211.ko` **改为 `ath10k_core.ko`**。

### 2.1 机制（源码位置已逐条核对，源码树 `/root/z17s-kbuild/linux-6.12.95`）

| 位置 | 代码 | 含义 |
|---|---|---|
| `ath10k/mac.c:6592` | `if (arvif->nohwcrypt) return 1;` | ★ **唯一的软解生效点**：返回 1 → mac80211 自己解密 |
| `ath10k/mac.c:320` | `if (arvif->nohwcrypt) return 1;` | 同一个判断，另一处入口（`ath10k_install_key`） |
| `ath10k/mac.c:5723` | `if (test_bit(ATH10K_FLAG_HW_CRYPTO_DISABLED)) arvif->nohwcrypt = true;` | `nohwcrypt` 的来源 |
| `ath10k/mac.c:5726` | `if (nohwcrypt && !RAW_MODE) { ret=-EINVAL; warn("cryptmode module param needed for sw crypto"); goto err; }` | ⚠️ **守卫在 `add_interface`（vdev create）里，不在 `set_key`**：过不去 → **接口都建不起来** |
| `ath10k/core.c:2666` | `cryptmode=1` 要求 `FW_FEATURE_RAW_MODE_SUPPORT` | HL1.0 固件没有 → `-EINVAL`（= 实测"cryptmode=1 被 probe 拒"） |
| `ath10k/core.c:2672-2673` | `cryptmode=1` 会**同时**置 `RAW_MODE` + `HW_CRYPTO_DISABLED` | ⚠️ 见下方陷阱 |
| `ath10k/core.c:2694` | `RAW_MODE` 会把 `rx_decap_mode` 切成 `ATH10K_HW_TXRX_RAW` | 🔴 这是发给**固件**的 WMI 参数，HL1.0 不支持 → **别为了软解去置 RAW_MODE** |
| `ath10k/mac.c:10103-10114` | WCN3990 清 `SW_CRYPTO_CONTROL`（注释/日志 *allow SW crypto fallback*） | ✅ **已在树里、也已在设备模块里**（见 §2.2），不用再改 |

**要补的只有第三步**：`ATH10K_FLAG_HW_CRYPTO_DISABLED` 全树**只有 `core.c:2673` 会置位**，
而那条路被 `RAW_MODE_SUPPORT` 挡死 ⇒ **WCN3990 上 `nohwcrypt` 恒为 false**
⇒ `set_key` 照样把 CCMP key 交给固件 ⇒ 固件照崩。**这才是崩的真正机制。**

### 2.2 已经探明的部分（2026-09-25 完成，**原来那三条探针作废**）

- `strings mac80211.ko` 命中的只有 6 条 `pr_info` 格式串 ⇒ 是**日志插桩**，既不是模块参数、也不是分支逻辑
- 源码里没有 `module_param(key_hw_accel)` ⇒ `/sys/module/mac80211/parameters/` 里不会有它，`echo 0` 那套**不成立**
- 编译产物 `ath10k_core.ko` 里**已含** `WCN3990: clear SW_CRYPTO_CONTROL (allow SW crypto fallback)`

#### 2.2.1 上机后先核一件事（1 分钟，防"改了等于没改"）

确认设备在跑的模块就是源码树编出来的那一版：

```bash
K=/lib/modules/$(uname -r)/kernel/drivers/net/wireless/ath/ath10k/ath10k_core.ko
strings "$K" | grep -i "WCN3990\|cryptmode"
# 期望同时看到：
#   WCN3990: clear SW_CRYPTO_CONTROL (allow SW crypto fallback)
#   cryptmode > 0 requires raw mode support from firmware
```

### 2.3 补丁：两处（都走 `cryptmode` 模块参数，**默认行为零变化**）

**A. `ath10k/core.c:2665`（触发开关）** —— 让 `cryptmode=1` 在 WCN3990 上被接受，但**只置 `HW_CRYPTO_DISABLED`、不置 `RAW_MODE`**：

```c
 	case ATH10K_CRYPT_MODE_SW:
 		if (!test_bit(ATH10K_FW_FEATURE_RAW_MODE_SUPPORT,
 			      fw_file->fw_features)) {
+			if (QCA_REV_WCN3990(ar)) {
+				ath10k_warn(ar, "WCN3990: SW crypto without raw mode, HW crypto disabled\n");
+				set_bit(ATH10K_FLAG_HW_CRYPTO_DISABLED, &ar->dev_flags);
+				break;	/* ★ 关键：不置 RAW_MODE */
+			}
 			ath10k_err(ar, "cryptmode > 0 requires raw mode support from firmware");
 			return -EINVAL;
 		}
```

**B. `ath10k/mac.c:5726`（必须的守卫放宽）** —— 否则 `add_interface` 直接 `-EINVAL`，"接口都建不起来"：

```c
 	if (arvif->nohwcrypt &&
-	    !test_bit(ATH10K_FLAG_RAW_MODE, &ar->dev_flags)) {
+	    !test_bit(ATH10K_FLAG_RAW_MODE, &ar->dev_flags) &&
+	    !QCA_REV_WCN3990(ar)) {
 		ret = -EINVAL;
 		ath10k_warn(ar, "cryptmode module param needed for sw crypto\n");
 		goto err;
 	}
```

`mac.c:10103-10114`（清 `SW_CRYPTO_CONTROL`）**已在树里，不用动**。

**生效方式**：`/etc/modprobe.d/99-z17s-ath10k.conf` 里写 `options ath10k_core cryptmode=1`；**不写这个文件 = 完全原来的行为**（变量干净、删文件即回退）。

🔴 **两条纪律**
1. **不要靠"假造 `RAW_MODE_SUPPORT`"来让 `cryptmode=1` 通过** —— `RAW_MODE` 会把 `rx_decap_mode` 改成 `ATH10K_HW_TXRX_RAW`（发给固件的 WMI 参数），HL1.0 不支持，会把 RX 一起弄坏。
2. A、B 缺一不可：只改 A → 接口建不起来；只改 B → `nohwcrypt` 恒 false，key 照样交固件。

**变体**：如果不想要参数开关、要"开机即软解"，可把 A 改成无条件（`QCA_REV_WCN3990(ar)` 直接置位、不看 `cryptmode`）。代价是 A/B 对比要重编两次。

### 2.4 ★ 实施形态：改的是一个 `.ko`，但**要持久就必须刷 boot**

因为 `CONFIG_ATH10K=m`，而且 **`ath10k` 不是启动必需模块**（网络入口是 gadget 的 RNDIS + 静态 IP）→ 换坏了最多"没有 Wi-Fi"，开机、`usb0`、SSH、串口**全都不受影响**，能当场回滚。`ath10k_snoc.ko` **不用换**（本次不动 `ath10k_core_create` 这类被 snoc import 的符号）。

> 🔴 **2026-09-25 重要更正："只换 `.ko`、不碰 boot"只说对了一半**
>
> 替换 `/lib/modules/.../ath10k_core.ko` 会**在下次开机被冲掉** —— 本机 initramfs 的 `init` 里有这一步：
>
> ```sh
> # init（在 switch_root 之前）
> screen_log "DRM_MOD copy modules to rootfs"
> $BB cp -a /lib/modules/. /rootfs/lib/modules/
> ```
>
> 方向是 **ramdisk → rootfs**：每次开机都把 **boot 镜像里那份**模块覆盖回 `/lib/modules`。
> （这正是"改 `/lib/modules` 不持久"的原因，也是这次要去改 boot 镜像的动机。）
>
> ⇒ **两种形态要分清：**
>
> | 目的 | 做法 | 代价 |
> |---|---|---|
> | **当场试一把**（不重启） | 只换 rootfs 的 `.ko` + `modprobe` | 零风险、可当场回滚；**重启即失效** |
> | **持久生效** | 把 `.ko` 换进 **boot 镜像的 ramdisk** → **必须重新签名** | 一次刷 boot |
>
> 🔴 改 boot 镜像**必须重签**，否则**黑屏开不了机**（引导器拒载、内核日志无痕）。
> 规则、验签方法、三重闸门与恢复通道见 **[boot镜像签名与恢复.md](boot镜像签名与恢复.md)**。
>
> ⚠️ 还有一条配套项：`/etc/modprobe.d/99-z17s-ath10k.conf`（`options ath10k_core cryptmode=1`，
> 在 **userdata** 上、持久）**只能配补丁模块**；一旦刷回**原厂模块**，`cryptmode=1` 会让
> ath10k probe 失败（WCN3990 不支持 RAW_MODE）⇒ **彻底没有 wlan0**。刷纯净版时必须删掉它。

> ✅ **构建环境现成（2026-09-25 实测，推翻上一版"必须先恢复 `.config` 并全量重编"的判断）**
> `O=` 输出树 **`/root/z17s-debian/build/kernel-out` 完整存在**：`.config`（161 564 B，与
> `build/config-6.12.95+` **逐字节相同**）、`Module.symvers`（731 262 B）、`kernel.release = 6.12.95+`，
> 且 `kernel-out/source -> /root/z17s-kbuild/linux-6.12.95`（带全部移植补丁的源码树）。
> 这正是产出**当前所刷 `boot-nx595j-debian13-signed.img`（2026-09-20 03:30）**的那次构建
> ⇒ **只需增量编一个模块（约 40 秒），不必全量 `make modules`**。

```bash
K=/root/z17s-kbuild/linux-6.12.95
O=/root/z17s-debian/build/kernel-out

# 1) 保证源码树"干净"：O= 构建有硬闸门（见下方坑 1）
make -C $K ARCH=arm64 mrproper

# 2) 打上 §2.3 的 A/B 两处补丁，然后只编 ath10k
make -C $K O=$O ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)" \
     M=$K/drivers/net/wireless/ath/ath10k modules
# ★ 产物在【源码树】目录里，不在 O= 里：$K/drivers/net/wireless/ath/ath10k/ath10k_core.ko
```

**四个实测坑**（都真踩过，不是推测）：

| # | 坑 | 处置 |
|---|---|---|
| 1 | `O=` 构建有硬闸门：srctree 存在 `.config` / `include/config/` / `arch/arm64/include/generated/` 任一即报 `The source tree is not clean` 并中止。⚠️ **`make -n` 干跑也会写入这些** | `make -C $K ARCH=arm64 mrproper`（**不会**删已改的 `core.c`/`mac.c`/`z17s_defconfig`，已验） |
| 2 | `M=drivers/net/...`（**相对**路径）在 `O=` 下必失败 —— kbuild 按 **objtree** 解析，`kernel-out/` 里没有 `drivers/` | `M=` 写**绝对路径** |
| 3 | 目录目标 `make ... drivers/net/wireless/ath/ath10k/` **什么都不编**（目录目标只编 built-in，ath10k 全是 `=m`） | 用 `M=… modules`，不要用目录目标 |
| 4 | 产物位置反直觉：`M=` 是"外部模块"语义 ⇒ `.o`/`.ko` 落在**源码树**；`O=` 里那份仍是旧版 | 取 `$K/drivers/net/wireless/ath/ath10k/ath10k_core.ko`；源码树里这批 `.o` 被内核 `.gitignore` 覆盖，`git status` 仍干净 |

> 📌 **两代模块并存（别拿错基线）**：已刷进 userdata 的 `rootfs-…ext4`（2026-09-18）里是**旧代**
> （md5 `dcc87626…`，与 `/root/z17s-kbuild/mods/` 同一份）；`kernel-out` 与 boot.img 的 ramdisk 是**新代**
> （md5 `1665de73…`）。**两代的同名导入符号 CRC 完全一致**（逐符号比对过 190/190），所以任一代都能当基线。
> 设备上真正加载的是哪一代，只能上机 `md5sum` 现场确认。

### 2.4.1 已编译产出（2026-09-25，**待部署**）

| 文件 | 大小 | md5 | 说明 |
|---|---|---|---|
| `ath10k_core.ko` | 549 552 | `e46e8e82b5df7b3bc79db962143e726b` | ★ 含 A/B 两处补丁 |
| `ath10k_core.ko.baseline` | 549 312 | `1665de738d810b21f39d40f80fd134cf` | 未打补丁的原样 |

- `vermagic=6.12.95+ SMP preempt mod_unload modversions aarch64`（与基线逐字节相同）；`depends: mac80211,cfg80211,led-class,ath`
- **ABI 预检：导入符号 190 = 190，CRC 不一致 0 处**；与**从已刷 rootfs 镜像里 `debugfs dump` 出来的那份**比对同样 0 处不一致
  ⇒ `insmod` 不会被 `CONFIG_MODVERSIONS` 拒载
- `strings` 可验到补丁自带字符串 `WCN3990: SW crypto without raw mode, HW crypto disabled`
- 分支一定生效的**调用时序证据**：`ar->hw_rev` 在 `ath10k_core_create()`（`core.c:3634`，由 `snoc.c:1738` 传入）赋值，
  而 `ath10k_core_init_firmware_features()` 在 `ath10k_core_probe_fw()`（`core.c:3456`）才被调用 —— 晚于前者
- 完整构建/部署/回滚清单另见工作区 `w1-out/构建说明.md`

```bash
# 0) 上机前先验兼容性（不替换就能判断会不会被拒）
modinfo 新-ath10k_core.ko | grep -E "vermagic|depends"      # 期望 depends: cfg80211,mac80211
modprobe --dump-modversions 新-ath10k_core.ko | sort > /tmp/new.crc
modprobe --dump-modversions /lib/modules/$(uname -r)/kernel/drivers/net/wireless/ath/ath10k/ath10k_core.ko \
  | sort > /tmp/old.crc
diff /tmp/old.crc /tmp/new.crc        # ★ 期望：**只有新增/无关行**，所有"同名符号的 CRC"必须一致
join -j1 /tmp/old.crc /tmp/new.crc | awk '$2!=$3'      # 空 = 全部一致，能加载
# vermagic 必须与设备一致：6.12.95+ SMP preempt ... aarch64

# 1) 备份 + 替换
cp -a /lib/modules/$(uname -r)/kernel/drivers/net/wireless/ath/ath10k/ath10k_core.ko \
      /root/fwbackup/ath10k_core.ko.orig
cp 新-ath10k_core.ko /lib/modules/$(uname -r)/kernel/drivers/net/wireless/ath/ath10k/ath10k_core.ko
depmod $(uname -r)
# 再加开关（不想要参数开关就跳过这行）：echo 'options ath10k_core cryptmode=1' > /etc/modprobe.d/99-z17s-ath10k.conf

# 2) 生效：直接 reboot。不要 rmmod 热卸（见 §2.5 止损）
```

**对照原方案的"重编内核 + 刷 boot"**，这条路省掉的东西：§12 的 `CONFIG_RPMSG_QCOM_SMD` 闸门、`Image.gz + DTB×3` 拼装、**AVB 签名**、37 MB 写入 + 回读校验、以及"刷坏 boot 要 TWRP 救"的风险。**为了改一个 Wi-Fi 模块，这些都不值得付。**

### 2.5 预期、风险与止损

**如实说四条风险**：

1. **不保证不再崩。** 崩溃是 modem 侧固件 assert（`EX:wlan_process:1:WLAN RT:1078`）。但现在机制已查清：**触发点就是 CCMP key 被下发进固件**（`set_key` → `ath10k_wmi_vdev_install_key`）。软解后固件手里不再有 key，**这个触发点被移除**；不过同一固件还有别的崩溃路径（作者已为它加过 `skip quiet mode for WCN3990` 之类的补丁），不能承诺 100%。
2. **软解吃 CPU。** 骁龙 835 跑 WPA2 软解吞吐会明显下降。**但对这台机器的实际用途（SSH / 面板 / 同步）够用** —— 它不需要跑满带宽。
3. **"连得上但数据不通"的风险已显著降低（源码已证）**：
   - **TX 侧有配套机制**：`nohwcrypt` → `ATH10K_SKB_F_NO_HWCRYPT` → `HTT_DATA_TX_DESC_FLAGS0_NO_ENCRYPT`（`htt_tx.c:1317` / `1512`），明确告诉固件"这帧别加密"，**这条路不需要 `RAW_MODE`**。
   - **RX 侧 host 不按 decap 模式分支**：`rx_decap_mode` 只用于给固件发 WMI 参数 + `wow.c`；解密标记来自固件上报的 enctype，而 `htt_rx.c:1998-2003` 的注释写得很清楚 —— 固件遇到"解不开的加密帧（缺 peer / key 无效）会**按 raw 上报**" ⇒ `RX_FLAG_DECRYPTED` 不置 ⇒ mac80211 自己软解。
   - 且 snoc 是 `ATH10K_DEV_TYPE_LL`（`snoc.c:1366`），不走 HL 的 `rx_ind` 特殊路径。
   - **剩下的唯一未知**：固件在"peer 没有 key"时，是**乖乖把加密帧上报**，还是**直接丢掉**（丢了 = 关联成功但 ping 不通）。只能上机验。
4. 🆕 **补丁写错的失败形态很好认**（省一轮排查）：只改 `core.c` 不改 `mac.c:5726` ⇒ `dmesg` 出现
   `cryptmode module param needed for sw crypto`，**vif 建不起来**（现象像"连不上/扫不到"）。

🔴 **止损规则（原方案没写，但这是实测过的雷）**：

```bash
# 崩了之后：立刻停 Wi-Fi，不要马上重载驱动
nmcli radio wifi off
```

> 在**固件已经崩掉**的状态下动 `wlan0` / `rmmod ath10k_snoc`，实测会**触发整机复位**，且 `wlan0` 之后再也不出现。
> 先在健康态观察，别在崩溃态折腾。

### 2.6 验收标准（比原方案更省时间）

原方案的"连续 ≥6 小时"**太长**。基线是"**开机约 7 分钟必崩**"（实测 103s 起来 → 441s 崩），所以：

| 阶段 | 判据 | 时长 |
|---|---|---|
| **Go/No-Go** | 无崩溃 + `ping` 网关零丢包 | **30 分钟**（已是基线的 4 倍） |
| 长跑（可选） | 同上 | 可**累计**，不必连续 6 小时 |

**硬判据（比"感觉没崩"可靠）**：

```bash
ping -c 5 <网关>                                    # ★ 必须 ping，不能看 ip link
journalctl -b | grep -c "fatal error: EX:wlan_process"   # 必须 0
journalctl -b | grep -c "firmware crashed!"              # 必须 0
uptime                                              # load 应 ~0.3，不是 1.9

# —— 2026-09-25 新增：直接证明"软解真的生效了" ——
dmesg | grep -c "cryptmode module param needed"      # 必须 0（≠0 = mac.c:5726 守卫没绕过）
dmesg | grep -c "cryptmode > 0 requires raw mode"    # 必须 0（≠0 = core.c 补丁没生效）
dmesg | grep "key_hw_accel" | tail -5                # ★ 期望出现 "key_hw_accel SW ok (drv ret=1)"
dmesg | grep -c "set_key cmd="                       # ★ 期望 0：不再把 key 下发固件
```

`key_hw_accel` 那 6 条 `pr_info` 这次终于派上用场：**`SW ok (drv ret=1)` = 驱动回退成功**；
若看到 `SW denied by SW_CRYPTO_CONTROL` 说明 `SW_CRYPTO_CONTROL` 又被置上了（`mac.c:10103` 那段失效）。

⭐ **两条纪律**：

- **必须 `ping` 真实网关** —— 形态②"下行卡死"时 `ip link` 是 `UP`、有 IP、`iw scan` 还能成功，**光看接口状态会以为 Wi-Fi 好着**。
- **崩溃检测不能只靠 SSH** —— 形态③"崩溃风暴"时网络会死、SSH 会卡。**PC 侧串口记录器要常驻**，`EX:wlan_process` 现场只在串口/dmesg 上。
  ```bash
  # 单独开一个窗口，双击：
  host\windows\serial\start-serial-log.cmd
  ```
  事后：`grep -c "EX:wlan_process" _z17s/serial-log/*.log`

---

## 3 W1 之前：三条零成本的路（原方案里没有）

**先做这三条，可能直接改变结论，也可能直接解决问题。全部不需要重编、不需要刷机。**

### 3.1 ⭐ `power_save off` —— 形态②的经典嫌疑

`CONFIG_CFG80211_DEFAULT_PS=y` → **cfg80211 默认打开省电模式**。而 ath10k + PS 的已知问题表现**恰好就是形态②**：接口 `UP`、有 IP、`scan` 成功、数据面死了，日志刷 `failed to extract amsdu: -11`。

```bash
iw dev wlan0 set power_save off
cat /sys/module/mac80211/parameters/... # （若无此参数则用 iw 查）
iw dev wlan0 get power_save             # 确认 off
```

**2 分钟，零风险，文档里没试过。** 如果形态②消失，说明"7 分钟必崩"里**至少有一部分是 PS 而不是 `key_hw_accel`** —— 这会直接降低 W1 的必要性。

⚠️ 前提：**在健康态做**（不要在固件已崩的状态下动 `wlan0`）。

### 3.2 ⭐ 用 `dyndbg` 看清 key 的下发路径（不用重编）

`CONFIG_DYNAMIC_DEBUG=y` **已经开着**，`CONFIG_DEBUG_FS=y` + `ALLOW_ALL` 也开着 → 可以**运行时**打开 mac80211 / ath10k 的调试打印：

```bash
# 打开 mac80211 的 key 处理与 tx 路径
echo 'file net/mac80211/key.c +p'            > /sys/kernel/debug/dynamic_debug/control
echo 'file net/mac80211/tx.c +p'             > /sys/kernel/debug/dynamic_debug/control
echo 'file drivers/net/wireless/ath/ath10k/mac.c +p' \
                                             > /sys/kernel/debug/dynamic_debug/control
# 看当前开了哪些
grep -c "=p" /sys/kernel/debug/dynamic_debug/control
# 用完关掉
echo 'file net/mac80211/* -p' > /sys/kernel/debug/dynamic_debug/control
```

**价值**：能回答"`key_hw_accel` 到底拦在哪个函数、`drv_set_key` 有没有被调、软解路径存不存在"。

→ **把 §2.3"改哪一行"从猜测变成确定。** 如果发现软解路径**根本不存在**（比如钩子直接把 key 标志改死），那 W1 的改法会是另一个形状（要补路径，不只是加开关），**成本评估完全不同** —— 这就是为什么必须先看。

⚠️ 会显著增加串口/dmesg 输出量，**配合串口记录器用，用完就关**。

### 3.3 regdb 双文件替换 —— 顺便解掉 ch12/ch13，**并验证"签名假设"**

**为什么 `apt-get --reinstall wireless-regdb` 大概率无效**：

内核开着 `CONFIG_CFG80211_REQUIRE_SIGNED_REGDB=y` + `CONFIG_CFG80211_USE_KERNEL_REGDB_KEYS=y` → cfg80211 要求 `regulatory.db` 必须**带有效签名**（伴随文件 `/lib/firmware/regulatory.db.p7s`），且**用内核自己内置的 key 验证**。

那句报错的完整原文是：

```
regulatory.db is malformed or signature is missing/invalid
```

—— "malformed" 只是**前半句**，"签名缺失/无效"才是常见原因。**如果是签名问题，重装同一个包一百次也没用**（除非 Debian 包里那份签名的 key 恰好被内核信任）。

**正解（零成本，不重编）**：内核源码树在构建时会把**配套的、用它内置 key 签过的**这两个文件装到 `/lib/firmware/`：

```bash
# 在内核源码树里找到它们
find <6.12.95 源码树> -name "regulatory.db*"
# 通常在 net/wireless/ 或构建产物里

# 拷到设备
scp regulatory.db regulatory.db.p7s z17s:/lib/firmware/
# 重新加载（健康态）
modprobe -r cfg80211 && modprobe cfg80211     # 或直接 reboot
iw reg get                                     # 期望：不再退到 country 99
```

**先验证假设**（设备在线时 5 秒）：

```bash
ls -la /lib/firmware/regulatory.db*
dmesg | grep -i regulatory
```

- 只有 `.db`、**没有 `.p7s`** → 签名假设成立，拷两个文件即可 ✅
- 两个都在但还是失败 → key 不匹配（或 regdb 格式比内核新），这时才需要考虑**关掉 `REQUIRE_SIGNED_REGDB` 重编 `cfg80211.ko`**（它也是模块 `CONFIG_CFG80211=m`，同样不用刷 boot）

> 收益上限不大（只是解 ch12/ch13，不算"修好 Wi-Fi"），但**成本几乎为零**，而且能顺手确认"这个内核信哪把 key" —— 对后续任何固件/监管域操作都有用。
> 原方案的"重装 `wireless-regdb`"如果照做，最可能的结果是**什么都没变**。

---

## 4 取证实装：**必须刷 boot，建议与 W1 拆开**

已确认四个开关**全都没开**（`SOFTLOCKUP_DETECTOR` / `DETECT_HUNG_TASK` / `MAGIC_SYSRQ` / `PSTORE`），所以要加就得重编。**但它们不是模块**，装不进 `.ko` —— **"W1 免刷 boot"这个便宜不能延伸到它们头上。**

| 开关 | 收益 | 代价 |
|---|---|---|
| `CONFIG_SOFTLOCKUP_DETECTOR` + `CONFIG_DETECT_HUNG_TASK` | §13 的 RCU stall 三次复现，开了才能在卡死时**打出谁在卡**（现在只能靠 `g`/`softirq=` 冻结这种间接判据） | 编进 `Image` → **刷 boot** |
| `CONFIG_MAGIC_SYSRQ` | 卡死时能强制 `sync` + `reboot`，保护 UFS | 同上；⚠️ **还要求 PC 侧能"写"串口**（见下） |
| `CONFIG_PSTORE` + `CONFIG_PSTORE_RAM` | 崩溃/断电前最后一段日志落盘 | 同上，**且要求 DTS 有 `ramoops` 节点** |
| `CONFIG_DEBUG_INFO` | 堆栈带行号 | **建议不加** —— 现在 `KALLSYMS=y`，堆栈已有函数名；加调试信息会让内核明显变大（当前镜像 37 MB / 分区 64 MB） |

⚠️ **`PSTORE` 的前置条件要先查**：`CONFIG_RAMOOPS` 当前也没开，而 ramoops 需要 **DTS 里有节点**。本仓库 `kernel/` 里没有 DTS 源，得在 WSL 源码树里确认：

```bash
grep -rn "ramoops" <源码树>/arch/arm64/boot/dts/qcom/*nx595j* 2>/dev/null
```

没有节点 → 要改 DTS → 改 DTB → 又是刷 boot + AVB 签名。**这一项可能是四个里最贵的，别默认它"顺手"**。

⚠️ **SysRq 的一个隐性前置**：现在 PC 侧串口记录器是**只读打开**的，**发不出 BREAK / SysRq 序列**。要让 `MAGIC_SYSRQ` 真正可用，记录器需要支持写入。这属于额外工作，建议**单独排期**，不要混进内核那一轮。

**为什么建议拆开（而不是原方案的"合并成一次"）**：

- W1（换 `.ko`）**零刷机风险**；取证开关（刷 boot）**有风险且要 AVB 签名**。
- 合在一起，一旦出问题你**分不清是 W1 无效还是新 boot 引入的**。这台机器的诊断史已经够复杂了，**变量要干净**。
- 拆开只多一次重启，换来的可归因性是值得的。

---

## 5 C1b：手机卡经 PC 中转 —— 形态要换（⚠️ 会撞网段）

**原理没问题**：这台机器出公网靠 PC 的 ICS/WinNAT，**上行是谁 NAT 根本不关心**。所以"PC 的上行换成 4G"确实能把网喂给 Z17S。

**但原方案选的形态有坑**：它建议"手机**USB 网络共享**插 PC"，并认为"既有 WinNAT 绑的是网段、不绑网卡实例，照常工作"。

⚠️ **问题在于网段会撞**：

- Windows 的 ICS / 移动热点**默认就用 `192.168.137.0/24`，网关恰好是 `192.168.137.1`**
- 而 `z17s-usb` 这个 NAT 用的**正是** `192.168.137.0/24`，Z17S 的 `usb0` 是静态 `192.168.137.2/24`、网关指向 `.1`
- 手机 USB 共享插进来 → Windows 极可能把 `192.168.137.1` 分配给手机那块网卡 → **PC 上同时存在两个 `192.168.137.x` 接口**

这正好对应之前的实测结论：**"谁的网被蹭谁当网关"** —— 只有一台设备能拿到 `.1`。后果是 Z17S 出网**时通时不通，或彻底不通**。

✅ **推荐形态：手机开 Wi-Fi 热点，PC 连热点。**

- Android 自带热点默认 `192.168.43.1/24` —— **和 `192.168.137.0/24` 不撞** ✅
- PC 的上行变成"Wi-Fi 到手机"，`z17s-usb` 照常把网 NAT 给 Z17S
- **零配置、零风险、立刻可用**

✅ **或者一劳永逸（推荐顺手做）**：把 Z17S 那条 NAT 挪到独立网段

```powershell
# Windows 侧（管理员）——思路，具体按现有 setup-rndis.cmd 的方式调整
Get-NetNat | Format-List Name,InternalIPInterfaceAddressPrefix
# 把 z17s-usb 改到 192.168.138.0/24，并同步改 usb0 的 ipv4.addresses/网关
```

这样以后**任何上行都不会撞**（无论手机是 USB 共享还是热点）。

**判据**：

```powershell
Get-NetNat                                    # 看 InternalIPInterfaceAddressPrefix
route print | Select-String "192.168.137"     # 出现两个接口 = 撞了
```

**剩下唯一的缺点**：必须连着 PC。而这正是这台机器的常态（USB 线同时供网 + 串口）。

---

## 6 C1a：4G dongle 直插 Z17S —— 判断对，但成本比原估更高

**§ 你先验 `dr_mode` / `usb_role` 的判断完全正确**，这一条确实被之前的"买随身 WiFi 插上去"低估了。验证命令保留：

```bash
for f in $(find /proc/device-tree -name dr_mode); do echo -n "$f: "; cat "$f"; echo; done
ls /sys/class/usb_role/ 2>/dev/null
ls /sys/class/udc/
```

**但要把成本说全 —— 比"改 DTS 重编"更麻烦**：

1. **物理互斥是硬事实**：同一个 USB-C 口**不可能同时**当 device（连 PC）和 host（插 dongle）。这不是配置问题。
2. **要当 host 得改 DTS**（`dr_mode = "otg"` 或 `"host"`）→ 改 DTB → **刷 boot + AVB 签名**。
3. **供电**：4G dongle 通常要额外供电（带供电的 hub 或 OTG + 外接电源）。
4. 🔴 **最要紧的一条**：**一旦它当 host，就没法连 PC —— 于是同时失去 SSH + 串口救援 + `usb0` 网络**，只剩 TWRP 组合键。
   对一台"开机约 7 分钟可能热崩"的机器，这个处境很差：**出问题时你连不上它**。

→ **建议把 C1a 降到最低优先级**：

- **不要为了 C1a 专门开机**。下次开机时顺便跑那三条命令，把结果记下来就够了。
- **只有在 W1 成功之后**才重新评估 —— 那时 Wi-Fi 稳定，可以当管理/救援通道，才谈得上"切断 USB"的代价。
- 而 W1 成功之后……你其实**不再需要 dongle** 了：让 4G 随身 WiFi 开个热点，Z17S 走 Wi-Fi 连它即可（这正是 § 想的联动，判断正确）。

**结论**：C1a 的实际门槛是"改 DTS + 重编 + 刷 boot + 外接供电 + 主动放弃救援通道"，**不是"买一个插上"**。在 W1 有结论之前不建议投入任何硬件钱。

---

## 7 修订后的执行顺序

| # | 动作 | 成本 | 风险 | 何时 |
|---|---|---|---|---|
| **0** | **W0 三条探针**：`ls /sys/module/mac80211/parameters/`、`grep -a key_hw_accel *.ko`、`ls /lib/firmware/regulatory.db*` | 5 分钟 | 无 | **下次开机第一件事** |
| **1** | `iw dev wlan0 set power_save off` 试形态②（§3.1） | 2 分钟 | 无 | 同上 |
| **2** | `dyndbg` 打开 key/tx 路径，看清 `key_hw_accel` 拦在哪（§3.2） | 10 分钟 | 无 | 同上 |
| **3** | regdb 双文件替换，解 ch12/ch13 + 验证签名假设（§3.3） | 5 分钟 | 无 | 同上 |
| **4** | **C1b**：手机开 Wi-Fi 热点给 PC（**不是 USB 共享**） | 零 | 无 | 今天随时 |
| **5** | **W1**：按 §2.2 分支 —— 是参数就 `echo`，否则只换 `mac80211.ko` | 半天内 | **低**（失败只丢 Wi-Fi） | 环境确认后 |
| **6** | 刷 boot 加取证开关（`SOFTLOCKUP`+`HUNG_TASK`+`SYSRQ`；PSTORE 先查 ramoops） | 半天 | **中**（AVB 签名 + 刷 boot） | **W1 有结论后** |
| **7** | C1a 的 `dr_mode` 验证 | 5 分钟 | 无 | **顺便**，不专门开机 |
| **8** | C1a 落地（改 DTS） | 高 | 高 | 只在 W1 成功后评估 |

**并行关系**：#0–#4 可以一次开机全做完；#5 与 #6 **串行**（变量要干净）；#7 搭在 #0 那一次开机上。

---

## 8 不要重复做的事

已在 [硬件现状.md §一](硬件现状.md) 实测全灭，**别再花时间**：

| 方向 | 已验结果 |
|---|---|
| `cryptmode=1` 强制软解（ath10k 侧） | ❌ 被驱动在 probe 阶段拒绝 |
| 换 `WLAN.HL.2.0` 新固件 | ❌ MSS 崩溃循环，比原来更糟 |
| 查上游 6.17 / 一加 7T（同款 WCN3990） | ❌ 同样必崩 → 无可移植修复 |
| `modprobe -r ath10k_snoc` 再加载 | ❌ `wlan0` 之后再也不出现 |
| `iw reg set CN` | ❌ 无效（`regulatory.db` 被拒，退到 `country 99`） |
| **在固件已崩的状态下动 `wlan0`** | 🔴 **会触发整机复位** —— 只能 `nmcli radio wifi off` 止损 |

**当前唯一能用的固件 = 原厂 `HL1.0-01352`**，备份在设备 `/root/fwbackup/`。

---

## 9 如果真要重编：必须改的配置清单

（**W1 走"换 .ko"就不需要本节**；只有 §4 取证开关才需要刷 boot）

**必改（原版 defconfig 的坑，见 [../kernel/README.md](../kernel/README.md)）**：

```
CONFIG_CGROUP_BPF=y              # 缺它任何容器都起不来
CONFIG_RPMSG_QCOM_SMD=y          # 绝不能是 =m（会连带 UFS 的 supplier 变模块 → 卡死在 UFS 等待循环）
```

**本次要新增（按需）**：

```
CONFIG_SOFTLOCKUP_DETECTOR=y     # §13 的 RCU stall 需要它打出阻塞者
CONFIG_DETECT_HUNG_TASK=y
CONFIG_MAGIC_SYSRQ=y             # ⚠️ 还要 PC 侧能写串口才有用
# CONFIG_PSTORE=y                # 先确认 DTS 有 ramoops 节点，否则这一项要连带改 DTS
# CONFIG_PSTORE_RAM=y
CONFIG_DEBUG_INFO_NONE=y         # 建议保持（KALLSYMS 已够；加了内核会明显变大）
```

**闸门（每次都必须过）**：

```bash
# 1) 与设备真实配置逐行 diff，只允许你"有意改"的那几行有差异
ssh z17s 'zcat /proc/config.gz' > config-running-new.txt
diff -u kernel/config-6.12.95-running.txt config-running-new.txt | grep -E '^[+-]CONFIG'

# 2) abootimg -k 收的是 Image.gz + DTB×3 拼接（按单份 DTB 算大小 → 刷进去必然起不来）

# 3) 刷前：boot 分区未被挂载（mount | grep sde18 应无输出）
# 4) 刷后：只回读"写入的那一段"比 md5，绝不能比整盘（37MB 镜像 vs 64MB 分区）

bash scripts/flash-boot-cgroupbpf.sh    # 现有脚本已含备份 → 写入 → 回读校验 → 装模块 → depmod
```

---

## 10 一句话总结

> **方向对，但要重新分配成本**：W1 的关键优势不是"改源码"，而是**它是模块 —— 只换一个文件就行**，风险从"可能变砖"降到"最多没 Wi-Fi"；
> 而在动它之前，有**三条零成本的路**（模块参数探测 / `power_save off` / `dyndbg` 看路径）可能直接把问题问清甚至解决；
> C1b 换成"手机 Wi-Fi 热点"才是真的零改动；C1a 的代价比原估高（要放弃救援通道），排在最后。

---

## 相关文档

| 文档 | 看什么 |
|---|---|
| [硬件现状.md](硬件现状.md) | Wi-Fi 三形态、根因、已穷尽的尝试、蜂窝的 IPA 定性 |
| [项目总览.md](项目总览.md) | 设备/项目信息一页看完；Wi-Fi 与蜂窝的对照分析 |
| [../kernel/README.md](../kernel/README.md) | 内核构建流程、两个必改配置、刷写与验证清单 |
| [修复记录.md](修复记录.md) §12/§13/§16/§17 | `RPMSG_QCOM_SMD` 坑、RCU stall、`ttyGS0`、半死态 |
| [日志与取证.md](日志与取证.md) | 串口记录器用法、三层日志 |
