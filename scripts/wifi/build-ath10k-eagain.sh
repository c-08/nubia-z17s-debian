#!/bin/bash
# ---------------------------------------------------------------------------
# Z17S round 171 -- ath10k_core.ko that tolerates a split A-MSDU
#
# Chain of death observed on WCN3990 / HL1.0:
#   firmware splits one A-MSDU across two in-order RX indications
#     -> ath10k_htt_rx_extract_amsdu() returns -EAGAIN
#     -> ath10k_htt_rx_in_ord_ind() treats it as fatal:
#          ath10k_warn("failed to extract amsdu: -11"); rx_confused = true
#     -> every later indication hits `if (htt->rx_confused) return -EIO;`
#     -> ath10k_htt_txrx_compl_task() sets resched_napi and burns the budget
#     -> RX ring drains, firmware asserts ~160 s later
#     -> ADSP dies -> modem dies (WCN3990 runs on ADSP)
#
# Fix: drop just that partial A-MSDU (a couple of packets, TCP retransmits)
#      and carry on.  rx_confused is left alone.
#
# Produces: /root/ath10k-out/ath10k_core.ko.eagain
# ---------------------------------------------------------------------------
set -u

SRC=/root/z17s-kbuild/linux-6.12.95
OUT=/root/z17s-debian/build/kernel-out
ATH=$SRC/drivers/net/wireless/ath/ath10k
DEST=/root/ath10k-out
mkdir -p "$DEST"

echo "==== [1] 先把 max_num_amsdu 还原成默认（上一版改成 1，已证明固件不认）===="
python3 - "$ATH/core.c" <<'PY'
import sys, io
p = sys.argv[1]
s = io.open(p, encoding='utf-8').read()
old = "\tar->htt.max_num_amsdu = 1;\n\tar->htt.max_num_ampdu = ATH10K_HTT_MAX_NUM_AMPDU_DEFAULT;\n"
new = "\tar->htt.max_num_amsdu = ATH10K_HTT_MAX_NUM_AMSDU_DEFAULT;\n\tar->htt.max_num_ampdu = ATH10K_HTT_MAX_NUM_AMPDU_DEFAULT;\n"
assert s.count(old) == 1, "core.c anchor=%d" % s.count(old)
s = s.replace(old, new, 1)
io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print("  core.c reverted")
PY
grep -n 'max_num_amsdu' "$ATH/core.c" | head -3

echo
echo "==== [2] htt_rx.c 打「容忍 -EAGAIN」补丁 ===="
git -C "$SRC" checkout -- "$ATH/htt_rx.c" || exit 1
python3 - "$ATH/htt_rx.c" <<'PY'
import sys, io
p = sys.argv[1]
s = io.open(p, encoding='utf-8').read()

# 2a. file-scope counter
anchor = "static int ath10k_htt_rx_extract_amsdu(struct ath10k_hw_params *hw,"
assert s.count(anchor) == 1, "func anchor=%d" % s.count(anchor)
counter = (
"/* Z17S round 171: how many partial (split) A-MSDUs we have dropped. */\n"
"static unsigned long z17s_amsdu_dropped;\n\n"
)
s = s.replace(anchor, counter + anchor, 1)

# 2b. split the -EAGAIN case out of the fatal branch
old = """		case -EAGAIN:
			fallthrough;
		default:
			/* Should not happen. */
			ath10k_warn(ar, "failed to extract amsdu: %d\\n", ret);
			htt->rx_confused = true;
			__skb_queue_purge(&list);
			return -EIO;
		}
"""
new = """		case -EAGAIN:
			/* Z17S round 171: WCN3990/HL1.0 splits a large A-MSDU
			 * across two in-order indications, so the MSDU list ends
			 * without RX_MSDU_END_INFO0_LAST_MSDU.  Upstream treats
			 * that as fatal: rx_confused = true, after which every
			 * later indication returns -EIO, the RX ring drains and
			 * the firmware asserts ~160 s later (and takes the ADSP,
			 * hence the modem, with it).  Dropping one partial A-MSDU
			 * costs a couple of packets that TCP retransmits.
			 */
			z17s_amsdu_dropped++;
			if (z17s_amsdu_dropped <= 5 ||
			    !(z17s_amsdu_dropped % 200))
				pr_info("Z17S: dropped partial A-MSDU #%lu (msdus=%u)\\n",
					z17s_amsdu_dropped, skb_queue_len(&list));
			__skb_queue_purge(&list);
			return 0;
		default:
			/* Should not happen. */
			ath10k_warn(ar, "failed to extract amsdu: %d\\n", ret);
			htt->rx_confused = true;
			__skb_queue_purge(&list);
			return -EIO;
		}
"""
assert s.count(old) == 1, "case anchor=%d" % s.count(old)
s = s.replace(old, new, 1)
io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print("  htt_rx.c patched")
PY

echo "  -- 改动确认 --"
grep -n 'z17s_amsdu_dropped' "$ATH/htt_rx.c"

echo
echo "==== [3] 编译 ===="
rm -f "$ATH"/ath10k_core.ko "$ATH"/ath10k_snoc.ko
make -C "$SRC" O="$OUT" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
	M="$ATH" modules 2>&1 | tail -20
rc=${PIPESTATUS[0]}
echo "  make rc=$rc"
[ "$rc" -eq 0 ] || { echo "  !! 编译失败"; exit 1; }

echo
echo "==== [4] 产物 ===="
cp -f "$ATH/ath10k_core.ko" "$DEST/ath10k_core.ko.eagain"
ls -la "$DEST/ath10k_core.ko.eagain"
md5sum "$DEST"/ath10k_core.ko.eagain "$DEST"/ath10k_core.ko.ctl "$DEST"/ath10k_core.ko.amsdu1

echo
echo "==== [5] 与 baseline 的差异（应只有本补丁引入的代码）===="
python3 - <<'PY'
a = open('/root/ath10k-out/ath10k_core.ko.ctl','rb').read()
b = open('/root/ath10k-out/ath10k_core.ko.eagain','rb').read()
n = min(len(a), len(b))
d = [i for i in range(n) if a[i] != b[i]]
print("  size ctl=%d eagain=%d  delta=%d  不同字节=%d" %
      (len(a), len(b), len(b)-len(a), len(d)))
PY
echo "==== done ===="
