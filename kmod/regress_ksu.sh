#!/bin/bash
# regress_ksu.sh —— **一条命令的端到端回归**：重启→punch→等本 boot 的链→加冕/授权→撤销→
#   未授权负对照→真 app 敲 su→UI 列表，六个闸门各自打 PASS/FAIL，最后汇总并 reboot。
# 为什么要有它(2026-10-03，§6.114 之后)：能力已经齐了，但每次改 apk/shim/stage 都要人肉把
#   五六条命令按顺序跑一遍再逐份看证据 —— 无人托管时最容易出的事故是"跑完了但某一环回退了"。
#   ⇒ 把判据固定成闸门表，退出码=FAIL 的个数。
# 用法：I_KNOW=1 bash kmod/regress_ksu.sh          # 整发(含 reboot 进出)
#       I_KNOW=1 KEEP=1 bash kmod/regress_ksu.sh   # 跑完不 reboot，留窗口继续手工测
#       SKIP_CHAIN=1 bash kmod/regress_ksu.sh      # 链已经在(活窗口)，只跑闸门 2..6
# ★口径(记忆里那条"判据代码自己也会骗自己")：每个闸门都要求**两个独立来源**或**正/负成对**，
#   任何"没报错"都不算 PASS。
#
# ★★过期声明(2026-10-12，第 110~112 发，§6.236~§6.238)——**现在跑它会 FAIL=2，而那不代表链坏了**：
#   G2(授权) 与 G5(撤销) 都走 suw 的 `@setprof:`，而内核从 #95 起只接受 **manager appid(官方 Manager，本机 uid 10104)**
#   写 SET_APP_PROFILE ⇒ suw 与 root 腿一律 `rc=-1 errno=1(EPERM)`；第 110/111/112 发的 `go.sh` 第 5.5 步每次都如实打这条。
#   ⇒ 这两格在修好之前**按 SKIP 理解，不要当回退**。修法：G2 换 `kmod/ui_grant.sh`(§6.237/§6.238 已在窗口里连证两遍)，
#     G5 换 `kmod/ui_grant.sh … --revoke`(§6.240 已实现并**离线双向验过决策表**，但那条 UI 序列还没在窗口里跑过)。
#   其余闸门(G1 加冕 / G3 负对照 / G4 真 app 敲 su / G6 UI 列表)口径仍然有效，但**跑之前先读 §6.238 的三条命令形状**。
set -u
cd "$(dirname "$0")/.." || exit 1
A() { MSYS_NO_PATHCONV=1 adb "$@"; }
S() { A shell "$@" 2>&1; }
PKG=${PKG:-}
GRANT=${GRANT:-}
RUN() {   # RUN <动词> <等待秒>：force-stop 再发 intent，动词才不会被旧进程吃掉
    A shell am force-stop com.suw.manager >/dev/null 2>&1
    sleep 1
    A shell "am start -n com.suw.manager/.MainActivity --es auto ksuarm --es cmd \"$1\"" >/dev/null 2>&1
    sleep "$2"
}
REP=/sdcard/Android/data/com.suw.manager/files/ksu_grant.txt
block() {   # block <cmd 文本>：从追加式报告里挑出**这一段**(两个写者+O_APPEND ⇒ 必须按 banner 切)
    S "cat $REP 2>/dev/null" | awk -v k="cmd=[$1] =====" 'index($0,k){p=1} p' 2>/dev/null
}
clean() {   # ★只去掉 NUL/控制字符，**不能**去掉非 ASCII —— 第一版用 `tr -cd '\11\12\15\40-\176'`
            #   把中文连字节一起删了，于是"扫 /proc/self/fd 得到 1 个"变成"  /proc/self/fd  1  ksu  fd: 3"，
            #   grep 认不到 ⇒ G4/G7 双双假红(设备侧证据其实是全绿)。判据文本不许被判据管道自己吃掉。
    tr -d '\000-\010\013\014\016-\037\177'
}
mkdir -p kmod/regress_evidence
EV=kmod/regress_evidence/$(date +%m%d-%H%M)
mkdir -p "$EV"
FAILS=0
gate() {   # gate <编号> <名字> <0=通过> <说明>
    if [ "$3" = 0 ]; then printf '  [G%s] PASS  %s\n' "$1" "$2"; else
        printf '  [G%s] FAIL  %s —— %s\n' "$1" "$2" "$4"; FAILS=$((FAILS+1)); fi
}

