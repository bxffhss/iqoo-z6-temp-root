#!/usr/bin/env bash
# run_slots_live.sh —— 给收尾件的 T2.7 拿一次**真 adb** 回执，**不花 punch**。
#   做法：在设备上摆一份**合成夹具**（就叫生产名 ksu_slots.dump.txt），把 T2.7 那段从收尾件里切出来、
#   接真 adb/A() 跑一遍，看它数出来的三个计数与两端 md5；再摘掉夹具跑第二遍，看失败支在真 adb 下的行为。
#   ★三处纪律：①开跑前先证明那个生产名**本来不在**（不在⇒我造的；在⇒可能是真发残留，立刻停手去查，例 77）；
#           ②产物一律改名成 `w414_LIVE_TEST_*`，生产前缀 `w412_ksu_slots_` 里不许留东西(一个名字只服务一个来源)；
#           ③结束时设备上必须复证 `No such file`——合成夹具绝不能活到下一发去冒充原件。
set -u
cd "$(dirname "$0")/../.." || exit 1
export MSYS_NO_PATHCONV=1
A() { adb shell "$1" 2>&1 | tr -d '\r'; }
EV=kmod/w103_evidence
P=/data/local/tmp/ksu_slots.dump.txt
FX=/data/local/tmp/w414_slots_fixture.txt
fail=0
chk() { if [ "$2" = 1 ]; then echo "  [OK] $1"; else echo "  [BAD] $1"; fail=1; fi; }

echo "=== 0) 前置：设备在线 + 生产名本来不在 + 存证目录没同名件 ==="
adb get-state 2>/dev/null | grep -q device || { echo "  [x] adb 不在线，这个测试没法跑"; exit 2; }
echo "  设备: $(A 'echo up=$(cut -d" " -f1 /proc/uptime) mod=$(grep -c kernelsu /proc/modules) enf=$(getenforce) uid=$(id -u)')"
GONE=$(A "ls $P 2>&1" | grep -ac 'No such file')
chk "①生产名 $P 开跑前就不在(命中=$GONE，必须是 1；在的话先停手去查是不是真发的残留)" "$([ "$GONE" = 1 ] && echo 1 || echo 0)"
PRE=$(ls "$EV" 2>/dev/null | grep -c 'w412_ksu_slots_')
chk "①存证目录开跑前没有 w412_ksu_slots_ 件(现=$PRE)" "$([ "$PRE" = 0 ] && echo 1 || echo 0)"
[ "$fail" = 0 ] || { echo "  === 前置不合格，不往下跑 ==="; exit 1; }

echo "=== 1) 铺合成夹具(6 桩已写回 / 4 不用改 / 18 其它 ⇒ CFIFIX 共 28 行) ==="
# ★源文件必须放在 **Windows 看得见的路径**(仓库内)：adb 是 Windows 二进制，喂它 `/tmp/...` 会**静默推空**
#   (第一版就是这样：push 没报错，设备上一 `cp` 才发现 No such file)。
FXL=kmod/_tmp_selftest_rdst/_w414_fixture.txt
{ i=1; while [ $i -le 6 ]; do echo "CFIFIX __arm64_sys_openat$i 桩已写回 17bfc134(=B 本体)"; i=$((i+1)); done
  i=1; while [ $i -le 4 ]; do echo "CFIFIX __arm64_sys_execve$i 不用改"; i=$((i+1)); done
  i=1; while [ $i -le 18 ]; do echo "CFIFIX __arm64_sys_other$i 现状=未改"; i=$((i+1)); done; } > "$FXL"
echo "  本机夹具: 行数=$(wc -l <"$FXL") 字节=$(wc -c <"$FXL") md5=$(md5sum "$FXL" | cut -c1-32)"
adb push "$FXL" "$FX" >/dev/null 2>&1
echo "  push 后设备回执: $(A "ls -l $FX 2>&1" | tr -s ' ' | cut -c1-70)"
# ★硬闸：设备上没拿到**逐字等长**的夹具就停手——不许让"件在"这一遍悄悄退化成"件不在"那一遍。
FS=$(A "wc -c <$FX 2>/dev/null" | tr -dc '0-9'); LM=$(A "md5sum $FX 2>/dev/null" | cut -c1-32); LM0=$(md5sum "$FXL" | cut -c1-32)
if [ "${FS:-x}" != "$(wc -c <"$FXL")" ] || [ "$LM" != "$LM0" ]; then
    echo "  [x] 夹具没铺上(设备字节=[${FS:-}] md5=[${LM:-}] 本机字节=$(wc -c <"$FXL") md5=$LM0) ⇒ 停，这一遍不算数"
    rm -f "$FXL"; exit 1
