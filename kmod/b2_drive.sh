#!/bin/bash
# b2_drive.sh —— 官方 Manager 显形 → 给三个标准 app 授权 → 复证，一条命令。
#   B1..B3 换来的三条硬规矩：
#     ①**绝不 force-stop** 官方 App：驱动 fd 是启动时抢装进"那一个实例"的，杀掉它 = 自伤（B1 就是这么废的）。
#       要用新状态时只重造 **Activity**（`--activity-clear-top`，同进程，fd 还在）。
#     ②`ls /proc/<别的 uid>/fd` 恒空（DAC 挡住，报错被 grep 吃成 0）⇒ 那不是 fd 读数，别用。
#     ③`ksuctl88 granted <uid>` 的 perm 是 manager_or_root，从 adb shell(2000) 发必然 EPERM/0
#       ⇒ 它只能当"调用者无权"的读数，**不能当名单读数**；名单的真判据是 `asuid <uid> su -c id` 出不出 uid=0。
#   跑法（go.sh 报 GO_RC=0 之后）：
#     bash kmod/b2_drive.sh probe     # 只探：dump UI、判 工作中/不支持/获取Root失败
#     bash kmod/b2_drive.sh grant     # probe 通过才授权三个 app，并复证
set -u
export MSYS_NO_PATHCONV=1
PKG=me.weishu.kernelsu
ACT=$PKG/.ui.MainActivity
CTL=/data/local/tmp/ksuctl88
D=/data/local/tmp
A() { adb shell "$1" 2>&1 | tr -d '\r'; }
PHASE=${1:-probe}
UI=""

dump() {
    A "uiautomator dump $D/b2_ui.xml" >/dev/null 2>&1
    UI=$(A "cat $D/b2_ui.xml 2>/dev/null")
}

judge() {
    local v=unknown
    printf '%s' "$UI" | grep -q 工作中 && v=WORKING
    printf '%s' "$UI" | grep -q 不支持 && v=UNSUPPORTED
    printf '%s' "$UI" | grep -q 获取\ Root\ 失败 && v=NO_ROOT
    printf '%s' "$UI" | grep -q 超级用户 && v=TAB_OK
    echo "$v"
}

echo "=== 0) 窗口体检 ==="
echo "  $(A 'echo up=$(cut -d" " -f1 /proc/uptime) enf=$(getenforce) mod=$(grep -c kernelsu /proc/modules) su=$(ls /product/bin/su 2>/dev/null | wc -l)')"

echo "=== 1) 开关与 RACE 回执 ==="
A "ls -l $D/ksu_race_fd $D/ksu_fd_keepalive 2>&1" | sed 's/^/  /'
A "ls -t $D/ksu_stage*.log 2>/dev/null | head -2" | sed 's/^/  stage log: /'

echo "=== 2) 叫前台（同进程；不 force-stop） ==="
A "input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard" >/dev/null 2>&1
P=$(A "pidof $PKG" | tr -d '\r' | tr -s ' ')
echo "  起前 pid=[$P]"
A "am start -n $ACT" | sed 's/^/  /'
sleep 5
P=$(A "pidof $PKG" | tr -d '\r' | tr -s ' ')
echo "  起后 pid=[$P]"

echo "=== 3) dump UI 并判牌 ==="
dump
echo "  字节=$(printf '%s' "$UI" | wc -c)  节点=$(printf '%s' "$UI" | grep -o '<node' | wc -l)"
for k in 工作中 越狱 不支持 超级用户 模块 设置 获取\ Root\ 失败; do
    echo "  [$k] x$(printf '%s' "$UI" | grep -o "$k" | wc -l)"
done
V=$(judge); echo "  ⇒ 判定=$V"

if [ "$V" = NO_ROOT ]; then
    # ★B4 已证：重造 Activity（同进程 --activity-clear-top）**不重查**——两轮过后仍是「获取 Root 失败」。
    #   原因是那次 su 检查在进程启动时就跑完了，结果缓存在进程里。⇒ 这里不再做无效重试，直接报死因。
    echo "=== 3b) 「获取 Root 失败」⇒ 已证重造 Activity 无效，直接判死因 ==="
    echo "  看 stage log：NOSUW_MGR2_PID / NOSUW_MGR2_FD / NOSUW_RACE2 抢装（fd 没进这一实例 ⇒ 必挂）"
fi

[ "$PHASE" = probe ] && { echo "  (probe 到此为止)"; exit 0; }
case "$V" in
    UNSUPPORTED) echo "  ★仍不支持（fd 没赶上首查）⇒ 不起授权腿"; exit 4 ;;
    NO_ROOT)     echo "  ★仍「获取 Root 失败」（su 没被内核放行）⇒ 不起授权腿"; exit 5 ;;
esac

echo "=== 4) 三个标准 app 授权（走官方 UI 点开关） ==="
g() { # 名称 词 uid 包名
    echo "--- $1 (uid=$3) ---"
    bash kmod/ui_grant.sh "$2" "$3" "$4" 2>&1 | tail -6 | sed 's/^/    /'
    echo "    rc=${PIPESTATUS[0]}"
}
g Scene      scene    10349 com.omarea.vtools
g NP管理器    np       10475 com.wn.app.np
g 黑域        brevent  10261 me.piebridge.brevent

echo "=== 5) 复证：真出 root（granted 那句只当"调用者无权"，不当名单） ==="
for u in 10349 10475 10261; do
    echo "  --- uid=$u ---"
    A "/data/local/tmp/asuid $u /product/bin/su -c id 2>&1 | tail -2" | sed 's/^/    /'
done
echo "=== DONE ==="
