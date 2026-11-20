#!/system/bin/sh
# ksu_one_stage.sh v10 —— 一个 boot 只试一档（md §6.35/§6.36）
# 规矩(全来自真机翻车)：
#  1) **永不 rmmod**（KSU 的 __exit 会拆"被闸门关掉、从没建过"的东西，实测两次当场重启）；
#  2) **永不 `dmesg -c`**（清空环形缓冲 = 自毁证据）；
#  3) 每条 log 都 sync；**收尾再 dump 一次整份 dmesg**（跑判据期间才产生的内核行靠这个才留得下来）；
#  4) 档位与附加参数都从文件读，换实验不重推脚本：
#       /data/local/tmp/ksu_stage.txt  = 0/2/4/7/8/9（默认 9）
#       /data/local/tmp/ksu_args.txt    = 附加 insmod 参数，例如
#                                         ksu_mass_mark=0 ksu_hook_mask=0x15
#     `ksu_mass_mark=0` 的意义：**adbd/zygote 不再被大面积打标** ⇒ 就算 hook 路径是坏的，
#     adb 也不会死；然后我们只给**脚本自己**打标(fork 继承) ⇒ 实验面最小化。
S=$(cat /data/local/tmp/ksu_stage.txt 2>/dev/null)
[ -n "$S" ] || S=9
ARGS=$(cat /data/local/tmp/ksu_args.txt 2>/dev/null)
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

log "=== 起点 stage=$S args=[$ARGS] ==="
log "id=$(id -u) enforce=$(getenforce) uname=$(uname -s) up=$(cut -d' ' -f1 /proc/uptime)"
log "ko md5=$(md5sum $KO | awk '{print $1}')"
mkdir -p /data/adb/ksu
cp "$ALLOW_SRC" "$ALLOW"; chmod 644 "$ALLOW"
cp /data/local/tmp/ksud /data/adb/ksud; chmod 755 /data/adb/ksud
log "allow=$(ls -l $ALLOW 2>&1)"
echo 8 4 1 8 > /proc/sys/kernel/printk 2>/dev/null
log "printk=$(cat /proc/sys/kernel/printk)"
log "----- Attempted stage=$S args=[$ARGS] -----"
sync

insmod "$KO" ksu_stage=$S allow_shell=1 $ARGS
RC=$?
log "insmod rc=$RC"
dmesg > "$FULL" 2>/dev/null; sync
log "dmesg 落盘=$(wc -c < "$FULL") 字节"
log "lsmod=[$(lsmod | grep -i kernelsu | tr -s ' ')]"
log "enforce=$(getenforce)"
log "布局自证(tilayout/uaccessprobe/apfmt):"
dmesg | grep -E 'tilayout|uaccessprobe|apfmt' | tail -6
log "dmesg 尾部:"
dmesg | grep -E "$DM" | tail -70
sync

if [ "$RC" = 0 ]; then
    log "===== 控制面判据(不靠 dmesg 单方证词) ====="
    "$CTL" fmt
    "$CTL" fd
    "$CTL" info
    "$CTL" allowlist
    "$CTL" granted 10284
    "$CTL" granted 2000
    dmesg > "$FULL.a" 2>/dev/null; cp "$FULL.a" "$FULL"; sync   # 打标**之前**先存一份    log "已存打标前的 dmesg(万一打标把脚本自己打坏，这份还在)"
    ME=$$
    log "===== 端到端 su：只给脚本自己(pid=$ME)打标 ====="
    "$CTL" mark get "$ME"
    "$CTL" mark mark "$ME"
    "$CTL" mark get "$ME"
    "$CTL" su 2000 "id"
    "$CTL" su 10284 "id"
    log "===== 不 rmmod：判据做完就结束本 boot ====="
fi
log "===== 收尾：再落一次整份 dmesg ====="
dmesg > "$FULL" 2>/dev/null
sync
grep -E "$DM" "$FULL" | tail -50
sync
log "=== 结束(能到这行=本 boot 活下来了) ==="
