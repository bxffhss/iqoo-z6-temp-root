#!/bin/bash
# w1000_shot66.sh —— 第 66 发：用 go.sh 新加的 LEG1 钩子，在**判据⑥那一瞬**派合并腿。
# 与 w996 的差别只有一件事：不再重跑 7 分钟的总闸，而是**核"这轮绿闸之后没动过文件"**；
#   只要有任何一件比闸新，就拒绝开窗（让我回去重跑闸，而不是拿旧绿灯开新枪）。
set -u
cd "$(dirname "$0")/.." || exit 1
EV=kmod/w103_evidence
A() { adb shell "$1" 2>&1 | tr -d '\r'; }
GATE=$EV/w413_console_latest.txt

echo "=== 0) 闸的新鲜度（#158：开枪前要绿灯；这里再加一格"绿灯之后没动过东西"） ==="
[ -f "$GATE" ] || { echo "[x] 没有闸记录 ⇒ 不开枪"; exit 1; }
grep -q '全绿' "$GATE" || { echo "[x] 最近一轮闸不是全绿 ⇒ 不开枪"; sed -n '/=== 汇总/,$p' "$GATE" | tail -3; exit 1; }
NEWER=$(find kmod analysis -maxdepth 2 -type f \( -name '*.sh' -o -name '*.c' -o -name '*.py' -o -name '*.md' -o -name '*.ko' -o -name '*.txt' \) -newer "$GATE" 2>/dev/null | head -8)
if [ -n "$NEWER" ]; then
  echo "[x] 这轮绿闸($GATE)之后这些文件又变过 ⇒ 不开枪，先重跑 w413："
  printf '%s\n' "$NEWER" | sed 's/^/    /'
  exit 1
fi
echo "  绿灯可复用：闸记录之后没有文件更新（闸时间戳=$(date -r "$GATE" '+%H:%M:%S')）"

echo "=== 1) 开窗并在判据⑥立刻派合并腿 ==="
LEG_MD5=$(md5sum kmod/w995_merged_leg.sh | cut -d' ' -f1)
echo "  合并腿 md5=$LEG_MD5（设备侧应＝同一个值，go.sh 3.5) 会两端对表）"
LEG1=/data/local/tmp/w995_merged_leg.sh LEG1OUT=/data/local/tmp/w995_merged.out LEG1MD5="$LEG_MD5" \
  I_KNOW=1 bash kmod/go.sh > "$EV/w1001_shot66_go.log" 2>&1
GO=$?
echo "GO_RC=$GO"
grep -aE 'insmod rc=0|判据⑥ 到了|3\.5\)|腿跑完|END up=|PARAM rt_|insmod_rc|POLICY_UNCHANGED|\[BAD\]|\[x\]|\[!\]|空枪|GO_RC=' "$EV/w1001_shot66_go.log" | cut -c1-170 | tail -28

if [ "$GO" -ne 0 ]; then echo "[x] go.sh rc=$GO ⇒ 不往下拉产物（先看上面日志）"; exit 1; fi

echo "=== 2) 腿的判据面（go.sh 3.5 已抄进 $EV/leg1_out.txt） ==="
[ -s "$EV/leg1_out.txt" ] || { echo "[x] 没有 leg1_out.txt ⇒ 腿没跑成，这格记未测"; exit 1; }
wc -l < "$EV/leg1_out.txt" | sed 's/^/  行数=/'
grep -aE 'BEGIN up=|ko_md5|PRE_rc|insmod_rc|MODULES_LINE|PARAM rt_|WR_rc|DMESG_w986|rmmod_rc|POST_rc|POLICY_UNCHANGED|END up=|\[x\]|\[!!\]' "$EV/leg1_out.txt" | cut -c1-165

echo "=== 3) 拉产物 ==="
for f in pol.pre_shot64 pol.post_shot64 w986_wr.bin; do
  MSYS_NO_PATHCONV=1 adb pull //data/local/tmp/$f "$EV/66_$f" >/dev/null 2>&1
  echo "  $f pull_rc=$? size=$(wc -c < "$EV/66_$f" 2>/dev/null) md5=$(md5sum "$EV/66_$f" 2>/dev/null | cut -d' ' -f1)"
done
echo "  设备终态：up=$(A 'cut -d\" \" -f1 /proc/uptime') enf=$(A getenforce) mod=$(A \"grep -c '^kernelsu' /proc/modules\")"
echo "SHOT66_DONE"
