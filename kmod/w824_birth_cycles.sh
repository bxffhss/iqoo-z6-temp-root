#!/usr/bin/env bash
# w824_birth_cycles.sh —— 第 57 发乙组：**反复把管理器杀干净再起，数 20 轮牌子还在不在**。
#   为什么用这个形状当靶子：第 56 发实测到"正常使用十几分钟就把 64 格出生安装预算烧光"，
#   而每一次 force-stop→start 都是一个**真·主进程出生**（正是该占预算的那种），所以它同时是
#     ①最接近用户日常用法的功能判据（每轮都要看到 工作中／32601-2／越狱有），
#     ②对 rc74c 的速率/上限改动的直接压力测试（20 次合法领头，远不到 4096，也远不到 8 次/秒）。
#   ★两条自己的规矩：每轮都单独记"第几轮/当时时刻/牌子三样"，掉了就把那一轮的 total/cap 现数一起写进 CSV；
#     不许只报成功的那几轮。深链不算切页，所以这里只 am start 首页（牌子就在首页上）。
set -u
cd "$(dirname "$0")/.." || exit 1
export MSYS_NO_PATHCONV=1 PYTHONUTF8=1
N=${1:-20}
PKG=me.weishu.kernelsu
EV=kmod/w103_evidence/shot57
CSV=$EV/w824_cycles.csv
mkdir -p "$EV"
A() { timeout 30 adb shell "$1" 2>/dev/null | tr -d '\r'; }
# ★组件名**现查**，不许照包名猜：第一、二版都写 $PKG/.MainActivity ⇒ 每轮都是 `Error type 3`(Activity class 不存在)，
#   看起来像"牌子掉了"，其实是"页面压根没起来"。真身是 $PKG/.ui.MainActivity ⇒ 现查一次并断言非空。
ACT=$(A "cmd package resolve-activity --brief $PKG" | grep -a "$PKG" | tail -1)
[ -n "$ACT" ] || { echo "[x] 解析不到 $PKG 的启动组件 ⇒ 停(别拿一个起不来的页面测牌子)"; exit 1; }
echo "  启动组件(现查)=$ACT"

: > "$CSV"
echo "round,up,mgrpid,badge,ver,jail,focus,note" >> "$CSV"
echo "=== w824 起：$N 轮 force-stop→start，每轮读牌子 ==="
for i in $(seq 1 "$N"); do
    A "am force-stop $PKG"; sleep 2
    # ★第一版把 keyevent 4 放在 am start **之后**，等于自己把 Manager 踢下去 ⇒ 19/20 轮"焦点没拿到"。
    #   顺序改成：起 → 断言焦点 → 只有焦点不在时才 BACK 一次(关模态框，★绝不点"取消")再起重试。
    A "am start -n $ACT >/dev/null 2>&1"; sleep 6
    FOCUS=$(A "dumpsys window 2>/dev/null | grep -a mCurrentFocus | tail -1" | grep -ao "$PKG" | head -1)
    if [ -z "$FOCUS" ]; then
        A "input keyevent 4" >/dev/null 2>&1
        sleep 1
        A "am start -n $ACT >/dev/null 2>&1"; sleep 5
        FOCUS=$(A "dumpsys window 2>/dev/null | grep -a mCurrentFocus | tail -1" | grep -ao "$PKG" | head -1)
    fi
    A "uiautomator dump /sdcard/w824.xml >/dev/null 2>&1"
    # ★第 58 发一手：轮 7 的"掉牌子"其实是**我这台仪器整轮读数全空**(`total` 那次也读不到)。
    #   `uiautomator dump` 会静默不产文件、`adb pull` 会静默不落地 ⇒ 落点还是**上一轮那份**或空 ⇒ 把"没读到"印成"掉了"。
    #   ⇒ 现在两侧都断言：设备侧字节非空 ∧ 本机落点字节与设备侧一致，不一致就记 EMPTYREAD=未测(不是掉牌)。
    SZD=$(A "wc -c < /sdcard/w824.xml" | grep -ao '[0-9]*' | head -1)
    MSYS_NO_PATHCONV=1 adb pull //sdcard/w824.xml "$EV/w824_last.xml" >/dev/null 2>&1
    SZP=$(wc -c < "$EV/w824_last.xml" 2>/dev/null | grep -ao '[0-9]*' | head -1)
    EMPTYREAD=""
    if [ -z "$SZD" ] || [ "$SZD" -lt 200 ] || [ "$SZP" != "$SZD" ]; then
        EMPTYREAD="读数缺失(设备侧=${SZD:-空} 本机=${SZP:-空})=未测(不是掉牌)"
    fi
    LINE=$(timeout 60 python kmod/w733_badgetext.py "$EV/w824_last.xml" 2>/dev/null | head -1)
    UP=$(A "cut -d' ' -f1 /proc/uptime")
    B=$(printf '%s' "$LINE" | grep -ao '工作中' | head -1)
    V=$(printf '%s' "$LINE" | grep -ao '32601-2' | head -1)
    J=$(printf '%s' "$LINE" | grep -ao '越狱有' | head -1)
    NOTE=""
    MGR=$(A "pidof $PKG" | cut -d' ' -f1)
    [ -z "$FOCUS" ] && NOTE="$NOTE 焦点没拿到=未测(不是掉牌)"
    [ -n "$EMPTYREAD" ] && NOTE="$NOTE $EMPTYREAD"
    [ -z "$MGR" ] && NOTE="$NOTE 管理器进程压根不在"
    if [ -n "$EMPTYREAD" ]; then
        echo "  轮$i up=$UP ⇒ **未测**（$EMPTYREAD；牌子不作结论）"
    elif [ -z "$B" ] || [ -z "$V" ] || [ -z "$J" ]; then
        TAIL=$(A "tail -c 200000 /data/local/tmp/dmesg2.log 2>/dev/null | grep -ao 'total=[0-9]*' | tail -1")
        CAPN=$(A "tail -c 200000 /data/local/tmp/dmesg2.log 2>/dev/null | grep -ac 'KSUBIRTH cap'")
        NOTE="$NOTE 掉牌子：${TAIL:-total读不到} cap行=${CAPN:-读不到}"
        echo "  轮$i up=$UP ⇒ **掉** [$LINE] $NOTE"
    else
        echo "  轮$i up=$UP ⇒ 工作中／32601-2／越狱有 ✓"
    fi
    echo "$i,$UP,${MGR:-无},${B:-无},${V:-无},${J:-无},${FOCUS:-无},\"$NOTE\"" >> "$CSV"
done
echo "=== w824 完；读数在 $CSV ==="
# ★★第 58 发一手：这行原来写死 `$3/$4/$5`，而表头是 `round,up,mgrpid,badge,ver,jail,focus,note`
#   ⇒ 牌子其实在 $4/$5/$6，逐轮明明 20 次都亮，汇总却打 `0/20`＝**我自己数错了列**（和 w810 那次"列名与列值错开一列"同族）。
#   ⇒ 现在**列号从表头现取**，不写死：以后加列也不会再骗我。
echo "  三样都在的轮数=$(awk -F, 'NR==1{for(i=1;i<=NF;i++){if($i=="badge")b=i;if($i=="ver")v=i;if($i=="jail")j=i}next} $b=="工作中" && $v=="32601-2" && $j=="越狱有"{c++} END{print c+0}' "$CSV")/$N"
echo "  其中记为【未测/读数缺失】的轮数=$(awk -F, 'NR>1 && $8~/未测|读数缺失|焦点没拿到/{c++} END{print c+0}' "$CSV")"
