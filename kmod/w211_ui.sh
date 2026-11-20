#!/bin/bash
# w211_ui.sh —— 窗口内**一步步用**的 UI/读数小工具(不是长跑脚本)：§6.211④ 那一发要走官方"模板"页，
#   而那一页里"模板"这一行的坐标**从来没量过** ⇒ 不能把它写死进一条长命令里(§6.197/§6.203 的账)。
#   所以这里每个动词只做一件事、都带回执，由我按读数决定下一步；**判据一律在内核/logcat，不靠眼睛**。
#   用法：bash kmod/w211_ui.sh <动词> [参数]
set -u
cd "$(dirname "$0")/.." || exit 1
export MSYS_NO_PATHCONV=1
A() { timeout 30 adb shell "$1" 2>&1 | tr -d '\r'; }
EV=kmod/w103_evidence; mkdir -p "$EV"
OFL=me.weishu.kernelsu; SUW=com.suw.manager
LOG=/data/local/tmp/dmesg2.log

cmd=${1:-help}
case "$cmd" in
  shot)   # 截图存证并拉回(参数=标签)
    T=${2:-page}; A "screencap -p /data/local/tmp/w211.png" >/dev/null 2>&1
    adb pull /data/local/tmp/w211.png "$EV/w211_${T}.png" >/dev/null 2>&1
    echo "shot $EV/w211_${T}.png $(stat -c %s "$EV/w211_${T}.png" 2>/dev/null) 字节" ;;
  dump)   # 无障碍树(列页/App Profile 页对它是半盲，只当辅助)
    A "rm -f /data/local/tmp/w211.xml; uiautomator dump /data/local/tmp/w211.xml >/dev/null 2>&1; cat /data/local/tmp/w211.xml 2>/dev/null" | tr '<' '\n' | grep -a "package=\"$OFL\"" | head -${2:-12} ;;
  tap)    # 点(坐标由调用方从截图/量测来，本脚本不接受"猜"的坐标——所以这里不校验，只在回执里写清点了哪)
    echo "tap $2 $3"; A "input tap $2 $3" >/dev/null; sleep 3 ;;
  swipe)  echo "swipe $2 $3 $4 $5"; A "input swipe $2 $3 $4 $5 300" >/dev/null; sleep 2 ;;
  wake)   # ★锁屏下 am start 拍到的就是锁屏(§6.209 之后又踩一次)：走路前先唤醒+解键盘
    A "input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard" >/dev/null; sleep 2
    A "dumpsys window 2>/dev/null | grep -aE 'mCurrentFocus|mShowingLockscreen' | head -3" ;;
  home)   A "am start -n $OFL/.ui.MainActivity" >/dev/null 2>&1; echo "回官方主页"; sleep 5 ;;
  tmpl)   # ★app 自己怎么看模板列表(这是判据②的程序化读数，不看像素)
    A "logcat -d -t 400 | grep -aE 'TemplateRepository|TemplateViewModel|KsuCli' | tail -25" ;;
  dom)    # ★判据③：内核侧域回执(X6/secctx/DOMAIN 回退)，只出最近 12 行
    A "grep -aE 'X6 before setup_selinux|secctx_to_secid|DOMAIN 回退|allow root for' $LOG 2>/dev/null | tail -12" ;;
  apc)    # 判据：SET_APP_PROFILE 进没进来(AP0/AP1 计数)
    A "echo \$(grep -ac 'KSUBEAT AP0' $LOG 2>/dev/null) \$(grep -ac 'KSUBEAT AP1' $LOG 2>/dev/null)" | tr -dc '0-9 '; echo ;;
  prof)   # 内核里这一条 profile 到底存成什么样(王座口径，全量名单)
    A "grep -a 'NEW_GET_ALLOW_LIST\|allow\[' /data/local/tmp/w205_list.out 2>/dev/null | tail -12" ;;
  kmsg)   # 全量最近内核行(出意外时用)
    A "tail -25 $LOG 2>/dev/null" ;;
  state)  echo "UP=$(A 'cut -d" " -f1 /proc/uptime')  MOD=$(A 'grep -c kernelsu /proc/modules')  LOAD=$(A 'cat /proc/loadavg')  ENF=$(A 'getenforce')"
    echo "--- 王座/装机 ---"; A "grep -aE 'GET_MANAGER_APPID|X6|DOMAIN' $LOG 2>/dev/null | tail -4" ;;
  rleg)   # 经 suw 的 root 通道发一条短腿(参数=设备上的脚本名，如 w210_tmpl.sh)
    S=${2:?用法: rleg <设备侧脚本名>}
    OUTDEV=/data/local/tmp/${S%.sh}.out
    A "rm -f $OUTDEV" >/dev/null
    A "am force-stop $SUW" >/dev/null; sleep 1
    A "am start -n $SUW/.MainActivity --es auto ksuarm --es cmd \"@sushd:/data/local/tmp/$S\"" >/dev/null 2>&1
    # ★#172(第 37 发一手，10-22)：先问"这条腿自己写不写 .out"。"等 DONE"这个判据**只对有氧化的腿有效**；
    #   对不产 .out 的腿(如 w426_enforce.sh，它的 stdout 归 sushd)空等 12 轮＝把"仪器读不到"报成"腿坏了"。
    P=$(A "grep -acF '$OUTDEV' /data/local/tmp/$S 2>/dev/null" | tr -dc '0-9')
    if [ "${P:-0}" = "0" ]; then
        echo "  [i] $S 派下去了，但这件腿**里没有 $OUTDEV 这个生产者** ⇒ '等 DONE' 对它无效"
        echo "      完成判据请换两条：①**状态变化**(PC 侧独立读回那个值)②**入口证人**(sushd.log 里 granted=1 cmd=[…] 那行)"
        echo "      ★退出码 7＝'这台仪器读不到它的完成信号'，**不等于腿失败、也不等于没跑**(例 84 的三种世界)"
        exit 7
    fi
    c=0
    for i in $(seq 1 12); do sleep 3
        c=$(A "grep -acF '=== DONE' $OUTDEV 2>/dev/null" | tr -dc '0-9')
        [ "${c:-0}" != "0" ] && { echo "  root 腿 $S 完成(轮=$i)"; break; }
    done
    # ★10-22 自测抓到的既存缺陷：原来这行是 `[ … ] && echo …`，读到 DONE 时短路成**退出码 1**、
    #   等满反而 0 ⇒ 成功与失败的方向是反的。现在两支各有明确出口码：0=读到 DONE，8=有生产者却等满。
    if [ "${c:-0}" = "0" ]; then
        echo "  ★$S 没等到 DONE(轮=12) ⇒ 通道或脚本有问题，别看旧内容下结论(退出码 8)"
        exit 8
    fi ;;
  fetch)  # 把短腿的输出拉回本地存证
    S=${2:?用法: fetch <设备侧脚本名>}; adb pull "/data/local/tmp/${S%.sh}.out" "$EV/${S%.sh}.out" >/dev/null 2>&1
    echo "--- $EV/${S%.sh}.out ---"; cat "$EV/${S%.sh}.out" 2>/dev/null ;;
  *) echo "动词: shot|dump|tap X Y|swipe|home|tmpl|dom|apc|prof|kmsg|state|rleg <腿>|fetch <腿>" ;;
esac
