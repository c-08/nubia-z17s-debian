#!/bin/bash
# =============================================================================
#  Z17S Debian 13 —— 系统备份（设备侧 T1 轻量档）
#
#  用法：
#    bash backup-system.sh [输出目录]        # 默认 /root/z17s-backup
#
#  ⚠️ 本脚本**故意不打包根文件系统**。
#     2026-09-21 实测：在设备上就地 tar 整个 `/` 会在数分钟内把内核拖进
#     RCU stall 硬卡死（整机失去 USB、只能强断电）。原因见
#     docs/备份与恢复.md 「⚠️ 为什么不在设备上打包根分区」。
#     根分区请改用 PC 侧流式拉取： host/pull-rootfs.sh
#
#  本脚本产出的 T1 内容（合计约 70 MB，20 秒内完成，IO 压力极小）：
#    00-partitions.txt        分区表 + cmdline（恢复时的关键依据）
#    10-boot-sde18.img.gz     boot 分区整段（含内核，恢复开机的核心）
#    20-persist-sda2.tar.gz   persist 内容（WiFi MAC / 蓝牙 NV —— 最珍贵，丢了不可再生）
#    21-persist-sda2.img.gz   persist 分区整段（更强的恢复力）
#    30-config.tar.gz         所有 z17s 配置与脚本
#    40-packages.txt          已安装包列表（重建系统时用）
#    50-rootfs-PLAN.txt       根分区备份的执行计划（含可直接粘贴的命令）
#    MD5SUMS.txt              全部产物的校验值
#
#  ⚠️ 恢复步骤见 docs/备份与恢复.md
# =============================================================================
set -u

OUT="${1:-/root/z17s-backup}"
OUT="${OUT%/}"
STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="$OUT/$STAMP"
GZ="-1"          # 快速压缩：手机 CPU 一般，-1 省时间，压缩率损失可接受

log() { echo "[$(date +%H:%M:%S)] $*"; }

if [ "$(id -u)" != "0" ]; then
    echo "必须以 root 运行" >&2
    exit 1
fi

mkdir -p "$DEST" || exit 1
log "备份目标: $DEST"

# ---------------------------------------------------------------------------
# 00 元数据：分区表 / blkid / cmdline
# ---------------------------------------------------------------------------
log "采集分区表与元数据..."
{
    echo "# 备份时间   : $(date -Is)"
    echo "# 主机名     : $(hostname)"
    echo "# 内核版本   : $(uname -r)"
    echo "# 设备序列号 : $(cat /proc/cmdline | tr ' ' '\n' | grep -m1 serialno || echo unknown)"
    echo
    echo "## 内核 cmdline（恢复时对照）"
    cat /proc/cmdline
    echo
    echo "## lsblk"
    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT
    echo
    echo "## blkid"
    blkid 2>/dev/null
    echo
    echo "## /proc/partitions"
    cat /proc/partitions
    echo
    echo "## 块设备大小"
    for d in /dev/sde18 /dev/sda2 /dev/sda10; do
        printf '%s = %s bytes\n' "$d" "$(blockdev --getsize64 "$d" 2>/dev/null || echo n/a)"
    done
    echo
    echo "## 根分区使用量（判断距上次备份的变化）"
    df -h / /mnt/persist 2>/dev/null
} > "$DEST/00-partitions.txt" 2>&1

# ---------------------------------------------------------------------------
# 10 boot 分区（含内核）—— 开机能力全在这里
# ---------------------------------------------------------------------------
log "备份 boot 分区 /dev/sde18 (64 MiB)..."
dd if=/dev/sde18 bs=4M 2>/dev/null | gzip $GZ > "$DEST/10-boot-sde18.img.gz"
log "  → $(du -h "$DEST/10-boot-sde18.img.gz" | cut -f1)"

# ---------------------------------------------------------------------------
# 20/21 persist —— WiFi MAC 与蓝牙 NV 存在这里，丢了无法再生
# ---------------------------------------------------------------------------
log "备份 persist (tar)..."
tar czf "$DEST/20-persist-sda2.tar.gz" -C /mnt/persist . 2>/dev/null
log "  → $(du -h "$DEST/20-persist-sda2.tar.gz" | cut -f1)"

