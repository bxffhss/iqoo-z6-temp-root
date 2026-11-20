#!/bin/bash
# w197_grant_demo.sh —— #82 最后那一格的**活证仪器**：在官方 Manager 的 UI 里把 Termux 的开关
#   关掉→再打开，两次都用内核侧读数认账，证明"这一写只可能来自官方 Manager"。
# 前提(两条，都是今晚 §6.196 量出来的)：
#   ① 窗口已起且**王座就是官方**：官方 APK 预装 + `KO=kmod/kernelsu_rc66.ko I_KNOW=1 bash kmod/go.sh`
#      (天然戴冠；go.sh 第 5.5 步那行会显示 suw 发 SETPROF 吃 EPERM —— 那正是"只有王座能写"的反面证据)
#   ② fd 必须赶在 Manager 启动那次查询之前装好：本脚本自己会跑短腿 `w196_fire.sh` 抢装(§6.193②/§6.196②)
# ★今晚两个坑的解法都写在这里：
#   A) **读名单要 force-stop+起 suw ⇒ 会把官方挤到后台** ⇒ 每次读完必须把官方重新拉到前台再点(否则点在 suw 的界面上，"点了没变")
#   B) 点完要等动画落定再 dump；dump 拿不到东西就**存截图**，绝不猜坐标(§6.147)
set -u
cd "$(dirname "$0")/.." || exit 1
export MSYS_NO_PATHCONV=1
A() { timeout 30 adb shell "$1" 2>&1 | tr -d '\r'; }
EV=kmod/w103_evidence; mkdir -p "$EV"
OFL=me.weishu.kernelsu; SUW=com.suw.manager; TGT=com.termux
CTL=/data/local/tmp/ksuctl
uidof() { A "pm list packages -U" | awk -v P="package:$1" '$1==P {split($2,a,":"); print a[2]}'; }
shot() { A "screencap -p /data/local/tmp/w197.png" >/dev/null 2>&1
         adb pull /data/local/tmp/w197.png "$EV/w197_$1.png" >/dev/null 2>&1
         echo "        (截图 $EV/w197_$1.png $(stat -c %s "$EV/w197_$1.png" 2>/dev/null) 字节)"; }
dump() { A "rm -f /data/local/tmp/w197.xml; uiautomator dump /data/local/tmp/w197.xml >/dev/null 2>&1; cat /data/local/tmp/w197.xml 2>/dev/null"; }
# 只在被测包自己的节点里找，命中就点 bounds 中心(坐标一律从 bounds 算，不硬编)
ctr() { echo "$1" | grep -oE '[0-9]+' | awk 'NR==1{a=$1}NR==2{b=$1}NR==3{c=$1}NR==4{print int((a+c)/2)" "int((b+$1)/2)}'; }   # ★别再拿 awk -F 数 $4：bounds 串切出来 $4 是空(§6.197④1)
pageid() {   # 只认"这一页独有"的东西判页(§6.197④2)；★不要拿『工作中』当门槛——它只在主页有(干跑抓到的)
    local T=$1
    case "$T" in
        *个应用*|*UMOUNT*) echo LIST ;;
        *"App Profile"*|*影响以下应用*) echo PROFILE ;;
        *工作中*|*越狱模式*) echo HOME ;;
        *不支持*) echo NOWORK ;;
        *) echo UNKNOWN ;;
    esac; }
