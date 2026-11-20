#!/system/bin/sh
# z6_dev_after.sh — 设备侧 ③「软重启后」(root)：注入 LSPosed + shd + 抢装 + 维持件（不踢框架）
#   跑法（软重启、framework 回来后）：su -c 'sh /sdcard/z6root/z6_dev_after.sh'
#   等价于 SKIP_KICK=1 跑 z6_stage4（起来自检/起 zn+lspd/打针/shd/守 serial/抢装管理器 fd/维持件）。
set -u
SRC="${SRC:-/sdcard/z6root}"; TMP=/data/local/tmp
LOG="$TMP/z6_dev_after.log"; : > "$LOG"
log(){ echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }
log "===== Z6_DEV_AFTER uid=$(id -u) boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null) ====="
[ "$(id -u)" = 0 ] || { log "[x] 需 root"; echo "===== DONE(need root) ====="; exit 1; }
MOD=$(grep -c kernelsu /proc/modules 2>/dev/null); MOD=${MOD:-0}
[ "$MOD" = 1 ] || { log "[x] 无活窗口(mod=$MOD) ⇒ 先 z6root.sh"; echo "===== DONE(no window) ====="; exit 1; }

# 确保 z6_stage4 在 /data/local/tmp
[ -f "$TMP/z6_stage4.sh" ] || cp -f "$SRC/kmod/z6_stage4.sh" "$TMP/z6_stage4.sh" 2>/dev/null
[ -f "$TMP/z6_stage4.sh" ] || { log "[x] 缺 z6_stage4.sh（先跑 z6_dev_on.sh）"; exit 2; }
[ -f "$TMP/probe2.jar" ] || cp -f "$SRC/probe2.jar" "$TMP/probe2.jar" 2>/dev/null

log "SKIP_KICK=1 起 z6_stage4（注入 + shd + 抢装 + 维持件；约 2–4 分钟后管理器回 工作中[越狱模式]）"
export SKIP_KICK=1
setsid sh "$TMP/z6_stage4.sh" </dev/null >/dev/null 2>&1 &
sleep 1
log "判据：/data/local/tmp/z6_stage4.log 出现 SUCCESS round= / MGR_FD / KEEPER；管理器首页 工作中[越狱模式]"
echo "===== DONE(after) ====="
