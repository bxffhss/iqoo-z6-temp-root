#!/usr/bin/env bash
# run_slots.sh —— 给 w161_teardown.sh 的 **T2.7(CFIFIX 原件删前 pull)** 做双向离线自测（不碰设备、不碰真存证目录）。
#   格数见下面实际调用(ok/mismatch/empty/missing/noperm ＋顺序三断言；条数由 chk 自数)： / mismatch(两端 md5 不符) / empty(adb 谎报成功、本机 0 字节) / missing(远端根本没这个件)。
#   规矩(例 109/116/121)：断言要打在**数值**上；失败支必须"不留下空/坏存证件"；这条腿全程 adb-only，
#   root 通道死了也要能跑(例 103：判据能拿的通道要挑最糙的那条)。
set -u
cd "$(dirname "$0")/../.." || exit 1
W=$(mktemp -d)
mkdir -p "$W/kmod/w103_evidence" "$W/kmod"
awk '/=== T2\.7/{f=1} /=== T3\)/{f=0} f' kmod/w161_teardown.sh > "$W/block.sh"
[ -s "$W/block.sh" ] || { echo "[x] 没能切出 T2.7 ⇒ 锚点失效"; exit 1; }
grep -q 'adb pull' "$W/block.sh" || { echo "[x] 切片里没有 adb pull ⇒ 起点锚错了"; exit 1; }
grep -q 'T2\.6\|ROOTPROBE' "$W/block.sh" && { echo "[x] 切片把 T2.6 也吞进来了 ⇒ 终点锚错了"; exit 1; }
echo "切片行数=$(wc -l < "$W/block.sh")"
fail=0

# 夹具：设备上那份 slots 的样子(28 条 CFIFIX：6 写回 / 4 不用改 / 18 其它)
make_fixture() {
    { local i
      for i in 1 2 3 4 5 6; do echo "CFIFIX __arm64_sys_openat$i 桩已写回 17bfc134(=B 本体)"; done
      for i in 1 2 3 4; do echo "CFIFIX __arm64_sys_execve$i 不用改"; done
      for i in $(seq 1 18); do echo "CFIFIX __arm64_sys_other$i 现状=未改"; done
    } > "$1"
}

run_case() { # $1=tag $2=模式
    local tag=$1 mode=$2
    : > "$W/log_$tag.txt"
    (
        cd "$W" || exit 1
        A() { echo "ADB[$1]" >> "$W/log_$tag.txt"
            case "$1" in
                *'ls -l /data/local/tmp/ksu_slots.dump.txt'*) echo '-rw-rw-rw- 1 root root 2176 2026-10-18 11:13 /data/local/tmp/ksu_slots.dump.txt' ;;
                *'head -c 16'*) [ "$mode" = noperm ] && echo 0 || echo 16 ;;
                'grep -ac CFIFIX /data/local/tmp/ksu_slots.dump.txt 2>/dev/null') echo 28 ;;
                *md5sum*) if [ "$mode" = mismatch ]; then echo 'deadbeefdeadbeefdeadbeefdeadbeef'
                          else F=$(ls "$W"/kmod/w103_evidence/w412_ksu_slots_*.txt 2>/dev/null | head -1)
                               [ -n "$F" ] && md5sum "$F" | cut -c1-32 || echo nodata; fi ;;
                *) echo STUB ;;
            esac; }
        adb() { echo "ADBRAW[$*]" >> "$W/log_$tag.txt"
            case "$1" in
                pull) D="$3"
                    case "$mode" in
                        ok|noperm|match) make_fixture "$D" ;;
                        mismatch) make_fixture "$D" ;;
                        empty) : > "$D" ;;
                        missing) : ;;
                    esac ;;
            esac; }
        source "$W/block.sh" > "$W/out_$tag.txt" 2>&1
        echo "RC=$?" > "$W/rc_$tag.txt"
    )
    echo "----- case $tag (模式=$mode) -----"
    sed 's/^/    /' "$W/out_$tag.txt"
    echo "    (rc=$(cut -d= -f2 "$W/rc_$tag.txt"))"
}
NCHK=0
chk() { NCHK=$((NCHK+1)); if [ "$2" = 1 ]; then echo "  [OK] $1"; else echo "  [BAD] $1"; fail=1; fi; }
N_EV() { ls "$W/kmod/w103_evidence" 2>/dev/null | grep -c 'w412_ksu_slots_'; }
NONEMPTY() { local f n=0
    for f in "$W"/kmod/w103_evidence/w412_ksu_slots_*.txt; do [ -s "$f" ] && n=$((n+1)); done; echo "$n"; }

