# boot 镜像的签名与恢复（🔴 改 boot 前必读）

> 事故驱动文档。2026-09-25：设备因「改了 boot 里的 ramdisk 却没重新签名」而黑屏开不了机。
> 这条坑**代价最大、现象最误导**（日志里什么都不留），所以单独成篇。

---

## 一、一句话结论

**这个设备的 boot 镜像必须签过名才能被引导器接受。
只要改动了 `boot.img` 里的**任何**字节 —— 包括只替换 initramfs 中的一个小 `.ko` ——
就必须用 `BootSignature.jar` 重新签名，否则引导器直接拒载：黑屏、卡 logo、内核日志无痕。**

> ⚠️ 最容易踩的误解是：「我只换 initramfs 里一个模块，不动内核，应该不算"改动镜像"」。
> **错。** 那 1320 字节的签名**覆盖整个 payload**（`kernel` + `ramdisk`，按页对齐）。
> 模块就在 ramdisk 里 —— 改它 = 改 payload = 签名作废。

---

## 二、怎么确认你面对的是这种镜像

### 2.1 直接验签（本地就能定案，不用刷机）

```bash
J=/root/z17s-debian/assets/signing/BootSignature.jar
java -jar $J -verify <boot镜像>
#   → "Signature is VALID"   /   "Signature is INVALID"
```

**最佳实践**：先拿一个**已知能开机**的镜像验一次（确认这套签名确实在管这个分区），
再验改动后的镜像 —— **一次定案**，不必冒着反复刷机的风险去试。

### 2.2 从结构上认出来

| 特征 | 说明 |
|---|---|
| 末尾没有 `AVBf` / `AVB0` magic | 说明**不是** mkbootimg 的 AVB，而是高通 `BootSignature.jar` 这一套 |
| payload 之后紧跟一段 1~2 KB、以 `30 82 …` 开头的数据 | 那就是签名（DER 编码的 PKCS#7 SignedData） |
| `30 82 05 24` ⇒ `0x524 + 4 = 1320` 字节 | 本机就是 1320 字节，起点 = payload 结尾 |

payload 长度算法（`pagesize` 通常 4096）：

```
payload_len = pagesize
            + align(kernel_size)
            + align(ramdisk_size)
            + align(second_size)
```

本机实测：`4096 + align(6682160) + align(30592512) = 37281792`，
签名 1320 字节 ⇒ **文件总长 37283112**。

> 📌 分区是 64 MiB，但**镜像只有 37 MB**；剩下的是**分区残留**（上一次写入留下的字节，
> `dd` 不会清零）。所以「设备上 dump 出来的 64 MiB 文件」与「构建产物」md5 不同是**正常的** ——
> 要比就比**前 37283112 字节**。

---

## 三、正确的改动流程

```bash
J=/root/z17s-debian/assets/signing/BootSignature.jar

# 0) 以「已知可用」的签名镜像为底，先备份
cp 已知可用.img /root/fwbackup/working.img

# 1) 解开（abootimg 会写出 bootimg.cfg / kernel.bin / ramdisk.cpio）
abootimg -x 已知可用.img bootimg.cfg kernel.bin ramdisk.cpio

# 2) 解 ramdisk
mkdir rd && cd rd && cpio -idm --no-absolute-filenames < ../ramdisk.cpio

# 3) ★ 改你要改的东西
#    ⚠️ 保持权限位（改完 chmod 回原值；模块一般 644）
cp 新模块.ko lib/modules/6.12.95+/kernel/drivers/net/wireless/ath/ath10k/ath10k_core.ko
chmod 644 lib/modules/6.12.95+/kernel/drivers/net/wireless/ath/ath10k/ath10k_core.ko

# 4) 重打包（格式与项目管线一致：newc）
find . -print0 | cpio --null -o --format=newc > ../ramdisk_new.cpio
cd ..

# 5) ⚠️ 手改 bootsize —— abootimg -x 从「签名后」镜像推出来的是「含签名的总长」，必须改回项目原值
sed -i 's/^bootsize = .*/bootsize = 0x4000000/' bootimg.cfg

# 6) 造未签名镜像
abootimg --create unsigned.img -f bootimg.cfg -k kernel.bin -r ramdisk_new.cpio

# 7) 签名（工具会自动把 64 MiB 截断到 payload 长度，日志会打 NOTE: truncating ...）
java -jar $J /boot unsigned.img verity.pk8 verity.x509.der signed.img

# 8) ★ 验签：必须 VALID
java -jar $J -verify signed.img
```

