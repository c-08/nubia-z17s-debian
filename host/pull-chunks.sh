#!/bin/bash
# =============================================================================
#  pull-chunks.sh —— 分块 + 限速 + 可续传 地拉取设备数据
#
#  为什么不用 pull-rootfs.sh 一把梭：
#    2026-09-21 实测，设备侧 `tar -C / -cf - . > /dev/null`（纯读盘、不走网络）
#    可以完整跑完；但同一份数据走 SSH/RNDIS 推出去时，设备会在 2 分钟量级
#    **整机硬卡死**（RCU stall，需断电重启）。
#    结论：RNDIS 不能用来搬整盘。改成小分块 + PC 侧限速，把通路压力压下来，
#    并把"最重要的数据"排在前面 —— 万一中途挂了，已经拿到的都是最有价值的。
#
#  用法：
#    ./pull-chunks.sh                          # profile=core（配置类，最小、最重要）
#    ./pull-chunks.sh --profile data           # + 固件 / var 状态 / home / 内核模块
#    ./pull-chunks.sh --profile full           # + 整个 usr + docker（最大，风险最高）
#    ./pull-chunks.sh --chunks 10,20,30        # 只拉指定块
#    ./pull-chunks.sh --rate 1m                # 限速更狠（默认 2m）
#    ./pull-chunks.sh --rate 0                 # 不限速
#    ./pull-chunks.sh --host root@192.168.137.2 --identity ~/.ssh/z17s_ed25519
#
#  特性：
#    · 已存在且 gzip 完好的分块会**自动跳过**（可反复重跑续传）
#    · 每块之间 sleep（--settle，默认 5s）让设备缓一缓
#    · 第一块失败就停下，不反复冲击已经出问题的设备
#    · 结束后生成 MANIFEST.md
# =============================================================================
set -euo pipefail

HOST="z17s"
OUTROOT="./z17s-chunks"
PROFILE="core"
CHUNKS_SEL=""
RATE="2m"
SETTLE=5
IDENT=""
PYTHON=""

while [ $# -gt 0 ]; do
    case "$1" in
        --host)     HOST="$2"; shift 2 ;;
        --identity) IDENT="$2"; shift 2 ;;
        --out)      OUTROOT="$2"; shift 2 ;;
        --profile)  PROFILE="$2"; shift 2 ;;
        --chunks)   CHUNKS_SEL="$2"; shift 2 ;;
        --rate)     RATE="$2"; shift 2 ;;
        --settle)   SETTLE="$2"; shift 2 ;;
        --python)   PYTHON="$2"; shift 2 ;;
        -h|--help)  sed -n '2,30p' "$0"; exit 0 ;;
        *)          echo "未知参数: $1" >&2; exit 2 ;;
    esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
THROTTLE="$HERE/net-throttle.py"

# ---------- 找一个能用的 python（限速器要用） --------------------------------
if [ -z "$PYTHON" ]; then
    for c in python3 python; do
        command -v "$c" >/dev/null 2>&1 && { PYTHON="$c"; break; }
    done
fi
[ -n "$PYTHON" ] || { echo "✗ 找不到 python，限速器无法运行（可用 --python 指定路径）" >&2; exit 1; }
[ -f "$THROTTLE" ] || { echo "✗ 缺少 net-throttle.py（应与本脚本同目录）" >&2; exit 1; }

command -v ssh >/dev/null || { echo "✗ 找不到 ssh" >&2; exit 1; }

# ---------- 分块定义 ---------------------------------------------------------
# 格式： 名称 | tar 路径参数 | 排除项
# ⚠️ 排除项**不能**带 ./ 前缀：本脚本用「路径参数」形式调用 tar，
#    成员名是 `root/...` 而不是 `./root/...`。写错会**静默失效**（实测 tar 1.35）。
#    对照：`tar -C / -cf - .` 的成员是 ./root/... 才需要 ./ 前缀。
CHUNK_DEFS=(
  "10-etc|etc|etc/mtab"
  "20-usr-local|usr/local|"
  "30-root-core|root|root/z17s-backup root/qlparts root/1panel-src root/*.tar.gz root/*.img root/*.tar root/*.deb"
  "40-opt|opt|"
  "50-usr-lib-firmware|usr/lib/firmware|"
  "55-var-lib-state|var/lib|var/lib/docker"
  "60-home|home|"
  "65-usr-lib-modules|usr/lib/modules|"
  "70-usr-rest|usr|usr/lib/modules usr/lib/firmware usr/share/doc usr/share/man usr/src usr/share/locale"
  "80-var-log|var/log|"
  "90-var-lib-docker|var/lib/docker|"
)

