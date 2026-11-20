#!/system/bin/sh
# ksu_module_apply.sh —— 在**临时 root 的窗口内**应用一个 KernelSU 形态的模块(md §6.62)
#
# 为什么只需要这一个脚本：模块从来不是"管理器"加载的，是 root 侧 runner 加载的 ⇒ 不需要第三方
#   Manager，也不需要啃 seccomp。边界(§6.61/记忆 item 23)：
#   - 可行：脚本类(post-fs-data.sh/service.sh)、文件替换类(system/ 逐文件 mount --bind)
#   - sepolicy.rule 整个免掉：窗口内本来就是 Permissive(而且我们的构建剔除了 rules.o/sepolicy.o)
#   - 不可行：依赖开机时序、或要重启框架(zygote/LSPosed 那类)——本 boot 只有 3~5 分钟
#   - 模块里调 `su` 会撞上那颗雷(sucompat 命中 execve(/system/bin/su) → 改写到 ksud → 无声复位)，
#     所以这里**一律不 exec su**：脚本直接由本(root)进程跑，已经是 uid 0。
#
# ★时序纪律(这条最贵)：每一步都套 `timeout`，整脚本有硬上限。窗口一旦被一个模块脚本挂死，
#   这一发就白烧了 —— 宁可报"脚本超时被杀"也不能等。
# 用法(以 root 跑): sh /data/local/tmp/ksu_module_apply.sh <模块目录>
MOD=${1:-/data/local/tmp/mod}
REC=/data/local/tmp/ksu_mod_mounts.txt
BEF=/data/local/tmp/ksu_mod_before.txt   # 每行 "路径 md5"，给 teardown 做"变回原样"的判据
LOG=/data/local/tmp/ksu_mod_apply.log
# ★硬上限：单脚本 20s、整段 apply 90s。本机 toybox 有 timeout(预检核过)。
TMO=20
: > "$LOG"; : > "$REC"; : > "$BEF"
exec >> "$LOG" 2>&1
log() { echo "[$(date +%H:%M:%S)] $*"; sync; }
PT=/system/bin:/system/xbin:/product/bin:/vendor/bin

log "===== 模块 apply 开始 uid=$(id -u) enforce=$(getenforce) up=$(cut -d' ' -f1 /proc/uptime) ====="
[ "$(id -u)" = "0" ] || { log "!! 不是 root ⇒ 什么都不做(这个脚本只能在窗口里跑)"; exit 1; }
[ -d "$MOD" ] || { log "!! 模块目录不存在: $MOD"; exit 1; }

log "----- ① module.prop -----"
if [ -f "$MOD/module.prop" ]; then
    sed 's/^/  /' "$MOD/module.prop"
    ID=$(grep -m1 '^id=' "$MOD/module.prop" | cut -d= -f2 | tr -d '\r')
    NAME=$(grep -m1 '^name=' "$MOD/module.prop" | cut -d= -f2 | tr -d '\r')
else
    ID=unknown; NAME="(没有 module.prop)"
    log "  没有 module.prop ⇒ id=unknown(不阻断，判据靠后面两步)"
fi
log "id=[$ID] name=[$NAME] 目录实况=[$(ls "$MOD" 2>&1 | tr '\n' ' ')]"