[ "${I_KNOW:-}" = 1 ] || { echo "[x] 这一发会 reboot 并打真机链：要跑就 I_KNOW=1"; exit 2; }

echo "=== 起点自检 ==="
S 'echo up=$(cut -d" " -f1 /proc/uptime) mod=$(lsmod|grep -c kernelsu) sys=$(uname -s) enf=$(getenforce)' | sed 's/^/  /'
if [ -z "${SKIP_CHAIN:-}" ]; then
    echo "  目标包：挑一个第三方包(★不选 com.suw.manager，它是 Manager=天然允许，测不出授权有没有生效)"
    PKG=${PKG:-$(S "pm list packages -3" | tr -d '\r' | sed 's/^package://' | grep -avE '^com\.suw\.manager$' | head -1)}
    GRANT=${GRANT:-$(S "dumpsys package $PKG" | tr -d '\r' | grep -aoE 'appId=[0-9]+' | head -1 | cut -d= -f2)}
    echo "  PKG=$PKG uid=$GRANT"
    echo "=== 1) 重启进干净 boot ==="
    A reboot >/dev/null 2>&1
    for i in $(seq 1 60); do sleep 5; [ -n "$(A get-state 2>/dev/null | grep device)" ] && break; done
    for i in $(seq 1 60); do
        BC=$(S 'getprop sys.boot_completed' | tr -d '\r\n')
        UP=$(S 'cut -d" " -f1 /proc/uptime' | awk -F. '{print $1}')
        [ "$BC" = "1" ] && [ "${UP:-0}" -gt 260 ] && { echo "  boot 就绪 up=${UP}s"; break; }
        sleep 10
    done
    echo "=== 2) push + 删残留(★跨 boot 残留日志会把整发判据带歪，§6.103) ==="
    bash kmod/push_ksu.sh 2>&1 | grep -aE "ok kernelsu.ko|ok ksu_args|ok ksud|\[x\]" | sed 's/^/  /'
    S 'rm -f /data/local/tmp/ksu_stage.log /data/local/tmp/sushd.log /data/local/tmp/dmesg.live /data/local/tmp/dmesg_full.txt /data/local/tmp/w103_run.out /data/local/tmp/w103_run.out.early /data/local/tmp/w103_run.out.late' >/dev/null
    S 'rm -f /sdcard/Android/data/com.suw.manager/files/ksu_grant.txt /sdcard/Android/data/com.suw.manager/files/app_su.txt /sdcard/Android/data/com.suw.manager/files/applist_diag.txt' >/dev/null
    echo "=== 3) punch ==="
    I_KNOW=1 bash suw_apk/bootstrap.sh --punch 2>&1 | grep -aE "slide=|dispatched|pr=" | tail -3 | sed 's/^/  /'
    echo "=== 4) 等**本 boot**的 stage 跑到判据④(post 可能 3~17 分钟，也可能整 boot 不跑 §6.113①) ==="
    for i in $(seq 1 240); do
        sleep 5
        N4=$(S 'grep -ac "判据④" /data/local/tmp/ksu_stage.log 2>/dev/null' | tr -dc '0-9')
        [ "${N4:-0}" != "0" ] && { echo "  判据④ 到了 t+$((i*5))s"; break; }
        [ $((i % 24)) = 0 ] && echo "    还在等 post… t+$((i*5))s"
    done
    if [ "${N4:-0}" = "0" ]; then
        echo "[x] 等满 20 分钟仍没有本 boot 的 stage 日志 ⇒ **不是链回退，是 post 这一发没跑**(§6.113①)"
        echo "    分诊三件套：mod=$(S 'lsmod|grep -c kernelsu') up=$(S 'cut -d" " -f1 /proc/uptime') pr.log 尾部："
        S 'tail -c 300 /data/local/tmp/pr.log' | clean | tail -3 | sed 's/^/      /'
        [ -z "${KEEP:-}" ] && A reboot >/dev/null 2>&1
        exit 3
    fi