case "$PROFILE" in
    core) WANT="10 20 30 40" ;;
    data) WANT="10 20 30 40 50 55 60 65" ;;
    full) WANT="10 20 30 40 50 55 60 65 70 80 90" ;;
    *)    echo "✗ 未知 profile: $PROFILE（可选 core / data / full）" >&2; exit 2 ;;
esac
[ -n "$CHUNKS_SEL" ] && WANT="$(echo "$CHUNKS_SEL" | tr ',' ' ')"

# ---------- 输出目录 ---------------------------------------------------------
STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="$OUTROOT/$STAMP"
mkdir -p "$DEST"

# ---------- ssh 选项 ---------------------------------------------------------
SSH_OPTS=(-o ServerAliveInterval=30 -o ServerAliveCountMax=6 -o ConnectTimeout=10)
if [ -n "$IDENT" ]; then
    SSH_OPTS+=(-i "$IDENT" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no
               -o UserKnownHostsFile=/dev/null)
fi

echo "======================================================================"
echo " 分块拉取   profile=$PROFILE   限速=$RATE   块=$WANT"
echo " 输出: $DEST"
echo "======================================================================"

# ---------- 前置探测 ---------------------------------------------------------
if ! timeout 15 ssh "${SSH_OPTS[@]}" -o BatchMode=yes "$HOST" "true" 2>/dev/null; then
    echo "✗ 设备不可达。先确认：ping 192.168.137.2 / 串口是否有反应" >&2
    echo "  若设备已卡死，需长按电源 15 秒强断电后再开机。" >&2
    exit 1
fi
echo "[探测] 设备可达 ✓"
DEV_INFO="$(timeout 20 ssh "${SSH_OPTS[@]}" -o BatchMode=yes "$HOST" \
    'uptime | sed "s/^ *//"; df -h / | tail -1' 2>/dev/null || true)"
echo "$DEV_INFO" | sed 's/^/       /'
echo

# ---------- 逐块拉取 ---------------------------------------------------------
OK_LIST=()
FAIL_LIST=()
TOTAL_BYTES=0

for want in $WANT; do
    DEF=""
    for d in "${CHUNK_DEFS[@]}"; do
        case "$d" in "$want-"*) DEF="$d"; break ;; esac
    done
    [ -n "$DEF" ] || { echo "⚠ 未找到块 $want，跳过"; continue; }

    NAME="${DEF%%|*}"; REST="${DEF#*|}"
    PATHS="${REST%%|*}"; EXCLS="${REST#*|}"

    ARCHIVE="$DEST/$NAME.tar.gz"

    # 续传：已存在且 gzip 完好就跳过
    if [ -f "$ARCHIVE" ] && gzip -t "$ARCHIVE" 2>/dev/null && \
       tar tzf "$ARCHIVE" >/dev/null 2>&1; then
        SZ=$(stat -c %s "$ARCHIVE" 2>/dev/null || echo 0)
        echo "[跳过] $NAME（已存在且完好，$((SZ/1048576)) MiB）"
        OK_LIST+=("$NAME")
        continue
    fi

    # 组装远端命令
    EXCL_ARGS=""
    for e in $EXCLS; do EXCL_ARGS="$EXCL_ARGS --exclude=$e"; done

    REMOTE_CMD="IONICE=\"\"; command -v ionice >/dev/null 2>&1 && IONICE=\"ionice -c3\"
