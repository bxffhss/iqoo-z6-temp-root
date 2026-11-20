#!/system/bin/sh
# w720_ksubirth_dump.sh —— 第 51 发收尾前的"全量证人落盘"腿：
#   把**当前整环** dmesg 与里面所有 KSUBIRTH/KSUFDINST 行原样落到文件，由 PC 侧离线数
#   (设备侧 mksh/toybox 的解析坑：BRE 的 \| 打空、半行取值——§6.414/§6.415 两条仪器教训)。
#   还顺手拍：Manager 主进程 pid、它表里 ksu_driver 那几条 fd、稳定性两条。
# 跑法：bash kmod/w211_ui.sh rleg w720_ksubirth_dump.sh   (suw 的 root 通道，产物名=脚本名去 .sh 加 .out)
L=/data/local/tmp/w720_ksubirth_dump.out
D=/data/local/tmp/w720_dmesg.txt
K=/data/local/tmp/w720_lines.txt
exec >"$L" 2>&1
echo "=== W720 起 up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) enf=$(cat /sys/fs/selinux/enforce 2>/dev/null) mod=$(grep -c kernelsu /proc/modules) boot_id=$(cat /proc/sys/kernel/random/boot_id)"
dmesg > "$D"
echo "  【输入证人】dmesg 落盘 rc=$? 行数=$(grep -ac . "$D") 字节=$(wc -c < "$D")"
echo "    首行=[$(head -1 "$D" | cut -c1-72)]"
echo "    末行=[$(tail -1 "$D" | cut -c1-72)]"
grep -a KSUBIRTH "$D" > "$K"
grep -a KSUFDINST "$D" >> "$K"
echo "  证人落盘：$K 行数=$(grep -ac . "$K")(逐 pid 计数在 PC 侧离线做，这里只保证原样)"
echo "  ★不在这里数命中：$K 里 KSUBIRTH=$(grep -ac KSUBIRTH "$K") KSUFDINST=$(grep -ac KSUFDINST "$K")"
for p in $(pidof me.weishu.kernelsu); do
    echo "  --- Manager pid=$p ---"
    echo "    cmdline=[$(tr -d '\0' < /proc/$p/cmdline | cut -c1-60)] start_ticks=$(awk '{print $22}' /proc/$p/stat 2>/dev/null)"
    ls -l /proc/$p/fd 2>/dev/null | grep -a ksu_driver
    echo "    fd_ksu=$(ls -l /proc/$p/fd 2>/dev/null | grep -ac ksu_driver) fd 总数=$(ls -1 /proc/$p/fd 2>/dev/null | grep -ac .)"
done
echo "  稳定性：signal6=$(grep -ac 'received signal 6' "$D") zygote行=$(grep -ac "Service 'zygote'" "$D") cap=$(grep -ac 'KSUBIRTH cap' "$D")"
echo "  up=$(cut -d' ' -f1 /proc/uptime) 模块=[$(grep -a '^kernelsu ' /proc/modules)]"
echo "=== DONE W720 ==="
