#!/system/bin/sh
# w774_pbin_keeper.sh —— 维持"裸 su 的落点"不被删源搞成空壳（第 54 发的形状改动，md §6.425/§6.426）。
#   为什么需要它（一手，不是猜）：官方 Manager 的 su **只有裸串 `su`**（classes.dex 里没有任何绝对 su 路径），
#     所以它走 PATH ⇒ 命中的就是 `/product/bin/su` ⇒ 那层 bind 对 Manager 是**必需件**，不是"裸敲 su 的辅助"。
#   今晚它坏的样子：bind 仍挂着，但源目录 `/data/local/tmp/pbin` 被删 ⇒ mountinfo 变成 `/local/tmp/pbin//deleted`
#     ⇒ **整层 /product/bin 在进程眼里是空目录**（不只是没 su）⇒ "软重启没反应""超级用户页更容易卡"。
#   ⇒ 两条设计改动：①**源挪进 root-only 的 `/data/adb/ksu/pbin`**（普通脚本/app 删不动它；今晚那个位置谁都能 rm -rf）；
#     ②这一条维持循环：只在"挂载没了/源被删"时**重建并重挂**，其余时间只读两行文件。
#   ★三条护栏（都是踩过的）：节拍 20 秒(不是 1 秒)、总次数上限(默认 200≈67 分钟，与窗同寿命)、**开关文件即 kill switch**
#     （删掉就自己退，不用 pkill、不留孤儿——照 w600 的形状）；连续 3 次修不好就 GIVEUP 退出，不无限重试。
TGT=${K774_TGT:-/product/bin}
NB=${K774_NB:-/data/adb/ksu/pbin}
SRC=${K774_SRC:-/data/adb/ksu/sustatic}
SW=${K774_SW:-/data/local/tmp/ksu_pbin_keep}
L=${K774_L:-/data/local/tmp/w774_keeper.log}
N=${K774_N:-200}
STEP=${K774_STEP:-20}
MAXFAIL=${K774_MAXFAIL:-3}

if [ "${1:-}" = selfcheck ]; then     # 离线自检：PC bash 与设备 mksh 都能跑；不碰挂载、不写真实路径
    echo "=== W774 selfcheck(离线：证的是判定形状，不是真机动作) ==="
    fail=0
    chk() { if [ "$2" = "$3" ]; then echo "  [OK] $1 = $2"; else echo "  [BAD] $1 = [$2] 应为 [$3]"; fail=1; fi; }
    # 三行 mountinfo 样本：正常挂 / 源已删(/deleted) / 压根没挂
    A='27492 36 253:44 /local/tmp/pbin /system/product/bin rw shared:33 - f2fs /dev/block/dm-44'
    B='27492 36 253:44 /local/tmp/pbin//deleted /system/product/bin rw shared:33 - f2fs /dev/block/dm-44'
    C='1 2 3:4 /nothing /elsewhere rw - ext4 /dev/zero'
    need() { # 该不该重建？0=不用(挂得好好的) 1=要动手
        printf '%s\n' "$1" | grep -aq "//deleted" && return 1
        printf '%s\n' "$1" | grep -aq "$2" || return 1
        return 0
    }
    need "$A" pbin; chk "正常挂载 → 不动作(0)" "$?" 0
    need "$B" pbin; chk "源已删除 → 要重建(1)" "$?" 1
    need "$C" pbin; chk "没挂我们那条 → 要挂(1)" "$?" 1
    # ★正对照：`//deleted` 必须被认出来（今晚就是它——只查"有没有挂载行"会读成"还挂着"＝假绿）
    case "$B" in *//deleted*) chk "半行识别 //deleted 在场" yes yes;; *) chk "半行识别 //deleted 在场" no yes;; esac
    [ "$fail" = 0 ] || { echo "[x] 自检有红 ⇒ 这条腿不许上机"; exit 1; }
    echo "  节拍=$STEP 秒 × 上限 $N 次 ≈ $((N * STEP / 60)) 分钟；开关=$SW；源=$NB"
    echo "PASS"
    exit 0
fi

say() { echo "$(date '+%H:%M:%S') up=$(cut -d' ' -f1 /proc/uptime) $1" >> "$L"; }
rebuild() {
    [ -s "$SRC" ] || { say "[x] 落点源 $SRC 不在或为空 ⇒ 不重建（不许挂空壳）"; return 1; }
    mkdir -p "$NB" 2>/dev/null
    if [ ! -e "$NB/su" ]; then cp "$SRC" "$NB/su" 2>/dev/null && chmod 755 "$NB/su" 2>/dev/null; fi
    # 先把坏态那条卸载掉（源被删的挂载仍占着挂载点），卸载失败也照做——umount 失败时下面 mount 会自己报错
    grep -aq "//deleted" /proc/self/mountinfo 2>/dev/null && umount "$TGT" 2>/dev/null
    grep -a " $TGT " /proc/self/mountinfo 2>/dev/null | grep -aq "$NB" || mount --bind "$NB" "$TGT"
    [ -e "$TGT/su" ]
}

echo "=== W774 起 up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) 目标=$TGT 源=$NB 开关=$SW N=$N STEP=$STEP ===" > "$L"
[ -f "$SW" ] || { echo "  [x] 开关文件 $SW 不在 ⇒ 拒绝启动（它同时是 kill switch）" >> "$L"; exit 3; }
i=0; bad=0
while [ "$i" -lt "$N" ]; do
    i=$((i + 1))
    [ -f "$SW" ] || { say "开关被删 ⇒ 自退(第 $i 轮)，不留孤儿"; exit 0; }
    M=$(grep -a "//deleted" /proc/self/mountinfo 2>/dev/null | grep -ac "$NB")
    H=$(ls -A "$NB" 2>/dev/null | grep -ac .)
    if [ ! -e "$TGT/su" ]; then
        bad=$((bad + 1))
        say "第 $i 轮：$TGT/su 不在(deleted行=$M 源内文件=$H) ⇒ 重建#$bad"
        if rebuild; then say "  修好了：$TGT/su 现在在"; bad=0
        else say "  [x] 没修好"; fi
        [ "$bad" -ge "$MAXFAIL" ] && { say "GIVEUP 连续 $bad 次修不好 ⇒ 退出 rc=3（不无限重试）"; exit 3; }
    else
        say "第 $i 轮：好(su 在，deleted行=$M 源内文件=$H) —— 什么都不做"
        bad=0
    fi
    sleep "$STEP"
done
say "到上限 $N 次正常退出"
exit 0
