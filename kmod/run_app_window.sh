#!/bin/bash
# run_app_window.sh —— 一扇 punch 窗口的 **PC 侧驱动器**(md §6.59)
#
# 为什么需要它：v27 的后处理脚本(root 侧)只会"等 app 报告"，而**触发 app 只能从 shell 侧做**
#   (`am start` 是 shell 的能力；root 侧那个域里跑 am 反而未必起得来)。
# 所以一发的分工是：
#   root 侧(ksu_post.sh=v27)  : seed 名单 → insmod → 正对照 grant → 等 app 报告 → 从 /proc 抓外部证据 → 清理
#   PC 侧(本脚本)             : 负对照(shd --ksugrant, uid 2000) → 触发 app(先不 arm，再 arm)
#                              → 从 shell 侧再抓一遍 /proc 证据(与 root 侧互相独立) → 收全部判据
#
# ★纪律：本脚本**不打链**(打链由 suw_apk/bootstrap.sh --punch 且 I_KNOW=1 负责)。
#   它在链已经发出之后跑；post 脚本通常在 MAC 判据之后 3~25 分钟才落地(见记忆 ghostlock-rtmutex-lpe)，
#   所以先等 `insmod rc=` 出现再动作。
set -u
cd "$(dirname "$0")/.." || exit 1
DEV=${DEV:-}
ADB=${ADB:-adb}
[ -n "$DEV" ] && A() { MSYS_NO_PATHCONV=1 "$ADB" -s "$DEV" "$@"; } || A() { MSYS_NO_PATHCONV=1 "$ADB" "$@"; }
S() { A shell "$@" 2>&1; }
PKG=com.suw.manager
REPORT=/sdcard/Android/data/$PKG/files/ksu_grant.txt
STAGE=/data/local/tmp/ksu_stage.log
WAIT_INS=${WAIT_INS:-1800}             # 等 insmod 那行的秒数(post 本身就可能在 25 分钟后才跑)
OUTDIR=kmod/app_w_$(date +%m%d_%H%M)
mkdir -p "$OUTDIR"
say() { echo "[$(date +%H:%M:%S)] $*"; }

say "起点: uname -s=[$(S 'uname -s' | tr -d '\r')]  enforce=[$(S getenforce | tr -d '\r')]  agent=[$(S 'pidof shd' | tr -d '\r')]"
echo "  ★判读：uname -s=Lin(不是 Linux) ⇒ 这个 boot 已经打过；Enforcing 且 insmod 迟迟不来 ⇒ 链没成"