run_case match ok
run_case mismatch mismatch
run_case empty empty
run_case missing missing
run_case noperm noperm

M1=$(grep -ac 'CFIFIX行=28' "$W/out_match.txt")
M2=$(grep -ac '桩已写回=6' "$W/out_match.txt")
M3=$(grep -ac '不用改=4' "$W/out_match.txt")
chk "①ok：三个计数按夹具数值打出(CFIFIX=28/写回=6/不改=4，命中 $M1/$M2/$M3)" "$([ "$M1" = 1 ] && [ "$M2" = 1 ] && [ "$M3" = 1 ] && echo 1 || echo 0)"
chk "①ok：本机那份非空(字节>0)" "$([ -n "$(ls "$W"/kmod/w103_evidence/w412_ksu_slots_*.txt 2>/dev/null)" ] && [ -s "$(ls "$W"/kmod/w103_evidence/w412_ksu_slots_*.txt | head -1)" ] && echo 1 || echo 0)"
EXP=$(ls "$W"/kmod/w103_evidence/w412_ksu_slots_*.txt 2>/dev/null | head -1)
EXP=$(md5sum "$EXP" 2>/dev/null | cut -c1-32)
# ★不"从打印出来的文案里正则把两个串抠出来再比"(例 91：派生数要现算)——自己算一份，去 grep 那整行。
chk "①ok：'两端 md5'那行两个都等于本机自己算出的 $EXP" "$(grep -aq "两端 md5：本机=$EXP 设备=$EXP" "$W/out_match.txt" && echo 1 || echo 0)"
chk "①ok：没走失败支" "$([ "$(grep -c '没 pull 到' "$W/out_match.txt")" = 0 ] && echo 1 || echo 0)"

rm -f "$W"/kmod/w103_evidence/w412_ksu_slots_*.txt
run_case mm2 mismatch
chk "②md5 不符：打出不符硬话" "$(grep -aq '两端 md5 不符' "$W/out_mm2.txt" && echo 1 || echo 0)"
chk "②md5 不符：那份坏件被删掉了(存证目录现在=0)" "$([ "$(N_EV)" = 0 ] && echo 1 || echo 0)"
chk "②md5 不符：那行里设备串＝桩给的不符值(不是被脚本吞了)" "$(grep -aq '设备=deadbeefdeadbeefdeadbeefdeadbeef' "$W/out_mm2.txt" && echo 1 || echo 0)"

run_case empty2 empty
chk "③adb 谎报成功(0 字节)：走 [x] 分支" "$(grep -aq '没 pull 到' "$W/out_empty2.txt" && echo 1 || echo 0)"
chk "③0 字节件**没留在**存证目录(空证件比没证件更坏)" "$([ "$(N_EV)" = 0 ] && echo 1 || echo 0)"

