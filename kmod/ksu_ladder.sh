#!/system/bin/sh
# ksu_ladder.sh v2 —— **分级试探**(md §6.26/§6.27)。第五发的教训写在这里：
#  · 只关 init 不够：rmmod 会去拆"从没建过"的东西(`unregister_kprobe(&reboot_kp)` /
#    `fsnotify_put_group(NULL)`) ⇒ 上一发设备就是这样在 stage=0 **加载成功之后**的 rmmod 上重启的。
#    ⇒ rc13 起 exit 侧也挂同编号闸门(`patch_ksu_stage.py` 的 exit-skip)。
#  · 证据只认"**崩溃前已 sync 到 /data 的行**"：所以每条 log 都 sync；最后一档**不 rmmod**，
#    把控制面判据先做完(那才是我们真正要的东西)。
OUT=/data/local/tmp/ksu_ladder.log
KO=/data/local/tmp/kernelsu.ko
CTL=/data/local/tmp/ksuctl
ALLOW_SRC=/data/local/tmp/allow.bin
ALLOW=/data/adb/ksu/.allowlist
STAGES="0 2 4 7 8 9"
LAST=9
: > "$OUT"
exec >> "$OUT" 2>&1
chmod 666 "$OUT" 2>/dev/null
log() { echo "[$(date +%H:%M:%S)] $*"; sync; }

log "=== 起点 ==="
log "id=$(id -u) enforce=$(getenforce) uname=$(uname -s) up=$(cut -d' ' -f1 /proc/uptime)"
log "ko md5=$(md5sum $KO | awk '{print $1}')"
log "=== 放授权名单文件(insmod 之前，只放一次) ==="
mkdir -p /data/adb/ksu
cp "$ALLOW_SRC" "$ALLOW" && chmod 644 "$ALLOW"
cp /data/local/tmp/ksud /data/adb/ksud && chmod 755 /data/adb/ksud
log "allow=$(ls -l $ALLOW 2>&1) ksud=$(ls -l /data/adb/ksud 2>&1)"
echo 8 4 1 8 > /proc/sys/kernel/printk 2>/dev/null
log "printk=$(cat /proc/sys/kernel/printk)"

DM='KSUSTEP|dev_syms|apfmt|allowlist|load_allow_uid|Unknown symbol|disagrees|dispatcher|sys_call_table|hook_manager|manage_mark|tp_marker|reboot kprobe|observer|tracker|fail|error|warn|Unable to handle|BUG|Oops'

for S in $STAGES; do
    log "----- Attempted stage=$S -----"
    insmod "$KO" ksu_stage=$S allow_shell=1
    RC=$?
    log "stage=$S insmod rc=$RC"
    log "stage=$S lsmod=[$(lsmod | grep -i kernelsu | tr -s ' ')] enforce=$(getenforce)"
    log "stage=$S dmesg 尾部:"
    dmesg | grep -E "$DM" | tail -26
    sync
    if [ "$RC" != 0 ]; then
        log "stage=$S 没加载上，下一档"
        continue
    fi
    if [ "$S" = "$LAST" ]; then
        log "===== stage=$S(全开) 活着 ⇒ 控制面判据 ====="
        "$CTL" fmt
        "$CTL" all
        "$CTL" granted 10284
        "$CTL" granted 2000
        ZP=$(pidof zygote64 | awk '{print $1}')
        AD=$(pidof adbd | awk '{print $1}')
        log "mark get zygote64($ZP) 之前:"; "$CTL" mark get "$ZP"
        "$CTL" mark refresh
        "$CTL" mark get "$ZP"
        "$CTL" mark get "$AD"
        log "su 测试请在本 boot 用普通 shell 跑: /system/bin/su -c id"
        log "===== 不 rmmod(留着这一档继续测) ====="
        break
    fi
    rmmod kernelsu
    log "stage=$S rmmod rc=$? 剩余=[$(lsmod | grep -i kernelsu)]"
    sync
    sleep 2
done
log "=== 跑完(能跑到这行=每一档都没让设备重启) ==="
