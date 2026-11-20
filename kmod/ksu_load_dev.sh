#!/system/bin/sh
# ksu_load_dev.sh v2 —— 第三发窗口：装 kernelsu.ko(rc11) 并把**判据链**逐条落到文件。
# 口径(记忆:执行类判据必须三判据+正对照)：每一步都要有能证伪的输出，不看 ret=0 就当成功。
#
# 顺序是设计过的，别调：
#   ①先放 /data/adb/ksu/.allowlist —— 内核只在 ksu_init 里读一次(policy/allowlist.c:506)
#   ②insmod 带 allow_shell=1 —— core/init.c:81 module_param，晚加载时让 uid 2000 直接算"已授权"，
#     这样窗口之后所有测试都能用**普通 adb shell**做，不必再占一次性 root 句柄。
#   ③ksuctl all —— 用 supercall 把"名单真的进内核了"读回来(不靠 dmesg 单方证词)
#   ④ksuctl mark get→refresh→get —— 晚加载时没人给存量任务打 mark，不打就永远等不到 su
OUT=/data/local/tmp/ksu_dev.log
KO=/data/local/tmp/kernelsu.ko
CTL=/data/local/tmp/ksuctl
SHIM=/data/local/tmp/ksud
ALLOW_SRC=/data/local/tmp/allow.bin
ALLOW=/data/adb/ksu/.allowlist
SUW_UID=10284
exec > "$OUT" 2>&1

echo "=== 0. 起点状态(必须先量，否则后面'变好'没有对照) ==="
date
id
getenforce
uname -a
echo "--- 模块在不在:"; lsmod 2>/dev/null | grep -i kernelsu || echo "(未加载)"
echo "--- 待装产物 md5:"; md5sum "$KO" "$CTL" "$SHIM" "$ALLOW_SRC" 2>&1
echo "--- ksuctl 自己那行 apfmt(要与下面内核打的 apfmt 逐字一致):"
"$CTL" fmt
echo "--- 负对照(没装模块时 reboot magic 必须拿不到 fd):"
"$CTL" fd

echo; echo "=== 1. 放授权名单文件(必须在 insmod 之前) ==="
mkdir -p /data/adb/ksu
cp "$ALLOW_SRC" "$ALLOW"
chmod 644 "$ALLOW"
ls -lZ "$ALLOW" 2>&1 || ls -l "$ALLOW"
echo "--- su 兼容层要的这个文件(上一发的残留也重放一遍，保证是本次的):"
cp "$SHIM" /data/adb/ksud
chmod 755 /data/adb/ksud
ls -lZ /data/adb/ksud 2>&1 || ls -l /data/adb/ksud

