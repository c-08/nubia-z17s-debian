#!/bin/bash
# =============================================================================
#  Z17S Debian 13 —— 部署脚本（在设备上运行）
#
#  用法：
#    sudo bash scripts/install-on-device.sh            # 部署全部
#    sudo bash scripts/install-on-device.sh --dry-run  # 只看会改什么
#
#  做四件事：
#    1. 把 device/ 下的文件按原始绝对路径装回去
#    2. 重载 udev 与 systemd
#    3. 启用 z17s-usbnet.timer（USB 网络开机自启）
#    4. 自检并打印关键状态
# =============================================================================
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO/device"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

die() { echo "错误: $*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "必须以 root 运行（sudo bash $0）"
[ -d "$SRC" ] || die "找不到 $SRC（请在仓库根目录运行）"

# ---------------------------------------------------------------------------
# 1. 安装文件
# ---------------------------------------------------------------------------
echo "=== 1/4 安装文件 ==="
cd "$SRC" || die "无法进入 $SRC"

installed=0
while IFS= read -r rel; do
    rel="${rel#./}"
    target="/$rel"
    # shell 脚本给 755，其余 644
    case "$rel" in
        *.sh) mode=755 ;;
        *)    mode=644 ;;
    esac

    if [ "$DRY" = "1" ]; then
        printf '  [dry] install -m %s %s -> %s\n' "$mode" "$rel" "$target"
    else
        mkdir -p "$(dirname "$target")"
        install -m "$mode" "$rel" "$target" && installed=$((installed + 1))
    fi
done < <(find . -type f | sort)

[ "$DRY" = "1" ] && { echo "（dry-run 结束，未做任何改动）"; exit 0; }
echo "  已安装/更新 $installed 个文件"

# ---------------------------------------------------------------------------
# 2. 重载规则
# ---------------------------------------------------------------------------
echo "=== 2/4 重载 udev 与 systemd ==="
udevadm control --reload-rules && echo "  udev 规则已重载"
systemctl daemon-reload && echo "  systemd 已重载"

# ---------------------------------------------------------------------------
# 3. 启用必要的单元
# ---------------------------------------------------------------------------
echo "=== 3/4 启用服务单元 ==="

# USB 网络：用 timer 驱动（service 本身故意不 enable —— 挂启动关键路径会卡开机）
systemctl enable --now z17s-usbnet.timer 2>/dev/null \
    && echo "  z17s-usbnet.timer 已启用" \
    || echo "  ⚠ z17s-usbnet.timer 启用失败，请手工检查"

# 明确关闭那些已废弃的单元（历史遗留，会干扰）
for u in z17s-netwatch.timer z17s-usbfallback.service z17s-wifi-watchdog.service; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^$u"; then
        systemctl disable --now "$u" 2>/dev/null && echo "  已禁用废弃单元 $u"
    fi
done

# 让 udev 规则立即对已存在的 usb0 生效
if ip link show usb0 >/dev/null 2>&1; then
    udevadm trigger --subsystem-match=net --action=change 2>/dev/null
    echo "  已对 usb0 触发 udev 重新评估"
fi

# ---------------------------------------------------------------------------
# 4. 自检
# ---------------------------------------------------------------------------
echo
echo "=== 4/4 自检 ==="

echo "--- 系统 ---"
echo "  运行状态      : $(systemctl is-system-running 2>&1)"
echo "  失败单元数    : $(systemctl --failed --no-legend 2>/dev/null | wc -l)"
echo "  内核          : $(uname -r)"

echo "--- USB 网络 ---"
echo "  usbnet.timer  : $(systemctl is-active z17s-usbnet.timer 2>&1)"
echo "  usbnet.service: $(systemctl show -p Result --value z17s-usbnet.service 2>/dev/null || echo n/a)"

if ip link show usb0 >/dev/null 2>&1; then
    printf '  usb0 地址     : %s\n' "$(ip -4 -br addr show usb0 2>/dev/null | awk '{print $3}')"
    printf '  NM 是否接管   : %s\n' "$(nmcli -t -f GENERAL.NM-MANAGED dev show usb0 2>/dev/null | cut -d: -f2)"
    printf '  NM reason     : %s\n' "$(nmcli -t -f GENERAL.REASON dev show usb0 2>/dev/null | cut -d: -f2)"
    printf '  连接状态      : %s\n' "$(nmcli -t -f GENERAL.STATE dev show usb0 2>/dev/null | cut -d: -f2)"
else
    echo "  ⚠ usb0 不存在（timer 可能还没跑，或 gadget 建立失败）"
fi

echo "--- DNS ---"
printf '  resolv.conf   : %s\n' "$(grep -m1 nameserver /etc/resolv.conf 2>/dev/null || echo '（空 —— 检查 NM 是否接管了 usb0）')"

echo "--- 内核关键配置 ---"
if [ -r /proc/config.gz ]; then
    printf '  CGROUP_BPF    : %s\n' "$(zcat /proc/config.gz | grep -m1 CONFIG_CGROUP_BPF || echo '缺失！容器会起不来')"
    printf '  RPMSG_QCOM_SMD: %s\n' "$(zcat /proc/config.gz | grep -m1 CONFIG_RPMSG_QCOM_SMD || echo '缺失')"
else
    echo "  （无 /proc/config.gz，跳过）"
fi

echo "--- 容器运行时 ---"
if command -v docker >/dev/null 2>&1; then
    printf '  docker        : %s\n' "$(docker --version 2>&1)"
    printf '  容器测试      : %s\n' "$(timeout 30 docker run --rm alpine:3.20 echo OK 2>&1 | tail -1)"
else
    echo "  docker 未安装"
fi

echo
echo "完成。"
echo
echo "下一步（在 PC 上）："
echo "  双击 host/windows/setup-rndis.cmd 给设备共享网络"
echo "  ⚠ 设备每次重启后都要重跑一次"
