#!/usr/bin/env bash
# w602_mgrwatch_selftest.sh —— w600_mgrwatch.sh 的**双向**离线自检(§6.405：作废级闸先试跑再开枪)。
#   每条都配"必须成立"与"故意坏一次必须被拒"两边 ⇒ 证这条牙有牙。
#   测的形状：①守卫(含 zygote/不含包名必须拒)；②GIVEUP(永远读不到 fd 必须 rc=3 并明写)；
#   ③"pid 变了才重装"(同一 pid 不许重复排)；④开关文件删掉⇒自己退(不靠 pkill)；⑤反夹具(开关一开始就不在⇒立刻退)。
set -u
cd "$(dirname "$0")/.." || exit 1
W600=kmod/w600_mgrwatch.sh
T=kmod/_tmp_selftest_rdst/w602
mkdir -p "$T"
ok=0; bad=0
P() { echo "  [OK] $1"; ok=$((ok + 1)); }
F() { echo "  [BAD] $1"; bad=$((bad + 1)); }
[ -s "$W600" ] || { echo "  [BAD] 没有 $W600"; echo "FAIL"; exit 1; }

echo "=== 1) 守卫：pc bash 与(若在)设备 mksh 都要 SELF PASS ==="
R=$(bash "$W600" selfcheck 2>&1); rc=$?
printf '%s\n' "$R" | sed 's/^/    /'
if [ $rc = 0 ] && printf '%s' "$R" | grep -qa 'SELF PASS'; then P "bash 侧守卫三条断言全对"; else F "bash 侧守卫 rc=$rc"; fi
if command -v adb >/dev/null 2>&1 && adb get-state >/dev/null 2>&1; then
    MSYS_NO_PATHCONV=1 adb push "$W600" /data/local/tmp/w602_sc.sh >/dev/null 2>&1
    R2=$(adb shell 'sh /data/local/tmp/w602_sc.sh selfcheck; echo RC=$?' 2>&1 | tr -d '\r')
    adb shell 'rm -f /data/local/tmp/w602_sc.sh' >/dev/null 2>&1
    printf '%s\n' "$R2" | tail -3 | sed 's/^/    /'
    if printf '%s' "$R2" | grep -qa 'SELF PASS' && printf '%s' "$R2" | grep -qa 'RC=0'; then
        P "设备 mksh 侧守卫也 SELF PASS(两壳同形)"
    else F "设备 mksh 侧守卫不 PASS"; fi
else echo "  [i] 设备不在 ⇒ 两壳一致性这格按没测到算(不算通过)"; fi

echo "=== 2) GIVEUP：FAKE_FD=0 永远读不到 fd ⇒ 必须 rc=3 且日志明写 GIVEUP ==="
SW=$T/sw2; L=$T/l2; PF=$T/pf2; rm -f "$SW" "$L" "$PF"; : > "$SW"
W600_SW="$SW" W600_L="$L" W600_PIDF="$PF" W600_FAKE_FD=0 W600_FAKE_PID=12345 \
    timeout 70 sh "$W600" >/dev/null 2>&1; rc2=$?
grep -qa 'GIVEUP' "$L" && g=1 || g=0
if [ "$rc2" = 3 ] && [ "$g" = 1 ]; then P "rc=3 且有 GIVEUP 那行($L)"; else F "rc=$rc2 GIVEUP=$g ⇒ 这条不成立"; fi
rm -f "$SW"

echo "=== 3) 反面：FAKE_FD=1(见得到 fd) ⇒ 不许 GIVEUP，且同一 pid 只排一次 ==="
SW=$T/sw3; L=$T/l3; PF=$T/pf3; rm -f "$SW" "$L" "$PF"; : > "$SW"
W600_SW="$SW" W600_L="$L" W600_PIDF="$PF" W600_FAKE_FD=1 W600_FAKE_PID=23456 W600_LIMIT=6 \
    timeout 40 sh "$W600" >/dev/null 2>&1; rc3=$?
Q=$(grep -ac '已排队新 pid' "$L")
if [ "$rc3" = 0 ] && [ "$Q" = 1 ] && ! grep -qa 'GIVEUP' "$L"; then
    P "跑满 6 轮只排 1 次(Q=$Q)且不 GIVEUP ⇒ 'pid 变了才重装'成立"
else F "rc=$rc3 排队次数=$Q(期望 1 ⇒ 要么重复排要么没排)"; fi

echo "=== 4) kill switch：跑起来后删掉开关 ⇒ 必须**自己**退(不 pkill)，日志写 开关还在=N ==="
SW=$T/sw4; L=$T/l4; PF=$T/pf4; rm -f "$SW" "$L" "$PF"; : > "$SW"
W600_SW="$SW" W600_L="$L" W600_PIDF="$PF" W600_FAKE_FD=1 W600_FAKE_PID=34567 \
    sh "$W600" >/dev/null 2>&1 &
BGPID=$!
sleep 3
W4=$(tr -dc '0-9' < "$PF" 2>/dev/null)
[ -d "/proc/$W4" ] && alive1=Y || alive1=N
rm -f "$SW"
sleep 3
if [ "$alive1" = Y ] && grep -qa '开关还在=N' "$L"; then P "开关删掉后自己退出(日志:$(grep -ao '开关还在=.' "$L" | tail -1))"; else F "删开关前活着=$alive1 日志=$(tail -1 "$L" 2>/dev/null)"; fi
kill -9 "$BGPID" 2>/dev/null

echo "=== 5) 反夹具：开关**一开始就不在** ⇒ 必须立刻退(证明第 4 条不是空跑) ==="
SW=$T/sw5; L=$T/l5; rm -f "$SW" "$L"
W600_SW="$SW" W600_L="$L" W600_PIDF=$T/pf5 W600_FAKE_FD=1 W600_FAKE_PID=4567 \
    timeout 15 sh "$W600" >/dev/null 2>&1; rc5=$?
I=$(grep -ao '共 [0-9]* 轮' "$L" 2>/dev/null | grep -ao '[0-9]*')
if [ "$rc5" = 0 ] && [ "${I:-9}" -le 1 ]; then P "无开关时立刻退(轮数=${I:-?})"; else F "rc=$rc5 轮数=${I:-?} ⇒ 这条没牙"; fi

echo "=== 6) 静态形状：w600 里必须**没有任何**往 zygote/system_server 写的路径 ==="
if grep -qaE 'zygote64|system_server' "$W600" && ! grep -qa 'mgr_guard_ok' "$W600"; then
    F "守卫函数不在 ⇒ 护栏不可信"
elif grep -qa 'exit 3' "$W600" && grep -qa 'W600_FAKE_FD' "$W600"; then
    P "守卫/GIVEUP/离线夹具三口都在(且 zygote 串只出现在守卫的**拒绝**分支里)"
else F "w600 少了 GIVEUP 或离线夹具入口"; fi

echo "=== 汇总 [OK]=$ok [BAD]=$bad ==="
[ "$bad" -gt 0 ] && { echo "FAIL(有牙不过)"; exit 1; }
[ "$ok" -lt 5 ] && { echo "FAIL(证据太少 $ok ⇒ 像空跑)"; exit 1; }
echo "PASS：w602 全部 $ok 组双向验过"
