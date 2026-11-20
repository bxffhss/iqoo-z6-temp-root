#!/system/bin/sh
# shot14 真实 root 演示：经 @sushd（Manager root 通道）跑实际特权操作，证明窗口给的是真 root，不止 ioctl 单元测。
O=/data/local/tmp/w14_demo.out
: > "$O"
echo "=== shot14 真实 root 演示（@sushd 通道）===" >> "$O"
echo "--- id ---" >> "$O"
id >> "$O" 2>&1
echo "--- whoami ---" >> "$O"
whoami >> "$O" 2>&1
echo "--- /proc/self/status (Uid/CapEff/CapBnd) ---" >> "$O"
grep -E '^(Uid|CapEff|CapBnd)' /proc/self/status >> "$O" 2>&1
echo "--- /proc/kallsyms：root 见真实地址，非 root 全 0 ---" >> "$O"
K=$(wc -l < /proc/kallsyms 2>/dev/null)
echo "kallsyms 总行数=$K" >> "$O"
NZ=$(grep -vc '^0000000000000000 ' /proc/kallsyms 2>/dev/null)
echo "kallsyms 非零地址行数=$NZ" >> "$O"
echo "采样: $(grep -m1 -v '^0000000000000000 ' /proc/kallsyms 2>/dev/null | head -c 140)" >> "$O"
echo "--- /data/system/packages.list：root 可读的系统数据 ---" >> "$O"
P=$(wc -l < /data/system/packages.list 2>/dev/null)
echo "packages.list 行数=$P" >> "$O"
echo "===== DONE =====" >> "$O"
