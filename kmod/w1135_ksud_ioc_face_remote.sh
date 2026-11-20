#!/bin/bash
# w1135_ksud_ioc_face_remote.sh —— #231 的一把闸(构建机上跑，0 枪)：把"真 ksud 往驱动发了哪些命令字"
#   与"我们 ko 收哪些命令字"两头**都现场算出来**再对表。
# ★为什么两头都要现算：
#   ①命令字那头(11-04)：字节扫给的是一堆没有判别力的候选；调用点反汇编才给"这条二进制真会发这个数"。
#     而调用点里绝大多数是薄封装(命令字的低半在调用它的函数里) ⇒ 必须**顺封装追一层**，否则 8 个点只能解 6 个，
#     剩下两个就被读成"没发"(例 219 那一族：拒人的闸要有"合法输入必过"的正对照；本件把正对照做成
#     `SITES_outside`＝外部独立 grep 出来的 ioctl 站点数，尺数出来必须与它相等)。
#   ②我们表那头：`_IOR('K',2,struct ksu_get_info_cmd)` 的 size＝sizeof(struct)，**必须**由编译器算。
#     ksud 发的是 0x80104b02(size 16)而不是 0x80004b02(size 0)——差的就是这一个字段；手算对齐会判错。
#   ③★"声明了"≠"有人处理"：表里 24 条命令字，dispatch.c 的 `ksu_ioctl_handlers[]` 要一条不少地都挂着 handler，
#     少一条 ksud 就打过去就是 -EINVAL。所以比三个数：探针 P() 行数 / 表行数 / dispatch 里 `.cmd =` 行数。
# ★尺不陈：每次跑都 `rm -f` 重造 asm 与 kotable，并核 ksud 两端 md5(11-03 拿 11-02 的旧 w1104_host 当新尺那一课)。
# 用法(远端 /home/lucy)：bash w1135_ksud_ioc_face_remote.sh <ksud 二进制名> <期望 md5> [<w1133.py> [<w1134.c> [<uapi 目录> [<dispatch.c>]]]]
# 输出键：KSUD_MD5= ASM= ASM_LINES= IOCTL_PLT= SITES_outside= PROBE_P= TABLE_ROWS= HANDLERS=
#         (以下转抄 w1133) SITES_ioctl= SITES_resolved= CMD_ksu= MISSING= UNRESOLVED_SITES= VERDICT=
set -u
cd /home/lucy || exit 9
BIN=${1:-ksud95}; WANT=${2:-}
PY=${3:-w1133_ksud_ioc_sites.py}; SRC=${4:-w1134_kotable_probe.c}
UAPI=${5:-/root/k/ksu/kernel/include/uapi}; DISP=${6:-/root/k/ksu/kernel/supercall/dispatch.c}
for f in "$BIN" "$PY" "$SRC" "$UAPI/supercall.h" "$DISP"; do
    [ -f "$f" ] || { echo "[x] 缺 $f"; echo VERDICT=fail; exit 8; }
done
M=$(md5sum "$BIN" | cut -d' ' -f1)
echo "KSUD_MD5=$M WANT_MD5=${WANT:-未给}"
if [ -n "$WANT" ] && [ "$M" != "$WANT" ]; then echo "[x] ksud 不是要验的那份⇒不跑"; echo VERDICT=fail; exit 8; fi
#   ★这把"尺是不是新版"的口头检查：新版才有序言正对照那几行；陈件没这几行 ⇒ 直接拒(别拿旧尺量新东西)
grep -q 'IM 里自带' "$PY" || { echo "[x] $PY 里没有序言正对照那版 ⇒ 是陈尺，拒跑"; echo VERDICT=fail; exit 8; }