nice -n 19 \$IONICE tar -C / $EXCL_ARGS -cf - $PATHS"

    echo "[拉取] $NAME  (路径: $PATHS)"
    [ -n "$EXCLS" ] && echo "       排除: $EXCLS"
    echo "       限速: $RATE"

    T0=$(date +%s)
    set +e
    # shellcheck disable=SC2029
    timeout 1800 ssh "${SSH_OPTS[@]}" "$HOST" "$REMOTE_CMD" 2>"$DEST/$NAME.ssh.log" \
        | "$PYTHON" "$THROTTLE" --rate "$RATE" 2>"$DEST/$NAME.throttle.log" \
        | gzip -1 > "$ARCHIVE"
    RC=${PIPESTATUS[0]}
    set -e
    T1=$(date +%s)

    if [ "$RC" != "0" ]; then
        echo "✗ $NAME 失败（ssh/tar 退出码 $RC，用时 $((T1-T0))s）" >&2
        [ -s "$DEST/$NAME.ssh.log" ] && tail -5 "$DEST/$NAME.ssh.log" >&2
        echo
        echo "  ⇒ 立刻停手，后续块不再尝试（避免反复冲击设备）。" >&2
        echo "    若设备已不可达：长按电源 15 秒强断电 → 开机 → 重跑本脚本（已完成的块会自动跳过）。" >&2
        FAIL_LIST+=("$NAME")
        break
    fi

    # 校验
    if ! gzip -t "$ARCHIVE" 2>/dev/null; then
        echo "✗ $NAME 归档损坏（gzip 校验不过）" >&2
        FAIL_LIST+=("$NAME")
        break
    fi
    SZ=$(stat -c %s "$ARCHIVE" 2>/dev/null || echo 0)
    CNT=$(tar tzf "$ARCHIVE" 2>/dev/null | wc -l)
    echo "       ✓ ${SZ} 字节 / ${CNT} 个成员 / $((T1-T0))s"
    OK_LIST+=("$NAME")
    TOTAL_BYTES=$((TOTAL_BYTES + SZ))

    sleep "$SETTLE"
done

# ---------- 生成 MANIFEST ----------------------------------------------------
{
    echo "# 分块备份 MANIFEST"
    echo
    echo "- 时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "- profile: $PROFILE   限速: $RATE"
    echo "- 设备: $(echo "$DEV_INFO" | head -1)"
    echo
    echo "## 已获取"
    echo
    for n in "${OK_LIST[@]:-}"; do
        [ -n "$n" ] || continue
        f="$DEST/$n.tar.gz"
        if [ -f "$f" ]; then
            echo "- \`$n.tar.gz\` — $(stat -c %s "$f" 2>/dev/null) 字节"
        fi
    done
    if [ "${#FAIL_LIST[@]}" -gt 0 ]; then
        echo
        echo "## ⚠ 失败"
        echo
        for n in "${FAIL_LIST[@]}"; do echo "- \`$n\`（原因见 $n.ssh.log）"; done
    fi
    echo
    echo "## 归档内的成员名形态"
    echo
    echo '用「路径参数」形式打包，成员名**没有** `./` 前缀，例如 `etc/hostname`、`root/z17s-backup`。'
    echo
    echo "恢复示例（在设备的 / 下展开）："
    echo
    echo '```bash'
    echo 'tar -C / -xzf <某块>.tar.gz'
    echo '```'
    echo
    echo "## 校验"
    echo
    echo '```bash'
    echo 'for f in *.tar.gz; do gzip -t "$f" && echo "$f OK"; done'
    echo '```'
} > "$DEST/MANIFEST.md"

# 汇总校验值
( cd "$DEST" && md5sum ./*.tar.gz > MD5SUMS.txt 2>/dev/null || true )

echo
echo "======================================================================"
echo " 完成: 成功 ${#OK_LIST[@]} 块 / 失败 ${#FAIL_LIST[@]} 块，共 $((TOTAL_BYTES/1048576)) MiB"
echo " 产物: $DEST"
[ "${#FAIL_LIST[@]}" -gt 0 ] && exit 1
exit 0
