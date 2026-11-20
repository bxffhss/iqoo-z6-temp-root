#!/system/bin/sh
# w300b_big.sh —— 第 106 发 #71 的第二格：把 /data/local/tmp 里**历史遗留的大文件与已完成使命的日志**清掉。
#   ★先 pull 再删(例64)：ksu_stage.log / shd.log 由本机侧拉走，这条腿只负责删并复证。
#   仍然有意不删：/data/local/tmp/kd(本发改道目标) —— 它只能在"不翻执法的收尾发"里由 root 腿带走。
O=/data/local/tmp/w300b_big.out
exec >>"$O" 2>&1
echo "=== W300B 起 up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) 域=$(cat /proc/self/attr/current 2>&1) enf=$(cat /sys/fs/selinux/enforce 2>&1) ==="
echo "  清前占用最大的几个："
ls -lS /data/local/tmp 2>&1 | head -8 | tr -s ' ' | cut -d' ' -f3,5,9
for f in ksu_ftrace.txt shd.log ksu_stage.log ksu_mod_teardown.log ksu_mod_mounts.txt ksu_mod_before.txt w201_snap.txt; do
    p=/data/local/tmp/$f
    if [ -e "$p" ]; then sz=$(ls -l "$p" | tr -s ' ' | cut -d' ' -f5); rm "$p"; echo "  rm $f (size=$sz) rc=$?"; else echo "  不在: $f"; fi
done
echo "  复证 ls -lS(前 8)："
ls -lS /data/local/tmp 2>&1 | head -8 | tr -s ' ' | cut -d' ' -f3,5,9
echo "  目录总占用：$(du -s /data/local/tmp 2>&1 | cut -f1) KB"
echo "=== DONE ==="
chmod 666 "$O" 2>/dev/null
