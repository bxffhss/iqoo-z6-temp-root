#!/bin/bash
# w1119_tmap_roundtrip.sh —— #232 的前置闸（**0 枪**，只在构建机上跑）：
#   证"读→写→再读"对那张**按位置**对的 type_attr_map 是恒等的，再谈往 type 表插新类型。
#   ★为什么这一格非过不可：93/94 两发的判据都是 avtab 三元组差分，而"符号表写出次序 ≠ value 升序"造成的
#     **整表集体错位**不会出现在三元组差分里 ⇒ 拿旧判据当"往返没问题"是借位。这张表要自己的证人。
#   形状：本机先过离线总闸 → 现算 w1104_delta.c 的 md5 → 推(源码／远端半支／厂商 pol.orig) →
#     远端编 x86 新件 w1104_v3(**不覆盖 w1104_host**) → 新旧两件 dump 必须逐行相同(证明加模式没改坏老路径) →
#     rt 往返 → tmap 前后各一份 → 逐行差 0，且这把尺先在"明知被改过的一份"上证明**有牙**。
#   判读（写死，不许互相顶替）：
#     TMAP_DIFF=0(逐行) ＋ RT_VS_ORIG_DUMP=0(三元组) ＋ CTRL_TEETH>=1(这把尺有牙) ＋ OLD_DUMP_VS_NEW=0(加模式没改坏老路径)
#       ⇒ 往返对这两张表都是恒等 ⇒ #232 可以往下写插新类型；
#     TMAP_DIFF>0 ⇒ 往返**会**动那张按位置对的表 ⇒ #232 判死（插新类型前必须先解决次序问题），不许靠"再加一次 delta"掩盖；
#     RT_VS_ORIG_DUMP>0 ⇒ 连 avtab 三元组都不恒等 ⇒ 停在语义层；
#     CTRL_TEETH=0 ⇒ 这把尺没牙 ⇒ 这一格记**未测**，不算通过也不算失败；
#     BUILD=失败 ⇒ 我写的新代码不合法＝**结论**（不是环境问题），修源码再来。
#   ★口径修正(这一发现学到)：往返后**字节数相同、md5 不同** ⇒ "空 delta 逐字节相同"在这份导出上不成立；
#     语义尺一律用结构(dump 三元组／逐行表)，md5 只用来证"两端是同一件"，不当语义证人。
#   ★不碰设备、不开窗、不写 /sys/fs/selinux/load。
set -u
cd "$(dirname "$0")/.." || exit 1
EV=kmod/w103_evidence
RM_CLI=hermes-remote1/cli.py; RM_CFG=hermes-remote1/config.json
REXEC() { HRMT_CLI=$RM_CLI W682_T=240 PYTHONUTF8=1 python kmod/w682_rr.py "$1" 2>&1 | tr -d '\r'; }
RPUSH() { HRMT_CLI=$RM_CLI python $RM_CLI --config $RM_CFG put "$1" "$2" 2>&1 | tail -1; }
RGET()  { HRMT_CLI=$RM_CLI python $RM_CLI --config $RM_CFG get  "$1" "$2" 2>&1 | tail -1; }
A() { adb shell "$1" 2>&1 | tr -d '\r'; }
if [ -n "${MSYS_NO_PATHCONV+set}" ]; then echo "[x] MSYS_NO_PATHCONV 被定义了(哪怕空值) ⇒ 拒跑(见例 218)"; exit 3; fi

CSRC=kmod/w1104_delta.c; RSRC=kmod/w1120_tmap_verify_remote.sh; POLFILE=kmod/w103_evidence/w1117_pol.orig_94
VENDOR=282a68611a2f36321a153fc0102f9ca0; VBYTES=1356948

echo "[1/4] 离线总闸(现跑)＋陈旧源码闸"
PYTHONUTF8=1 bash kmod/w413_selftest_sweep.sh > $EV/w413_console_latest.txt 2>&1
W=$?; tail -2 $EV/w413_console_latest.txt; [ "$W" = 0 ] || { echo "[x] 总闸 rc=$W ⇒ 先补前置，不跑这一发"; exit 1; }
STALE=$(find kmod analysis cm57 -type f \( -name '*.sh' -o -name '*.c' -o -name '*.py' -o -name '*.md' \) -not -path '*/w103_evidence/*' -newer $EV/w413_console_latest.txt 2>/dev/null)
[ -n "$STALE" ] && { echo "[x] 有源码比绿闸新 ⇒ 拒跑:"; printf '%s\n' "$STALE" | sed 's/^/      /'; exit 1; }

echo "[2/4] 三件本机的现值(不背历史)"
SM=$(md5sum $CSRC | cut -d' ' -f1); RM=$(md5sum $RSRC | cut -d' ' -f1)
PM=$(md5sum $POLFILE | cut -d' ' -f1); PB=$(wc -c < $POLFILE)
echo "  w1104_delta.c md5=$SM ($(wc -l < $CSRC) 行)／远端半支 md5=$RM"
echo "  pol.orig=$PB B md5=$PM (厂商件应＝$VENDOR/$VBYTES)"
[ "$PM" = "$VENDOR" ] && [ "$PB" = "$VBYTES" ] || { echo "[x] 这份 pol.orig 不是厂商此刻正生效那件 ⇒ 换凭据，不跑"; exit 1; }
grep -ac 'dump_type_attr_map' $CSRC | sed 's/^/  源码里 dump_type_attr_map 出现次数(期望=2：定义＋调用)：/'
grep -ac 'strcmp(argv\[1\], "tmap")' $CSRC | sed 's/^/  源码里 tmap 分派(期望=1)：/'

