#!/system/bin/sh
OUT=/data/local/tmp/w1188_su2.out
: > "$OUT"
echo "=== root $(id) ===" >> "$OUT"
echo "--- [4-fixed] ksu_su 0 sh -c id  as 10667(granted) ---" >> "$OUT"
/data/local/tmp/asuid 10667 /data/local/tmp/ksu_su 0 sh -c id >> "$OUT" 2>&1
echo "--- [1b] ksu_su -c id  as 10342(suw) ---" >> "$OUT"
/data/local/tmp/asuid 10342 /data/local/tmp/ksu_su -c id >> "$OUT" 2>&1
echo "--- [4b] ksu_su 0 /system/bin/id  as 10667 ---" >> "$OUT"
/data/local/tmp/asuid 10667 /data/local/tmp/ksu_su 0 /system/bin/id >> "$OUT" 2>&1
echo "===== DONE =====" >> "$OUT"
