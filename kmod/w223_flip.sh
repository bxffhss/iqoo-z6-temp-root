#!/system/bin/sh
# w223_flip.sh —— 只把执法态翻成 1 并留时刻，**不做任何恢复**(恢复=adb reboot，§6.214③/#103 的账：
#   shell 域在执法下写不回 0，实测 rc=1，所以"腿里自己改回来"不是方案)。
L=/data/local/tmp/w223_flip.out
exec >>"$L" 2>&1
echo "=== W223 翻执法 up=$(cut -d' ' -f1 /proc/uptime) 本腿域=$(cat /proc/self/attr/current 2>&1) 现在 enf=$(cat /sys/fs/selinux/enforce 2>&1) ==="
echo 1 > /sys/fs/selinux/enforce
echo "写入 rc=$?  现在 enf=$(cat /sys/fs/selinux/enforce 2>&1) up=$(cut -d' ' -f1 /proc/uptime)"
echo "自证这一腿还活着(外部命令在执法下能不能跑，就是 §6.212③ 那格): ls -d /data/local/tmp => $(ls -d /data/local/tmp 2>&1)"
echo "=== DONE ==="
chmod 666 "$L" 2>/dev/null