tapnode() {   # 只在被测包自己的节点里找；命中就点 bounds 中心，点前先存一张证
    local RX=$1 B XY
    B=$(dump | tr '<' '
' | grep -a "package=\"$OFL\"" | grep -aE "$RX" | grep -aoE 'bounds="\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]"' | head -1)
    [ -n "$B" ] || { echo "        [!] 没有节点 [$RX]"; shot "miss_${RX//[^a-zA-Z]/_}"; return 1; }
    XY=$(ctr "$B")
    echo "        命中[$RX] $B → 点 $XY"
    A "input tap $XY" >/dev/null; sleep 7; return 0
}
kread() {
    local G
    A "echo $TGTUID > /data/local/tmp/w161_u1.uid; echo $SUWUID > /data/local/tmp/w161_u2.uid; rm -f /data/local/tmp/w161_g2.out" >/dev/null
    A "am force-stop $SUW" >/dev/null; sleep 1
    A "am start -n $SUW/.MainActivity --es auto ksuarm --es cmd \"@sushd:/data/local/tmp/w161_g2.sh\"" >/dev/null 2>&1
    for i in $(seq 1 8); do sleep 3
        c=$(A "grep -acF '=== DONE ===' /data/local/tmp/w161_g2.out 2>/dev/null" | tr -dc '0-9')
        [ "${c:-0}" != "0" ] && break
    done
    G=$(A "grep -a 'UID_GRANTED_ROOT uid='"$TGTUID" /data/local/tmp/w161_g2.out 2>/dev/null" | head -1)
    M=$(A "grep -a GET_MANAGER_APPID /data/local/tmp/w161_g2.out 2>/dev/null" | tail -1 | grep -aoE 'appid=[0-9]+')
    A "am start -n $OFL/.ui.MainActivity" >/dev/null 2>&1; sleep 4      # ★回到官方，后面的点才点在官方身上
    KG=$(echo "$G" | sed -n "s/.*granted=\([0-9]\).*/\1/p")
    echo "        内核: ${G:-（没读到)}  [$M]"
    [ -n "${1:-}" ] || return 0
    [ "$KG" = "$1" ] && echo "        ✅ 实际 granted=$KG 与期望 $1 相符"                       || { echo "        ★实际 [${KG:-读不到}] 与期望 $1 不符 ⇒ 这一格不算活证"; FAIL=$((FAIL+1)); }
}
refire() {   # 抢装 fd 必须走 suw 的 root 通道：/proc/ksu_install_fd 是 0600 root，shell 身份写它必 EACCES
    #   (§6.200：我这一发手滑用 `sh w196_fire.sh` 直接跑 ⇒ 看门狗整轮"写触发口失败"，官方掉回不支持页)
    A "rm -f /data/local/tmp/w196_fire.out" >/dev/null      # ★先删旧 DONE，否则第一轮就误判"已完成"(例 39)
    A "am force-stop $SUW" >/dev/null; sleep 1
    A "am start -n $SUW/.MainActivity --es auto ksuarm --es cmd \"@sushd:/data/local/tmp/w196_fire.sh\"" >/dev/null 2>&1
    local j c
    for j in $(seq 1 10); do sleep 3
        c=$(A "grep -acF '===== DONE' /data/local/tmp/w196_fire.out 2>/dev/null" | tr -dc '0-9')
        [ "${c:-0}" != "0" ] && break
    done
    echo "        fire 轮=$j"
    sleep 22                                                # 等看门狗把新 pid 的 fd 装上 + 启动查询跑完
}
TGTUID=$(uidof "$TGT"); SUWUID=$(uidof "$SUW"); OFLUID=$(uidof "$OFL")
echo "=== 0) 前置：窗口/王座/三个 uid ==="
echo "  mod=$(A 'grep -c kernelsu /proc/modules') enf=$(A getenforce) up=$(A 'cut -d" " -f1 /proc/uptime' | cut -d. -f1)"
echo "  Termux uid=$TGTUID  suw uid=$SUWUID  官方 uid=$OFLUID"
[ "$(A 'grep -c kernelsu /proc/modules' | tr -dc 0-9)" != "0" ] || { echo "[x] 模块没加载 ⇒ 先起窗"; exit 3; }
for v in TGTUID SUWUID OFLUID; do eval "X=\${$v}"; case "$X" in ''|*[!0-9]*) echo "[x] $v 取不到 ⇒ 停"; exit 3;; esac; done
adb push kmod/w196_fire.sh kmod/w161_fdwatch.sh /data/local/tmp/ 2>&1 | tail -1 | sed 's/^/  /'
A "chmod 755 /data/local/tmp/w196_fire.sh /data/local/tmp/w161_fdwatch.sh; rm -f /data/local/tmp/w196_fire.out /data/local/tmp/w161_fdwatch.log" >/dev/null

echo "=== 1) 抢装 fd(短腿，只干活) ==="
refire
A "grep -a 已排队 /data/local/tmp/w161_fdwatch.log | tail -2" | cut -c1-60 | sed 's/^/    /'

