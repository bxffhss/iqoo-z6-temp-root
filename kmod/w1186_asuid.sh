#!/system/bin/sh
# w1186_asuid.sh — 由 @sushd(root) 派单：用 asuid_grant 分别以 10342(名单内) 与 10667(名单外) 走 /dev/ksud GRANT_ROOT。
# 正对照 10342 应 rc=0 且 fork 出 uid=0；负对照 10667 应 rc=-1 EPERM 且 id=uid=10667。产出 /data/local/tmp/w1186_asuid.out
OUT=/data/local/tmp/w1186_asuid.out
: > "$OUT"
echo "=== running as root: $(id) ===" >> "$OUT"
echo "--- POSITIVE: uid 10342 (com.suw.manager, granted=1) ---" >> "$OUT"
/data/local/tmp/asuid_grant 10342 >> "$OUT" 2>&1
echo "--- NEGATIVE: uid 10667 (com.termux, granted=0) ---" >> "$OUT"
/data/local/tmp/asuid_grant 10667 >> "$OUT" 2>&1
echo "===== DONE =====" >> "$OUT"