echo; echo '=== 1.5 先把**上一 boot 的崩溃现场**捞走(它只有一份，且可能被下一次崩溃覆盖) ==='
mkdir -p /data/local/tmp/pstore_prev
for f in /sys/fs/pstore/*; do
    [ -e "$f" ] || continue
    cp "$f" "/data/local/tmp/pstore_prev/$(basename "$f")" 2>&1
    echo "  拷出 $(basename "$f"): $(wc -c < "$f") 字节"
done
ls -l /data/local/tmp/pstore_prev/ 2>&1 | head
chmod -R 777 /data/local/tmp/pstore_prev 2>/dev/null
cat /data/local/tmp/pstore_prev/* 2>/dev/null | tr -d '\000' \
  | grep -inE 'Kernel panic|Oops|BUG:|Call trace|CFI|Unable to handle|Unknown symbol|kernelsu|KSUMARK' | tail -40

echo; echo "=== 2. insmod(带 allow_shell=1) ==="
# ★★上一发(17:25)吃了两个亏，都在这段修掉：
#  (a) 绝对不许再 `dmesg -c`：清空环形缓冲 = 把"insmod 之后内核说了什么"的唯一副本擦掉，
#      那次设备在 insmod 处重启，事后什么都拿不到(§6.26)。
#  (b) 必须把 console 级别抬到 8：CONFIG_PSTORE_CONSOLE=y 只镜像 **console 实际打印**的内容，
#      默认 console_loglevel 会把 pr_info 挡掉 ⇒ pstore 里就只剩 panic 尾巴，看不到失败原因。
#  取证改走两条独立通道：/dev/kmsg 打点(下面 mark()，能在 pstore 里定位自己跑到哪一步)
#  + 事后从 /sys/fs/pstore/console-ramoops-0 读回(insmod 若炸，那是唯一现场)。
mark() { echo "KSUMARK: $*" > /dev/kmsg 2>/dev/null; }
cat /proc/sys/kernel/printk
echo "8 4 1 8" > /proc/sys/kernel/printk 2>/dev/null && echo "  printk 抬到 8(失败也不要紧，继续)"
cat /proc/sys/kernel/printk
mark "before-insmod rc11 md5=$(md5sum $KO | awk '{print $1}') allow_shell=1"
insmod "$KO" allow_shell=1
echo "insmod rc=$?"
mark "after-insmod rc=$?"
dmesg > /data/local/tmp/dmesg_after.txt 2>/dev/null
chmod 666 /data/local/tmp/dmesg_after.txt 2>/dev/null
echo '--- 内核日志尾部(insmod 之后；这次不清缓冲，随时可重取):'
dmesg | tail -70
echo '--- 判据 A: lsmod 必须有 kernelsu(这才是"真的加载了"):'
lsmod | grep -i kernelsu || echo "!! lsmod 里没有 kernelsu"
echo "--- 判据 B: /sys/module/kernelsu/initstate:"
cat /sys/module/kernelsu/initstate 2>&1
echo "--- 判据 C: 参数真的吃进去了吗:"
for f in /sys/module/kernelsu/parameters/*; do echo -n "$f = "; cat "$f" 2>&1; done

echo; echo "=== 3. 三条必看的内核回执 ==="
echo "--- dev_syms 解析了几个(缺>0 就不算成功):"
dmesg | grep -E 'dev_syms' | tail -25
echo "--- apfmt(与上面 ksuctl fmt 对表):"
dmesg | grep -E 'apfmt' | tail -3
echo "--- allowlist 读没读进去:"
dmesg | grep -E 'allowlist|load_allow_uid|Unsupported profile|invalid app_profile|permission denied|Unknown symbol|disagrees' | tail -25
echo "--- 其它 init 期错误:"
dmesg | grep -iE 'kernelsu|ksu:' | grep -iE 'fail|err|warn|bug|panic|unable' | tail -25

echo; echo "=== 4. 控制面：从 uid 0 用 supercall 把名单读回来 ==="
"$CTL" all
echo "--- 专门查 suw 的 uid 有没有 root(判据：granted=1):"
"$CTL" granted "$SUW_UID"
echo "--- 查 shell(2000) —— allow_shell=1 生效的判据:"
"$CTL" granted 2000

echo; echo "=== 5. mark：晚加载必须手工补，否则存量任务收不到 hook ==="
ZP=$(pidof zygote64 | awk '{print $1}')
echo "--- 打之前: zygote64(pid $ZP) mark 应当=0:"
"$CTL" mark get "$ZP"
echo "--- refresh(只给 init/shell/zygote/allowlisted 打):"
"$CTL" mark refresh
echo "--- 打之后同一个 pid 应当=1:"
"$CTL" mark get "$ZP"
echo '--- 若还是 0：说明 tracepoint 注册数>1(refresh 会主动让路)，改用 mark all 兜底:'
if [ "$("$CTL" mark get "$ZP" | grep -c 'result=1')" = 0 ]; then
    "$CTL" mark all
    echo "--- mark all 之后:"; "$CTL" mark get "$ZP"
fi
echo '--- adbd 自己(uid 2000)必须=1，否则 adb shell 里 su 不会被拦:'
ADBD=$(pidof adbd | awk '{print $1}')
"$CTL" mark get "$ADBD"
echo "--- 内核侧应当有 'manage_mark: refreshed' 与 'tp_marker: mark process':"
dmesg | grep -E 'manage_mark|tp_marker' | tail -20

echo; echo "=== 6. 收尾提示(不在本脚本里做) ==="
echo '窗口之后 **普通 adb shell** 就能测 su(allow_shell=1)，例如:'
echo '  adb shell /system/bin/su -c id'
echo '  adb shell /system/bin/su -c ps -AZ    # 看自己落在哪个 SELinux 域'
echo '清理(不留持久化): rmmod kernelsu; rm -rf /data/adb/ksu /data/adb/ksud (root 才能删)'
echo "=== 完成: 结果在 $OUT ==="
chmod 666 "$OUT" /data/local/tmp/dmesg_after.txt 2>/dev/null
ls -l "$OUT"