### 两个必踩的坑

1. **`bootsize`**：签名器会打印 `NOTE: truncating file unsigned.img from 67108864 to 37281792 bytes`
   —— 这是**正常**的。但如果你拿 `abootimg -x` 从**签名后**的镜像解出的 cfg 直接用，
   它的 `bootsize` 是 `0x238e528`（含签名总长），产物形状会变。**改回 `0x4000000`**。
2. **别自己骗自己**：解 ramdisk 时**解两份**（一份留着当"原始对照"），
   不要在同一目录里改完又拿它去 `diff`。正确结果应该是 `diff -r --brief` **只报你改的那一个文件**。

---

## 四、上机前的三重闸门（缺一不可）

```bash
# ① 签名有效
java -jar $J -verify signed.img                       # → Signature is VALID

# ② 内核段与已知可用镜像逐字节相同
abootimg -x signed.img n.cfg n.kernel.bin n.ramdisk.cpio
cmp kernel.bin n.kernel.bin && echo "kernel identical"

# ③ ramdisk 只差你改的文件
mkdir -p chk && cd chk && cpio -idm --no-absolute-filenames < ../n.ramdisk.cpio
cd .. && diff -r --brief rd_orig chk                  # → 只应有 1 行
```

三条都过 = 「除了你想改的，什么都没动，且签名有效」—— **这时候才值得去刷。**

---

## 五、开不了机时的恢复

### 5.1 先判设备状态

```powershell
# Windows：只看「在位」的设备，别看历史幽灵
Get-PnpDevice -PresentOnly -Class Ports | Select-Object Status, FriendlyName, InstanceId
```
```bash
D:\adb\fastboot.exe devices      # 有输出 → 进 fastboot
D:\adb\adb.exe devices           # 有输出 → 进 recovery/TWRP（或系统还活着）
```

⚠️ **幽灵设备陷阱**：设备管理器里可能长期留着 `Qualcomm HS-USB QDLoader 9008 (COMx)`、
`HS-USB Diagnostics 9091`，`Status` 是 **`Unknown`** —— 那是以前插过留下的记录，
**不代表设备现在在位**。判据只有 `-PresentOnly` + `fastboot/adb devices`。

### 5.2 三条通道（按优先级）—— ⚠️ 2026-09-25 实测更正

| 通道 | 条件 | 做法 |
|---|---|---|
| ~~fastboot~~ | ❌ **实测不可用，别在这里浪费时间** | 见下方"fastboot 为什么不行" |
| **TWRP + adb** | `音量上 + 电源` 能进 TWRP | **唯一可用通道**：`adb push` 后 `dd if=/tmp/boot.img of=/dev/block/sde18 bs=4096` |
| **EDL 9008** | 只剩 9008（要 firehose programmer / QFIL，本机没有） | 最后手段 |

#### 🔴 「fastboot 为什么不行」—— 2026-09-25 实机定案

设备确实能进 fastboot（`fastboot devices` → `5d6dc569 fastboot`，`getvar product` → `QC_Reference_Phone`），
但这是一个**只答极少命令的精简 XBL fastboot**，**根本没有实现 `download:` / `flash:`**：

```
fastboot flash boot boot_w1_ath10k_signed.img
  → Sending 'boot' (36409 KB)  FAILED (remote: 'unknown command')
fastboot -S 8M flash boot …    → 同样 FAILED (remote: 'unknown command')   # 与分块大小无关
fastboot reboot-bootloader     → FAILED (remote: 'unknown command')
fastboot oem device-info / oem ? / getvar:serialno / getvar:current-slot
                               → FAILED (remote: 'unknown command')
fastboot getvar version/secure/partition-size:boot
                               → FAILED (remote: 'GetVar Variable Not found')
fastboot reboot recovery       → OKAY……但设备只是普通重启（没有真的进 recovery）
```

⚠️ **`reboot recovery` 回 `OKAY` 是假信号**：设备随后走正常启动流程 ⇒ 坏 boot ⇒ logo 循环。
要进 TWRP，**只能人工按 `音量上 + 电源`**。

