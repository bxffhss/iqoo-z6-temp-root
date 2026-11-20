#!/system/bin/sh
# 投递 B2：/data/adb/ksud 就位之后再跑 post-fs-data，看这次挂不挂。
L=/data/local/tmp/w144b.out; K=/data/adb/ksud
MC() { grep -ac modules /proc/self/mountinfo; }
{
echo "===== up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) ns=$(readlink /proc/self/ns/mnt) ====="
echo "BEFORE: update标记=$([ -e /data/adb/modules/zygisk_lsposed/update ] && echo 有 || echo 无) modules行数=$(MC)"
echo "--- module list(它自己怎么看) ---"; timeout 15 $K module list 2>&1 | head -8; echo "  rc=$?"
echo "--- post-fs-data #1 ---"; timeout 30 $K post-fs-data >/data/local/tmp/w144b_p1.txt 2>&1; echo "  rc=$? 行数=$(MC)"
grep -aiE "mount|magic|skip|error|fail" /data/local/tmp/w144b_p1.txt | head -8 | sed 's/^/    /'
echo "--- post-fs-data #2 ---"; timeout 30 $K post-fs-data >/data/local/tmp/w144b_p2.txt 2>&1; echo "  rc=$? 行数=$(MC)"
grep -aiE "mount|magic|skip|error|fail" /data/local/tmp/w144b_p2.txt | head -8 | sed 's/^/    /'
echo "--- 现在 mountinfo 里跟模块/system 有关的行 ---"
grep -aE "modules| /system| /vendor| /product" /proc/self/mountinfo | cut -c1-140 | head -12
echo "FINAL modules行数=$(MC)  框架=$(runcon u:r:shell:s0 service list 2>/dev/null|head -1)"
echo "===== DONE up=$(cut -d' ' -f1 /proc/uptime) ====="
} >"$L" 2>&1
chmod 666 "$L"