else
    PKG=${PKG:-$(S "pm list packages -3" | tr -d '\r' | sed 's/^package://' | grep -avE '^com\.suw\.manager$' | head -1)}
    GRANT=${GRANT:-$(S "dumpsys package $PKG" | tr -d '\r' | grep -aoE 'appId=[0-9]+' | head -1 | cut -d= -f2)}
    echo "  SKIP_CHAIN=1：活窗口，PKG=$PKG uid=$GRANT"
fi
MSYS_NO_PATHCONV=1 adb push kmod/w103_neg.sh /data/local/tmp/w103_neg.sh >/dev/null 2>&1
S 'chmod 755 /data/local/tmp/w103_neg.sh' >/dev/null

echo "=== 闸门 ==="
# G1 内核在 + 我们是 Manager(能发 only_manager 的 SET_APP_PROFILE)：拿 GET_INFO 的 version 当证据
RUN "@mgr" 8
b=$(block "@mgr" | clean)
echo "$b" > "$EV/g1_mgr.txt"
printf '%s\n' "$b" | grep -aq "GET_INFO.*rc=0.*version=[0-9]"
gate 1 "内核侧握手(GET_INFO 有版本号 ⇒ 模块在且我们是加冕的 Manager)" $? \
    "报告里没 GET_INFO rc=0 ⇒ 链没落地或没加冕(看 $EV/g1_mgr.txt)"

# G2 授权面(正对照)：给一个**非 Manager** 的第三方 uid 写 profile，两来源=发起侧 rc + 内核复读 granted
RUN "@setprof:$GRANT:1:$PKG" 10
b=$(block "@setprof:$GRANT:1:$PKG" | clean); echo "$b" > "$EV/g2_setprof.txt"
# ★断言**不能写死整条回执字符串**(第 47 发一手)：JNI 的回执后来多了 ` domain=u:r:shell:s0`，
#   于是 `key=$PKG: rc=0` 这个整体匹配失配 ⇒ 明明 `granted=1` 却被判 FAIL。
#   改成"三个互相独立的必要条件分别查"(同一行里有 uid+allow / 有 key / 有 rc=0)，
#   形状再变也不会误判；真失败(内核回 granted=0)照样会被抓到。
ln=$(printf '%s\n' "$b" | grep -a "SETPROF uid=$GRANT allow=1" | grep -a "key=$PKG" | head -1)
printf '%s\n' "$ln" | grep -aq "rc=0"
r1=$?
printf '%s\n' "$b" | grep -aq "UID_GRANTED_ROOT uid=$GRANT: rc=0 granted=1"
r2=$?
[ $r1 = 0 ] && [ $r2 = 0 ]; gate 2 "授权($PKG uid=$GRANT)：发起侧 rc=0 且内核复读 granted=1" $? \
    "两来源没同时绿(rc=$r1 granted=$r2，见 $EV/g2_setprof.txt)"

# G3 名单里确实有它(第三个来源：内核自己列出来)
RUN "@list" 8
block "@list" | clean > "$EV/g3_list.txt"
grep -aq "LIST uid=$GRANT" "$EV/g3_list.txt"
gate 3 "内核 @list 里能看到 uid=$GRANT(不是我们本地记的账)" $? "没列出(见 $EV/g3_list.txt；★Manager 自己永不列出，所以才挑第三方)"

