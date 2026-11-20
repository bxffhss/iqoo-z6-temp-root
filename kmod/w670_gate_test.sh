#!/usr/bin/env bash
# w670_gate_test.sh —— 给 w625 那三格闸(#180：冷却 / 每-boot 预算 / 已在位不动进程)做**设备侧真跑**的逻辑认证。
#   为什么不能只靠 sh -n：这三格是"要不要往下走 force-stop"的分支，写错的症状是**腿拒绝干活**，
#   而"腿被自己的闸拒了"和"腿坏了"在屏幕上长得一模一样(例 168 那一族) ⇒ 分支必须逐格踢到。
#   ★形状：闸的逻辑**一行都不改**，只把 4 个"读/写哪里"的路径 sed 成夹具路径(触发口 /dev 那两条不许在执法态外写)，
#     所以跑的是同一份控制流；夹具件从仓库那份现生，不手写、不留档(跑完即删，见文件尾)。
#   ★边界(诚实)：这发没有窗口(mod=0)，所以认证的是**分支逻辑**，不是"牌子亮着时真被拦住"那一格——
#     那一格要 root＋活触发口，排在 #178 那一发里顺带收(它自己会连敲两次)。
set -u
cd "$(dirname "$0")/.." || exit 1
export MSYS_NO_PATHCONV=1
LEG=kmod/w625_seedrestart.sh
EV=kmod/w103_evidence
D=/data/local/tmp
FX1=kmod/w670_fx_port.sh
FX2=kmod/w670_fx_fd.sh
fail=0
say() { echo "$@"; }

# ---------- 1) 生成两份夹具(纯路径重定向)并**自证只改了路径** ----------
[ -f "$LEG" ] || { echo "[x] 没有 $LEG ⇒ 停"; exit 1; }
sed -e 's#^PORT=/proc/ksu_install_fd$#PORT='"$D"'/w670_fakeport#' \
    -e 's#^LOCK=/data/local/tmp/w625_lock$#LOCK='"$D"'/w670_lock#' \
    -e 's#^L=/data/local/tmp/w625_seedrestart.out$#L='"$D"'/w670_fx.out#' \
    -e 's#^NG=/data/local/tmp/w625_nogate$#NG='"$D"'/w670_nogate#' \
    "$LEG" > "$FX1"
sed -e 's#"/proc/\$MP/fd"#'"$D"'/w670_fxfd#' \
    -e 's#"/proc/\$P/fd"#'"$D"'/w670_fxfd#' "$FX1" > "$FX2"
norm() { # 把"读/写哪里"的四行与两处 fd 读数路径抹成同一种形状 ⇒ 剩下的必须逐字节同一份
    sed -e '/^\(PORT\|LOCK\|L\|NG\)=/d' \
        -e 's#"/proc/\$MP/fd"#@FD@#' -e 's#"/proc/\$P/fd"#@FD@#' \
        -e 's#'"$D"'/w670_fxfd#@FD@#' "$1"
}
for F in "$FX1" "$FX2"; do
    N=$(diff "$LEG" "$F" | grep -ac '^[<>]')
    # ★"逻辑一行没改"这条不靠我记得改了哪几行：把两份都归一化后**逐字节比**(cmp)。
    #   将来往腿里加了闸、这里忘了同步 sed 的映射，cmp 会自己红——而不是静默跑在一份"我以为是"的代码上。
    norm "$LEG" > /tmp/w670_a.$$; norm "$F" > /tmp/w670_b.$$
    if cmp -s /tmp/w670_a.$$ /tmp/w670_b.$$; then SAME=同一份; OKF=1; else SAME=不同; OKF=0; fi
    rm -f /tmp/w670_a.$$ /tmp/w670_b.$$
    A=$(grep -ac 'SR-COOL\|SR-BUDGET\|SR-ALREADY' "$LEG"); B=$(grep -ac 'SR-COOL\|SR-BUDGET\|SR-ALREADY' "$F")
    say "  $(basename "$F")：与出货件差异行=$N(只应是路径行)；归一化后=$SAME；闸词元命中 出货=$A 夹具=$B"
    [ "$OKF" = 1 ] || { echo "  [x] 夹具动了路径以外的代码 ⇒ 停"; fail=1; }
    [ "$N" -ge 2 ] || { echo "  [x] 差异行=0 ⇒ sed 根本没生效，夹具就是出货件本身(那这格没测到东西)"; fail=1; }
    [ "$A" = "$B" ] && [ "$A" -ge 3 ] || { echo "  [x] 夹具里闸的代码与出货件不一致 ⇒ 停"; fail=1; }
done
# 夹具自己必须**没有**真触发口/真锁的路径(否则一发就写进交付件的位置)
grep -aq '^PORT=/proc/ksu_install_fd$' "$FX1" && { echo "  [x] 夹具仍指向真触发口 ⇒ 停"; fail=1; }
grep -aq '^LOCK=/data/local/tmp/w625_lock$' "$FX1" && { echo "  [x] 夹具仍写真锁 ⇒ 停"; fail=1; }
[ "$fail" = 0 ] || exit 1

