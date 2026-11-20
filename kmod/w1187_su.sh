#!/system/bin/sh
# w1187_su.sh — 由 @sushd(root) 派单：用真正讲标准契约的 ksu_su 与 setprof(manager门) 做端到端。
# 产出 /data/local/tmp/w1187_su.out
OUT=/data/local/tmp/w1187_su.out
: > "$OUT"
echo "=== root: $(id) ===" >> "$OUT"
echo "--- [1] POSITIVE su as 10342(suw, granted=1): ksu_su -c id ---" >> "$OUT"
/data/local/tmp/asuid 10342 /data/local/tmp/ksu_su -c id >> "$OUT" 2>&1
echo "--- [2] grant termux 10667 via ksuctl88 setprof AS manager-uid 10104 ---" >> "$OUT"
/data/local/tmp/asuid 10104 /data/local/tmp/ksuctl88 setprof 10667 com.termux u:r:shell:s0 >> "$OUT" 2>&1
echo "--- [3] su as 10667(termux) AFTER grant: ksu_su -c id ---" >> "$OUT"
/data/local/tmp/asuid 10667 /data/local/tmp/ksu_su -c id >> "$OUT" 2>&1
echo "--- [4] su as 10667 '0 sh -c id' (libsu form) ---" >> "$OUT"
/data/local/tmp/asuid 10667 /data/local/tmp/ksu_su 0 sh -c id >> "$OUT" 2>&1
echo "--- [5] NEGATIVE su as 10349(Scene, not granted): ksu_su -c id ---" >> "$OUT"
/data/local/tmp/asuid 10349 /data/local/tmp/ksu_su -c id >> "$OUT" 2>&1
echo "--- [6] re-check granted 10667 (as manager 10104) ---" >> "$OUT"
/data/local/tmp/asuid 10104 /data/local/tmp/ksuctl88 granted 10667 >> "$OUT" 2>&1
echo "===== DONE =====" >> "$OUT"