# G4 真 app 敲 su(正)：扫到内核装的驱动 fd + uid 后是 0 + 不打 reboot
RUN "@su:id" 10
S 'cat /sdcard/Android/data/com.suw.manager/files/app_su.txt 2>&1' | clean > "$EV/g4_app_su.txt"
grep -aq "SHIM-ESC 扫 /proc/self/fd 得到 [1-9]" "$EV/g4_app_su.txt"; s1=$?
grep -aq "uid后=0" "$EV/g4_app_su.txt"; s2=$?
grep -aq "^uid=0(root)" "$EV/g4_app_su.txt"; s3=$?
grep -aq "SHIM-ESC reboot(magic)" "$EV/g4_app_su.txt"; s4=$?   # 1=没出现=好
[ $s1 = 0 ] && [ $s2 = 0 ] && [ $s3 = 0 ] && [ $s4 = 1 ]
gate 4 "真 app 敲 su → uid=0(root)，且全程没打 reboot(魔数)" $? \
    "s1=$s1 s2=$s2 s3=$s3 s4=$s4(s4 期望 1) ⇒ 见 $EV/g4_app_su.txt；app 域里 reboot=SIGSYS 就是 §6.110 那个死形"

# G5 撤销(负对照)：allow=0 之后内核必须说不给
RUN "@setprof:$GRANT:0:$PKG" 10
b=$(block "@setprof:$GRANT:0:$PKG" | clean); echo "$b" > "$EV/g5_revoke.txt"
printf '%s\n' "$b" | grep -aq "SETPROF uid=$GRANT allow=0"
v1=$?
printf '%s\n' "$b" | grep -aq "granted=0"
v2=$?
[ $v1 = 0 ] && [ $v2 = 0 ]; gate 5 "撤销后内核复读 granted=0(负对照)" $? "v1=$v1 v2=$v2，见 $EV/g5_revoke.txt"

# G6 未授权 uid 敲 su(负)：必须 ENOENT/非 0 —— 证明"改道"是**按名单**的，不是全局后门
S 'rm -f /data/local/tmp/w103_run.out' >/dev/null
RUN "@sushd:/data/local/tmp/w103_neg.sh" 12
S 'cat /data/local/tmp/w103_run.out 2>&1' | clean > "$EV/g6_neg.txt"
grep -aq "uid=0(root)" "$EV/g6_neg.txt"; n1=$?   # 0=出现了=坏
# ★判据不能写成 `grep "No such file"`：文件本身没生成时 `cat` 的报错也是"No such file"⇒ 空过。
#   要认的是**子进程自己印的那行失败**，并且要有本 boot 的头行证明脚本真跑了。
grep -aqE "execve\(/system/bin/su\).*(No such file|errno=2)" "$EV/g6_neg.txt"; n2=$?
grep -aq "uid=10999" "$EV/g6_neg.txt"; n3=$?
[ $n1 = 1 ] && [ $n2 = 0 ] && [ $n3 = 0 ]; gate 6 "名单外 uid 敲 su 拿不到 root(子进程自己 ENOENT，走原实现)" $? \
    "n1=$n1(期望 1) n2=$n2(期望 0) n3=$n3(期望 0)，见 $EV/g6_neg.txt ⇒ 若 uid=0 出现，说明 sucompat 变成了全局后门"

# G7 UI 列表：su 通了之后整机第三方列表应当 >100(§6.114)
A shell am force-stop com.suw.manager >/dev/null 2>&1; sleep 1
A shell am start -n com.suw.manager/.MainActivity >/dev/null 2>&1; sleep 25
S 'cat /sdcard/Android/data/com.suw.manager/files/applist_diag.txt 2>&1' | clean > "$EV/g7_diag.txt"
N=$(sed -n 's/.*留下=\([0-9]*\).*/\1/p' "$EV/g7_diag.txt" | head -1)
[ "${N:-0}" -gt 100 ]; gate 7 "UI 列表源 = su 拼表(留下=${N:-?} 条)" $? \
    "没到 100 条 ⇒ 走回 pm 支路了(raw=1 那个老问题)，见 $EV/g7_diag.txt"

echo "=== 汇总：FAIL=$FAILS  证据=$EV ==="
ls -l "$EV" | tail -n +2 | awk '{printf "  %-22s %s\n", $NF, $5}'
[ -z "${KEEP:-}" ] && { echo "  收尾: reboot"; A reboot >/dev/null 2>&1; }
exit $FAILS
