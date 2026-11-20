#!/system/bin/sh
# w1185_chmod.sh — 把 rc77 的 /dev/ksud 字符设备权限补成 0666（社区 su 入口必须让非 root 能 open）
# 由 @sushd(root) 派单执行。产出：/data/local/tmp/w1185_chmod.out
OUT=/data/local/tmp/w1185_chmod.out
: > "$OUT"
echo "BEFORE: $(ls -l /dev/ksud 2>&1)" >> "$OUT"
chmod 0666 /dev/ksud 2>>"$OUT"
echo "CHMOD_RC=$?" >> "$OUT"
echo "AFTER: $(ls -l /dev/ksud 2>&1)" >> "$OUT"
echo "MISC: $(grep -i ksud /proc/misc 2>&1)" >> "$OUT"
echo "===== DONE =====" >> "$OUT"