⚠️ 还有一条副作用：`getvar partition-size:boot` 失败 ⇒ fastboot 会打印
`skip copying boot image avb footer (boot partition size: 0…)`，那是**误导**，与签名无关。

#### TWRP 侧硬约束（详见 [备份与恢复](备份与恢复.md)）

```bash
# TWRP 是 toybox：dd 不支持 bs=1M、不支持 conv=fsync
adb push boot.img /tmp/boot.img
adb shell "dd if=/tmp/boot.img of=/dev/block/sde18 bs=4096"
adb shell "sync"
# 回读校验要限长（64 MiB = 16384 × 4096），别整盘算 md5
```

### 5.3 🔴 恢复后必须处理的配套项

如果设备上有 `/etc/modprobe.d/99-z17s-ath10k.conf`（内容 `options ath10k_core cryptmode=1`），
它**只能配打过补丁的模块**：

| 刷入的镜像 | 后果 |
|---|---|
| 补丁版（W1） | ✅ 正确 —— 这就是软解生效的开关 |
| **纯净版（原厂模块）** | ❌ `cryptmode=1` 要求固件支持 RAW_MODE，WCN3990 没有 ⇒ **ath10k probe 失败 ⇒ 彻底没有 wlan0** |

⇒ **要么刷补丁版；要么刷纯净版并同时删掉那个 conf。**

---

## 六、回退

```bash
# 只有这一条通道（fastboot 不能刷，见 §5.2）
adb push boot_orig_full64.img /tmp/boot.img
adb shell "dd if=/tmp/boot.img of=/dev/block/sde18 bs=4096"
adb shell "md5sum /dev/block/sde18"     # 必须等于 acf5c3da7bcfeabb64039caafa88c0a3
adb shell "sync; reboot"
```

设备侧另有 `/root/fwbackup/`（原模块、原 boot、回退脚本）。
PC 侧长期备份见 [备份与恢复](备份与恢复.md)（`10-boot-sde18.img.gz`）。

### 6.1 实战记录：2026-09-25 黑屏恢复（成功）

| 步骤 | 结果 |
|---|---|
| 现状存档 | `adb shell md5sum /dev/block/sde18` → `227a4829ca9d8e3cd8ea3ba0a28222cc`（= 隔壁那版未签名的坏镜像） |
| 分区几何 | `cat /sys/class/block/sde18/size` → `131072`（× 512 B = 64 MiB）；`by-name/boot → sde18` |
| 推入 | `adb push boot_w1_ath10k_full64.img /tmp/boot_w1.img`（67 108 864 B，43.7 MB/s，1.5 s） |
| 设备侧校验 | `md5sum /tmp/boot_w1.img` → `84c37378165ec191b023b63e5216f653` ✅ 与主机一致 |
| 写入 | `dd if=/tmp/boot_w1.img of=/dev/block/sde18 bs=4096` → `16384+0 records out`，0.48 s |
| 回读校验 | `md5sum /dev/block/sde18` → `84c37378165ec191b023b63e5216f653` ✅ |
| 重启 | `sync; reboot` → **T+56 s** RNDIS + 串口枚举、`ping 192.168.137.2` 通 ✅ |

关键时序（重启后）：`T+10~37 s` 只出现「USB 串行设备」（早期 ACM）→ `T+46 s` gadget 重枚举
→ `T+56 s` RNDIS + 串口 + `usb0` 就绪。**别在 45 s 之前就判"没起来"。**

---

## 七、附：本机的关键数字（便于比对）

| 项 | 值 |
|---|---|
| `pagesize` | 0x1000（4096） |
| `kernel_size` | 6682160（`Image.gz` + DTB×3，`abootimg -k` 收） |
| `ramdisk_size` | 30592512（newc cpio，512 字节块对齐） |
| payload 结尾 / 签名起点 | 37281792 |
| 签名长度 | 1320 字节 |
| **签名镜像总长** | **37283112** |
| boot 分区 | `/dev/sde18`，64 MiB |
| cmdline 关键项 | `root=/dev/ram0 rdinit=/init … z17s.rootfs=userdata` |
| 签名材料 | `assets/signing/{BootSignature.jar, verity.pk8, verity.x509.der}` |