echo "[3/4] 推三件(本地绝对路径／远端裸名)＋远端编件并跑往返"
RPUSH "$CSRC"    w1104_src_tmap.c            | sed 's/^/  put src: /'
RPUSH "$RSRC"    w1120_verify_remote.sh      | sed 's/^/  put leg: /'
RPUSH "$POLFILE" pol.tmap                    | sed 's/^/  put pol: /'
OUT=$(REXEC "cd /home/lucy; bash w1120_verify_remote.sh w1104_src_tmap.c $SM pol.tmap")
echo "$OUT" | grep -aE '^(SRC_MD5_LOCAL|LIB_MEMBER|BUILD|OLD_DUMP_VS_NEW|TRAILER_|TROWS_|MD5 |BYTES|BYTE_DIFF|RT_VS_ORIG_DUMP|CTRL_TEETH|TMAP_DIFF|TMAP_VERDICT|TMAP_BEFORE|TMAP_AFTER|RT)' | sed 's/^/    /'
echo "$OUT" | grep -a '^  D ' | head -12 | sed 's/^/    /'
echo "$OUT" > $EV/w1119_tmap_roundtrip.txt

echo "[4/4] 取回两张表当证件(各 ~3.6k 行)＋判读"
RGET tmap_before.txt "$EV/w1119_tmap_before.txt" | sed 's/^/  get before: /'
RGET tmap_after.txt  "$EV/w1119_tmap_after.txt"  | sed 's/^/  get after:  /'
for f in $EV/w1119_tmap_before.txt $EV/w1119_tmap_after.txt; do
    echo "  $f 行数=$(wc -l < $f 2>/dev/null) 本机再算逐行差=$(diff $EV/w1119_tmap_before.txt $EV/w1119_tmap_after.txt 2>/dev/null | grep -ac '^[<>]')"
done
V=$(echo "$OUT" | sed -n 's/^TMAP_VERDICT=//p'); D=$(echo "$OUT" | sed -n 's/^TMAP_DIFF=\([0-9]*\).*/\1/p')
C=$(echo "$OUT" | sed -n 's/^CTRL_TEETH=\([0-9]*\).*/\1/p'); O=$(echo "$OUT" | sed -n 's/^OLD_DUMP_VS_NEW=\([0-9]*\).*/\1/p')
R=$(echo "$OUT" | sed -n 's/^RT_VS_ORIG_DUMP=\([0-9]*\).*/\1/p'); BY=$(echo "$OUT" | sed -n 's/^BYTE_DIFF=\([0-9]*\).*/\1/p')
echo "  六把现值：TMAP_VERDICT=[$V] TMAP_DIFF=[$D] CTRL_TEETH=[$C] OLD_DUMP_VS_NEW=[$O] RT_VS_ORIG_DUMP=[$R] BYTE_DIFF=[$BY]"
if [ "$V" != ok ] || [ -z "$D" ] || [ -z "$C" ] || [ -z "$R" ]; then
    echo "[x] 判读没拿到齐的尺(见 $EV/w1119_tmap_roundtrip.txt 上面抄出的行)⇒ BUILD/RT/TMAP_* 哪一步红就补哪一步；这一格记**未测**"
    exit 1
elif [ "$C" = 0 ]; then
    echo "[!] 这把尺没牙(正对照=0)⇒ 这一格记**未测**，不算通过也不算失败；先修尺"
    exit 1
elif [ "$D" != 0 ]; then
    echo "[x] TMAP_DIFF=$D>0 ⇒ 往返**会**动这张表(集体错位的风险是真的)⇒ #232 判死：先把符号表写出次序的问题解决掉"
    exit 1
elif [ "$R" != 0 ]; then
    echo "[x] RT_VS_ORIG_DUMP=$R>0 ⇒ 往返**会**动 avtab 三元组 ⇒ 语义都不恒等，#232 停在这一步"
    exit 1
else
    echo "★判正：往返对 type_attr_map 逐行恒等、对 avtab 三元组恒等，且这把尺先在改动件上证明过有牙 ⇒ #232 可以往下写插新类型"
    echo "  附一(老路径有没有被加模式改坏)：OLD_DUMP_VS_NEW=[$O] ⇒ $( [ "$O" = 0 ] && echo 没改坏 || echo '不是 0，先看 D_ 两份差在哪' )"
    echo "  附二(口径修正)：字节级 BYTE_DIFF=[$BY] ⇒ md5 **不等**于「没改坏」；今后往返的判据用这两把结构尺(TMAP_DIFF／RT_VS_ORIG_DUMP)，不许再用 md5 相同当语义尺"
fi
echo "证件：$EV/w1119_tmap_roundtrip.txt $EV/w1119_tmap_{before,after}.txt"
