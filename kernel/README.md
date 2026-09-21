# 内核构建要点

底层移植与构建脚本来自 [huanhuangyun/z17s-debian](https://github.com/huanhuangyun/z17s-debian)，
**本目录只记录"必须改什么、怎么验"** —— 因为原版 defconfig 有两个会让人白折腾一整天的坑。

- 目标内核：**主线 Linux 6.12.x**（非 Android 内核）
- 本机在跑的版本：`6.12.95+`

---

## 一、必须改的两项配置

上游 `arch/arm64/configs/z17s_defconfig` 需要改这两行，否则会分别导致「容器全崩」和「开不了机」：

### 1. `CONFIG_CGROUP_BPF=y` —— 不加则所有容器起不来

```
CONFIG_CGROUP_BPF=y
```

**不改的后果**：cgroup v2 的 device controller 需要 `BPF_PROG_TYPE_CGROUP_DEVICE`，
缺它时 `runc` 报：

```
bpf_prog_query(BPF_CGROUP_DEVICE) failed: invalid argument
```

**任何容器都起不来**（连 `alpine` 都不行），跟镜像和容器配置完全无关。

> 💡 排查提示：遇到"容器起不来"，**先用最小镜像验证是不是全盘性故障**：
> `docker run --rm alpine:3.20 echo OK`
> 如果它也失败，就别去重装应用了，直接查内核配置。

### 2. `CONFIG_RPMSG_QCOM_SMD=y` —— 不能是 `=m`

```
CONFIG_RPMSG_QCOM_SMD=y
```

**不改的后果**：这一项在 Kconfig 里是多个关键驱动的 `depends on` 上游。一旦它是 `=m`，
`olddefconfig` 会**连带**把下面这些也压成模块：

```
QCOM_SMD_RPM
QCOM_RPMPD
REGULATOR_QCOM_SMD_RPM
INTERCONNECT_QCOM_*
```

而这些是 **UFS 的 supplier（供电 / 时钟 / 互连）驱动**。它们变成模块后，依赖它们的 UFS 驱动
永远等不到 supplier → **开机卡死在 UFS 等待循环**。

> ⚠️ 这个坑的隐蔽之处：`=m` 和 `=y` 在 diff 输出里几乎看不出差别，但后果是开不了机。
> **改完 defconfig 必须逐行 diff。**

---

## 二、构建流程

```bash
# 1. 取源码（tarball + 补丁都在上游仓库的 scripts/ 里）
bash build-kernel.sh   <源码路径>
bash build-boot.sh     <源码路径>

# 产物落在 build/ 下
```

构建脚本已随仓库提供：`build-kernel.sh` / `build-boot.sh` / `build-rootfs.sh`。

### 配置闸门（强烈建议每次都做）

**用设备上正在运行的内核的真实配置作为基准**，生成的新 `.config` 与它逐行 diff。
取真值最方便的方式是直接读设备的 `/proc/config.gz`（比 `abootimg` + `extract-ikconfig` 简单得多）：

```bash
# 从设备拉取运行时配置
ssh z17s 'zcat /proc/config.gz' > config-running.txt

# 生成新配置后对比
diff -u config-running.txt .config | grep -E '^[+-]CONFIG'
```

**期望结果**：只有你有意改的那几行有差异。出现意料之外的 `=m` / `=y` 变化 → 停下来查。

### 关于 `abootimg` 的一个坑

`abootimg -k` 接受的 kernel 映像是 **`Image.gz + DTB×3` 拼接**的结果，所以：

```
kernel_size = sizeof(Image.gz) + 3 * sizeof(dtb)
```

如果手工重组 boot 镜像时按单份 DTB 算大小，刷进去必然起不来。

---

## 三、刷写

boot 分区是 `/dev/sde18`（64 MiB）。**运行时可以直接写**（该分区未挂载）：

```bash
# 见 scripts/flash-boot-cgroupbpf.sh：备份 → 写入 → 回读校验 → 装模块 → depmod
bash scripts/flash-boot-cgroupbpf.sh
```

⚠️ **三件必须注意的事**：

1. **绝不能比整盘 md5**
   镜像 37 MB、分区 64 MB，整盘 md5 必然不同。校验必须**只比写入的那一段**：
   ```bash
   dd if=/dev/sde18 bs=4194304 count=1024 | md5sum
   ```
   （或者按实际镜像长度回读）

2. **模块也要一起更新**
   内核换了必须同步安装 `modules-*.tar.gz` 并跑 `depmod`，否则驱动版本不匹配。

3. **写之前确认分区没被挂载**
   ```bash
   mount | grep sde18     # 应该没有输出
   ```

### 本次已验证的产物

| 文件 | 大小 | md5 |
|---|---|---|
| `boot-nx595j-debian13-cgroupbpf-signed.img` | 37283112 B | `272f07c471ebcf0b52dcf6754e60afbb` |
| `modules-6.12.95+-cgroupbpf.tar.gz` | — | `61ede3aa6e2ca7cd0db424939c86317b` |

### 恢复出厂 boot

最新可用备份：`flash/boot_prev_before_debian.img`（64 MiB，dd 回 `sde18` 即可）。

---

## 四、验证清单

刷完新内核后，按顺序验：

```bash
uname -r                                                  # 版本号对不对
zcat /proc/config.gz | grep CONFIG_CGROUP_BPF             # =y
docker run --rm alpine:3.20 echo CONTAINER_OK             # 容器能起
systemd-analyze time                                      # userspace 应在 1 分钟左右
systemctl is-system-running                               # running
systemctl --failed                                        # 0 failed
```

---

## 五、安全红线

| 禁止 | 原因 |
|---|---|
| 写 `persist` / `modem` / `dsp` / `vendor` / `system` 分区 | 丢失 Wi-Fi MAC、蓝牙 NV，可能变砖 |
| 加载 `ipa.ko` | 直接 boot loop |
| 在 Wi-Fi 固件已崩的状态下操作 `wlan0` | 实测会触发整机复位 |

详见仓库根目录 [README](../README.md) 与 [docs/硬件现状.md](../docs/硬件现状.md)。
