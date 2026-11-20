#!/system/bin/sh
# w345_samplemod_dev.sh —— 在**窗口内以 root** 放一个"能被官方 Manager 列出来"的样本模块(#125 的判据素材)
#
# 为什么需要它：§6.244 证过 `Module{List}` 这支**不崩**，但 `/data/adb` 是 0700 root 且里面**没有模块**
#   ⇒ "不崩但列出空"与"根本没跑到"在 UI 上长得一模一样。所以要**先放一个已知内容**，
#   再让"模块页有没有 `窗口内模块自测(suw)` 这一行"变成一条**可读的判据**(而不是"看起来没报错")。
# 用法(以 root 跑)：sh /data/local/tmp/w345_samplemod_dev.sh
# ★每一步都套 timeout；每条判据都"写完立刻读回来"(不接受"我 mkdir 过了")。
MODSRC=${1:-/data/local/tmp/testmod}
MODDIR=/data/adb/modules
OUT=/data/local/tmp/w345_samplemod.out
exec > "$OUT" 2>&1
log() { echo "[$(date +%H:%M:%S)] $*"; }

log "===== 开始 uid=$(id -u) enforce=$(getenforce) up=$(cut -d' ' -f1 /proc/uptime) ====="
[ "$(id -u)" = "0" ] || { log "!! 不是 root ⇒ 什么都不做"; exit 1; }
[ -f "$MODSRC/module.prop" ] || { log "!! 素材不在: $MODSRC/module.prop"; exit 1; }

log "----- ① 放置 -----"
ID=$(timeout 5 grep -m1 '^id=' "$MODSRC/module.prop" | cut -d= -f2 | tr -d '\r\n')
log "  module.prop 里的 id=[$ID]"
[ -n "$ID" ] || { log "!! id 是空的 ⇒ 停(不然会建出一个没有名字的目录，判据就废了)"; exit 1; }
timeout 10 mkdir -p "$MODDIR/$ID"
timeout 10 cp "$MODSRC/module.prop" "$MODDIR/$ID/module.prop"
timeout 10 chmod 755 "$MODDIR" "$MODDIR/$ID"
timeout 10 chmod 644 "$MODDIR/$ID/module.prop"

log "----- ② 贴标签(best-effort：restorecon 在本机可能没有) -----"
if timeout 5 restorecon -R "$MODDIR" 2>/dev/null; then log "  restorecon 跑了"; else log "  restorecon 没跑成(不阻断，看下面的 ls -Z)"; fi

log "----- ③ ★写完立刻读回来(三件都要有回执) -----"
log "  ls -Zl = $(timeout 5 ls -Zl "$MODDIR/$ID" 2>&1 | tr '\n' '|')"
log "  cat module.prop = $(timeout 5 cat "$MODDIR/$ID/module.prop" 2>&1 | tr '\n' '|')"
log "  modules 目录里现有 = [$(timeout 5 ls "$MODDIR" 2>&1 | tr '\n' ' ')]"
log "  以 root 能不能读到(直路，不靠 ls) = $(timeout 5 head -1 "$MODDIR/$ID/module.prop" 2>&1)"

log "----- ④ 判别用的两行(给脚本外面 grep) -----"
if timeout 5 grep -q '^id=' "$MODDIR/$ID/module.prop" 2>/dev/null; then
    log "SAMPLEMOD_OK id=$ID path=$MODDIR/$ID"
else
    log "SAMPLEMOD_FAIL 读不回 module.prop"
fi
log "===== DONE ====="
echo "[===== DONE =====]"