say "① 等 root 侧跑到 insmod(上限 ${WAIT_INS}s)"
# ★★假阳性闸门：/data/local/tmp/ksu_stage.log **跨重启还在**(上一发故意留着当判据)，
#   里面天然就有 `insmod rc=0` 那行 ⇒ 直接 grep 会立刻"等到了"，然后把 app 触发到一个
#   根本没有 ko 的机器上。所以只认**本次开机**的那一份：用起点行里的 up= 与实时 uptime 比，
#   差得远(>3600s)就是历史文件。起点行本身还带 v27 版本号，两道一起看。
stage_is_fresh() {
    FIRST=$(S "head -1 $STAGE 2>/dev/null" | tr -d '\r')
    case "$FIRST" in *"起点 v"*) ;; *) return 1;; esac   # 前缀就够，真正判"本 boot"靠下面的 uptime 差
    # ★闸门必须用"本次开机的时刻"当基准，不能用 uptime 差：
    #   上一 boot 的 ksu_stage.log 跨重启还在，它的 up= 与实时 up= 差值可以很小(355 vs 650) ⇒ 照样放行
    BOOT=$(S "awk '/btime/{print \$2}' /proc/stat" 2>/dev/null | tr -d '
')
    MT=$(S "stat -c %Y $STAGE 2>/dev/null" 2>/dev/null | tr -d '
')
    [ -n "$BOOT" ] && [ -n "$MT" ] || return 1
    [ "$MT" -ge "$BOOT" ] || { echo "  这份 stage.log 比本次开机还早 ⇒ 是上一 boot 的残留" ; return 1; }
    OLD=$(echo "$FIRST" | grep -oE 'up=[0-9]+' | head -1 | cut -d= -f2)
    NOW=$(S "cut -d' ' -f1 /proc/uptime" | tr -d '\r' | cut -d. -f1)
    [ -n "$OLD" ] && [ -n "$NOW" ] || return 1
    D=$((NOW - OLD)); [ "$D" -lt 0 ] && D=$((-D))
    [ "$D" -lt 3600 ]
}
i=0
L=""
while [ "$i" -lt "$WAIT_INS" ]; do
    if stage_is_fresh; then
        L=$(S "grep -m1 'insmod rc=' $STAGE 2>/dev/null" | tr -d '\r')
        [ -n "$L" ] && { say "  看到(且起点行属本 boot): $L"; break; }
    else
        say "  起点行还是上一发的残留($(S "head -1 $STAGE 2>/dev/null" | tr -d '\r' | cut -c1-60)) ⇒ 继续等"
    fi
    i=$((i + 10)); sleep 10
done
if [ -z "${L:-}" ]; then say "!! 没等到本 boot 的 insmod 那行 ⇒ 退出(不发任何触发)"; exit 1; fi
echo "$L" > "$OUTDIR/insmod_line.txt"
case "$L" in *"rc=0"*) ;; *) say "!! insmod 非 0 ⇒ 内核侧没起来，后面的 app 触发没有意义，退出"; exit 1;; esac

say "   等 root 侧守护起来(它由 stage 脚本在 insmod 之后拉起，上限 150s)"
z=0
while [ $z -lt 75 ]; do
    S 'grep -c "在听 @suwksu" /data/local/tmp/sushd.log 2>/dev/null' | tr -d '
' | grep -qv '^0$' && break
    sleep 2
    z=$((z + 1))
done
say "   等了 $((z * 2))s"
say "②b 先跑 root 侧守护代跑(窗口只有几分钟，这一格才是交付物，排最前(§6.72③ 定下来的可用形态；授权只问 KSU 白名单)"
S "am force-stop $PKG" >/dev/null
sleep 1
S "am start -n $PKG/.MainActivity --es auto ksuarm --es cmd '@sushd:id; echo MARKER_VIA_SUSHD; getenforce; grep -m1 ^Uid: /proc/self/status'" | tee "$OUTDIR/am_sushd.txt"
# ★必须等够再读：报告文件每次触发都是 O_TRUNC 重写的 ⇒ 这一格读晚了会被后面几发覆盖，
#   读早了又看不见守护的回执(守护那边最坏 8s 读 + 10s 等子进程)。
sleep 35
S "cat $REPORT" > "$OUTDIR/app_sushd.txt" 2>&1
say "   守护代跑的报告(出现 uid=0(root) 才算原语成立)："
grep -E "SUSHD|uid=|MARKER|Permissive|Enforcing|Uid" "$OUTDIR/app_sushd.txt" 2>/dev/null | tail -12 | sed 's/^/     /'
S "cat /data/local/tmp/sushd.log 2>&1" > "$OUTDIR/sushd.log" 2>&1
say "   守护侧日志(它问内核那一行 = 授权判定的真凭据)："
tail -8 "$OUTDIR/sushd.log" 2>/dev/null | sed 's/^/     /'
say "② 负对照：shd --ksugrant(以 **shell uid 2000** 走一遍 KSUFD)"
say "   期望：GET_INFO rc=0(fd 跨进程活着) + GRANT_ROOT 被拒 + uid 仍是 2000"
S '/data/local/tmp/shd --ksugrant' | tee "$OUTDIR/neg_control_uid2000.txt"