fi
echo "  夹具已铺好且两端 md5 一致($LM0)"
A "cp $FX $P; chmod 666 $P; rm -f $FX; ls -l $P | tr -s ' ' | cut -c1-70" | sed 's/^/  设备上: /'
echo "  设备侧自己数: CFIFIX=$(A "grep -ac CFIFIX $P") 写回=$(A "grep -ac '桩已写回' $P") 不用改=$(A "grep -ac '不用改' $P") 字节=$(A "wc -c <$P" | tr -dc '0-9')"
echo "  设备侧 md5=$(A "md5sum $P" | cut -c1-32)"

echo "=== 2) 切出 T2.7 那段，接**真 adb** 跑(第一遍：件在) ==="
W=$(mktemp -d)
awk '/=== T2\.7/{f=1} /=== T3\)/{f=0} f' kmod/w161_teardown.sh > "$W/b.sh"
grep -q 'adb pull' "$W/b.sh" && grep -q 'T2\.6' "$W/b.sh" && { echo "  [x] 切片锚点不对"; exit 1; }
echo "  切片行数=$(wc -l <"$W/b.sh")"
( source "$W/b.sh" ) > "$W/live1.txt" 2>&1
sed 's/^/  /' "$W/live1.txt"
N=$(grep -ac 'CFIFIX行=28 桩已写回=6 不用改=4' "$W/live1.txt")
chk "②第一遍：三个计数从**真设备件**里数出来(命中=$N，期望 1)" "$([ "$N" = 1 ] && echo 1 || echo 0)"
# ★这里不拿 grep 反向引用去"解析自己打印的文案"(例 91)；改成用**夹具基准 md5** 去比 pull 回来的本机件。
FILE1=$(ls "$EV"/w412_ksu_slots_*.txt 2>/dev/null | head -1)
PULLED=$(md5sum "$FILE1" 2>/dev/null | cut -c1-32)
chk "②第一遍：pull 回来的本机件 md5＝夹具基准 $LM0(现=[${PULLED:-空}])——这才是'两端一致'的正证，不是文案" "$([ "${PULLED:-x}" = "$LM0" ] && echo 1 || echo 0)"
chk "②第一遍：本机真的落了非空件(=$(basename "${FILE1:-无}") 字节=$(wc -c <"${FILE1:-/dev/null}" 2>/dev/null))" "$([ -n "$FILE1" ] && [ -s "$FILE1" ] && echo 1 || echo 0)"
BAD=$(grep -ac '没 pull 到' "$W/live1.txt")
chk "②第一遍：没走失败支(命中=$BAD)" "$([ "$BAD" = 0 ] && echo 1 || echo 0)"

echo "=== 3) 把产物改名，生产前缀里不许留东西 ==="
if [ -n "$FILE1" ]; then mv "$FILE1" "$EV/w414_LIVE_TEST_$(basename "$FILE1" | sed 's/^w412_//')"; fi
A "rm -f $P" >/dev/null
LEFT=$(ls "$EV" 2>/dev/null | grep -c 'w412_ksu_slots_')
chk "③改名后 w412_ksu_slots_ 前缀剩 $LEFT 件(必须 0)" "$([ "$LEFT" = 0 ] && echo 1 || echo 0)"
chk "③改名后的产物在($(ls "$EV"/w414_LIVE_TEST_* 2>/dev/null | wc -l) 件)" "$([ "$(ls "$EV"/w414_LIVE_TEST_* 2>/dev/null | wc -l)" = 1 ] && echo 1 || echo 0)"

echo "=== 4) 第二遍：件不在 ⇒ 真 adb 下的失败支 ==="
echo "  设备复证: $(A "ls $P 2>&1" | tail -1)"
( source "$W/b.sh" ) > "$W/live2.txt" 2>&1
sed 's/^/  /' "$W/live2.txt"
B2=$(grep -ac '没 pull 到' "$W/live2.txt")
chk "④第二遍：打了失败支(命中=$B2)" "$([ "$B2" = 1 ] && echo 1 || echo 0)"
L2=$(ls "$EV" 2>/dev/null | grep -c 'w412_ksu_slots_')
chk "④第二遍：没往存证目录写东西(现=$L2)" "$([ "$L2" = 0 ] && echo 1 || echo 0)"

echo "=== 5) 收线复证 ==="
echo "  设备: $(A "ls $P 2>&1" | tail -1)"
echo "  设备: $(A "ls $FX 2>&1" | tail -1)"
chk "⑤设备上生产名与夹具名都没留(各 No such file 命中=$(A "ls $P $FX 2>&1" | grep -ac 'No such file'))" "$([ "$(A "ls $P $FX 2>&1" | grep -ac 'No such file')" = 2 ] && echo 1 || echo 0)"
rm -rf "$W"; rm -f "$FXL"   # ★本机夹具也清掉：工作产物不许留在仓库里(它和生产件同名同形)
echo
[ "$fail" = 0 ] && echo "=== run_slots_live 全绿(真 adb) ===" || echo "=== 有红项 ==="
