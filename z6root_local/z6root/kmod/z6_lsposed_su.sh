#!/system/bin/sh
# z6_lsposed_su.sh — 用 root(su -c) 直接跑七步、绕开 @sushd（suw 那只黑盒 app-intent）
#   在已授权终端（termux 等）里：  su -c 'sh /sdcard/z6root/z6_lsposed_su.sh'
#   全程 root：w230/w232/z6_launch 直接 sh 跑（无 @sushd），长的 z6_stage4 由 z6_launch setsid 脱离。
#   为什么不走 @sushd：suw 被系统反复回收后 @sushd 会"收到但假成功/最后收不到"；su 走 shd(@suwshd) 稳定。
set -u
SRC="${SRC:-/sdcard/z6root}"; TMP=/data/local/tmp; MZ="/sdcard/Download/必备模块"
LOG="$TMP/z6_lsposed_su.log"; : > "$LOG"
log(){ echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG" >&2; }
log "===== Z6_LSPOSED_SU START uid=$(id -u) boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null) ====="
[ "$(id -u)" = 0 ] || { echo "[x] 需 root：su -c 'sh $SRC/z6_lsposed_su.sh'（在已授权终端里）"; exit 1; }
MOD=$(grep -c kernelsu /proc/modules 2>/dev/null); MOD=${MOD:-0}
[ "$MOD" = 1 ] || { log "[x] 无活窗口(mod=$MOD) ⇒ 先 run.sh 开窗"; echo "===== DONE(no window) ====="; exit 1; }

# 0) 铺可执行件到 /data/local/tmp（/sdcard noexec）
log "-- 铺件 --"
cp -f "$SRC"/kmod/*.sh "$TMP"/ 2>/dev/null
[ -f "$SRC/probe2.jar" ] && cp -f "$SRC/probe2.jar" "$TMP/probe2.jar"
if [ -f "$SRC/w234_ksud_orig" ]; then cp -f "$SRC/w234_ksud_orig" "$TMP/w234_ksud_orig"
elif [ -f "$SRC/ksud" ]; then cp -f "$SRC/ksud" "$TMP/w234_ksud_orig"; fi
chmod 755 "$TMP"/*.sh 2>/dev/null; chmod 644 "$TMP/probe2.jar" 2>/dev/null
mkdir -p "$MZ"; for z in "$SRC"/modules/*.zip; do [ -f "$z" ] && cp -f "$z" "$MZ/"; done
log "  已铺 zips=$(ls "$MZ"/*.zip 2>/dev/null|wc -l) probe2=$([ -f "$TMP/probe2.jar" ]&&echo y||echo n) ksud=$([ -f "$TMP/w234_ksud_orig" ]&&echo y||echo n)"

# 1) w230 重建模块（root 直接跑，长脚本 su -c 不限时长）
log "-- ① w230 --"
[ -f "$TMP/w230_rebuild_all.sh" ] || { log "[x] 缺 w230"; exit 2; }
sh "$TMP/w230_rebuild_all.sh"; sleep 1
grep -q KSUD_OK "$TMP/w230_rebuild_all.out" 2>/dev/null && log "  KSUD_OK" || log "  [!] 未见 KSUD_OK（看 out）"

# 2) w232 前置闸
log "-- ② w232 --"
[ -f "$TMP/w232_zn_precheck.sh" ] || { log "[x] 缺 w232"; exit 2; }
sh "$TMP/w232_zn_precheck.sh"; sleep 1
if grep -q ZGATE=PASS "$TMP/w232_zn_precheck.out" 2>/dev/null; then log "  ZGATE=PASS"
else log "[x] ZGATE 未过"; tail -8 "$TMP/w232_zn_precheck.out" 2>/dev/null|sed 's/^/    /'; echo "===== DONE(zgate fail) ====="; exit 3; fi

# 3) z6_launch（root 直接跑；它内部 setsid 把 z6_stage4 脱离起来，扛过踢框架）
log "-- ③ z6_launch 起 z6_stage4（脱离）--"
[ -f "$TMP/z6_launch.sh" ] || { log "[x] 缺 z6_launch"; exit 2; }
sh "$TMP/z6_launch.sh"; sleep 2
log "  已脱离；约 2–4 分钟后管理器应回 工作中[越狱模式]（判据：$TMP/z6_stage4.log 出现 SUCCESS/MGR_FD/KEEPER）"
echo "===== DONE(z6_stage4 launched) ====="