log "----- ② 判据前置: 替换目标在挂载前是什么(正对照的'before') -----"
# ★先记 before，最后再记 after：两格都变/都没变才是结论，只看"mount 成功"等于没判。
find "$MOD/system" -type f 2>/dev/null | while read -r f; do
    rel=${f#$MOD}                      # /system/etc/hosts 之类
    BM=$(timeout 5 md5sum "$rel" 2>/dev/null | cut -d' ' -f1)
    [ -n "$BM" ] && echo "$rel $BM" >> "$BEF"
    log "  target $rel : before_md5=[$BM]"
done

log "----- ③ 文件替换: system/ 逐文件 mount --bind -----"
# erofs 只读**不妨碍** bind 覆盖(bind 改的是挂载表，不动底层文件系统)。
# 只覆盖"目标已存在"的普通文件：目标是符号链接/不存在时 bind 语义会跑偏，直接跳过并说明。
find "$MOD/system" -type f 2>/dev/null | while read -r src; do
    dst=${src#$MOD}
    if [ ! -e "$dst" ] || [ -L "$dst" ]; then
        log "  跳过 $dst (不存在或是符号链接) ⇒ 需要它就得改脚本做整目录挂载"
        continue
    fi
    # ★用 suwbind 而不是 `mount -o bind`：本机 toybox 0.8.9-android 的 mount **没有 bind 支持**
    #   (任何写法都退化成 "bad /etc/fstab")，窗口里会发现"命令返回了但什么都没挂"。
    OUT=$(timeout 10 /data/local/tmp/suwbind "$src" "$dst" 2>&1)
    if [ $? = 0 ]; then
        echo "$dst" >> "$REC"
        log "  bind OK  $src -> $dst :: $(echo "$OUT" | tr '
' '|')"
        log "    复读: $(/data/local/tmp/suwbind --check "$dst" 2>&1 | tr '
' '|')"
    else
        log "  !! bind 失败 $dst :: $(echo "$OUT" | tr '
' '|')"
    fi
done
log "挂上的条数=$(wc -l < $REC 2>/dev/null)"
log "  /proc/mounts 里的实况(一手，不看命令返回码):"
if [ -s "$REC" ]; then
    while read -r d; do
        log "    $(grep -m1 -- "$d" /proc/mounts 2>/dev/null)"
    done < "$REC"
else
    log "    (一条都没挂上)"
fi

log "----- ④ after: 目标内容真的变成模块版了吗(正对照的'after') -----"
while read -r dst; do
    [ -n "$dst" ] || continue
    log "  $dst : after_md5=$(timeout 5 md5sum "$dst" 2>/dev/null | cut -d' ' -f1) 首行=[$(head -1 "$dst" 2>/dev/null)]"
done < "$REC"

log "----- ⑤ 脚本类: post-fs-data.sh / service.sh (直接以本进程身份跑，绝不调 su) -----"
for s in post-fs-data.sh service.sh; do
    if [ -f "$MOD/$s" ]; then
        log "  --- 跑 $s (上限 ${TMO}s) up=$(cut -d' ' -f1 /proc/uptime)"
        # ★toybox sh 的算术不能带小数(旧坑)，这里只用整数 timeout；cwd=/、PATH 用系统那套
        ( cd / && PATH=$PT timeout "$TMO" sh "$MOD/$s"; rc=$?; log "  $s rc=$rc $( [ $rc = 124 ] && echo '⇒ 被 timeout 杀的(窗口保命优先)' )"; sync )
    else
        log "  没有 $s"
    fi
done

log "----- ⑥ 落地判据: 脚本自己写的证据文件 -----"
for f in /data/local/tmp/ksu_mod_selftest.txt; do
    log "  $f = [$(cat "$f" 2>&1 | tr '\n' '|')]"
done
log "----- ⑦ 新起进程能不能看到替换后的目标(已跑着的进程不变，这条才是要证的) -----"
FIRST=$(head -1 "$REC" 2>/dev/null)
if [ -n "$FIRST" ]; then
    log "  另起一个 sh 读 $FIRST 的首行 = [$(timeout 5 sh -c "head -1 $FIRST" 2>&1)]"
    log "  (上面这条是**新进程**读的 ⇒ 看见模块内容才算 bind 真的对后来者生效)"
else
    log "  没有挂载记录 ⇒ 这一格跳过(不算通过)"
fi

log "===== apply 结束: 清场用 sh /data/local/tmp/ksu_module_teardown.sh up=$(cut -d' ' -f1 /proc/uptime) ====="
sync
chmod 666 "$LOG" "$REC" 2>/dev/null
