#!/system/bin/sh
# ksu_one_stage.sh v9 —— 一个 boot 只试一档（md §6.32 / §6.34 / §6.35）
# 三条来自真机的规矩：
#  1) **永不 rmmod**：KSU 的 __exit 会拆"被闸门关掉、从没建过"的东西(实测两次因此重启)。
#     一档一 boot，判据做完就收工；换档只改 /data/local/tmp/ksu_stage.txt(0/2/4/7/8/9)。
#  2) **永不 `dmesg -c`**：清空环形缓冲 = 自毁证据(第三发丢过整份现场)。
#  3) **每条 log 都 sync**；收尾再 dump 一次整份 dmesg（"跑判据期间才产生的内核行"靠这个才留得下来）。
# 打标策略(第十四发的新规矩)：**只给脚本自己打标**，用 ksuctl 的 su 子进程测端到端。
#   mark 是继承的(fork 复制 thread_flags) ⇒ 脚本打标 ⇒ 子进程带标 ⇒ execve hook 命中；
#   而 `mark refresh` 会连 adbd/zygote 一起打标 ⇒ dispatcher 万一还有问题 adb 立刻全灭
#   (第十、十一发就是这样，只能长按电源键)。真要 refresh 才建 /data/local/tmp/ksu_do_mark.txt。
S=$(cat /data/local/tmp/ksu_stage.txt 2>/dev/null)
[ -n "$S" ] || S=9
OUT=/data/local/tmp/ksu_stage.log
KO=/data/local/tmp/kernelsu.ko
CTL=/data/local/tmp/ksuctl
ALLOW_SRC=/data/local/tmp/allow.bin
ALLOW=/data/adb/ksu/.allowlist
FULL=/data/local/tmp/dmesg_full.txt
DM='tilayout|uaccessprobe|KSUSTEP|KSUBEAT|dev_syms|apfmt|load_allow|allowlist version|dispatcher|sys_call_table|reboot kprobe|hook_manager|register_|umount|sucompat|setuid|tp_marker|manage_mark|observer|tracker|Unknown symbol|disagrees|Unable to handle|BUG|Oops|Internal error|Call trace|CFI|install ksu fd|ksu fd'
: > "$OUT"; : > "$FULL"
exec >> "$OUT" 2>&1
chmod 666 "$OUT" "$FULL" 2>/dev/null
log() { echo "[$(date +%H:%M:%S)] $*"; sync; }

log "=== 起点 stage=$S ==="
log "id=$(id -u) enforce=$(getenforce) uname=$(uname -s) up=$(cut -d' ' -f1 /proc/uptime)"
log "ko md5=$(md5sum $KO | awk '{print $1}')"
mkdir -p /data/adb/ksu
cp "$ALLOW_SRC" "$ALLOW"; chmod 644 "$ALLOW"
cp /data/local/tmp/ksud /data/adb/ksud; chmod 755 /data/adb/ksud
log "allow=$(ls -l $ALLOW 2>&1)"
echo 8 4 1 8 > /proc/sys/kernel/printk 2>/dev/null
log "printk=$(cat /proc/sys/kernel/printk)"
log "----- Attempted stage=$S -----"
sync

insmod "$KO" ksu_stage=$S allow_shell=1
RC=$?
log "insmod rc=$RC"
dmesg > "$FULL" 2>/dev/null; sync
log "dmesg 落盘=$(wc -c < "$FULL") 字节"
log "lsmod=[$(lsmod | grep -i kernelsu | tr -s ' ')]"
log "enforce=$(getenforce)"
log "参数: $(for f in /sys/module/kernelsu/parameters/*; do echo -n "$(basename $f)=$(cat $f) "; done)"
log "布局自证(tilayout/uaccessprobe/apfmt):"
dmesg | grep -E 'tilayout|uaccessprobe|apfmt' | tail -6
log "dmesg 尾部:"
dmesg | grep -E "$DM" | tail -60
sync

if [ "$RC" = 0 ]; then
    log "===== 控制面判据(不靠 dmesg 单方证词) ====="
    "$CTL" fmt
    "$CTL" fd
    "$CTL" info
    "$CTL" allowlist
    "$CTL" granted 10284
    "$CTL" granted 2000
    ME=$$
    log "===== 端到端 su：只给脚本自己(pid=$ME)打标 ====="
    "$CTL" mark get "$ME"
    "$CTL" mark mark "$ME"
    "$CTL" mark get "$ME"
    "$CTL" su 2000 "id"
    "$CTL" su 10284 "id"
    if [ -e /data/local/tmp/ksu_do_mark.txt ]; then
        ZP=$(pidof zygote64 | awk '{print $1}')
        log "(ksu_do_mark.txt 在 => 追加 mark refresh, adb 可能失效)"
        "$CTL" mark refresh
        "$CTL" mark get "$ZP"
    fi
    log "===== 不 rmmod：判据做完就结束本 boot ====="
fi
log "===== 收尾：再落一次整份 dmesg(含跑判据期间新产生的行) ====="
dmesg > "$FULL" 2>/dev/null
sync
grep -E "$DM" "$FULL" | tail -45
sync
log "=== 结束(能到这行=本 boot 活下来了) ==="
