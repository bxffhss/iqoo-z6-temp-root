#!/system/bin/sh
# z6_lsposed.sh — 设备侧 LSPosed 加装 = 照抄 PC 七步，只是把 adb shell 的 am start 换成本地 am start
#   在 uid2000 的 shell（Stellar/Shizuku）里跑：  sh /sdcard/z6root/z6_lsposed.sh
#   关键：每个 @sushd 派单都是"短脚本"（w230/w232/z6_launch），长的 z6_stage4 由 z6_launch 用 setsid 脱离跑。
#   前置：run.sh 已开窗（mod=1、shd 活、suw 已授权）；/sdcard/z6root 有 kmod/ modules/ probe2.jar ksud。
set -u
SRC="${SRC:-/sdcard/z6root}"; TMP=/data/local/tmp; MGR=com.suw.manager; MZ="/sdcard/Download/必备模块"
LOG="$TMP/z6_lsposed.log"; : > "$LOG"
log(){ echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }
log "===== Z6_LSPOSED START uid=$(id -u) boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null) ====="
MOD=$(grep -c kernelsu /proc/modules 2>/dev/null); MOD=${MOD:-0}
[ "$MOD" = 1 ] || { log "[x] 无活窗口(mod=$MOD) ⇒ 先跑 run.sh"; echo "===== DONE(no window) ====="; exit 1; }

# 0) 铺可执行件到 /data/local/tmp（★/sdcard 是 noexec，@sushd exec /sdcard 会 127）
log "-- 铺件到 /data/local/tmp --"
cp -f "$SRC"/kmod/*.sh "$TMP"/ 2>/dev/null
[ -f "$SRC/probe2.jar" ] && cp -f "$SRC/probe2.jar" "$TMP/probe2.jar"
if [ -f "$SRC/w234_ksud_orig" ]; then cp -f "$SRC/w234_ksud_orig" "$TMP/w234_ksud_orig"
elif [ -f "$SRC/ksud" ]; then cp -f "$SRC/ksud" "$TMP/w234_ksud_orig"; fi
chmod 755 "$TMP"/*.sh 2>/dev/null; chmod 644 "$TMP/probe2.jar" 2>/dev/null
mkdir -p "$MZ"; for z in "$SRC"/modules/*.zip; do [ -f "$z" ] && cp -f "$z" "$MZ/"; done
log "  已铺: scripts=$(ls "$TMP"/*.sh 2>/dev/null|wc -l) zips=$(ls "$MZ"/*.zip 2>/dev/null|wc -l) probe2=$([ -f "$TMP/probe2.jar" ]&&echo y||echo n) ksud=$([ -f "$TMP/w234_ksud_orig" ]&&echo y||echo n)"

# 短 @sushd 派单器（每发都是短脚本，长的靠 z6_launch setsid 脱离）
fire(){ local B; B="$(basename "$1")"; local OUT="$2"
  rm -f "$TMP/$OUT"
  am force-stop "$MGR" >/dev/null 2>&1; sleep 1
  am start -f 0x4000000 -n "$MGR/.MainActivity" --es auto ksuarm --es cmd "@sushd:$TMP/$B" >/dev/null 2>&1
  for i in $(seq 1 45); do grep -aq '===== DONE' "$TMP/$OUT" 2>/dev/null && { return 0; }; sleep 3; done
  return 1
}

# 1) w230 重建模块（短）
log "-- ① w230 重建模块 --"; fire w230_rebuild_all.sh w230_rebuild_all.out || log "[!] w230 未见到 DONE"
grep -q KSUD_OK "$TMP/w230_rebuild_all.out" 2>/dev/null && log "  KSUD_OK" || log "  [!] 未见 KSUD_OK"

# 2) w232 前置闸（短）
log "-- ② w232 前置闸 --"; fire w232_zn_precheck.sh w232_zn_precheck.out || log "[!] w232 未见到 DONE"
if grep -q ZGATE=PASS "$TMP/w232_zn_precheck.out" 2>/dev/null; then log "  ZGATE=PASS"
else log "[x] ZGATE 未过 ⇒ 停（见 $TMP/w232_zn_precheck.out）"; tail -8 "$TMP/w232_zn_precheck.out" 2>/dev/null|sed 's/^/    /'; echo "===== DONE(zgate fail) ====="; exit 3; fi

# 3) z6_launch（短：只 setsid 把 z6_stage4 脱离拉起；长活交给它，扛过踢框架）
log "-- ③ z6_launch 起 z6_stage4（脱离；踢框架+注入+shd+抢装+维持件）--"
fire z6_launch.sh z6_launch.out || log "[!] z6_launch 未见到 DONE（看 $TMP/z6_launch.out）"
log "  已脱离启动；约 2–4 分钟后管理器应回 工作中[越狱模式]（判据：$TMP/z6_stage4.log 出现 SUCCESS/MGR_FD/KEEPER）"
echo "===== DONE(z6_stage4 launched) ====="
