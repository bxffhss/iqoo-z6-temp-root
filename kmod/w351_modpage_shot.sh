#!/usr/bin/env bash
# w351_modpage_shot.sh —— 把官方 Manager 冷启动到"模块"页并**截图存证**（判据是像素，不是 a11y 树）。
# 用法：bash kmod/w351_modpage_shot.sh <标签>
# ★为什么用截图：第 115/116 发两次实测——模块页的 uiautomator 树只给 `主页/超级用户/模块/设置` 四个导航标签，
#   列表内容(以及"正在刷新…")**不进树** ⇒ 拿 a11y 判"有没有列出模块"必假阴性。
set -u
export MSYS_NO_PATHCONV=1
TAG=${1:-t0}; MGR=me.weishu.kernelsu
EV=kmod/w103_evidence; mkdir -p "$EV"
S(){ timeout 60 adb shell "$1" 2>&1 | tr -d '\r'; }

# ★★绝不 force-stop 官方 Manager(第 117 发的学费，§6.258③)：fd 是装在**那个进程**里的，杀掉就掉回"不支持"，
#   而抢装窗口只在 insmod 后几十秒——本发四次"起看门狗+冷启动"都没翻回来，等于把这一格判据弄丢到下一 boot。
#   要重进页面只需要 am start(它是 singleTop) + 深链。
S "am start -n $MGR/.ui.MainActivity >/dev/null 2>&1"; sleep 6
# ★页签要深链才进树(#124 一手：同一进程 12253B/tabs=0 → 补深链 → 18360B/tabs=4)
S "am start -a android.intent.action.VIEW -d ksu://action/superuser $MGR >/dev/null 2>&1"; sleep 4

# 先读一次树，确认页签在（不在就别点，免得把"没点中"当成"页面空"）
S "rm -f /data/local/tmp/w351_a.xml; uiautomator dump /data/local/tmp/w351_a.xml >/dev/null 2>&1" >/dev/null
adb pull //data/local/tmp/w351_a.xml "$EV/w351_nav_$TAG.xml" >/dev/null 2>&1
N=$(grep -o -a -E 'text="(主页|超级用户|模块|设置)"' "$EV/w351_nav_$TAG.xml" 2>/dev/null | wc -l | tr -dc '0-9')
echo "  页签在树里的数量=$N(满值 4)"
if [ "${N:-0}" -lt 3 ]; then
    echo "  [!] 页签没进树 ⇒ 不点页签，只截当前屏存证（这一格标成'没点到'，不是'页面空'）"
    S "screencap -p /data/local/tmp/w351_$TAG.png" >/dev/null
    adb pull "//data/local/tmp/w351_$TAG.png" "$EV/w351_$TAG.png" >/dev/null 2>&1
    exit 4
fi
S "input tap 675 2195"; sleep 8
S "screencap -p /data/local/tmp/w351_$TAG.png" >/dev/null
adb pull "//data/local/tmp/w351_$TAG.png" "$EV/w351_$TAG.png" >/dev/null 2>&1
ls -l "$EV/w351_$TAG.png" | tail -1
echo "  --- 同一时刻的 ksud 动词(有没有真发出 Module{List}) ---"
S "logcat -d -s KernelSU 2>/dev/null | grep -a 'ksud::cli' | tail -4" | sed 's/^/    /'
echo "SHOT=$EV/w351_$TAG.png"
