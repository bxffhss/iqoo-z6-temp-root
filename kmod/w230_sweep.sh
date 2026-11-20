#!/system/bin/sh
# w230_sweep.sh —— 第 100 发:#109 测完(Permissive 段)在**翻执法之前**把 root 腿还删得动的脚印先扫掉。
#   为什么排在这个时刻(例58):`setenforce 0` 实测 rc=1 写不回,而 shell 域执法下对 adb_data_file 没有写权
#     ⇒ "翻完之后收尾腿顺手清"不是方案,必须在翻之前清完。
#   本腿只删两样:stage 无条件写的 /data/adb/ksud(改道目标早已不指它)、#100 留下的自制模板文件。
O=/data/local/tmp/w230_sweep.out
exec >>"$O" 2>&1
echo "=== W230 扫脚印 up=$(cut -d' ' -f1 /proc/uptime) 域=$(cat /proc/self/attr/current 2>&1) enf=$(cat /sys/fs/selinux/enforce 2>&1) ==="
echo "  之前 /data/adb = [$(ls -a /data/adb 2>&1 | tr '\n' ' ')]"
rm -f /data/adb/ksud; echo "  rm ksud rc=$?"
rm -f /data/adb/ksu/profile/templates/vivoshell.root; echo "  rm 模板 rc=$?"
echo "  之后 /data/adb = [$(ls -a /data/adb 2>&1 | tr '\n' ' ')]"
echo "  模板目录 = [$(ls -a /data/adb/ksu/profile/templates 2>&1 | tr '\n' ' ')]"
echo "  改道目标还在: $(ls -l /data/data/com.termux/files/usr/bin/kd2 2>&1 | tr -s ' ' | cut -d' ' -f1,3,4,5,9)"
# ★第 100 发收尾时我明明让 Termux 自己 rm 掉了 kd2(屏上有 `No such file` 三行)，这一发起点它又在了
#   ⇒ 不许归因，先量 mtime/大小/标签，再决定是谁写的(例54：先读自己的落盘)。
echo "  残留复量: 设备时间=[$(date 2>&1)] kd2=[$(ls -lZ /data/data/com.termux/files/usr/bin/kd2 2>&1)]"
echo "  同目录近 5 个: $(ls -lt /data/data/com.termux/files/usr/bin 2>&1 | head -5 | tr '\n' '|' | cut -c1-200)"
echo "=== DONE ==="
chmod 666 "$O" 2>/dev/null