chk "④远端没这个件：走 [x] 且照样不阻断(rc=0)" "$([ "$(cut -d= -f2 "$W/rc_missing.txt")" = 0 ] && grep -aq '没 pull 到' "$W/out_missing.txt" && echo 1 || echo 0)"
chk "⑤shell 读不到(头 16 字节=0)：登记后 rc 仍=0" "$([ "$(cut -d= -f2 "$W/rc_noperm.txt")" = 0 ] && grep -aq 'shell 能读的字节数' "$W/out_noperm.txt" && echo 1 || echo 0)"
#   ★FIRE 只认**动作形**(行首的 `fire `、`WAITFOR ` 调用、`@sushd:` 派单串)，不认裸词——
#     第一版写了裸词 `sushd`，第 30 发把 `sushd.log`(一份**文件名**!)加进 T2.8 收证名单后，
#     这条断言就红在"名单里有个带 sushd 的名字"上(例 140 同族：断言数到自家文案/名字，而不是被测的动作)。
FIRE=$(grep -cE '^[[:space:]]*fire |WAITFOR |@sushd:' "$W/block.sh")
chk "⑥这条腿是 adb-only(切片里 fire/WAITFOR/sushd 命中=$FIRE，root 死了也能跑)" "$([ "$FIRE" = 0 ] && echo 1 || echo 0)"
DT=$(grep -c 'SL_TAG=$(date' "$W/block.sh")
chk "⑦文件名里的 date 只算一次(命中=$DT，且不复用 RP_TAG)" "$([ "$DT" = 1 ] && ! grep -q 'RP_TAG' "$W/block.sh" && echo 1 || echo 0)"

# ★⑧⑨⑩ **顺序要显式断言，不能只靠切片锚隐式保住**：T2.7 的意义是"删之前先 pull"，
#   而删发生在 T3 那行 rm 里 ⇒ 谁把 T3 挪到前面、或把 ksu_slots.dump.txt 从 rm 清单里漏掉，
#   这条腿就变成"要么白跑要么留跨 boot 残留"(§6.343 那一族)。三个数都现算。
#   ★⑪(#139 新加的牙)删与复证必须**同源**：rm 只引用 T3_GLOB/T3_RM 这两个变量，复证那圈也从同一对
#     变量派生；旧写法里那条手写的"残留 grep 模式串"必须不再存在(否则名单有两个生产者＝删 N 复证 M)。
L7=$(grep -an '=== T2\.7' kmod/w161_teardown.sh | cut -d: -f1)
L3=$(grep -an 'rm -f \$T3_GLOB \$T3_RM' kmod/w161_teardown.sh | cut -d: -f1)
N7=$(grep -ac '=== T2\.7' kmod/w161_teardown.sh)
N3=$(grep -ac 'rm -f \$T3_GLOB \$T3_RM' kmod/w161_teardown.sh)
NS=$(grep -ac '^T3_RM=.*ksu_slots\.dump\.txt' kmod/w161_teardown.sh)
NR=$(grep -ac 'for f in \$T3_RM \$T3_GLOB' kmod/w161_teardown.sh)
NG=$(grep -ac 'grep -aE "w16\[1-4\]' kmod/w161_teardown.sh)
chk "⑩ 两个锚点各自唯一(T2.7 标题=$N7、T3 的 rm 行=$N3)" "$([ "$N7" = 1 ] && [ "$N3" = 1 ] && echo 1 || echo 0)"
chk "⑧ 顺序承重：T2.7(第 ${L7:-无} 行) 必须早于 T3 的 rm(第 ${L3:-无} 行)" "$([ -n "$L7" ] && [ -n "$L3" ] && [ "$L7" -lt "$L3" ] && echo 1 || echo 0)"
chk "⑨ 原件确实被跨 boot 清理收走(T3_RM 名单里有 ksu_slots.dump.txt，命中=$NS)" "$([ "$NS" = 1 ] && echo 1 || echo 0)"
chk "⑪ 删与复证同源(rm 用变量=$N3／复证走同一对变量=$NR／旧的手写残留模式串已不在=$NG)" "$([ "$NR" = 1 ] && [ "$NG" = 0 ] && echo 1 || echo 0)"



[ "$fail" = 0 ] && echo "=== run_slots 自测 PASS($NCHK 项，条数由 chk 自己数) ===" || echo "=== FAIL($NCHK 项里有红) ==="
echo "临时件留在 $W(手看再删)"
