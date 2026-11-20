#!/bin/bash
# w206_oneshot.sh —— #82 最后一格的正式仪器：**一发一点 + 只认全量名单**。
#   为什么是这个形状(§6.201/§6.202 的一手事实)：
#   ① 判据只认 `NEW_GET_ALLOW_LIST`(全量)。`UID_GRANTED_ROOT` 读的是**另一张表**——上一发它全程 0，
#      而全量名单里 10667 随官方 UI 的点击出现过又消失过。拿错表当判据 = #89 那次过判的根因。
#   ② 官方 App 一个进程大概**只发第一次**写(§6.202：第一次 ON 进了表、第一次 OFF 删了表，
#      之后 4 次点击内核里一条 `KSUBEAT AP` 都没有 ⇒ "没发"不是"没收")。
#      ⇒ 每个待测的翻转都**先把官方进程重启 + 重新抢装 fd**，让 UI 状态从内核重新导出，然后**只点一下**。
#   ③ 列表页/App Profile 页对 `uiautomator` 永久半盲(截图有 8 行、dump 只吐底部导航)
#      ⇒ 坐标按**截图几何**给(下面 TAP_* 常量，1080x2388 实测)，且每次点后回读一张截图当 UI 侧读数。
#   ★跑法(窗口内)：bash kmod/w206_oneshot.sh      ★收法：I_KNOW=1 bash kmod/w161_teardown.sh
set -u
cd "$(dirname "$0")/.." || exit 1
export MSYS_NO_PATHCONV=1
A() { timeout 40 adb shell "$1" 2>&1 | tr -d '\r'; }
EV=kmod/w103_evidence; mkdir -p "$EV"
OFL=me.weishu.kernelsu; SUW=com.suw.manager; TGT=com.termux
TGTUID=${TGTUID:-10667}
SHOT=0
pic() { SHOT=$((SHOT + 1)); local F="$EV/w206_${SHOT}_$1.png"
        A "screencap -p /sdcard/w206_$1.png" >/dev/null
        adb pull "/sdcard/w206_$1.png" "$F" >/dev/null 2>&1
        echo "        (截图 $F)" >&2
        echo "$F"; }   # ★stdout 只出路径(给 cmp 用)，提示走 stderr
# 坐标(1080x2388)：底部导航「超级用户」文本中心 / Termux 行中心 / **开关中心随页而变**：
#   编辑器页(Root 访问)= 965 480；分组页(超级用户 + 影响以下应用)= 960 660
#   ★上一跑点空了：同一行进的是分组页，却拿编辑器页的 y=480 去点 ⇒ 落在两张卡片中间，ioctl 自然为 0。
#   ⇒ 用 TAP_SW 传进来，且**点完必须回读一张截图**核对开关颜色真的变了。
TAP_NAV=${TAP_NAV:-"405 2195"}; TAP_ROW=${TAP_ROW:-"400 880"}; TAP_SW=${TAP_SW:-"960 660"}

