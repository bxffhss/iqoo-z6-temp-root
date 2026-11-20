#!/system/bin/sh
# root_probe.sh — 临时 root 窗口里跑的一次性测量: 运行时内核修补的四道门 + 第三方 app 能不能被认出
L=/data/local/tmp/root_probe.log
rm -f $L
exec >> $L 2>&1
echo "=== root_probe 开始 uptime=$(cat /proc/uptime) ==="
id
grep -E 'Uid|CapEff|Seccomp' /proc/self/status
echo
echo "--- G1 /proc/kallsyms (kptr_restrict 还挡不挡) ---"
cat /proc/sys/kernel/kptr_restrict
grep -w linux_banner /proc/kallsyms
grep -c ' linux_banner$' /proc/kallsyms
echo "--- G2 /sys/fs/pstore (能不能读到以前 panic 的现场) ---"
ls -l /sys/fs/pstore/ 2>&1
for f in /sys/fs/pstore/*; do
  if [ -f "$f" ]; then echo "-- $f ($(wc -c < $f) 字节)"; head -c 500 "$f"; echo; fi
done
echo "--- G3 dmesg (CAP_SYSLOG) 尾 ---"
dmesg 2>&1 | tail -6
echo "--- G4 kgate: tracefs kprobe + bpf + perf 端到端 ---"
/data/local/tmp/kgate 22f2400000
echo "G4rc=$?"
echo "--- G5 kprobe 是否已摘干净(别让 handler 搅下一轮的节拍) ---"
cat /sys/kernel/tracing/kprobe_events 2>&1
echo "--- G6 第三方 app 的 task 在不在 /proc/sla 那张表里 ---"
P=$(pidof com.user.app)
echo "target: pid=$P comm=[$(cat /proc/$P/comm 2>/dev/null)] uid=$(grep -m1 Uid: /proc/$P/status)"
echo "[commtop 搜 'com.user']"
/data/local/tmp/commtop 512 com.user 2>&1 | tail -20
echo "[commtop 只列 top comm, 看表的覆盖面]"
/data/local/tmp/commtop 512 2>&1 | tail -26
echo "=== root_probe 结束 uptime=$(cat /proc/uptime) ==="
sync