say "③ 第一段 app 触发：只握手(--es auto ksu，不申请授权)"
S "am force-stop $PKG" >/dev/null
S "rm -f $REPORT" >/dev/null
S "am start -n $PKG/.MainActivity --es auto ksu" | tee "$OUTDIR/am_handshake.txt"
sleep 8
S "cat $REPORT" > "$OUTDIR/app_handshake.txt" 2>&1
say "   报告 $(wc -c < "$OUTDIR/app_handshake.txt") 字节："
sed 's/^/     /' "$OUTDIR/app_handshake.txt"

say "④ 第二段 app 触发：真授权(--es auto ksuarm)"
S "am force-stop $PKG" >/dev/null
sleep 1
CMD=${SUW_CMD:-'id > /data/local/tmp/suw_cmd_fast.out 2>&1; echo MARKER_FAST >> /data/local/tmp/suw_cmd_fast.out; grep -m1 ^Uid: /proc/self/status >> /data/local/tmp/suw_cmd_fast.out 2>&1'}
say "   ★带 cmd 触发(子进程授权成功后会 exec 它)：cmd=[$CMD]"
S "am start -n $PKG/.MainActivity --es auto ksuarm --es cmd \"$CMD\"" | tee "$OUTDIR/am_arm.txt"
say "   ★子进程实测只活 ~4s(报告里有 t+04s 没有 t+08s) ⇒ 必须**紧跟着轮询**，不能先 sleep 8"
# ★外部判据的正确取法(第四十发复核)：
#   1) 扫描要带 /status；厚先写成 /proc/$P/task/* 只会得到 "Is a directory"
#   2) 别按名字找：`ps -A -o NAME` 取的是 **cmdline**(com.suw.manager)，`pidof`/comm 才是 suwrootd
#   3) app 报告在发 ioctl 之前就已印出 `SubProc pid=...` ⇒ 直接按那个 pid 读 /proc
CPID=""
for t in $(seq 1 60); do
    [ -z "$CPID" ] && CPID=$(S "grep -oE '子进程 pid=[0-9]+' $REPORT" 2>/dev/null | tr -d '
' | head -1 | cut -d= -f2)
    if [ -n "$CPID" ]; then
        ST=$(S "grep -m1 '^Uid:' /proc/$CPID/status" 2>/dev/null | tr -d '
' | tr '	' ' ')
        case "$ST" in
            *"Uid: 0 0 0 0"*)
                CE=$(S "grep -m1 '^CapEff:' /proc/$CPID/status" 2>/dev/null | tr -d '
' | tr -d '	')
                say "   ★★★外部一手证据(t+$((t/2))s): 子进程 $CPID 的 $ST  $CE"
                echo "pid=$CPID $ST $CE" >> "$OUTDIR/external_uid0.txt"
                break;;
            *"No such file"*|*"Is a directory"*|*denied*)
                say "   子进程 $CPID 已退出(第 $t 次读不到) ⇒ 这一格没抓到，需要把 PARK 改长或者 root 侧接力"; break;;
            *) sleep 0.5;;
        esac
    else
        sleep 0.5
    fi
