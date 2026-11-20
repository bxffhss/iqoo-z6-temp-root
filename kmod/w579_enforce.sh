#!/system/bin/sh
# w579_enforce.sh —— 第 45 发的**改道版恢复执法**：@sushd 那条腿这次被内核答了 granted=1 却没真的把 MAC 翻过来
#   (一手：`sushd.log: granted=1 cmd=[…w426_enforce.sh]` 之后 getenforce 连读 6 次仍是 Permissive)。
#   改道那条路本发已被证能出 root( SU0..SU4 ret=0 ＋载荷里 uid=0)，所以让它自己把 enforce 写回 1。
#   ★这只在 Permissive 窗内做得到；写完之后一切判据才算"执法态"。
OUT=/data/local/tmp/w579_enforce.out
: > "$OUT"
{
    echo "=== W579 起点 enf=$(getenforce) uid=$(id -u) dom=$(cat /proc/self/attr/current | tr -d '\000') up=$(cut -d' ' -f1 /proc/uptime) ==="
    echo 1 > /sys/fs/selinux/enforce 2>&1
    echo "写 enforce rc=$?"
    echo "复读 enf=$(getenforce) mod=$(grep -c kernelsu /proc/modules)"
    sync
    echo "===== DONE"
} >> "$OUT" 2>&1
chmod 666 "$OUT" 2>/dev/null
echo "W579_DONE"
