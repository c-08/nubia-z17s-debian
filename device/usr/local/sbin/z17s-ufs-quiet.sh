#!/bin/sh
# =============================================================================
#  Z17S —— 抑制 UFS 的运行时电源 / 调频抖动（RCU stall 缓解）
#
#  背景：见 docs/修复记录.md §13 与 §17.6
#    高 IO 任务跑起来后会看到：
#        l26: failed to set load 560000: -ETIMEDOUT
#        ufshcd-qcom 1da4000.ufshc: ufshcd_config_vreg_load:
#            vccq set load (ua=560000) failed, err=-110
#    紧接着 RCU stall 级联（load 只增不减），最后整机停摆 / 半死态，只能长按电源 15 秒。
#
#    `vccq set load` 是 UFS 在 HPM/LPM 之间切换时，对 VCCQ 供电轨发出"负载电流改成 560mA"
#    的请求，走 PMIC → RPM(SMD) 通道；-ETIMEDOUT 说明那条通道在**运行时**（不是开机时）不可靠。
#
#  本脚本关掉两类抖动源：
#    ① runtime PM      —— 不再进出 LPM，也就不会再发 vccq set load
#    ② devfreq 时钟缩放 —— 不再请求频率/总线带宽变更
#    ③ auto-hibern8    —— 链路不再自动进低功耗态
#
#  ⚠️ 只关"省电"，不改正确性；代价是功耗略高。
#  ⚠️ **有效性尚未在设备上验证**（半死态只能长按电源恢复，没法在线对比）。
#     验证方式：开机后确认本脚本生效，再跑一次 scripts/qinglong/z17s_depcheck.js，
#     grep 内核日志看是否还出现 ufshcd_config_vreg_load / RCU stall。
#
#  手动执行： /usr/local/sbin/z17s-ufs-quiet.sh
#  回滚    ： systemctl disable --now z17s-ufs-quiet.service
# =============================================================================
set -u

UFHSC_DIR=/sys/bus/platform/devices/1da4000.ufshc

say() { echo "z17s-ufs-quiet: $*"; }

# --- ①runtime PM：关掉，让 UFS 常驻 active -----------------------------------
ctl="$UFHSC_DIR/power/control"
if [ -w "$ctl" ]; then
    echo on > "$ctl" 2>/dev/null
    say "runtime PM  power/control = $(cat "$ctl" 2>/dev/null) (runtime_status=$(cat "$UFHSC_DIR/power/runtime_status" 2>/dev/null))"
else
    say "跳过 runtime PM（$ctl 不存在或不可写）"
fi

# --- ②ufshcd 的时钟缩放（devfreq）：关掉 --------------------------------------
# 属性名是 clkscale_enable，挂在每个 scsi_host 下面
found_clk=0
for f in /sys/class/scsi_host/host*/clkscale_enable; do
    [ -e "$f" ] || continue
    echo 0 > "$f" 2>/dev/null && found_clk=1
    say "clkscale     $f = $(cat "$f" 2>/dev/null)"
done
[ "$found_clk" = 0 ] && say "跳过时钟缩放（没有 clkscale_enable，可能内核没编译 UFS devfreq）"

# --- ③auto-hibern8：关掉（0 = 不自动进低功耗链路态） -------------------------
found_h8=0
for f in $(find /sys/devices/platform -maxdepth 3 -name auto_hibern8 2>/dev/null); do
    echo 0 > "$f" 2>/dev/null && found_h8=1
    say "auto_hibern8 $f = $(cat "$f" 2>/dev/null)"
done
[ "$found_h8" = 0 ] && say "跳过 auto-hibern8（没找到属性）"

say "完成"