done
# ★先赋值再判空(上一版反着写，set -u 下直接 unbound 崩在这里)
P=$(S "pidof $PKG" | tr -d '
' | cut -d' ' -f1)
if [ -n "$P" ]; then
ALL=$(S "grep -h '^Uid:' /proc/$P/task/*/status" 2>/dev/null | tr -d '
')
HIT=$(echo "$ALL" | grep -cE '^Uid: 0')
say "   回头再看一次 app 自己：pid=$P 线程数=$(echo "$ALL" | grep -c .) uid0线程数=$HIT(预期 0：授权只发生在子进程)"
else
  say "   app 已经不在了(pidof 空) ⇒ 这一格只能靠上面的子进程轮询"
fi
# ★报告要**轮询到它自己写完**：第三十七发就是 cat 得太早(app 还驻留 25s)，
#   看到的报告停在"GRANT_ROOT rc=0"，缺"授权后"那一行，差点把成功读成未知。
for q in $(seq 1 30); do
    SZ=$(S "wc -c < $REPORT" 2>/dev/null | tr -d '
')
    END=$(S "grep -c '结束(能到这行' $REPORT" 2>/dev/null | tr -d '
')
    [ -n "$END" ] && [ "$END" != "0" ] && break
    sleep 2
done
S "cat $REPORT" > "$OUTDIR/app_arm.txt" 2>&1
say "   app 侧报告 $(wc -c < "$OUTDIR/app_arm.txt") 字节(轮询 ${q} 轮)："
sed 's/^/     /' "$OUTDIR/app_arm.txt"

# ★v34 的第二支：daemon 版(cmd 前缀 @daemon: ⇒ JNI 里二次 fork+setsid ⇒ ppid=1)。
#   两支只差"父进程是不是 app"，其余完全一样 ⇒ 若 daemon 版活到 exec，凶手判的就是亲子关系。
say "④b 第二发：@daemon 版(二次 fork ⇒ 被 init 收养)"
S "am force-stop $PKG" >/dev/null
sleep 1
DCMD='id > /data/local/tmp/suw_cmd_daemon.out 2>&1; echo MARKER_DAEMON >> /data/local/tmp/suw_cmd_daemon.out; grep -m1 ^Uid: /proc/self/status >> /data/local/tmp/suw_cmd_daemon.out 2>&1; ls -l /proc/self/exe >> /data/local/tmp/suw_cmd_daemon.out 2>&1'
S "am start -n $PKG/.MainActivity --es auto ksuarm --es cmd \"@daemon:$DCMD\"" | tee "$OUTDIR/am_arm_daemon.txt"
sleep 14
S "cat $REPORT" > "$OUTDIR/app_arm_daemon.txt" 2>&1
say "   daemon 版报告 $(wc -c < "$OUTDIR/app_arm_daemon.txt") 字节："
sed 's/^/     /' "$OUTDIR/app_arm_daemon.txt" | tail -14
S "touch /data/local/tmp/ksu_dump_now"   # ★告诉 root 侧：两支都跑完了，可以 dump 探针了
say "   两发的 exec 产物(能读到=子进程真跑了一条 root 命令)："
S "ls -l /data/local/tmp/suw_cmd_fast.out /data/local/tmp/suw_cmd_daemon.out /sdcard/Android/data/com.suw.manager/files/child.log 2>&1; echo '--- child.log(子进程侧日志) ---'; cat /sdcard/Android/data/com.suw.manager/files/child.log 2>&1; echo '--- fast ---'; cat /data/local/tmp/suw_cmd_fast.out 2>&1; echo '--- daemon ---'; cat /data/local/tmp/suw_cmd_daemon.out 2>&1" > "$OUTDIR/exec_products.txt" 2>&1
sed 's/^/     /' "$OUTDIR/exec_products.txt"
# ★内核侧当场对账(不等收尾的整份 dmesg)：escape 的真回执只有 X7/X8/XC 这组行才算"cred 真的改了"
S "dmesg | grep -E 'allow root for|KSUBEAT (X0|X2|X7|X8|XA|XC)|install ksu fd'" > "$OUTDIR/dmesg_after_arm.txt" 2>&1
say "   内核侧对账(最后 12 行)："
tail -12 "$OUTDIR/dmesg_after_arm.txt" | sed 's/^/     /'

# ★v30：那个 SIGKILL 的凶手只能由内核自己回答(signal_generate 的 comm/pid=发送方 + 内核栈)，
#   而 root 侧的 stage 脚本现在会在 armed 报告之后立刻 dump。这里就是等那份文件，
#   别抢在它前面收工(上一发就是驱动先跑完、root 侧还没轮到探针)。
say "   等 root 侧 dump ftrace(上限 100s)"
k=0
while [ $k -lt 100 ]; do
    FSZ=$(S "wc -c < /data/local/tmp/ksu_ftrace.txt 2>/dev/null" | tr -d '\r' | tr -d ' ')
    case "$FSZ" in ''|*[!0-9]*) FSZ=0;; esac
    [ "$FSZ" -gt 200 ] && break
    sleep 4
    k=$((k + 4))
done
say "   等了 ${k}s ⇒ ksu_ftrace.txt = ${FSZ} 字节"
S "cat /data/local/tmp/ksu_ftrace.txt" > "$OUTDIR/ksu_ftrace.txt" 2>&1
# ★v32：kprobe 打出来的 LR 是一个裸地址，要拿本次开机的 /proc/kallsyms 才能算出函数名
A pull /data/local/tmp/ksu_kallsyms.txt "$OUTDIR/" >/dev/null 2>&1
S "cat /data/local/tmp/ksu_tainted_before.txt 2>&1; echo -n ' 后='; cat /proc/sys/kernel/tainted 2>&1" > "$OUTDIR/tainted.txt" 2>&1
say "   kallsyms=$(wc -l < "$OUTDIR/ksu_kallsyms.txt" 2>/dev/null) 行  tainted=$(cat "$OUTDIR/tainted.txt" 2>/dev/null | tr -d '\r')"
say "   SIGKILL 生成点(前 60 行，带内核栈)："
grep -E 'signal_generate|signal_deliver' "$OUTDIR/ksu_ftrace.txt" 2>/dev/null | head -60 | sed 's/^/     /'
S "cat /data/local/tmp/suw_cmd.out /data/local/tmp/suw_child.log 2>&1" > "$OUTDIR/child_products.txt" 2>&1
say "   子进程产物(exec 输出/子进程日志)："
sed "s/^/     /" "$OUTDIR/child_products.txt" | head -20
say "⑤ 收判据(root 侧日志 + 内核落盘 + agent 日志)"
S "cat $STAGE" > "$OUTDIR/ksu_stage.log" 2>&1
S "ls -l /data/local/tmp/app_ksu.txt 2>&1; cat /data/local/tmp/app_ksu.txt 2>/dev/null" > "$OUTDIR/root_side_app_copy.txt" 2>&1
S "dmesg" > "$OUTDIR/dmesg_full.txt" 2>&1
A pull /data/local/tmp/dmesg_full.txt "$OUTDIR/" >/dev/null 2>&1
A pull /data/local/tmp/dmesg.live "$OUTDIR/" >/dev/null 2>&1
S "tail -40 /data/local/tmp/shd.log" > "$OUTDIR/shd.log" 2>&1
S "tail -20 /data/local/tmp/punch.log" > "$OUTDIR/punch.log" 2>&1

say "⑥ 结论行(自己判，不看退出码)"
{
    echo "--- app 侧(自报) ---"; grep -E 'GRANT_ROOT|授权后|成立|收到 fd|GET_INFO' "$OUTDIR/app_arm.txt" 2>/dev/null
    echo "--- 外部(shell 侧独立扫 /proc) ---"; cat "$OUTDIR/external_uid0.txt" 2>/dev/null || echo "  (没抓到 uid 0 线程)"
    echo "--- 负对照(uid 2000) ---"; grep -E 'GRANT_ROOT|正对照|授权前|授权后' "$OUTDIR/neg_control_uid2000.txt" 2>/dev/null
    echo "--- root 侧计数 ---"; grep -E 'KSUBEAT (X0|X7|X8|XA|XB|XC) =|★外部证据' "$OUTDIR/ksu_stage.log" 2>/dev/null | tail -20
} | tee "$OUTDIR/VERDICT.txt"

say "证据目录 = $OUTDIR"
say "收尾(不留持久化)：确认读完后 `adb reboot`，重启后验 uname -s=Linux / Enforcing / lsmod 里没有 kernelsu"