log "备份 persist (整段镜像)..."
dd if=/dev/sda2 bs=1M 2>/dev/null | gzip $GZ > "$DEST/21-persist-sda2.img.gz"
log "  → $(du -h "$DEST/21-persist-sda2.img.gz" | cut -f1)"

# ---------------------------------------------------------------------------
# 30 配置与脚本
#   ⚠️ 这里是 `-C /` + 相对路径，排除/包含都按相对写法；
#      **不要**写 `--exclude=/etc/xxx` 这种绝对路径 —— GNU tar 拿它去比
#      成员名 `./etc/xxx` 是**匹配不上**的（见 50-rootfs-PLAN.txt 里的实测记录）。
# ---------------------------------------------------------------------------
log "备份 z17s 配置与脚本..."
tar czf "$DEST/30-config.tar.gz" -C / \
    etc/systemd/system \
    etc/systemd/system.conf.d \
    etc/udev/rules.d \
    etc/sysctl.d \
    etc/NetworkManager/conf.d \
    etc/NetworkManager/system-connections \
    etc/modprobe.d \
    etc/modules-load.d \
    etc/docker \
    etc/fstab \
    usr/local/sbin \
    usr/local/bin \
    2>/dev/null
log "  → $(du -h "$DEST/30-config.tar.gz" | cut -f1)"

# ---------------------------------------------------------------------------
# 40 包列表
# ---------------------------------------------------------------------------
log "导出已安装包列表..."
dpkg --get-selections > "$DEST/40-packages.txt" 2>/dev/null
log "  → $(wc -l < "$DEST/40-packages.txt") 个包"

# ---------------------------------------------------------------------------
# 50 根分区：不在这里做，只写执行计划
# ---------------------------------------------------------------------------
ROOT_USED="$(df -h --output=used / | tail -1 | tr -d ' ')"
cat > "$DEST/50-rootfs-PLAN.txt" <<PLAN
根文件系统备份计划（T2）
========================================
生成时间 : $(date -Is)
根分区   : /dev/sda10，已用 $ROOT_USED

⚠️ 为什么设备侧不做
----------------------------------------
在设备上就地 \`tar czf /root/... / \` 有两个致命问题：

1. **把输出写进了被归档的那个文件系统**，导致 tar 读到正在增长的归档文件本身
   （"file changed as we read it"），产生大量同分区读写交错；
   本机实测约 10 分钟后内核进入 RCU stall 硬卡死，USB 整个消失，只能强断电。
2. gzip 单核跑满，叠加 IO 压力，把内核里本就脆弱的存储/SMD-RPM 路径逼出问题。

正确做法：**从 PC 侧流式拉取** —— 设备端只 `tar cf -`（不压缩、不写盘），
压缩在 PC 上做。设备侧 IO 压力降到最低，且不产生任何写入。

在 PC 上执行（Git Bash / WSL / Linux 均可）：
----------------------------------------
    host/pull-rootfs.sh                 # 默认存到 /d/z17s-backup/<时间戳>/
    host/pull-rootfs.sh --slim          # 排除 docker overlay2 / 日志 / 缓存，更小更快

Windows 用户可直接双击：
    host\\windows\\pull-rootfs.cmd

拉完务必校验：
    cd <备份目录> && md5sum -c MD5SUMS.txt

PLAN

log "  → 已写出根分区备份计划: $DEST/50-rootfs-PLAN.txt"

# ---------------------------------------------------------------------------
# 校验
# ---------------------------------------------------------------------------
log "生成校验值..."
( cd "$DEST" && md5sum ./* > MD5SUMS.txt 2>/dev/null )
cat "$DEST/MD5SUMS.txt"

log "完成。产物在: $DEST"
log "总大小: $(du -sh "$DEST" | cut -f1)"
log "下一步：在 PC 上运行 host/pull-rootfs.sh 拉取根分区备份"
