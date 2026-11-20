#!/system/bin/sh
# w300_clean.sh —— 第 106 发的 #71 收口腿（**必须排在翻执法之前**：flip 之后 root 腿通道就死了，#104）。
#   能删的：root-owned 的 /data/adb/{ksu,ksud} 与 /data/local/tmp 里 root-owned 的日志。
#   不能删的：/data/local/tmp/kd —— 它就是本发的改道目标，删了 su 就没得验(#71 那一格留给"不翻执法的收尾发")。
#   ★口径(例61)：每条 rm 之后由**同一条腿**列目录复证，不许让被删对象自证。
O=/data/local/tmp/w300_clean.out
exec >>"$O" 2>&1
echo "=== W300 起 up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) 域=$(cat /proc/self/attr/current 2>&1) enf=$(cat /sys/fs/selinux/enforce 2>&1) mod=$(grep -c kernelsu /proc/modules) ==="
echo "  清之前 /data/adb = [ $(ls /data/adb 2>&1 | tr '\n' ' ') ]"
for f in /data/adb/ksu /data/adb/ksud; do
    if [ -e "$f" ]; then rm -rf "$f"; echo "  rm -rf $f rc=$?"; else echo "  不在: $f"; fi
done
echo "  复证 /data/adb = [ $(ls /data/adb 2>&1 | tr '\n' ' ') ]"
echo "STAGE1 done"

for f in sushd.log sushd_last.out dmesg2.log dmesg.live dmesg_full.txt ksu_ui_track.txt w184_sample.out; do
    p=/data/local/tmp/$f
    if [ -e "$p" ]; then
        own=$(ls -l "$p" | tr -s ' ' | cut -d' ' -f3)
        sz=$(ls -l "$p" | tr -s ' ' | cut -d' ' -f5)
        rm "$p"; echo "  rm $f (owner=$own size=$sz) rc=$?"
    else
        echo "  不在: $f"
    fi
done
echo "  复证(这些名字应当全部 No such file)：$(ls /data/local/tmp/sushd.log /data/local/tmp/dmesg2.log /data/local/tmp/dmesg.live /data/local/tmp/dmesg_full.txt /data/local/tmp/ksu_ui_track.txt /data/local/tmp/w184_sample.out 2>&1 | tr '\n' '|' | cut -c1-260)"
echo "  ★没删的(有意留下)：$(ls -l /data/local/tmp/kd 2>&1 | tr -s ' ' | cut -d' ' -f1,3,5,9)"
echo "STAGE2 done"
echo "  /data/local/tmp 里现在还剩什么(前 12 行)："
ls -lt /data/local/tmp 2>&1 | head -12
echo "=== DONE ==="
chmod 666 "$O" 2>/dev/null