fire() {   # 抢装 fd：只有 suw 的 root 通道写得动 /proc/ksu_install_fd(0600 root)
    A "rm -f /data/local/tmp/w196_fire.out" >/dev/null          # ★先删旧 DONE(例 39)
    A "am force-stop $SUW" >/dev/null; sleep 1
    A "am start -n $SUW/.MainActivity --es auto ksuarm --es cmd \"@sushd:/data/local/tmp/w196_fire.sh\"" >/dev/null 2>&1
    local j c
    for j in $(seq 1 10); do sleep 3
        c=$(A "grep -acF '===== DONE' /data/local/tmp/w196_fire.out 2>/dev/null" | tr -dc '0-9')
        [ "${c:-0}" != "0" ] && break
    done
    sleep 22
    A "grep -a 已排队 /data/local/tmp/w161_fdwatch.log | tail -1" | cut -c1-60 | sed 's/^/        抢装: /'
}
list() {   # 读**全量**名单，回来两个读数：LC=条数、HAS=10667 在不在里面
    A "rm -f /data/local/tmp/w205_list.out" >/dev/null
    A "am force-stop $SUW" >/dev/null; sleep 1
    A "am start -n $SUW/.MainActivity --es auto ksuarm --es cmd \"@sushd:/data/local/tmp/w205_list.sh\"" >/dev/null 2>&1
    local j c
    for j in $(seq 1 10); do sleep 3
        c=$(A "grep -acF '=== DONE ===' /data/local/tmp/w205_list.out 2>/dev/null" | tr -dc '0-9')
        [ "${c:-0}" != "0" ] && break
    done
    RAW=$(A "grep -aE 'NEW_GET_ALLOW_LIST|allow\[' /data/local/tmp/w205_list.out 2>/dev/null")
    [ -n "$RAW" ] || { echo "        [x] 名单读不到 ⇒ 这一格按没测到算(不许拿'没读到'当'没有')"; LC="?"; HAS="?"; return 1; }
    echo "$RAW" | sed 's/^/          /'
    LC=$(echo "$RAW" | grep -aoE 'count=[0-9]+' | head -1 | tr -dc '0-9')
    HAS=$(echo "$RAW" | grep -acE "uid=$TGTUID")
    echo "        ⇒ count=${LC:-?} 含 $TGTUID 的条数=$HAS"
    A "am start -n $OFL/.ui.MainActivity" >/dev/null 2>&1; sleep 3
    return 0
}
# ★屏幕必须**醒着且已解锁**才准点：上一跑第一翻失败就是因为 go.sh 跑了 15 分钟期间屏幕熄了，
#   dump 拍到的是锁屏(例 52)，`input tap` 全落在锁屏上 ⇒ "官方没发"是仪器自己造的假象。
wake() {
    A "input keyevent 224" >/dev/null; sleep 2                 # WAKEUP
    A "input swipe 540 1900 540 900 300" >/dev/null; sleep 2   # 上滑收锁屏(本机 secure=false)
    echo "        唤醒后: $(A 'echo wake=$(dumpsys power | grep -m1 -o "Awake") key=[$(cat /sys/class/power_supply/button/wake_method 2>/dev/null)]')"
}
onground() {   # 门槛：dump 里必须能看到底部导航的「超级用户」，否则说明没解锁/没在官方页 ⇒ 不许点
    local n
    n=$(A "uiautomator dump /sdcard/w206g.xml >/dev/null 2>&1; grep -ac 超级用户 /sdcard/w206g.xml 2>/dev/null" | tr -dc '0-9')
    echo "        门槛:导航『超级用户』在树上=$([ "${n:-0}" != "0" ] && echo 是 || echo 否)"
    [ "${n:-0}" != "0" ]
}
apc() {   # 内核侧主判据：SET_APP_PROFILE 有没有真的进来(rc52 起 do_set_app_profile 入口就有这两句)
    #   只出两个干净的数字(AP0 AP1)，别把中文/符号带进算术里
    A "echo \$(grep -ac 'KSUBEAT AP0' /data/local/tmp/dmesg2.log 2>/dev/null) \$(grep -ac 'KSUBEAT AP1' /data/local/tmp/dmesg2.log 2>/dev/null)" | tr -dc '0-9 '
}
pol() {   # 污染对照：这几项若在两次读数之间变了，说明中间发生过"整表重灌"(§6.204)，那一格作废
    A "echo PFD=\$(grep -ac 'on_post_fs_data' /data/local/tmp/dmesg2.log 2>/dev/null) LOAD=\$(grep -ac 'load_allow_list' /data/local/tmp/dmesg2.log 2>/dev/null) L5=\$(grep -ac 'KSUBEAT L5' /data/local/tmp/dmesg2.log 2>/dev/null)" | tr -dc '0-9='; echo
}
measure_switch() {   # ★开关中心**量出来**，不再肉眼估：上一发我"点开关"点的 y=660/480，
    #   而实测药丸框是 x 862..995 y 760..842(中心 928,801) ⇒ 差 120~320 像素，全落在药丸外面。
    #   做法：右半区找"横向连续成块的等色块"，**两种主题都要认**(浅灰 180..245 或 深灰 55..110)；
    #   §6.207 的账：只认浅灰时，深色主题的 Profile 页找不到块 ⇒ 退回兜底常量 ⇒ 点空。
    local F=$1
    PYTHONUTF8=1 python - "$F" <<'PY'
import sys
from PIL import Image
im=Image.open(sys.argv[1]).convert("RGB"); w,h=im.size; px=im.load()
def scan(lo,hi):
    rows=[]
    for y in range(300,1200,2):
        run=[]
        for x in range(600,w,2):
            r,g,b=px[x,y]
            if abs(r-g)<14 and abs(g-b)<14 and lo<=r<=hi: run.append(x)
            else:
                if len(run)>=45 and run[-1]>900: rows.append((run[0],run[-1],y))
                run=[]
        if len(run)>=45 and run[-1]>900: rows.append((run[0],run[-1],y))
    return rows
for lo,hi in ((180,245),(55,110)):
    rows=scan(lo,hi)
    if rows:
        x0=min(r[0] for r in rows); x1=max(r[1] for r in rows); ys=[r[2] for r in rows]
        if 90<=x1-x0<=180 and 50<=max(ys)-min(ys)<=130:      # 必须是"药丸大小"，UMOUNT 那种徽章串会宽到 440+
            print("%d %d" % ((x0+x1)//2, (min(ys)+max(ys))//2)); sys.exit(0)
print("")
PY
}
# 一次"重启官方 → 走到编辑器页 → 只点一下 → 读名单"
one_flip() {   # $1=期望翻转后 HAS(0/1)  $2=标签
    local WANT=$1 TAG=$2 GOT A0 A1 P0 P1n
    echo "--- 一发一点[$TAG]：重启官方 → 抢装 → 点一下 → 判据=内核 AP0 计数 + 全量名单(带污染对照) ---"
    wake
    A "am force-stop $OFL" >/dev/null; sleep 1
    fire
    A "am start -n $OFL/.ui.MainActivity" >/dev/null 2>&1; sleep 8
    onground || { echo "        [x] 不在官方页(锁屏/没起来) ⇒ 这一翻作废，不点"; return 2; }
    local T
    # ★这里不玩嵌套引号(例 40：`bash -n` 抓不到远端丢引号)：直接按**字节**数关键词
    T=$(A "uiautomator dump /sdcard/w206a.xml >/dev/null 2>&1; echo 不支持=\$(grep -ac 不支持 /sdcard/w206a.xml 2>/dev/null) 工作中=\$(grep -ac 工作中 /sdcard/w206a.xml 2>/dev/null)")
    echo "        起页读数: $T"
    case "$T" in
        *"不支持=1"*) echo "        [x] 起来就是不支持页 ⇒ 抢装没赶上启动查询，这一发这一点作废(重跑)"; return 2 ;;
    esac
    A "input tap $TAP_NAV" >/dev/null; sleep 6          # 底部导航 → 超级用户列表
    A "input tap $TAP_ROW" >/dev/null; sleep 6          # Termux 行 → App Profile 页
    local P1 P2 SW
    P1=$(pic "before_$TAG")
    SW=$(measure_switch "$P1")
    if [ -z "$SW" ]; then
        echo "        ★[$TAG] 量不到开关药丸(主题/页面不对) ⇒ **停手不点**，绝不退回硬编常量(§6.207 就是这么点空的)"
        FAIL=$((FAIL + 1)); return 3
    fi
    echo "        开关中心(量出来的是)=[${SW}]  兜底常量=$TAP_SW"
    A0=$(apc); P0=$(pol)
    echo "        点前: 内核 AP0/AP1=[$A0] | 污染对照 $P0"
    A "input tap $SW" >/dev/null; sleep 6              # ★只点这一下(点在量出来的中心)
    P2=$(pic "after_$TAG")
    A1=$(apc); P1n=$(pol)
    echo "        点后: 内核 $A1 | 污染对照 $P1n"
    # UI 侧只用来证明"那一下确实点在开关上"：框内逐点差(状态栏会自己变，整图比不行)
    if cmp -s "$P1" "$P2"; then
        echo "        ★[$TAG] 整图逐字相同 ⇒ 屏幕没变(点空/或坐标偏)，不算 UI 读数"
    else
        if PYTHONUTF8=1 python - "$P1" "$P2" <<'PY'
import sys
from PIL import Image
a=Image.open(sys.argv[1]).convert("RGB"); b=Image.open(sys.argv[2]).convert("RGB")
w,h=a.size; n=0
for y in range(200,1500,2):                 # 排掉状态栏(时钟一定变)
    for x in range(0,w,3):
        pa,pb=a.getpixel((x,y)),b.getpixel((x,y))
        if abs(pa[0]-pb[0])+abs(pa[1]-pb[1])+abs(pa[2]-pb[2])>60: n+=1
print("        UI 侧读数(程序化): 状态栏以下差异像素(采样)=%d  %s"%(n,"开关真的动了" if n else "屏幕没变=点空"))
sys.exit(0 if n else 1)
PY
        then :; else echo "        ★[$TAG] UI 没动 ⇒ 点空，这一格不作 UI 证据(但内核计数仍是主判据)"; fi
    fi
    list; GOT=$HAS
    local D0 N0 N1
    set -- $A0; N0=${1:-0}
    set -- $A1; N1=${1:-0}
    D0=$((N1 - N0))
    echo "        —— 主判据：AP0 点前=$N0 点后=$N1 (增量=$D0)；名单含 $TGTUID 条数=$GOT 期望=$WANT；污染对照 点前 $P0 / 点后 $P1n"
    if [ "$GOT" = "$WANT" ]; then
        echo "        ✅[$TAG] 名单与期望相符(官方 UI 那一下写进了内核这张表)"
    else
        echo "        ★[$TAG] 名单=$GOT 期望 $WANT ⇒ 这一格不算活证"
        FAIL=$((FAIL + 1))
    fi
    return 0
}

echo "=== 0) 前置 ==="
M=$(A "grep -c kernelsu /proc/modules" | tr -dc '0-9')
echo "  mod=$M enf=$(A getenforce) up=$(A 'cut -d" " -f1 /proc/uptime' | cut -d. -f1) 目标 uid=$TGTUID"
[ "$M" != "0" ] || { echo "[x] 模块没加载 ⇒ 先起窗(I_KNOW=1 bash kmod/go.sh)"; exit 3; }
adb push kmod/w196_fire.sh kmod/w161_fdwatch.sh kmod/w205_list.sh /data/local/tmp/ >/dev/null 2>&1
A "chmod 755 /data/local/tmp/w196_fire.sh /data/local/tmp/w161_fdwatch.sh /data/local/tmp/w205_list.sh" >/dev/null
A "cmd notification dismiss 2>/dev/null; settings put global heads_up_notifications_enabled 0" >/dev/null
FAIL=0

echo "=== 1) ★基线：谁都没点之前先读全量名单(§6.201 缺的就是这一格) ==="
list || exit 4
B0="$HAS"; BL="$LC"
case "$B0" in 0|1) : ;; *) echo "[x] 基线读不到 ⇒ 停"; exit 4 ;; esac
echo "  基线：count=$BL 含 $TGTUID=$B0"

