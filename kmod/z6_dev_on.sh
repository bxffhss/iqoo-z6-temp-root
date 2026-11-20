#!/system/bin/sh
# z6_dev_on.sh — 设备侧 ①「安装模块」(root)：w230 重建 ZN+LSPosed → w232 前置闸
#   跑法（在已授权的目标 App root 终端）：  su -c 'sh /sdcard/z6root/z6_dev_on.sh'
#   前提：z6root.sh 已跑过（有活窗口 mod=1）；/sdcard/z6root/ 里有 kmod/ modules/ w234_ksud_orig probe2.jar
set -u
SRC="${SRC:-/sdcard/z6root}"; TMP=/data/local/tmp; MZ="/sdcard/Download/必备模块"
LOG="$TMP/z6_dev_on.log"; : > "$LOG"
log(){ echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }
log "===== Z6_DEV_ON uid=$(id -u) ====="
[ "$(id -u)" = 0 ] || { log "[x] 需 root：目标 App 里 su -c 'sh $SRC/z6_dev_on.sh'"; echo "===== DONE(need root) ====="; exit 1; }
MOD=$(grep -c kernelsu /proc/modules 2>/dev/null); MOD=${MOD:-0}
[ "$MOD" = 1 ] || { log "[x] 无活窗口(mod=$MOD) ⇒ 先跑 z6root.sh 拿临时 root"; echo "===== DONE(no window) ====="; exit 1; }

# 铺脚本/载荷
mkdir -p "$TMP"
cp -f "$SRC"/kmod/*.sh "$TMP"/ 2>/dev/null
[ -f "$SRC/probe2.jar" ] && cp -f "$SRC/probe2.jar" "$TMP/probe2.jar"
if [ -f "$SRC/w234_ksud_orig" ]; then cp -f "$SRC/w234_ksud_orig" "$TMP/w234_ksud_orig"
elif [ -f "$SRC/ksud" ]; then cp -f "$SRC/ksud" "$TMP/w234_ksud_orig"; fi
mkdir -p "$MZ"; for z in "$SRC"/modules/*.zip; do [ -f "$z" ] && cp -f "$z" "$MZ/"; done
chmod 755 "$TMP"/*.sh 2>/dev/null; chmod 644 "$TMP/probe2.jar" 2>/dev/null
log "铺好: scripts=$(ls "$TMP"/*.sh 2>/dev/null|wc -l) zips=$(ls "$MZ"/*.zip 2>/dev/null|wc -l) ksud=$([ -f "$TMP/w234_ksud_orig" ]&&echo y||echo n)"

# w230 重建模块
[ -f "$TMP/w230_rebuild_all.sh" ] || { log "[x] 缺 w230"; exit 2; }
sh "$TMP/w230_rebuild_all.sh"; sleep 1
grep -q KSUD_OK "$TMP/w230_rebuild_all.out" 2>/dev/null && log "w230 KSUD_OK" || log "[!] w230 未见 KSUD_OK（继续）"
# w232 前置闸
[ -f "$TMP/w232_zn_precheck.sh" ] || { log "[x] 缺 w232"; exit 2; }
sh "$TMP/w232_zn_precheck.sh"; sleep 1
if grep -q ZGATE=PASS "$TMP/w232_zn_precheck.out" 2>/dev/null; then
  log "ZGATE=PASS ⇒ 模块就绪，下一步 z6_dev_soft.sh"
else
  log "[x] ZGATE 未过 ⇒ 停（见 $TMP/w232_zn_precheck.out）"; tail -8 "$TMP/w232_zn_precheck.out" 2>/dev/null | sed 's/^/  /'
  echo "===== DONE(zgate fail) ====="; exit 3
fi
# ★起 shd（idle=0 + cgroup 脱离 z6stage）——它必须扛过软重启，之后 su/@sushd 才连得上 @suwshd 拿到 root
log "-- 起 shd（idle=0 + cgroup 脱离，扛软重启）--"
SHD=/data/local/tmp/shd
[ -x "$SHD" ] || { [ -f "$SRC/shd" ] && cp -f "$SRC/shd" "$SHD"; }
chmod 755 "$SHD" 2>/dev/null
for p in $(pidof shd 2>/dev/null); do kill -9 "$p" 2>/dev/null; done; sleep 1
( cd /data/local/tmp && /system/bin/setsid nohup "$SHD" 31339 0 </dev/null >>/data/local/tmp/shd.log 2>&1 & ) 2>/dev/null
sleep 2
mkdir -p /sys/fs/cgroup/z6stage 2>/dev/null
for p in $(pidof shd 2>/dev/null); do echo "$p" > /sys/fs/cgroup/z6stage/cgroup.procs 2>/dev/null; echo -1000 > /proc/$p/oom_score_adj 2>/dev/null; done
log "SHD=[$(pidof shd)] cgroup=[$(for p in $(pidof shd); do cat /proc/$p/cgroup 2>/dev/null|tail -1; done|tr '\n' ' ')]"
echo "===== DONE(on) ====="
