#!/bin/bash
# =============================================================================
#  Z17S Debian 13 —— 系统备份脚本（在设备上运行）
#
#  用法：
#    bash backup-system.sh [输出目录]        # 默认 /root/z17s-backup
#
#  备份内容（分层，可按需取用）：
#    00-partitions.txt        分区表 + cmdline（恢复时的关键依据）
#    10-boot-sde18.img.gz     boot 分区整段（含内核，恢复开机的核心）
#    20-persist-sda2.tar.gz   persist 内容（WiFi MAC / 蓝牙 NV —— 最珍贵，丢了不可再生）
#    21-persist-sda2.img.gz   persist 分区整段（更强的恢复力）
#    30-config.tar.gz         所有 z17s 配置与脚本
#    40-packages.txt          已安装包列表（重建系统时用）
#    50-rootfs-sda10.tar.gz   根文件系统（排除虚拟文件系统）
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
# ---------------------------------------------------------------------------
log "备份 z17s 配置与脚本..."
tar czf "$DEST/30-config.tar.gz" -C / \
    etc/systemd/system/z17s-audio-load.service \
    etc/systemd/system/z17s-early.service \
    etc/systemd/system/z17s-grow-rootfs.service \
    etc/systemd/system/z17s-netwatch.service \
    etc/systemd/system/z17s-netwatch.timer \
    etc/systemd/system/z17s-usbfallback.service \
    etc/systemd/system/z17s-usbnet.service \
    etc/systemd/system/z17s-usbnet.timer \
    etc/systemd/system/z17s-wifi-load.service \
    etc/systemd/system.conf.d \
    etc/udev/rules.d \
    etc/sysctl.d \
    etc/NetworkManager/conf.d \
    etc/NetworkManager/system-connections \
    etc/modprobe.d \
    etc/modules-load.d \
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
# 50 根文件系统
# ---------------------------------------------------------------------------
log "打包根文件系统（约 3.4G，请耐心等几分钟）..."
tar cf - \
    --one-file-system \
    --exclude=/proc \
    --exclude=/sys \
    --exclude=/dev \
    --exclude=/run \
    --exclude=/tmp \
    --exclude=/mnt \
    --exclude=/media \
    --exclude=/lost+found \
    --exclude="$OUT" \
    -C / . 2>/dev/null | gzip $GZ > "$DEST/50-rootfs-sda10.tar.gz"
log "  → $(du -h "$DEST/50-rootfs-sda10.tar.gz" | cut -f1)"

# ---------------------------------------------------------------------------
# 校验
# ---------------------------------------------------------------------------
log "生成校验值..."
( cd "$DEST" && md5sum ./* > MD5SUMS.txt 2>/dev/null )
cat "$DEST/MD5SUMS.txt"

log "完成。产物在: $DEST"
log "总大小: $(du -sh "$DEST" | cut -f1)"
