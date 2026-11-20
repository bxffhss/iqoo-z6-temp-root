#!/bin/bash
# 0 枪：补上第 63 发腿 1 里我**只跑了一遍**的那格——把「工具确定性」真正测出来。
# 做法：同一份输入(设备本 boot 导出的活策略)在 x86 上跑两遍，比三样：
#   ①两遍输出是否逐字节相同(确定性)；②与设备 arm64 那遍的输出 md5 是否相同(跨架构，§6.462 那条例外是否仍成立)；
#   ③输出大小是否仍等于输入(空 delta 的形状)。
# 判据自己说人话：任一不符就红，并把红在哪一条写清楚。
set -u
D=/home/lucy
IN=$D/pol.shot63.in
cd "$D" || { echo "!! 没有 $D"; exit 1; }
[ -s "$IN" ] || { echo "!! 输入不在($IN) ⇒ 停(先把 pol.live_1027_shot63 put 进来)"; exit 1; }
echo "输入 md5=$(md5sum $IN | cut -d' ' -f1) 字节=$(wc -c < $IN)"
echo "设备 arm64 那遍的输出 md5=93dd7c3190c5f432f386a83ede448419 (腿 1 的 S3，本仓记录)"
echo
echo "=== 1) 建 x86 那份同源工具(源码 md5 现取) ==="
echo "源 md5=$(md5sum $D/w976_rt_public.c 2>&1)"
[ -f "$D/w976_rt_public.c" ] || { echo "!! 源不在 ⇒ 停"; exit 1; }
gcc -O0 -o $D/w976_host $D/w976_rt_public.c -lsepol 2>&1 | tail -5
GCC_RC=$?
echo "gcc_rc=$GCC_RC"
[ "$GCC_RC" -eq 0 ] || { echo "!! 编不出来 ⇒ 这格记未测"; exit 1; }
file $D/w976_host | cut -c1-90
echo
echo "=== 2) 同一输入跑两遍 ==="
$D/w976_host $IN $D/rt.a.bin > $D/rt.a.log 2>&1; RA=$?
$D/w976_host $IN $D/rt.b.bin > $D/rt.b.log 2>&1; RB=$?
echo "runA_rc=$RA runB_rc=$RB"
[ -s "$D/rt.a.bin" ] && [ -s "$D/rt.b.bin" ] || { echo "!! 有输出是空的 ⇒ 判失败(0 字节不是'相同')"; exit 1; }
MA=$(md5sum $D/rt.a.bin | cut -d' ' -f1); MB=$(md5sum $D/rt.b.bin | cut -d' ' -f1)
SA=$(wc -c < $D/rt.a.bin); SB=$(wc -c < $D/rt.b.bin)
echo "A md5=$MA 字节=$SA"
echo "B md5=$MB 字节=$SB"
echo
echo "=== 3) 三条判据 ==="
if [ "$MA" = "$MB" ] && [ "$SA" = "$SB" ]; then echo "[ok] 确定性：同一输入两遍逐字节相同"; else echo "[红] 确定性破了：$MA vs $MB ($SA/$SB 字节)"; fi
if [ "$MA" = "93dd7c3190c5f432f386a83ede448419" ]; then echo "[ok] 跨架构：x86 这遍＝设备 arm64 那遍(§6.462 那条仍成立)"; else echo "[注意] 跨架构不同：x86=$MA vs arm64 设备=93dd7c3190c5f432f386a83ede448419 ⇒ 记下(不一定是坏，可能是 libsepol 版本不同)"; fi
if [ "$SA" = "$(wc -c < $IN)" ]; then echo "[ok] 空 delta 保持大小"; else echo "[红] 大小变了：$SA vs $(wc -c < $IN)"; fi
echo
echo "--- 两遍日志尾部(工具自报的那几行，给人读句子) ---"
tail -4 $D/rt.a.log; echo "==="; tail -4 $D/rt.b.log
echo DONE
