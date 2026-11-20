#!/system/bin/sh
# z6_dev_soft.sh — 设备侧 ②「软重启」(root)：杀 zygote/system_server 重启 framework（ko 不卸载、不花 punch）
#   跑法：su -c 'sh /sdcard/z6root/z6_dev_soft.sh'
#   之后 framework 数秒回来，再跑 z6_dev_after.sh 完成注入。
set -u
LOG=/data/local/tmp/z6_dev_soft.log; : > "$LOG"
log(){ echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }
log "===== Z6_DEV_SOFT uid=$(id -u)  up=$(cut -d' ' -f1 /proc/uptime) ====="
[ "$(id -u)" = 0 ] || { log "[x] 需 root"; echo "===== DONE(need root) ====="; exit 1; }
MOD=$(grep -c kernelsu /proc/modules 2>/dev/null); MOD=${MOD:-0}
[ "$MOD" = 1 ] || { log "[x] 无活窗口(mod=$MOD)"; echo "===== DONE(no window) ====="; exit 1; }
SS=$(pidof system_server); Z=$(pidof zygote64); Z2=$(pidof zygote)
log "kill system_server=$SS zygote64=$Z zygote=$Z2"
kill -9 $SS $Z $Z2 2>/dev/null
log "已发踢框架；framework 数秒后回来（mod 仍 1），随后跑 z6_dev_after.sh"
echo "===== DONE(soft) ====="
