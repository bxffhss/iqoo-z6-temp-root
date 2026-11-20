#!/system/bin/sh
# w549_kt2.sh —— §6.394 那条梯的**直接**反对照（第 42 发现在窗口里补做）。
#   为什么不能只写内核线程 pid：内核线程不回到用户态也不退出 ⇒ task_work 一直排队不跑 ⇒ 既不 crash 也不打印，
#   那一格只能证"排队安全"，证不了护栏。真正危险的形状是：**排队之后目标立刻 fatal exit**
#   ⇒ do_exit 里 exit_files(:855) 先跑、exit_task_work(:860) 后跑 ⇒ 回调在 files==NULL 时执行。
#   rc73 有护栏 ⇒ 期望 `KSUFDINST NULLFILES skip` 且**不复位**；rc67 没护栏 ⇒ 期望踩空(所以只在 rc73 上打这一格)。
#   ★规矩：重定向全写在脚本内部；工具一律绝对路径；fork 数要少(suw 的 root agent 会掐长任务，第 41 发那份扫全 /proc 就被掐了)。
OUT=/data/local/tmp/w549_kt2.out
: > "$OUT"
chmod 666 "$OUT" 2>/dev/null
echo "== 身份 ==" >> "$OUT"
/system/bin/id >> "$OUT" 2>&1
echo "enforce=$(getenforce) up=$(cut -d. -f1 /proc/uptime)" >> "$OUT"
echo "== 五轮：排一个短命 sleep，立刻 SIGKILL 它 ==" >> "$OUT"
K=0
while [ "$K" -lt 5 ]; do
    K=$((K + 1))
    /system/bin/sleep 30 &
    P=$!
    /system/bin/echo "$P" > /proc/ksu_install_fd 2>>"$OUT"
    RC=$?
    /system/bin/kill -9 "$P" 2>/dev/null
    echo "第 $K 轮 pid=$P write_rc=$RC up=$(cut -d. -f1 /proc/uptime)" >> "$OUT"
    /system/bin/sleep 2
done
/system/bin/sleep 2
echo "== 第 6 轮：故意打一个「已经退完了」的 pid（问的是目标没了会怎样） ==" >> "$OUT"
/system/bin/sleep 0.05 &
GP=$!
/system/bin/sleep 1
/system/bin/echo "$GP" > /proc/ksu_install_fd 2>>"$OUT"
echo "第 6 轮 pid=$GP write_rc=$? up=$(cut -d. -f1 /proc/uptime)" >> "$OUT"
/system/bin/sleep 2
echo "== 还活着吗 ==" >> "$OUT"
echo "up=$(cut -d. -f1 /proc/uptime) mod=$(grep -ac kernelsu /proc/modules) enf=$(getenforce)" >> "$OUT"
echo "== dmesg 里 KSUFDINST 最近 14 行 ==" >> "$OUT"
/system/bin/dmesg 2>/dev/null | /system/bin/grep -a KSUFDINST | /system/bin/tail -14 >> "$OUT" 2>&1
/system/bin/dmesg > /data/local/tmp/w549_dmesg.txt 2>/dev/null
D=/data/local/tmp/w549_dmesg.txt
echo "== 三个计数（本机现数，别手数） ==" >> "$OUT"
echo "已排队=$(/system/bin/grep -ac 'KSUFDINST 已排队给' "$D" 2>/dev/null)" >> "$OUT"
echo "回调跑在=$(/system/bin/grep -ac 'KSUFDINST 回调跑在' "$D" 2>/dev/null)" >> "$OUT"
echo "NULLFILES_skip=$(/system/bin/grep -ac 'KSUFDINST NULLFILES skip' "$D" 2>/dev/null)" >> "$OUT"
echo "dmesg 抓取字节=$(wc -c < "$D" 2>/dev/null)" >> "$OUT"
echo "== DONE ==" >> "$OUT"