# ---------- 2) 铺件 + 设备侧语法闸(两端 md5) ----------
for F in "$FX1" "$FX2"; do
    adb push "$F" "$D/$(basename "$F")" 2>&1 | tr -d '\r'
done
R=$(adb shell "chmod 755 $D/w670_fx_port.sh $D/w670_fx_fd.sh; sh -n $D/w670_fx_port.sh; echo RC=\$?; sh -n $D/w670_fx_fd.sh; echo RC2=\$?; md5sum $D/w670_fx_*.sh" 2>&1 | tr -d '\r')
say "  设备侧：$R"
echo "$R" | grep -q 'RC=0' && echo "$R" | grep -q 'RC2=0' || { echo "  [x] 设备 mksh 语法不过 ⇒ 停"; exit 1; }
for F in "$FX1" "$FX2"; do
    M1=$(md5sum "$F" | cut -c1-32); M2=$(adb shell "md5sum $D/$(basename "$F")" 2>&1 | tr -d '\r' | cut -c1-32)
    say "  $(basename "$F") 两端 md5：本机=$M1 设备=$M2"
    [ "$M1" = "$M2" ] || { echo "  [x] 两端不是同一份 ⇒ 停"; exit 1; }
done

run() { # $1=夹具 $2=参数串 $3=格子名 $4=期望词元
    adb shell "rm -f $D/w670_fx.out; sh $D/$1 $2 >/dev/null 2>&1; echo rc=\$?" 2>&1 | tr -d '\r' | sed 's/^/    /'
    adb pull "$D/w670_fx.out" "$EV/w670_$3.txt" >/dev/null 2>&1
    say "  ---- 格子 $3($1 $2)期望命中[$4] ----"
    if [ ! -s "$EV/w670_$3.txt" ]; then say "    [x] 产物不在或 0 字节 ⇒ 这格不算跑过"; fail=1; return; fi
    sed 's/^/    /' "$EV/w670_$3.txt"
    if grep -aq "$4" "$EV/w670_$3.txt"; then say "    [OK] $3 命中 $4"; else say "    [x] $3 没命中 $4 ⇒ 记失败"; fail=1; fi
}

# ---------- 3) 逐格踢分支 ----------
adb shell "mkdir -p $D/w670_fxfd; : > $D/w670_fakeport; rm -f $D/w670_lock $D/w670_nogate; ls -l $D/w670_fakeport" 2>&1 | tr -d '\r' | sed 's/^/  铺夹具: /'
say "-- C1 无锁⇒应走到 force-stop 并落锁(runs=1)；shell 读不到 app 的 fd 表所以 fd=0 是预期的"
run w670_fx_port.sh "6 0.1 150 6" C1 'coolup='
adb shell "cat $D/w670_lock" 2>&1 | tr -d '\r' | sed 's/^/  锁读回: /'
say "-- C2 立刻再敲⇒必须 SR-COOL(不许再 force-stop)"
run w670_fx_port.sh "6 0.1 150 6" C2 'SR-COOL'
say "-- C3 清锁后用 maxruns=1 cool=0 连敲两次⇒第二次必须 SR-BUDGET"
adb shell "rm -f $D/w670_lock" >/dev/null 2>&1
run w670_fx_port.sh "1 0.1 0 1" C3a 'coolup='
run w670_fx_port.sh "1 0.1 0 1" C3b 'SR-BUDGET'
say "-- C4 放 nogate 标记⇒必须打 SR-NOGATE=1 且照走(测量腿的逃生口)"
adb shell "rm -f $D/w670_lock; : > $D/w670_nogate" >/dev/null 2>&1
run w670_fx_port.sh "1 0.1 150 6" C4 'SR-NOGATE=1'
say "-- C5 夹具 fd 目录(里面有名为 ksu_driver 的条目)⇒第二次必须 SR-ALREADY(不动进程)"
adb shell "rm -f $D/w670_lock $D/w670_nogate; : > $D/w670_fxfd/ksu_driver; ls -l $D/w670_fxfd" 2>&1 | tr -d '\r' | sed 's/^/  /'
run w670_fx_fd.sh "6 0.1 150 6" C5a 'SR-ROUND'
adb shell "pidof me.weishu.kernelsu; cat $D/w670_lock" 2>&1 | tr -d '\r' | sed 's/^/  中途读数: /'
run w670_fx_fd.sh "6 0.1 150 6" C5b 'SR-ALREADY'

# ---------- 4) 收尾：夹具件与夹具产物全删并复证 ----------
adb shell "rm -f $D/w670_fx_port.sh $D/w670_fx_fd.sh $D/w670_lock $D/w670_fx.out $D/w670_nogate $D/w670_fakeport $D/w670_fxfd/ksu_driver; rmdir $D/w670_fxfd; ls -d $D/w670_* 2>&1" 2>&1 | tr -d '\r' | sed 's/^/  复证(应 No such file): /'
rm -f "$FX1" "$FX2"
echo "=== w670 结束 fail=$fail（0=三格全踢到；非 0 就别把这段当认证）==="
exit "$fail"