echo "=== 2) 确认页面是『工作中』(不是『不支持』) ==="
T=$(dump | tr '>' '\n' | grep -aoE 'text="[^"]+"' | grep -av 'text=""' | head -3 | paste -sd' ' -)
echo "    $T"
case "$T" in *工作中*) : ;; *) echo "[x] 没进工作态 ⇒ 停(别点，点了也没意义)"; shot nowork; exit 4;; esac

nav_to_switch() {   # ★§6.197⑤：每次点之前都重新走到开关跟前(kread 会把官方挤到后台，回来时页面会恢复成上次那页)
    local T P i
    for i in 1 2 3; do
        A "am start -a android.intent.action.VIEW -d ksu://action/superuser" >/dev/null 2>&1; sleep 8
        T=$(dump | tr '>' '\n' | grep -aoE 'text="[^"]+"' | grep -av 'text=""' | paste -sd' ' -)
        P=$(pageid "$T"); echo "    第 $i 轮：深链后页面身份=$P"
        case "$P" in
            NOWORK) echo "        [!] 掉回『不支持』⇒ 重打抢装(kread 之后官方可能被系统杀过，新进程启动那次查询没有 fd)"
                    refire; continue ;;
            LIST)   break ;;
            PROFILE) echo "        已经在 App Profile 页"; return 0 ;;
        esac
        # HOME 且导航在 = 列表页没组出来 / 或无障碍树看不见列表(§6.200：截图明明有 8 行，dump 只吐导航)
        #   ⇒ 先收掉 heads-up 通知(它会占住 a11y 窗口并把内容顶下去、吃掉点按)，再滑一下强制重组
        A "cmd statusbar collapse; settings put global heads_up_notifications_enabled 0" >/dev/null 2>&1
        tapnode 'text="超级用户"'
        A "input swipe 540 1400 540 1000 300" >/dev/null 2>&1; sleep 3
        T=$(dump | tr '>' '\n' | grep -aoE 'text="[^"]+"' | grep -av 'text=""' | paste -sd' ' -)
        P=$(pageid "$T"); echo "        收通知+点导航+滑动后身份=$P"
        [ "$P" = LIST ] && break
    done
    [ "$P" = LIST ] || { echo "    [x] 三轮都到不了列表页 ⇒ 停(不猜坐标)"; shot nolisto; return 1; }
    tapnode 'text="Termux user"' || return 1
    N=$(dump | tr '<' '\n' | grep -ac 'checkable="true"')
    echo "    到 App Profile：checkable 开关个数=$N"
    [ "$N" != "0" ] || { echo "    [!] 这一页没有开关 ⇒ 停(不猜坐标)"; shot noswitch; return 1; }
}
echo "=== 3) 先走到开关跟前(确认这条路走得通，再谈点) ==="
nav_to_switch || exit 5
echo "=== 4) 基线(不预设它是 0 还是 1) ==="
FAIL=0
kread
B0="${KG:-}"
case "$B0" in 0|1) : ;; *) echo "[x] 基线读不到 ⇒ 停(别在没基线的时候点)"; exit 6;; esac
E1=$((1 - B0))
echo "    基线 granted=$B0 ⇒ 点第一下之后期望 $E1"
echo "=== 5) 点第一下 ⇒ 期望翻转($B0 → $E1)：这一翻只可能来自官方 UI(suw 这一发发 SETPROF 是 EPERM) ==="
nav_to_switch && tapnode 'checkable="true"' && kread "$E1"
echo "=== 6) 点第二下 ⇒ 期望翻回 $B0(双向可观测才叫活证) ==="
nav_to_switch && tapnode 'checkable="true"' && kread "$B0"
if [ "$B0" = 0 ]; then
    echo "=== 7) 点第三下：把 Termux 留在 granted=1(交付演示的形状) ==="
    nav_to_switch && tapnode 'checkable="true"' && kread 1
fi
echo "=== 6) 判据(自己念) ==="
echo "  ① 两次翻转都打了 ✅(FAIL=$FAIL，必须 0) ⇒ 这一写只可能来自王座(官方 Manager)——本发 suw 发 SETPROF 是 EPERM、起窗基线 granted=$B0"
echo "  ② 全程王座读数应始终是官方 uid=$OFLUID"
echo "  ③ 收尾前 Termux 要留在 granted=1(交付演示的形状)"
echo "  ★收法：I_KNOW=1 bash kmod/w161_teardown.sh"