echo "=== 2) 走一遍到开关跟前，先看 UI 与内核说的是否一致 ==="
wake
A "am force-stop $OFL" >/dev/null; sleep 1; fire
A "am start -n $OFL/.ui.MainActivity" >/dev/null 2>&1; sleep 8
A "input tap $TAP_NAV" >/dev/null; sleep 6
A "input tap $TAP_ROW" >/dev/null; sleep 6
pic "baseline_page"

echo "=== 3) 第一翻：期望 $B0 → $((1 - B0)) ==="
one_flip "$((1 - B0))" "A"
echo "=== 4) 第二翻(重启官方再来一次)：期望回到 $B0 ==="
one_flip "$B0" "B"
echo "=== 5) 判据(自己念) ==="
echo "  ① 两翻都 ✅(FAIL=$FAIL，必须 0) ⇒ 官方 UI 的开关在**全量名单这张表**上双向可观测"
echo "  ② 本 boot 的负对照：go.sh 5.5 里 suw 发 SETPROF 当场 EPERM(见 w205_go.log) ⇒ 写手只剩王座(官方)"
echo '  ③ 若某翻 FAIL 且内核里 KSUBEAT AP 计数=0 ⇒ 是「官方没发」(App 侧状态机)，不是我们没收 —— 记进 §6.203'
echo "  ★收法：I_KNOW=1 bash kmod/w161_teardown.sh"
echo "  ★还原 heads-up：adb shell settings put global heads_up_notifications_enabled 1"
