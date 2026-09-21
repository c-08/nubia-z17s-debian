#!/bin/bash
# =============================================================================
#  Z17S Debian 13 —— 从 PC 侧流式拉取根文件系统备份（T2）
#
#  在 PC 上运行（Git Bash / WSL / Linux 均可）。设备端**只读不写、不压缩**，
#  把 IO 和 CPU 压力压到最低 —— 这是 2026-09-21 那次"备份把整机跑死"之后
#  改成的方案（原因见 docs/备份与恢复.md）。
#
#  用法：
#    ./pull-rootfs.sh                     # → /d/z17s-backup/<时间戳>/50-rootfs-sda10.tar.gz
#    ./pull-rootfs.sh --out DIR           # 指定输出根目录
#    ./pull-rootfs.sh --slim              # 再排除 docker overlay2 / 日志 / 缓存（体积小很多）
#    ./pull-rootfs.sh --host z17s         # 指定 ssh 别名（默认 z17s，见 ~/.ssh/config）
#    ./pull-rootfs.sh --no-compress       # 不压缩（裸 tar，PC 侧零 CPU，但体积大）
#
#  前置条件：
#    · PC 侧 ~/.ssh/config 里有 `Host z17s`（见 README「三种进设备的方式」）
#    · 设备已通电并接 USB；**建议接充电器**，不要只靠 PC 的 USB 口供电
# =============================================================================
set -euo pipefail

HOSTNAME_SSH="z17s"
OUTROOT="/d/z17s-backup"
SLIM=0
COMPRESS=1

while [ $# -gt 0 ]; do
    case "$1" in
        --out)          OUTROOT="$2"; shift 2 ;;
        --slim)         SLIM=1; shift ;;
        --host)         HOSTNAME_SSH="$2"; shift 2 ;;
        --no-compress)  COMPRESS=0; shift ;;
        -h|--help)      sed -n '2,25p' "$0"; exit 0 ;;
        *)              echo "未知参数: $1" >&2; exit 2 ;;
    esac
done

command -v ssh >/dev/null || { echo "✗ 找不到 ssh" >&2; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="$OUTROOT/$STAMP"
mkdir -p "$DEST"

# 归档文件名：与 backup-system.sh 的编号约定一致
if [ "$COMPRESS" = "1" ]; then
    ARCHIVE="$DEST/50-rootfs-sda10.tar.gz"
else
    ARCHIVE="$DEST/50-rootfs-sda10.tar"
fi

echo "======================================================================"
echo " 设备侧根分区流式备份"
echo "   来源 : $HOSTNAME_SSH （/dev/sda10 → /）"
echo "   输出 : $ARCHIVE"
echo "   模式 : $([ "$COMPRESS" = 1 ] && echo '设备 tar 不压缩 + PC 侧 gzip -1' || echo '裸 tar，不压缩')"
[ "$SLIM" = 1 ] && echo "   slim : 已启用（排除 docker overlay2 / 日志 / 缓存）"
echo "======================================================================"

# --- 设备侧命令 -------------------------------------------------------------
# 要点：
#   · `tar -cf -` 不压缩 —— 压缩是 CPU 大户，放到 PC 上做
#   · `nice -n 19`  + `ionice -c3`（Idle 级）—— 让备份给系统里其他一切让路
#   · `--one-file-system` —— 不跨挂载点，自动跳过 /proc /sys /dev /run /mnt
#   · 排除模式一律用**相对**写法 `./xxx`：
#     实测 GNU tar 1.35 里 `--exclude=/root/xxx` 匹配不上成员名 `./root/xxx`，
#     会**静默失效**（这正是上次把归档文件打进自己的原因）
REMOTE_CMD='set -e
IONICE=""
command -v ionice >/dev/null 2>&1 && IONICE="ionice -c3"
nice -n 19 $IONICE tar -C / --one-file-system \
  --exclude=./proc --exclude=./sys --exclude=./dev --exclude=./run \
  --exclude=./tmp --exclude=./mnt --exclude=./media --exclude=./lost+found \
  --exclude=./root/z17s-backup \
  '"$([ "$SLIM" = 1 ] && echo '  --exclude=./var/lib/docker/overlay2 --exclude=./var/cache --exclude=./var/log --exclude=./var/lib/apt/lists ')"' \
  -cf - .'

echo "[1/4] 开始拉取（首次约 5–15 分钟，取决于体积和 USB 速度）..."
echo "      设备端只读；期间不要跑其他重 IO 任务"

START=$(date +%s)
if [ "$COMPRESS" = "1" ]; then
    # shellcheck disable=SC2029
    ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=6 "$HOSTNAME_SSH" "$REMOTE_CMD" \
        | gzip -1 > "$ARCHIVE"
    RC=${PIPESTATUS[0]}
else
    # shellcheck disable=SC2029
    ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=6 "$HOSTNAME_SSH" "$REMOTE_CMD" \
        > "$ARCHIVE"
    RC=$?
fi
ELAPSED=$(( $(date +%s) - START ))

if [ "$RC" != "0" ]; then
    echo "✗ 拉取中断（ssh/tar 退出码 $RC），用时 ${ELAPSED}s" >&2
    echo "  已写入的部分保留在: $ARCHIVE" >&2
    echo "  → 先确认设备是否还在线：ping + ssh 测试；必要时重启设备后重跑本脚本" >&2
    exit 1
fi

SIZE="$(du -h "$ARCHIVE" | cut -f1)"
echo "[2/4] 拉取完成，用时 ${ELAPSED}s，大小 $SIZE"

echo "[3/4] 校验归档可读性（列出前几个成员，确认不是半截文件）..."
if [ "$COMPRESS" = "1" ]; then
    tar tzf "$ARCHIVE" 2>/dev/null | head -5 || { echo "✗ 归档不可读！" >&2; exit 1; }
else
    tar tf "$ARCHIVE" 2>/dev/null | head -5 || { echo "✗ 归档不可读！" >&2; exit 1; }
fi

echo "[4/4] 生成校验值..."
( cd "$DEST" && md5sum ./* > MD5SUMS.txt )
cat "$DEST/MD5SUMS.txt"

echo
echo "✓ 完成。产物: $DEST"
echo "  恢复步骤见 docs/备份与恢复.md"
