#!/bin/bash
# w1004_shot67.sh —— 第 67 发＝#219：总闸绿 → 开窗 → 判据⑥那一瞬派 w1002 合并腿（铺尺→翻执法→三量→清理）→ 拉判据。
# ★不装任何自带模块（B 那条已推迟）；★不碰 /sys/fs/selinux/load（腿只 echo 1 > enforce，即关窗方向）。
set -u
cd "$(dirname "$0")/.." || exit 1
unset MSYS_NO_PATHCONV   # ★这条链里绝不能带着它(会让离线自测假红，见 §6.468)
EV=kmod/w103_evidence
A() { adb shell "$1" 2>&1 | tr -d '\r'; }

echo "=== 1) 总闸（改了 go.sh/文档，必须重跑） ==="
PYTHONUTF8=1 bash kmod/w413_selftest_sweep.sh > "$EV/w413_console_latest.txt" 2>&1
W=$?
tail -2 "$EV/w413_console_latest.txt"
[ "$W" -eq 0 ] || { echo "[x] 闸 rc=$W ⇒ 不开枪"; exit 1; }

echo "=== 2) 开窗 + 判据⑥即派 #219 腿 ==="
LM=$(md5sum kmod/w1002_mlsrange_leg.sh | cut -d' ' -f1)
echo "  腿 md5=$LM"
LEG1=/data/local/tmp/w1002_mlsrange_leg.sh LEG1OUT=/data/local/tmp/w1002_mlsrange.out LEG1MD5="$LM" \
  I_KNOW=1 bash kmod/go.sh > "$EV/w1005_shot67_go.log" 2>&1
GO=$?
echo "GO_RC=$GO"
grep -aE 'insmod rc=0|判据. 到了|3\.5\)|腿跑完|leg1_out|\[BAD\]|\[x\]|\[!\]|空枪|GO_RC=' "$EV/w1005_shot67_go.log" | cut -c1-165 | tail -18

echo "=== 3) 取 #219 的判据 ==="
A "cat /data/local/tmp/w1002_mlsrange.out" > "$EV/w1002_shot67.out" 2>&1
echo "  行数=$(wc -l < "$EV/w1002_shot67.out")  设备 up=$(A 'cat /proc/uptime')  enf=$(A getenforce)"
cat -v "$EV/w1002_shot67.out" 2>/dev/null | sed -n '1,60p' | cut -c1-175
echo "SHOT67_DONE"