rm -f kotable /home/lucy/ksud_face.asm
llvm-objdump -d "$BIN" > ksud_face.asm 2>objdump.err || { echo "[x] objdump 失败"; tail -3 objdump.err; echo VERDICT=fail; exit 7; }
echo "ASM=ksud_face.asm ASM_LINES=$(wc -l < ksud_face.asm) ASM_MD5=$(md5sum ksud_face.asm | cut -d' ' -f1)"
IOCA=$(sed -n 's/^\([0-9a-f]\{16\}\) <ioctl@plt>:/\1/p' ksud_face.asm | head -1 | sed 's/^0*//')
[ -n "$IOCA" ] || { echo "[x] 这份二进制里没有 <ioctl@plt>⇒它不走 ioctl，本闸不适用"; echo VERDICT=n/a; exit 0; }
NS=$(grep -acE "^[[:space:]]*[0-9a-f]+:([[:space:]]+[0-9a-f]{2})+[[:space:]]+(bl|b)[[:space:]]+0x${IOCA} <ioctl@plt>" ksud_face.asm)
echo "IOCTL_PLT=0x$IOCA SITES_outside=$NS"

cp "$SRC" "$UAPI/w1134_kotable.c" || { echo "[x] 拷不进 $UAPI"; echo VERDICT=fail; exit 8; }
gcc -I"$UAPI" -I"$(dirname "$UAPI")" -o kotable "$UAPI/w1134_kotable.c" 2>kotable.err \
    || { echo "[x] 编译命令表探针失败:"; head -6 kotable.err; echo VERDICT=fail; exit 7; }
./kotable > ko_ioc_table.txt 2>&1
NP=$(grep -c '^[[:space:]]*P(KSU_IOCTL_' "$SRC")
NT=$(grep -c 'dir=' ko_ioc_table.txt)
NH=$(grep -c '\.cmd = KSU_IOCTL_' "$DISP")
echo "PROBE_P=$NP TABLE_ROWS=$NT HANDLERS=$NH  (三个数必须相等：声明了却没 handler＝ksud 打过去吃 -EINVAL)"
[ "$NP" = "$NT" ] && [ "$NT" = "$NH" ] || { echo "[x] 命令表/ handler 数不齐⇒这一格不结论"; echo VERDICT=fail; exit 7; }

python3 "$PY" ksud_face.asm "$NS" ko_ioc_table.txt > ksud_face.out 2>&1
K=$?
grep -aE '^(ASM=|SITES_ioctl=|SITES_resolved=|CMD_total=|KO_TABLE=|SELFTEST=|UNRESOLVED_SITES=|VERDICT=|CMD 0x)' ksud_face.out | sed 's/^/  /'
[ "$K" = 0 ] || { echo "[x] w1133 rc=$K"; echo VERDICT=fail; exit 7; }
g() { sed -n "s/.*$1=\([0-9]*\).*/\1/p" ksud_face.out | head -1; }
SI=$(g SITES_ioctl); SR=$(g SITES_resolved); UR=$(g UNRESOLVED_SITES); MI=$(sed -n 's/^KO_TABLE=[0-9]* KSU_TYPE=[0-9]* MATCH=\([0-9]*\) MISSING=\([0-9]*\).*/\2/p' ksud_face.out | head -1)
MA=$(sed -n 's/^KO_TABLE=[0-9]* KSU_TYPE=[0-9]* MATCH=\([0-9]*\).*/\1/p' ksud_face.out | head -1)
grep -aq '^SELFTEST=ok' ksud_face.out || { echo "[x] 尺自己没牙(SELFTEST 不 ok)⇒不结论"; echo VERDICT=fail; exit 7; }
V=ok
[ "${UR:-x}" = 0 ] || V=fail-有取不到的点
[ "${SR:-x}" = "${SI:-y}" ] || V=fail-站点没全解开
[ "${MI:-x}" = 0 ] || V=fail-表里缺命令字
echo "SUMMARY sites=$SI resolved=$SR unresolved=$UR matched=$MA missing=$MI table=$NT handlers=$NH"
echo "VERDICT=$V (ok＝$SI 个 ioctl 调用点全解开、$MA 条命令字全在我们 $(echo $NT) 行的表里、且表里每条都挂着 handler)"
[ "$V" = ok ] || exit 6
exit 0
